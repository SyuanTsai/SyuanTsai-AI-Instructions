$script:InstallScript = Join-Path $PSScriptRoot '..\scripts\install-ai-instructions-bootstrap.ps1'
$script:InstalledBootstrapScript = Join-Path $PSScriptRoot '..\scripts\bootstrap-ai-instructions-installed.ps1'

function Invoke-InstallScript {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [string[]] $AutoCommitRepositoryUrls = @(),
        [string[]] $ExcludedRepositoryUrls = @(),
        [string[]] $ExcludedRepositoryPaths = @()
    )

    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome)
    if ($AutoCommitRepositoryUrls.Count -gt 0) {
        $arguments += '-AutoCommitRepositoryUrls'
        foreach ($repositoryUrl in $AutoCommitRepositoryUrls) { $arguments += $repositoryUrl }
    }
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
    param([string]$RepositoryRoot,[string]$CodexHome)
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$RepositoryRoot,'-CodexHome',$CodexHome)
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

    It 'InterT05_installs_the_multi_source_runtime_without_creating_a_SessionStart_hook' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Test-Path -LiteralPath $installedHookScript | Should Be $true
        (Get-Content -Raw -LiteralPath $installedHookScript) | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)

        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        foreach ($relativePath in @(
            'bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
            'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
            'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
            'runtime-bundle.json','catalog\skills-catalog.json','catalog\skills-catalog-lock.json'
        )) {
            Test-Path -LiteralPath (Join-Path $runtimeRoot $relativePath) | Should Be $true
        }

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $bundle = Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 3
        @($configuration.autoCommitRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryUrls).Count | Should Be 0
        @($configuration.excludedRepositoryPaths).Count | Should Be 0
        [string]$configuration.catalog.repository | Should Match '^https://github\.com/.+/.+\.git$'
        [string]$configuration.catalog.ref | Should Match '^[0-9a-f]{40}$'
        [string]$bundle.repository | Should Be ([string]$configuration.catalog.repository)
        [string]$bundle.commit | Should Be ([string]$configuration.catalog.ref)
        @($configuration.catalog.profiles) | Should Be @('core')
        @($configuration.catalog.includeSkills).Count | Should Be 0
        @($configuration.catalog.excludeSkills).Count | Should Be 0

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Repository Instructions Bootstrap'
        $agents | Should Match 'production code'
        $agents | Should Match '問問題'
        $agents | Should Not Match 'SessionStart'
        $agents | Should Match 'excludedRepositoryUrls'
        $agents | Should Match 'excludedRepositoryPaths'
        $agents | Should Match 'Agent Skills'
        $agents | Should Match 'customized or unmanaged Instructions or Agent Skills'
        $agents | Should Match 'Git ignore.*精確的受管理檔案與 manifest'
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks.json') | Should Be $false
    }

    It 'InterT15_overwrites_a_stale_bootstrap_hook_with_the_installed_launcher' {
        $installedHookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Set-TestText -Path $installedHookScript -Value "git stash push --include-untracked --quiet -m PersonalAgent -- AGENTS.md`n"
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $installedHook = Get-Content -Raw -LiteralPath $installedHookScript
        $installedHook | Should Be (Get-Content -Raw -LiteralPath $script:InstalledBootstrapScript)
        $installedHook | Should Match 'runtime-bundle\.json'
        $installedHook | Should Not Match "'stash', 'push', '--include-untracked'"
    }

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

    It 'InterT25_removes_SessionStart_when_the_legacy_bootstrap_is_its_only_entry' {
        Set-TestText -Path (Join-Path $codexHome 'hooks.json') -Value @'
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","commandWindows":"powershell.exe -File \"C:\\old\\bootstrap-ai-instructions.ps1\""}]}]}}
'@
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hooks = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks.json') | ConvertFrom-Json
        ($hooks.hooks.PSObject.Properties.Name -contains 'SessionStart') | Should Be $false
    }

    It 'InterT30_migrates_legacy_configuration_to_schema_version_3' {
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
            -AutoCommitRepositoryUrls @('ssh://git@example.com/team/new-project.git') `
            -ExcludedRepositoryUrls @('https://example.com/team/architecture-only.git') `
            -ExcludedRepositoryPaths @('design/planning-only')

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
        $configuration.schemaVersion | Should Be 3
        @($configuration.autoCommitRepositoryUrls).Count | Should Be 3
        ($configuration.autoCommitRepositoryUrls -contains 'git@example.com:team/old-project.git') | Should Be $true
        ($configuration.autoCommitRepositoryUrls -contains 'https://example.com/team/second-project.git') | Should Be $true
        ($configuration.autoCommitRepositoryUrls -contains 'ssh://git@example.com/team/new-project.git') | Should Be $true
        @($configuration.excludedRepositoryUrls).Count | Should Be 2
        @($configuration.excludedRepositoryPaths).Count | Should Be 2
        ($configuration.PSObject.Properties.Name -contains 'autoCommitRepositoryPaths') | Should Be $false
        @($configuration.catalog.profiles) | Should Be @('core')
    }

    It 'InterT35_preserves_schema_v3_selections_while_advancing_the_same_bundle_pin' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.ref = ('0' * 40)
        $configuration.catalog.profiles = @('observability')
        $configuration.catalog.includeSkills = @('work-with-jira')
        $configuration.catalog.excludeSkills = @('search-with-felo')
        Set-TestJson -Path $configurationPath -Document $configuration

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $updated = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $expectedHead = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        [string]$updated.catalog.ref | Should Be $expectedHead
        @($updated.catalog.profiles) | Should Be @('observability')
        @($updated.catalog.includeSkills) | Should Be @('work-with-jira')
        @($updated.catalog.excludeSkills) | Should Be @('search-with-felo')
    }

    It 'InterT37_rejects_a_mutable_schema_v3_bundle_ref_before_installation_changes' {
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

    It 'InterT40_rejects_unknown_configuration_schema_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value '{"schemaVersion":99,"autoCommitRepositoryUrls":[],"excludedRepositoryUrls":[],"excludedRepositoryPaths":[]}'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'Unsupported AI instruction sync configuration schemaVersion'
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }

    It 'InterT42_rejects_a_schema_v3_bundle_repository_from_another_repo' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.repository = 'https://github.com/example/other-ai-instructions.git'
        Set-TestJson -Path $configurationPath -Document $configuration
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'same GitHub AI-Instructions repository'
    }

    It 'InterT45_rejects_dirty_installer_runtime_sources_before_mutating_CodexHome' {
        $cloneRoot = Join-Path $TestDrive 'dirty-source'
        $origin = (@(& git -C $repositoryRoot remote get-url origin) -join '').Trim()
        & git clone --quiet $repositoryRoot $cloneRoot
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create installer source clone.' }
        & git -C $cloneRoot remote set-url origin $origin
        if ($LASTEXITCODE -ne 0) { throw 'Failed to reset installer source clone origin.' }
        [System.IO.File]::AppendAllText((Join-Path $cloneRoot 'scripts\skills-selection.psm1'), "`n# dirty installer fixture`n")

        $result = Invoke-InstallExpectFailure -RepositoryRoot $cloneRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'differ from HEAD'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }

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
}
