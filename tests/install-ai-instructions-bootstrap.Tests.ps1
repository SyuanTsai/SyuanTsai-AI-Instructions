$script:InstallScript = Join-Path $PSScriptRoot '..\scripts\install-ai-instructions-bootstrap.ps1'
$script:InstalledBootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions-installed.ps1'
$script:TestPowerShellExecutable = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })

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

    $output = & $script:TestPowerShellExecutable @arguments 2>&1
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
    $output = & $script:TestPowerShellExecutable @arguments 2>&1
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

    # Scenario: Codex uses its default home because CODEX_HOME is not set when an Agent follows the installed bootstrap instruction.
    # Purpose: Keep the generated instruction executable for the installer's supported $HOME/.codex fallback instead of resolving a root-level hooks path.
    It 'InterT07_installed_bootstrap_instruction_supports_the_default_Codex_Home' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match ([regex]::Escape("[string]::IsNullOrWhiteSpace(`$env:CODEX_HOME)"))
        $agents | Should Match ([regex]::Escape("Join-Path `$HOME '.codex'"))
        $agents | Should Match ([regex]::Escape("Join-Path `$codexHome 'hooks\bootstrap-ai-instructions.ps1'"))
        $agents | Should Not Match ([regex]::Escape('$CODEX_HOME/hooks/bootstrap-ai-instructions.ps1'))
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
        $installedBootstrapHook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{
            hooks = [ordered]@{
                SessionStart = @(
                    [ordered]@{matcher='startup';hooks=@([ordered]@{type='command';command="powershell.exe -File `"$installedBootstrapHook`""})},
                    [ordered]@{matcher='other';hooks=@([ordered]@{type='command';command='powershell.exe -File "C:\keep\other.ps1"'})}
                )
                Stop = @([ordered]@{matcher='keep-stop';hooks=@()})
            }
        })
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
        $installedBootstrapHook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{
            hooks = [ordered]@{
                SessionStart = @([ordered]@{
                    matcher = 'startup'
                    hooks = @(
                        [ordered]@{type='command';command="powershell.exe -File `"$installedBootstrapHook`""},
                        [ordered]@{type='command';command='powershell.exe -File "C:\keep\personal-startup.ps1"'}
                    )
                })
            }
        })

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        @($hooks.hooks.SessionStart[0].hooks).Count | Should Be 1
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Match 'personal-startup\.ps1'
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Not Match 'bootstrap-ai-instructions\.ps1'
    }

    # Scenario: A personal SessionStart command invokes a different script that happens to use the bootstrap filename.
    # Purpose: Require installer ownership evidence before deleting a user hook with a colliding basename.
    It 'InterT24_preserves_a_same_named_SessionStart_hook_outside_the_installed_path' {
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{
  "hooks": {
    "SessionStart": [
      {"matcher":"personal","hooks":[{"type":"command","command":"powershell.exe -File \"C:\\personal-tools\\bootstrap-ai-instructions.ps1\""}]}
    ]
  }
}
'@

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        @($hooks.hooks.SessionStart).Count | Should Be 1
        [string]$hooks.hooks.SessionStart[0].hooks[0].command | Should Match 'C:\\personal-tools\\bootstrap-ai-instructions\.ps1'
    }

    # Scenario: SessionStart contains only the obsolete bootstrap command.
    # Purpose: Remove the now-empty hook category instead of leaving background bootstrap behavior.
    It 'InterT25_removes_SessionStart_when_the_legacy_bootstrap_is_its_only_entry' {
        $installedBootstrapHook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{
            hooks = [ordered]@{
                SessionStart = @([ordered]@{
                    matcher = 'startup'
                    hooks = @([ordered]@{type='command';commandWindows="powershell.exe -File `"$installedBootstrapHook`""})
                })
            }
        })
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
        $result.Output | Should Match '(?s)SourceArchivePath SHA-256.*does\s+not\s+match'
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
    # Purpose: Materialize the runtime directly from immutable Git objects so mutable worktree bytes never execute or install.
    It 'InterT45_installs_immutable_HEAD_sources_when_the_worktree_is_dirty' {
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
            'cleanup-ai-instructions-pollution.ps1','installer-safe-mutation.psm1'
        )) {
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$fileName") -Destination (Join-Path $cloneRoot "scripts\$fileName") -Force
        }
        & git -C $cloneRoot add -- scripts
        & git -C $cloneRoot -c user.name='Installer Test' -c user.email='installer@example.test' commit --quiet --allow-empty -m 'installer fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to commit installer source fixture.' }
        $executionEvidence = Join-Path $TestDrive 'dirty-contract-executed.txt'
        $committedRuntimeSource = [System.IO.File]::ReadAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1')
        ).Replace("`r`n","`n").Replace("`r","`n")
        [System.IO.File]::AppendAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1'),
            "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n"
        )

        $result = Invoke-InstallExpectFailure -RepositoryRoot $cloneRoot -CodexHome $codexHome -GitCheckout
        $result.ExitCode | Should Be 0
        Test-Path -LiteralPath $executionEvidence | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $true
        [System.IO.File]::ReadAllText(
            (Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-runtime-contract.psm1')
        ).Replace("`r`n","`n").Replace("`r","`n") | Should Be $committedRuntimeSource
    }

    # Scenario: A malformed codeload candidate fails during staged PowerShell validation.
    # Purpose: Remove all staging and backup directories when failure occurs before active runtime mutation.
    It 'InterT46_cleans_transaction_directories_after_staging_validation_failure' {
        $invalidSource = Join-Path $TestDrive 'invalid-staging-source'
        & git clone --quiet $repositoryRoot $invalidSource
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create invalid staging source clone.' }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\installer-safe-mutation.psm1') `
            -Destination (Join-Path $invalidSource 'scripts\installer-safe-mutation.psm1') -Force
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
    It 'InterT49_revalidates_the_complete_active_runtime_inside_the_install_lock' {
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
    It 'InterT50_rejects_an_unsafe_existing_directory_at_a_stable_file_path' {
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
    It 'InterT51_rolls_back_runtime_config_and_agent_files_when_a_late_install_step_fails' {
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

    # Scenario: A verified launcher is actively executing runtime fan-out while another installation starts for the same Codex Home.
    # Purpose: Hold a shared runtime read lock through execution so the installer cannot swap files into a mixed running bundle.
    It 'InterT53_blocks_runtime_installation_while_verified_fan_out_is_running' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $markerPath = Join-Path $TestDrive 'fan-out-running.marker'
        $slowBootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'
        Set-TestText -Path $slowBootstrapPath -Value @"
param([string]`$CatalogPath,[string]`$LockPath,[string]`$ConfigurationPath,[string]`$TargetRoot)
[System.IO.File]::WriteAllText('$markerPath','running')
Start-Sleep -Seconds 15
"@
        $runtimeContractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $updatedBundle = New-AiInstructionsRuntimeBundleV2 `
            -RuntimeRoot $runtimeRoot `
            -Repository ([string]$bundle.repository) `
            -Commit ([string]$bundle.commit) `
            -Acquisition ([string]$bundle.acquisition) `
            -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hookPath,'-SkipUpdateCheck')
        $fanOutProcess = Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $arguments -PassThru -WindowStyle Hidden
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline -and -not $fanOutProcess.HasExited) {
                Start-Sleep -Milliseconds 100
            }
            Test-Path -LiteralPath $markerPath | Should Be $true

            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'installer is already running|runtime is being installed'
        }
        finally {
            if (-not $fanOutProcess.HasExited) { Stop-Process -Id $fanOutProcess.Id -Force }
            $fanOutProcess.Dispose()
        }
    }

    # Scenario: The launcher starts its automatic update check while another installation targets the same Codex Home.
    # Purpose: Dispatch the verified stable updater so its shared runtime lock prevents a swap during child module loading and use.
    It 'InterT54_launcher_update_check_uses_the_locked_stable_updater_path' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $stableUpdaterPath = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $runtimeUpdaterPath = Join-Path $runtimeRoot 'update-ai-instructions.ps1'
        $markerPath = Join-Path $TestDrive 'launcher-updater-running.marker'
        $slowUpdater = @"
param([string]`$CodexHome)
`$entryPointDirectoryName = Split-Path -Leaf ([System.IO.Path]::GetFullPath(`$PSScriptRoot).TrimEnd([char[]]@('\','/')))
if (`$entryPointDirectoryName -ieq 'hooks') {
    `$lockPath = Join-Path `$CodexHome 'ai-instructions-install.lock'
    `$runtimeReadLock = [System.IO.File]::Open(`$lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    try {
        [System.IO.File]::WriteAllText('$markerPath','stable')
        Start-Sleep -Seconds 15
    }
    finally { `$runtimeReadLock.Dispose() }
}
else {
    [System.IO.File]::WriteAllText('$markerPath','runtime')
    Start-Sleep -Seconds 15
}
"@
        Set-TestText -Path $stableUpdaterPath -Value $slowUpdater
        Set-TestText -Path $runtimeUpdaterPath -Value $slowUpdater
        $runtimeContractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $updatedBundle = New-AiInstructionsRuntimeBundleV2 `
            -RuntimeRoot $runtimeRoot `
            -Repository ([string]$bundle.repository) `
            -Commit ([string]$bundle.commit) `
            -Acquisition ([string]$bundle.acquisition) `
            -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle

        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hookPath)
        $launcherProcess = Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $arguments -PassThru -WindowStyle Hidden
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline -and -not $launcherProcess.HasExited) {
                Start-Sleep -Milliseconds 100
            }
            Test-Path -LiteralPath $markerPath | Should Be $true
            (Get-Content -Raw -LiteralPath $markerPath) | Should Be 'stable'

            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'installer is already running|runtime is being installed'
        }
        finally {
            if (-not $launcherProcess.HasExited) { Stop-Process -Id $launcherProcess.Id -Force }
            $launcherProcess.Dispose()
        }
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
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>&1
        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime bundle does not match'
    }

    # Scenario: An interrupted swap leaves a strict configuration and verified runtime bundle pinned to different canonical commits.
    # Purpose: Keep ordinary launch fail closed while allowing the same stable updater to repair only this proven mismatch.
    It 'InterT56_same_updater_recovers_a_verified_bundle_configuration_pin_mismatch' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json') | ConvertFrom-Json
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        Set-TestJson -Path $configurationPath -Document $configuration
        $receipt = [ordered]@{
            schemaVersion = 1
            checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            mode = [string]$configuration.updates.mode
            channel = [string]$configuration.updates.channel
            ref = [string]$configuration.updates.ref
            currentCommit = [string]$bundle.commit
            candidateCommit = $null
            outcome = 'current'
            archiveSha256 = $null
            message = 'Verified runtime was current before the interrupted config write.'
        }
        Set-TestJson -Path (Join-Path $codexHome 'ai-instructions-update-receipt.json') -Document $receipt
        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'

        $blockedOutput = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome 2>&1
        $blockedExitCode = $LASTEXITCODE
        $recoveryOutput = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater `
            -CodexHome $codexHome -RecoverInterruptedInstall 2>&1
        $recoveryExitCode = $LASTEXITCODE

        $blockedExitCode | Should Not Be 0
        ($blockedOutput -join [Environment]::NewLine) | Should Match 'runtime bundle does not match'
        ($recoveryOutput -join [Environment]::NewLine) | Should Match 'Recovered interrupted AI instructions installation'
        ($recoveryOutput -join [Environment]::NewLine) | Should Not Match 'AI instructions update outcome'
        $recoveryExitCode | Should Be 0
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json).catalog.ref |
            Should Be ([string]$bundle.commit)
        @(Get-ChildItem -LiteralPath $codexHome -Force -File | Where-Object {
            $_.Name -match '^\.ai-instructions-sync\.json\.(recovery|backup|failed)-'
        }).Count | Should Be 0
    }

    # Scenario: A verified pin mismatch exists while another installer owns the per-home install lock.
    # Purpose: Prevent recovery from racing a transactional runtime/config swap and writing a stale pin afterward.
    It 'InterT57_interrupted_install_recovery_refuses_a_concurrent_installer' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        Set-TestJson -Path $configurationPath -Document $configuration
        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $installLock = [System.IO.File]::Open(
            $installLockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater `
                -CodexHome $codexHome -RecoverInterruptedInstall 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally { $installLock.Dispose() }

        $exitCode | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'recovery refused to run while another AI instructions installer is active'
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json).catalog.ref |
            Should Be ('0' * 40)
    }

    # Scenario: The installed configuration carries an update interval above the v4 schema and migration boundary.
    # Purpose: Make the trusted stable-launcher preflight reject out-of-contract policy before importing runtime code.
    It 'InterT58_installed_launcher_rejects_an_out_of_range_update_interval' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.updates.minimumCheckIntervalMinutes = [long][int]::MaxValue + 1
        Set-TestJson -Path $configurationPath -Document $configuration
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'update policy is invalid'
    }

    # Scenario: The installed updater module is missing and an unmanaged sibling module is placed beside the stable command.
    # Purpose: Make the stable updater fail closed before importing fallback code from an incomplete installed layout.
    It 'InterT59_manual_updater_rejects_a_missing_installed_module_before_sibling_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeUpdater = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-updater.psm1'
        $siblingUpdater = Join-Path $codexHome 'hooks\ai-instructions-updater.psm1'
        $executionEvidence = Join-Path $codexHome 'fallback-updater-executed.txt'
        Remove-Item -LiteralPath $runtimeUpdater -Force
        Set-Content -Encoding UTF8 -LiteralPath $siblingUpdater -Value "[System.IO.File]::WriteAllText('$executionEvidence','executed')"

        $manualUpdater = Join-Path $codexHome 'hooks\update-ai-instructions.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome -ForceCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'installed updater module is missing'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: One installed runtime module is changed after its bundle inventory was created.
    # Purpose: Stop the stable launcher before executing any tampered runtime code.
    It 'InterT60_installed_launcher_rejects_runtime_inventory_tampering_before_execution' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-runtime-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-contract-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

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
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $manualUpdater -CodexHome $codexHome -ForceCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A user runs the stable cleanup command after its runtime contracts are tampered.
    # Purpose: Refuse cleanup before importing or executing the unverified contract modules.
    It 'InterT62_cleanup_command_preflights_runtime_before_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeScript = Join-Path $codexHome 'hooks\ai-instructions-runtime\skills-catalog-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'tampered-cleanup-contract-executed.txt'
        [System.IO.File]::AppendAllText($runtimeScript, "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n")

        $cleanupCommand = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $cleanupCommand -TargetRoot $repositoryRoot -Authorize 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'runtime inventory'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: The stable launcher bytes drift from the reference copy covered by the active runtime inventory.
    # Purpose: Detect an interrupted mixed-version install before update or target bootstrap code executes.
    It 'InterT63_installed_launcher_rejects_stable_launcher_version_drift' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [System.IO.File]::AppendAllText($hookPath,"`n# stable launcher drift`n")

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stable launcher does not match'
    }

    # Scenario: The installed runtime directory is replaced by a file while unmanaged cleanup contracts exist beside the stable command.
    # Purpose: Make cleanup reject the malformed installed layout before importing fallback contract modules or mutating the target index.
    It 'InterT64_cleanup_rejects_a_non_directory_runtime_before_sibling_import' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $siblingContract = Join-Path $codexHome 'hooks\skills-catalog-contract.psm1'
        $executionEvidence = Join-Path $codexHome 'fallback-cleanup-contract-executed.txt'
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
        Set-Content -Encoding UTF8 -LiteralPath $runtimeRoot -Value 'not a directory'
        Set-Content -Encoding UTF8 -LiteralPath $siblingContract -Value "[System.IO.File]::WriteAllText('$executionEvidence','executed')"

        $cleanupCommand = Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1'
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $cleanupCommand -TargetRoot $repositoryRoot -Authorize 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'installed runtime directory is missing or invalid'
        Test-Path -LiteralPath $executionEvidence | Should Be $false
    }

    # Scenario: A stable installer destination is a hard-link alias of a file outside Codex Home.
    # Purpose: Reject ambiguous stable-file ownership before installation can change any external alias bytes.
    It 'InterT65_installer_rejects_a_hard_linked_stable_file' {
        $outsidePath = Join-Path $TestDrive 'installer-hard-link-outside.ps1'
        $stablePath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stablePath) | Out-Null
        Set-TestText -Path $outsidePath -Value "# outside original`n"
        New-Item -ItemType HardLink -Path $stablePath -Target $outsidePath | Out-Null
        $outsideBefore = [System.IO.File]::ReadAllBytes($outsidePath)

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'hard link|multiple file-system links|exclusive ownership'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outsidePath)) |
            Should Be ([Convert]::ToBase64String($outsideBefore))
        (Get-Item -Force -LiteralPath $stablePath).LinkType | Should Be 'HardLink'
    }

    # Scenario: The hooks directory is replaced by a junction after the installer's last path check but before active copies begin.
    # Purpose: Hold a handle-bound directory guard across the complete active swap so stable commands and runtime cannot escape Codex Home.
    It 'InterT66_installer_blocks_a_parent_junction_swap_during_active_mutation' {
        $archivePath = Join-Path $TestDrive 'installer-junction-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $outsideRoot = Join-Path $TestDrive 'installer-junction-outside'
        $savedHooks = Join-Path $codexHome 'hooks-original'
        $resultPath = Join-Path $TestDrive 'installer-junction-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-junction-probe.ps1'
        New-Item -ItemType Directory -Force -Path $outsideRoot | Out-Null
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $OutsideRoot,
    [Parameter(Mandatory = $true)][string] $SavedHooks,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$mutationLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern "Set-InstallerTransactionalFileBytes.*hooks/bootstrap-ai-instructions\.ps1" |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($mutationLine.Count -ne 1) { throw 'Could not locate the installer active-mutation boundary.' }
$global:InstallerProbeHooks = Join-Path $CodexHome 'hooks'
$global:InstallerProbeSavedHooks = $SavedHooks
$global:InstallerProbeOutside = $OutsideRoot
$global:InstallerProbeSwapResult = 'not-attempted'
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $mutationLine[0] -Action {
    try {
        Move-Item -LiteralPath $global:InstallerProbeHooks -Destination $global:InstallerProbeSavedHooks
        New-Item -ItemType Junction -Path $global:InstallerProbeHooks -Target $global:InstallerProbeOutside | Out-Null
        $global:InstallerProbeSwapResult = 'swapped'
    }
    catch { $global:InstallerProbeSwapResult = 'blocked: ' + $_.Exception.Message }
}
try {
    $installerError = ''
    & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
        -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
        -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
    $installerExit = 0
}
catch {
    $installerExit = 1
    $installerError = $_.Exception.Message
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
}
$result = @($installerExit,$global:InstallerProbeSwapResult,$installerError) -join "`n"
[System.IO.File]::WriteAllText($ResultPath,$result,(New-Object System.Text.UTF8Encoding($false)))
Remove-Variable -Name InstallerProbeHooks,InstallerProbeSavedHooks,InstallerProbeOutside,InstallerProbeSwapResult -Scope Global -ErrorAction SilentlyContinue
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-OutsideRoot',$outsideRoot,
            '-SavedHooks',$savedHooks,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^0\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^blocked:'
        Test-Path -LiteralPath (Join-Path $outsideRoot 'bootstrap-ai-instructions.ps1') | Should Be $false
        Test-Path -LiteralPath (Join-Path $outsideRoot 'ai-instructions-runtime') | Should Be $false
        (Get-Item -Force -LiteralPath (Join-Path $codexHome 'hooks')).LinkType | Should BeNullOrEmpty
    }

    # Scenario: A user edits AGENTS.md after the installer snapshots stable files but before that file is replaced.
    # Purpose: Compare original bytes inside the mutation handle, preserve the concurrent edit, and roll back earlier installer changes.
    It 'InterT67_preserves_a_concurrent_stable_file_edit_before_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $archivePath = Join-Path $TestDrive 'installer-cas-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $agentsPath = Join-Path $codexHome 'AGENTS.md'
        $hookBefore = [System.IO.File]::ReadAllBytes($hookPath)
        $bundleBefore = [System.IO.File]::ReadAllBytes($bundlePath)
        $configurationBefore = [System.IO.File]::ReadAllBytes($configurationPath)
        $externalAgents = "# Concurrent personal instructions`n"
        $resultPath = Join-Path $TestDrive 'installer-cas-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-cas-probe.ps1'
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $AgentsPath,
    [Parameter(Mandatory = $true)][string] $ExternalAgents,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$mutationLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern "Set-InstallerTransactionalFileBytes.*hooks/bootstrap-ai-instructions\.ps1" |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($mutationLine.Count -ne 1) { throw 'Could not locate the installer active-mutation boundary.' }
