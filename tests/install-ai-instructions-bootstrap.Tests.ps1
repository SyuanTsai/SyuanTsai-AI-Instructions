$script:InstallScript = Join-Path $PSScriptRoot '..\scripts\install-ai-instructions-bootstrap.ps1'
$script:InstalledBootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions-installed.ps1'

function New-InstallerSourceArchive {
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [switch] $Unrelated
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $ArchivePath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $stream = [System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            if ($Unrelated) {
                $entry = $archive.CreateEntry('unrelated-root/README.md')
                $writer = New-Object System.IO.StreamWriter($entry.Open(),(New-Object System.Text.UTF8Encoding($false)))
                try { $writer.Write("# Unrelated archive fixture`n") }
                finally { $writer.Dispose() }
            }
            else {
                $sourceRootPath = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\','/'))
                foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $sourceRootPath 'scripts'),(Join-Path $sourceRootPath 'catalog') -Recurse -File | Sort-Object FullName)) {
                    $relativePath = $file.FullName.Substring($sourceRootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                    $entry = $archive.CreateEntry("candidate-root/$relativePath")
                    $input = [System.IO.File]::OpenRead($file.FullName)
                    $output = $entry.Open()
                    try { $input.CopyTo($output) }
                    finally { $output.Dispose(); $input.Dispose() }
                }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    return (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-InstallScript {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [string[]] $ExcludedRepositoryUrls = @(),
        [string[]] $ExcludedRepositoryPaths = @()
    )

    $sourceCommit = (@(& git -C $RepositoryRoot rev-parse HEAD) -join '').Trim()
    $archivePath = Join-Path (Split-Path -Parent $CodexHome) ((Split-Path -Leaf $CodexHome) + '-source.zip')
    $archiveSha256 = New-InstallerSourceArchive -SourceRoot $RepositoryRoot -ArchivePath $archivePath
    $arguments = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,
        '-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome,
        '-Acquisition','github-codeload',
        '-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
        '-SourceCommit',$sourceCommit,
        '-ArchiveSha256',$archiveSha256,
        '-SourceArchivePath',$archivePath
    )
    if ($ExcludedRepositoryUrls.Count -gt 0) {
        $arguments += '-ExcludedRepositoryUrls'
        foreach ($repositoryUrl in $ExcludedRepositoryUrls) { $arguments += $repositoryUrl }
    }
    if ($ExcludedRepositoryPaths.Count -gt 0) {
        $arguments += '-ExcludedRepositoryPaths'
        foreach ($repositoryPath in $ExcludedRepositoryPaths) { $arguments += $repositoryPath }
    }

    $output = & powershell.exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Install script failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-InstallExpectFailure {
    param(
        [string]$RepositoryRoot,
        [string]$CodexHome,
        [switch]$GitCheckout,
        [switch]$InvalidArchiveHash,
        [switch]$UnrelatedArchive,
        [string]$ExpectedCurrentCommit,
        [string]$ExpectedUpdateMode,
        [string]$ExpectedUpdateChannel,
        [string]$ExpectedUpdateRef
    )
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome)
    if (-not $GitCheckout) {
        $sourceCommit = (@(& git -C $RepositoryRoot rev-parse HEAD) -join '').Trim()
        $archivePath = Join-Path (Split-Path -Parent $CodexHome) ((Split-Path -Leaf $CodexHome) + '-source.zip')
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $RepositoryRoot -ArchivePath $archivePath -Unrelated:$UnrelatedArchive
        if ($InvalidArchiveHash) { $archiveSha256 = ('0' * 64) }
        $arguments += @(
            '-Acquisition','github-codeload',
            '-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-SourceArchivePath',$archivePath
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit)) { $arguments += @('-ExpectedCurrentCommit',$ExpectedCurrentCommit) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUpdateMode)) { $arguments += @('-ExpectedUpdateMode',$ExpectedUpdateMode) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUpdateChannel)) { $arguments += @('-ExpectedUpdateChannel',$ExpectedUpdateChannel) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUpdateRef)) { $arguments += @('-ExpectedUpdateRef',$ExpectedUpdateRef) }
    $output = & powershell.exe @arguments 2>&1
    return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($output -join [Environment]::NewLine) }
}