$global:InstallerCasAgentsPath = $AgentsPath
$global:InstallerCasExternalAgents = $ExternalAgents
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $mutationLine[0] -Action {
    [System.IO.File]::WriteAllText(
        $global:InstallerCasAgentsPath,
        $global:InstallerCasExternalAgents,
        (New-Object System.Text.UTF8Encoding($false)))
}
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit = 0
        $installerError = ''
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable -Name InstallerCasAgentsPath,InstallerCasExternalAgents -Scope Global -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError) -join "`n"),(New-Object System.Text.UTF8Encoding($false)))
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-AgentsPath',$agentsPath,
            '-ExternalAgents',$externalAgents,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match 'changed concurrently'
        (Get-Content -Raw -LiteralPath $agentsPath) | Should Be $externalAgents
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($hookPath)) | Should Be ([Convert]::ToBase64String($hookBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        @(Get-ChildItem -LiteralPath $codexHome -Directory -Force | Where-Object { $_.Name -like '.ai-instructions-*' }).Count | Should Be 0
    }

    # Scenario: A user replaces a stable launcher after a late install failure begins rollback.
    # Purpose: Preserve external bytes, restore every unaffected transaction file, and retain recovery backup evidence.
    It 'InterT68_preserves_concurrent_stable_file_bytes_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $archivePath = Join-Path $TestDrive 'installer-rollback-cas-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $agentsPath = Join-Path $codexHome 'AGENTS.md'
        $hooksPath = Join-Path $codexHome 'hooks.json'
        $bundleBefore = [System.IO.File]::ReadAllBytes($bundlePath)
        $configurationBefore = [System.IO.File]::ReadAllBytes($configurationPath)
        $agentsBefore = [System.IO.File]::ReadAllBytes($agentsPath)
        Set-TestText -Path $hooksPath -Value '{not-json'
        $hooksBefore = [System.IO.File]::ReadAllBytes($hooksPath)
        $externalHook = "# Concurrent launcher replacement`n"
        $resultPath = Join-Path $TestDrive 'installer-rollback-cas-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-rollback-cas-probe.ps1'
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $HookPath,
    [Parameter(Mandatory = $true)][string] $ExternalHook,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$rollbackLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*\$installError=\$_\s*$' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($rollbackLine.Count -ne 1) { throw 'Could not locate the installer rollback boundary.' }
$global:InstallerRollbackCasHookPath = $HookPath
$global:InstallerRollbackCasExternalHook = $ExternalHook
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $rollbackLine[0] -Action {
    [System.IO.File]::WriteAllText(
        $global:InstallerRollbackCasHookPath,
        $global:InstallerRollbackCasExternalHook,
        (New-Object System.Text.UTF8Encoding($false)))
}
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit = 0
        $installerError = ''
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable -Name InstallerRollbackCasHookPath,InstallerRollbackCasExternalHook -Scope Global -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError) -join "`n"),(New-Object System.Text.UTF8Encoding($false)))
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-HookPath',$hookPath,
            '-ExternalHook',$externalHook,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?is)rollback also failed.*current bytes were preserved'
        (Get-Content -Raw -LiteralPath $hookPath) | Should Be $externalHook
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($agentsPath)) | Should Be ([Convert]::ToBase64String($agentsBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($hooksPath)) | Should Be ([Convert]::ToBase64String($hooksBefore))
        @(Get-ChildItem -LiteralPath $codexHome -Directory -Force | Where-Object { $_.Name -like '.ai-instructions-backup-*' }).Count | Should Be 1
    }

    # Scenario: A user adds content to the transaction-installed runtime after a late install failure begins rollback.
    # Purpose: Quarantine and preserve unverified runtime drift instead of recursively deleting it, while restoring the previous runtime.
    It 'InterT69_preserves_concurrent_runtime_content_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimePath = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $activeSourcePath = Join-Path $runtimePath 'safe-zip.psm1'
        $activeSourceBefore = [System.IO.File]::ReadAllBytes($activeSourcePath)
        $candidateRoot = Join-Path $TestDrive 'installer-runtime-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts') -Destination $candidateRoot -Recurse
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        $candidateSourcePath = Join-Path $candidateRoot 'scripts\safe-zip.psm1'
        [System.IO.File]::AppendAllText($candidateSourcePath,"`n# runtime rollback candidate`n",(New-Object System.Text.UTF8Encoding($false)))
        $candidateSourceBytes = [System.IO.File]::ReadAllBytes($candidateSourcePath)
        $archivePath = Join-Path $TestDrive 'installer-runtime-rollback-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $hooksPath = Join-Path $codexHome 'hooks.json'
        Set-TestText -Path $hooksPath -Value '{not-json'
        $externalRuntimeContent = "Concurrent runtime content`n"
        $resultPath = Join-Path $TestDrive 'installer-runtime-rollback-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-runtime-rollback-probe.ps1'
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $ExternalRuntimeContent,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$rollbackLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*\$installError=\$_\s*$' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($rollbackLine.Count -ne 1) { throw 'Could not locate the installer rollback boundary.' }
$global:InstallerRollbackRuntimeRoot = Join-Path $CodexHome 'hooks\ai-instructions-runtime'
$global:InstallerRollbackRuntimeContent = $ExternalRuntimeContent
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $rollbackLine[0] -Action {
    [System.IO.File]::WriteAllText(
        (Join-Path $global:InstallerRollbackRuntimeRoot 'concurrent-runtime-note.txt'),
        $global:InstallerRollbackRuntimeContent,
        (New-Object System.Text.UTF8Encoding($false)))
}
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit = 0
        $installerError = ''
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable -Name InstallerRollbackRuntimeRoot,InstallerRollbackRuntimeContent -Scope Global -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError) -join "`n"),(New-Object System.Text.UTF8Encoding($false)))
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-ExternalRuntimeContent',$externalRuntimeContent,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?is)rollback also failed.*runtime rollback preserved'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($activeSourcePath)) |
            Should Be ([Convert]::ToBase64String($activeSourceBefore))
        $backupRoot = @(Get-ChildItem -LiteralPath $codexHome -Directory -Force |
            Where-Object { $_.Name -like '.ai-instructions-backup-*' })
        $backupRoot.Count | Should Be 1
        $quarantinedRuntime = Join-Path $backupRoot[0].FullName 'failed-runtime'
        (Get-Content -Raw -LiteralPath (Join-Path $quarantinedRuntime 'concurrent-runtime-note.txt')) |
            Should Be $externalRuntimeContent
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $quarantinedRuntime 'safe-zip.psm1'))) |
            Should Be ([Convert]::ToBase64String($candidateSourceBytes))
    }

    # Scenario: The installer backup root is swapped for an outside junction when rollback begins.
    # Purpose: Hold a non-delete-sharing handle on the transaction backup root until rollback and cleanup are complete.
    It 'InterT70_blocks_a_backup_root_junction_swap_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $archivePath = Join-Path $TestDrive 'installer-backup-guard-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $hooksPath = Join-Path $codexHome 'hooks.json'
        Set-TestText -Path $hooksPath -Value '{not-json'
        $outsideRoot = Join-Path $TestDrive 'installer-backup-guard-outside'
        $savedBackupRoot = Join-Path $codexHome 'backup-root-swapped'
        $resultPath = Join-Path $TestDrive 'installer-backup-guard-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-backup-guard-probe.ps1'
        New-Item -ItemType Directory -Force -Path $outsideRoot | Out-Null
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $OutsideRoot,
    [Parameter(Mandatory = $true)][string] $SavedBackupRoot,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$rollbackLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*\$installError=\$_\s*$' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($rollbackLine.Count -ne 1) { throw 'Could not locate the installer rollback boundary.' }
$global:InstallerBackupGuardCodexHome = $CodexHome
$global:InstallerBackupGuardOutside = $OutsideRoot
$global:InstallerBackupGuardSaved = $SavedBackupRoot
$global:InstallerBackupGuardSwapResult = 'not-attempted'
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $rollbackLine[0] -Action {
    try {
        $backupRoot = @(Get-ChildItem -LiteralPath $global:InstallerBackupGuardCodexHome -Directory -Force |
            Where-Object { $_.Name -like '.ai-instructions-backup-*' })
        if ($backupRoot.Count -ne 1) { throw 'Could not identify the active installer backup root.' }
        Move-Item -LiteralPath $backupRoot[0].FullName -Destination $global:InstallerBackupGuardSaved -ErrorAction Stop
        New-Item -ItemType Junction -Path $backupRoot[0].FullName -Target $global:InstallerBackupGuardOutside -ErrorAction Stop | Out-Null
        $global:InstallerBackupGuardSwapResult = 'swapped'
    }
    catch { $global:InstallerBackupGuardSwapResult = 'blocked: ' + $_.Exception.Message }
}
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit = 0
        $installerError = ''
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText(
    $ResultPath,
    (@($installerExit,$global:InstallerBackupGuardSwapResult,$installerError) -join "`n"),
    (New-Object System.Text.UTF8Encoding($false)))
Remove-Variable -Name InstallerBackupGuardCodexHome,InstallerBackupGuardOutside,InstallerBackupGuardSaved,InstallerBackupGuardSwapResult -Scope Global -ErrorAction SilentlyContinue
'@

        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-OutsideRoot',$outsideRoot,
            '-SavedBackupRoot',$savedBackupRoot,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^blocked:'
        Test-Path -LiteralPath $savedBackupRoot | Should Be $false
        @(Get-ChildItem -LiteralPath $codexHome -Directory -Force |
            Where-Object { $_.Name -like '.ai-instructions-backup-*' }).Count | Should Be 0
        @(Get-ChildItem -LiteralPath $outsideRoot -Force).Count | Should Be 0
    }
}