function Set-TestText {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-TestJson {
    param([string]$Path,[object]$Document)
    Set-TestText -Path $Path -Value (($Document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n")
}

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

    # Scenario: A clean Codex Home installs the verified multi-source runtime for the first time.
    # Purpose: Materialize all stable commands and runtime files without restoring SessionStart execution.
    It 'InterT05_installs_the_multi_source_runtime_without_creating_a_SessionStart_hook' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Test-Path -LiteralPath $installedHookScript | Should Be $true
        (Get-Content -Raw -LiteralPath $installedHookScript) | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)

        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        foreach ($relativePath in @(
            'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
            'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
            'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
            'ai-instructions-runtime-contract.psm1','ai-instructions-updater.psm1','update-ai-instructions.ps1',
            'cleanup-ai-instructions-pollution.ps1',
            'runtime-bundle.json','catalog\skills-catalog.json','catalog\skills-catalog-lock.json'
        )) {
            Test-Path -LiteralPath (Join-Path $runtimeRoot $relativePath) | Should Be $true
        }

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $bundle = Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 4
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryUrls') | Should Be $false
        @($configuration.excludedRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryPaths).Count | Should Be 0
        [string]$configuration.catalog.repository | Should Match '^https://github\.com/.+/.+\.git$'
        [string]$configuration.catalog.ref | Should Match '^[0-9a-f]{40}$'
        [string]$bundle.repository | Should Be ([string]$configuration.catalog.repository)
        [string]$bundle.commit | Should Be ([string]$configuration.catalog.ref)
        $bundle.schemaVersion | Should Be 2
        [string]$bundle.acquisition | Should Be 'github-codeload'
        [string]$bundle.archiveSha256 | Should Match '^[0-9a-f]{64}$'
        [string]$bundle.inventorySha256 | Should Match '^[0-9a-f]{64}$'
        @($bundle.inventory).Count | Should BeGreaterThan 10
        @($configuration.catalog.profiles) | Should Be @('core')
        @($configuration.catalog.includeSkills).Count | Should Be 0
        @($configuration.catalog.excludeSkills).Count | Should Be 0
        [string]$configuration.updates.mode | Should Be 'notify-only'
        [string]$configuration.updates.channel | Should Be 'protected-branch'
        [string]$configuration.updates.ref | Should Be 'main'
        [int]$configuration.updates.minimumCheckIntervalMinutes | Should Be 1440
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1') | Should Be $true

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Repository Instructions Bootstrap'
        $agents | Should Match 'production code'
        $agents | Should Match '問問題'
        $agents | Should Not Match 'SessionStart'
        $agents | Should Match 'excludedRepositoryUrls'
        $agents | Should Match 'excludedRepositoryPaths'
        $agents | Should Match 'Agent Skills'
        $agents | Should Match 'customized or unmanaged Instructions or Agent Skills'
        $agents | Should Match '所有 branch 共用的個人 runtime artifacts'
        $agents | Should Match '不得自動 stage、commit 或 push'
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks.json') | Should Be $false
    }

    # Scenario: A prior installation left an outdated stable bootstrap launcher.
    # Purpose: Replace installer-owned launcher bytes with the verified candidate version.
    It 'InterT15_overwrites_a_stale_bootstrap_hook_with_the_installed_launcher' {
        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestText -Path $installedHookScript -Value "git stash push --include-untracked --quiet -m PersonalAgent -- AGENTS.md`n"
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $installedHook = Get-Content -Raw -LiteralPath $installedHookScript
        $installedHook | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)
        $installedHook | Should Match 'runtime-bundle\.json'
        $installedHook | Should Not Match "'stash', 'push', '--include-untracked'"
    }

    # Scenario: Codex Home contains personal Agent content and unrelated hooks beside a legacy bootstrap SessionStart entry.
    # Purpose: Remove only installer-owned legacy activation while preserving independent user configuration.
    It 'InterT20_preserves_personal_content_and_unrelated_hooks_while_removing_bootstrap_SessionStart' {
        Set-TestText -Path (Join-Path $codexHome 'AGENTS.md') -Value @'
# Personal Codex Rules

Keep this personal note.

## Repository Instructions Bootstrap

old bootstrap text

## Other Rules

Keep this section too.
'@
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{
  "hooks": {
    "SessionStart": [
      {"matcher":"startup","hooks":[{"type":"command","command":"powershell.exe -File \"C:\\old\\bootstrap-ai-instructions.ps1\""}]},
      {"matcher":"other","hooks":[{"type":"command","command":"powershell.exe -File \"C:\\keep\\other.ps1\""}]}
    ],
    "Stop": [{"matcher":"keep-stop","hooks":[]}]
  }
}
'@
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Keep this personal note'
        $agents | Should Match 'Keep this section too'
        $agents | Should Not Match 'old bootstrap text'
        ([regex]::Matches($agents, 'Repository Instructions Bootstrap')).Count | Should Be 1
        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        @($hooks.hooks.SessionStart | Where-Object { @($_.hooks | Where-Object { $_.command -match 'bootstrap-ai-instructions\.ps1' }).Count -gt 0 }).Count | Should Be 0
        @($hooks.hooks.Stop).Count | Should Be 1
    }

    # Scenario: One SessionStart entry contains both the obsolete bootstrap command and an unrelated personal command.
    # Purpose: Remove only the obsolete hook instead of deleting the user's unrelated hook from the same entry.
    It 'InterT22_preserves_unrelated_hooks_inside_a_mixed_SessionStart_entry' {
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {"type":"command","command":"powershell.exe -File \"C:\\old\\bootstrap-ai-instructions.ps1\""},
          {"type":"command","command":"powershell.exe -File \"C:\\keep\\personal-startup.ps1\""}
        ]
      }
    ]
  }
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        @($hooks.hooks.SessionStart[0].hooks).Count | Should Be 1
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Match 'personal-startup\.ps1'
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Not Match 'bootstrap-ai-instructions\.ps1'
    }

    # Scenario: SessionStart contains only the obsolete bootstrap command.
    # Purpose: Remove the now-empty hook category instead of leaving background bootstrap behavior.
    It 'InterT25_removes_SessionStart_when_the_legacy_bootstrap_is_its_only_entry' {
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","commandWindows":"powershell.exe -File \"C:\\old\\bootstrap-ai-instructions.ps1\""}]}]}}
'@
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        ($hooks.hooks.PSObject.Properties.Name -contains 'SessionStart') | Should Be $false
    }

    # Scenario: Installer encounters a legacy configuration with obsolete routing and auto-commit properties.
    # Purpose: Preserve exclusions while producing strict schema v4 with no commit authority.
    It 'InterT30_migrates_legacy_configuration_to_schema_version_4_without_auto_commit_state' {
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value @'
{
  "schemaVersion": 1,
  "autoCommitRepositoryUrls": ["git@example.com:team/old-project.git"],
  "autoCommitRepositoryPaths": ["C:\\Local\\Project"],
  "repositoryUrls": ["https://example.com/team/second-project.git"],
  "excludedRepositoryUrls": ["git@example.com:team/planning-only.git"],
  "excludedRepositoryPaths": ["docs/architecture-planning"]
}
'@
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome `
            -ExcludedRepositoryUrls @('https://example.com/team/architecture-only.git') `
            -ExcludedRepositoryPaths @('design/planning-only')

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 4
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryUrls') | Should Be $false
        ($configuration.PSObject.Properties.Name -contains 'repositoryUrls') | Should Be $false
        @($configuration.excludedRepositoryUrls).Count | Should Be 2
        @($configuration.excludedRepositoryPaths).Count | Should Be 2
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryPaths') | Should Be $false
        @($configuration.catalog.profiles) | Should Be @('core')
        $configuration.updates.mode | Should Be 'notify-only'
    }

    # Scenario: A valid schema-v4 installation is refreshed to a newer canonical bundle commit.
    # Purpose: Advance the immutable pin while preserving the user's Skill selection and update policy.
    It 'InterT35_preserves_schema_v4_selections_and_update_policy_while_advancing_the_same_bundle_pin' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        $configuration.catalog.profiles = @('observability')
        $configuration.catalog.includeSkills = @('work-with-jira')
        $configuration.catalog.excludeSkills = @('search-with-felo')
        $configuration.updates.mode = 'auto-install-approved'
        $configuration.updates.minimumCheckIntervalMinutes = 60
        Set-TestJson -Path $configurationPath -Document $configuration

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $updated = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $expectedHead = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        [string]$updated.catalog.ref | Should Be $expectedHead
        @($updated.catalog.profiles) | Should Be @('observability')
        @($updated.catalog.includeSkills) | Should Be @('work-with-jira')
        @($updated.catalog.excludeSkills) | Should Be @('search-with-felo')
        [string]$updated.updates.mode | Should Be 'auto-install-approved'
        [int]$updated.updates.minimumCheckIntervalMinutes | Should Be 60
    }

    # Scenario: An existing schema-v4 configuration was manually changed to a mutable Catalog ref.
    # Purpose: Fail before installation mutation rather than normalizing an untrusted bundle identity.
    It 'InterT37_rejects_a_mutable_schema_v4_bundle_ref_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = 'main'
        Set-TestJson -Path $configurationPath -Document $configuration
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $hookBefore = Get-Content -Raw -LiteralPath $hookPath
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'catalog.ref must be a full lowercase 40-character commit SHA'
        (Get-Content -Raw -LiteralPath $hookPath) | Should Be $hookBefore
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: Existing personal configuration declares a future schema unknown to this installer.
    # Purpose: Fail closed before replacing any active runtime or configuration bytes.
    It 'InterT40_rejects_unknown_configuration_schema_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value '{"schemaVersion":99,"excludedRepositoryUrls":[],"excludedRepositoryPaths":[]}'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Unsupported AI instruction sync configuration schemaVersion'
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: An existing schema-v4 configuration points at a noncanonical bundle repository.
    # Purpose: Preserve the single canonical trust boundary before any active runtime replacement.
    It 'InterT42_rejects_a_schema_v4_bundle_repository_from_another_repo' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.repository = 'https://github.com/example/other-ai-instructions.git'
        Set-TestJson -Path $configurationPath -Document $configuration
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'accepts only the canonical repository'
    }

    # Scenario: A supplied codeload archive does not match its declared immutable SHA-256.
    # Purpose: Reject altered download bytes before any Codex Home mutation.
    It 'InterT43_rejects_a_codeload_archive_hash_mismatch_before_mutating_CodexHome' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -InvalidArchiveHash

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'SourceArchivePath SHA-256 does not match'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: A caller pairs a valid canonical commit and archive hash with an unrelated local RepositoryRoot.
    # Purpose: Bind github-codeload provenance to the archive bytes that actually supply the installed runtime.
    It 'InterT44_rejects_a_codeload_archive_that_does_not_supply_the_runtime_sources' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -UnrelatedArchive

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'archive.*runtime source|runtime source.*archive'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: Git-checkout installation sources differ from their immutable HEAD commit.
    # Purpose: Prevent uncommitted local bytes from entering the trusted Codex Home runtime.
    It 'InterT45_rejects_dirty_installer_runtime_sources_before_mutating_CodexHome' {
        $cloneRoot = Join-Path $TestDrive 'dirty-source'
        $origin = (@(& git -C $repositoryRoot remote get-url origin) -join '').Trim()
        & git clone --quiet $repositoryRoot $cloneRoot
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create installer source clone.' }
        & git -C $cloneRoot remote set-url origin $origin
        if ($LASTEXITCODE -ne 0) { throw 'Failed to reset installer source clone origin.' }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\install-ai-instructions-bootstrap.ps1') -Destination (Join-Path $cloneRoot 'scripts\install-ai-instructions-bootstrap.ps1') -Force
        foreach ($fileName in @(
            'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1',
            'safe-zip.psm1','skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
            'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
            'ai-instructions-runtime-contract.psm1','ai-instructions-updater.psm1','update-ai-instructions.ps1',
            'cleanup-ai-instructions-pollution.ps1'
        )) {
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$fileName") -Destination (Join-Path $cloneRoot "scripts\$fileName") -Force
        }
        & git -C $cloneRoot add -- scripts
        & git -C $cloneRoot -c user.name='Installer Test' -c user.email='installer@example.test' commit --quiet --allow-empty -m 'installer fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to commit installer source fixture.' }
        $executionEvidence = Join-Path $TestDrive 'dirty-contract-executed.txt'
        [System.IO.File]::AppendAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1'),
            "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n"
        )

        $result = Invoke-InstallExpectFailure -RepositoryRoot $cloneRoot -CodexHome $codexHome -GitCheckout
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'differ from HEAD'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: A malformed codeload candidate fails during staged PowerShell validation.
    # Purpose: Remove all staging and backup directories when failure occurs before active runtime mutation.
    It 'InterT46_cleans_transaction_directories_after_staging_validation_failure' {
        $invalidSource = Join-Path $TestDrive 'invalid-staging-source'
        & git clone --quiet $repositoryRoot $invalidSource
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create invalid staging source clone.' }
        [System.IO.File]::AppendAllText((Join-Path $invalidSource 'scripts\skills-selection.psm1'), "`nfunction Invalid-StagingFixture {`n")

        $result = Invoke-InstallExpectFailure -RepositoryRoot $invalidSource -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'PowerShell parse error'
        @(Get-ChildItem -LiteralPath $codexHome -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.ai-instructions-install-*' -or $_.Name -like '.ai-instructions-backup-*' }).Count | Should Be 0
    }

    # Scenario: Another installer owns the per-Codex-Home installation transaction lock.
    # Purpose: Prevent concurrent runtime swaps and rollback from overwriting a successful installation.
    It 'InterT47_refuses_installation_while_the_install_lock_is_held' {
        New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
        $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $lockStream = [System.IO.File]::Open($installLockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        }
        finally {
            $lockStream.Dispose()
        }

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'another AI instructions installer is already running'
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\ai-instructions-runtime') | Should Be $false
    }

    # Scenario: The installed runtime changes after updater candidate selection but before the installer acquires its lock.
    # Purpose: Refuse a stale candidate transaction instead of overwriting a newer or divergent installed runtime.
    It 'InterT48_revalidates_the_expected_current_commit_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -ExpectedCurrentCommit ('0' * 40)

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'installed runtime changed before installation'
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: The active runtime keeps the expected commit string but one inventory file drifts before install lock acquisition.
    # Purpose: Revalidate the complete active state, not only attacker-controllable bundle metadata, before candidate swap.
    It 'InterT48b_revalidates_the_complete_active_runtime_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $expectedCommit = [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json).commit
        $runtimeFile = Join-Path $runtimeRoot 'skills-selection.psm1'
        [System.IO.File]::AppendAllText($runtimeFile,"`n# drift before installer lock`n")
        $driftedBytes = Get-Content -Raw -LiteralPath $runtimeFile

        $result = Invoke-InstallExpectFailure `
            -RepositoryRoot $repositoryRoot `
            -CodexHome $codexHome `
            -ExpectedCurrentCommit $expectedCommit

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'installed runtime changed before installation'
        $result.Output | Should Match 'inventory'
        (Get-Content -Raw -LiteralPath $runtimeFile) | Should Be $driftedBytes
    }

    # Scenario: A stable Codex Home script path is already an unrelated user directory.
    # Purpose: Fail before mutation rather than copying into or deleting a path whose type proves it is not installer-owned.
    It 'InterT49_rejects_an_unsafe_existing_directory_at_a_stable_file_path' {
        $unsafePath = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        New-Item -ItemType Directory -Force -Path $unsafePath | Out-Null
        Set-TestText -Path (Join-Path $unsafePath 'personal.txt') -Value "preserve me`n"

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'unsafe installer mutation path'
        Test-Path -LiteralPath $unsafePath -PathType Container | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $unsafePath 'personal.txt')) | Should Be "preserve me`n"
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

    # Scenario: A late hooks-file validation failure occurs after active installer mutation begins.
    # Purpose: Restore launcher, runtime, configuration, Agent, and hook bytes as one transaction.
    It 'InterT50_rolls_back_runtime_config_and_agent_files_when_a_late_install_step_fails' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $agentsPath = Join-Path $codexHome 'AGENTS.md'
        $hookBefore = Get-Content -Raw -LiteralPath $hookPath
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath
        $configurationBefore = Get-Content -Raw -LiteralPath $configurationPath
        $agentsBefore = Get-Content -Raw -LiteralPath $agentsPath
        $badHooks = '{not-json'
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value $badHooks

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'hooks file is not valid JSON'
        (Get-Content -Raw -LiteralPath $hookPath) | Should Be $hookBefore
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
        (Get-Content -Raw -LiteralPath $configurationPath) | Should Be $configurationBefore
        (Get-Content -Raw -LiteralPath $agentsPath) | Should Be $agentsBefore
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json')) | Should Be $badHooks
    }

    # Scenario: Auto-install approval is revoked after candidate acquisition but before the installer takes its lock.
    # Purpose: Revalidate opt-in policy before any runtime, launcher, configuration, Agent, or hook mutation.
    It 'InterT52_revalidates_expected_update_policy_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.updates.mode = 'auto-install-approved'
        Set-TestJson -Path $configurationPath -Document $configuration
        $expectedCurrentCommit = [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json).commit
        $configuration.updates.mode = 'notify-only'
        Set-TestJson -Path $configurationPath -Document $configuration
        $configurationBefore = Get-Content -Raw -LiteralPath $configurationPath
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome `
            -ExpectedCurrentCommit $expectedCurrentCommit `
            -ExpectedUpdateMode 'auto-install-approved' `
            -ExpectedUpdateChannel 'protected-branch' `
            -ExpectedUpdateRef 'main'

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'update policy changed before installation'
        (Get-Content -Raw -LiteralPath $configurationPath) | Should Be $configurationBefore
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    # Scenario: The installed configuration pin is changed without replacing the runtime bundle.
    # Purpose: Make the stable launcher reject mixed configuration/runtime identity before bootstrap.
    It 'InterT55_installed_launcher_rejects_a_runtime_bundle_pin_mismatch' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('f' * 40)
        Set-TestJson -Path $configurationPath -Document $configuration
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>&1
        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime bundle does not match'
    }

    # Scenario: One installed runtime module is changed after its bundle inventory was created.
    # Purpose: Stop the stable launcher before executing any tampered runtime code.
    It 'InterT60_installed_launcher_rejects_runtime_inventory_tampering_before_execution' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-runtime-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-contract-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A user runs the stable manual updater after an installed runtime module is tampered.
    # Purpose: Reuse trusted launcher preflight before importing any runtime updater code.
    It 'InterT61_manual_updater_preflights_runtime_before_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-updater.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-updater-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome -ForceCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A user runs the stable cleanup command after its runtime contracts are tampered.
    # Purpose: Refuse cleanup before importing or executing the unverified contract modules.
    It 'InterT61b_cleanup_command_preflights_runtime_before_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\skills-catalog-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-cleanup-contract-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $cleanupCommand = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cleanupCommand -TargetRoot $repositoryRoot -Authorize 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: The stable launcher bytes drift from the reference copy covered by the active runtime inventory.
    # Purpose: Detect an interrupted mixed-version install before update or target bootstrap code executes.
    It 'InterT62_installed_launcher_rejects_stable_launcher_version_drift' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [System.IO.File]::AppendAllText($hookPath,"`n# stable launcher drift`n")

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stable launcher does not match'
    }
}
