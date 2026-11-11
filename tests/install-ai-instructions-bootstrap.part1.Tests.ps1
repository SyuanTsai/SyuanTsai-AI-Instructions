. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach $script:InstallAiInstructionsBootstrapBeforeEach

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: An exact source archive supplies its licensing declarations alongside the runtime.
    # Purpose: Bind installed license bytes to the bundle inventory and immutable source commit.
    It 'InterT04_inventories_runtime_licenses_from_the_verified_source_archive' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome | Out-Null
        $runtime = Join-Path $codexHome 'hooks/ai-instructions-runtime'
        $bundle = Get-Content -Raw -LiteralPath (Join-Path $runtime 'runtime-bundle.json') | ConvertFrom-Json
        $license = Join-Path $runtime 'licenses/source/LICENSE'
        (Get-FileHash -LiteralPath $license).Hash | Should Be ((Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'LICENSE')).Hash)
        $receipt = Get-Content -Raw -LiteralPath (Join-Path $runtime 'licenses/delivery.json') | ConvertFrom-Json
        $receipt.sourceCommit | Should Be $bundle.commit
        @($bundle.inventory | Where-Object path -like 'licenses/*').Count | Should Be 7
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
            'ai-instructions-runtime-contract.psm1','WindowsDacl.psm1','agent-artifact-remediation.psm1','repo-shared-skills-migration.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
            'ai-instructions-updater.psm1','update-ai-instructions.ps1','agent-environment-reconciler.psm1','update-agent-environment.ps1',
            'cleanup-ai-instructions-pollution.ps1','ai-instructions-install-transaction.psm1',
            'platform-runtime.psd1','platform-runtime.psm1','installer-safe-mutation.psm1','Resolve-StandardValidationTool.ps1',
            'platform\PlatformNative.cs','platform\UnixNative.cs','platform\WindowsNative.cs','platform\WindowsInstallerMutation.cs',
            'platform\OwnedProcess.cs','platform\UnixProcess.cs','platform\WindowsProcess.cs','platform\Unix.psm1',
            'platform\RuntimePreparation.psm1','platform\Windows.psm1','platform\Linux.psm1','platform\MacOS.psm1',
            'runtime-bundle.json','catalog\skills-catalog.json','catalog\skills-catalog-lock.json'
        )) {
            Test-Path -LiteralPath (Join-Path $runtimeRoot $relativePath) | Should Be $true
        }
        $installedPlatformRuntime=Import-Module (Join-Path $runtimeRoot 'platform-runtime.psd1') -Force -PassThru
        & $installedPlatformRuntime {param($root)Assert-PlatformRuntimeInventory -Root $root -ManifestPath (Join-Path $root 'platform-runtime.psd1')|Out-Null} $runtimeRoot
        $platformRuntimeManifest=Import-PowerShellDataFile -LiteralPath (Join-Path $runtimeRoot 'platform-runtime.psd1')
        $bundle = Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle.json') | ConvertFrom-Json
        $bundlePaths=@($bundle.inventory|ForEach-Object{[string]$_.path})
        foreach($declaredPath in @($platformRuntimeManifest.FileList)){
            $normalizedPath=([string]$declaredPath).Replace('\','/')
            Test-Path -LiteralPath (Join-Path $runtimeRoot ([string]$declaredPath)) -PathType Leaf|Should Be $true
            $bundlePaths|Should Contain $normalizedPath
        }
        $installedReconciler=Import-Module (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Force -PassThru
        {& $installedReconciler {param($root)Import-AgentEnvironmentRuntimeModules -RuntimeRoot $root} $runtimeRoot}|Should Not Throw

        $configuration = Get-Content -Raw -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
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
        @($bundle.inventory | Where-Object { [string]$_.path -ceq 'agent-artifact-remediation.psm1' }).Count | Should Be 1
        @($bundle.inventory | Where-Object { [string]$_.path -ceq 'ai-instructions-rollout.psm1' }).Count | Should Be 1
        @($bundle.inventory | Where-Object { [string]$_.path -ceq 'invoke-ai-instructions-rollout.ps1' }).Count | Should Be 1
        @($configuration.catalog.profiles) | Should Be @('core')
        @($configuration.catalog.includeSkills).Count | Should Be 0
        @($configuration.catalog.excludeSkills).Count | Should Be 0
        [string]$configuration.updates.mode | Should Be 'notify-only'
        [string]$configuration.updates.channel | Should Be 'protected-branch'
        [string]$configuration.updates.ref | Should Be 'main'
        [int]$configuration.updates.minimumCheckIntervalMinutes | Should Be 1440
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\update-agent-environment.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\cleanup-ai-instructions-pollution.ps1') | Should Be $true

        $agents = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $codexHome 'AGENTS.md')
        $agents | Should Match 'Repository Instructions Bootstrap'
        $agents | Should Match 'production code'
        $agents | Should Match '問問題'
        $agents | Should Match 'reserved Agent artifact'
        $agents | Should Match 'remediation commit'
        $agents | Should Match '不得自動 push'
        $agents | Should Not Match 'fail closed.*污染路徑'
        $agents | Should Not Match 'SessionStart'
        $agents | Should Match 'excludedRepositoryUrls'
        $agents | Should Match 'excludedRepositoryPaths'
        $agents | Should Match '目前 Codex Home'
        $agents | Should Not Match ([regex]::Escape('~/.codex/ai-instructions-sync.json'))
        $agents | Should Match 'Agent Skills'
        $agents | Should Match 'customized or unmanaged Instructions or Agent Skills'
        $agents | Should Match '所有 branch 共用的個人 runtime artifacts'
        $agents | Should Match '只包含精確 reserved path deletions 的一次性本機 remediation commit'
        $agents | Should Match '沙箱或權限拒絕'
        $agents | Should Match '核准後重試一次'
        $agents | Should Match 'compatibility、configuration 或 integrity'
        $agents | Should Match '不得重試'
        $agents | Should Match 'notify-only.*available.*未安裝'
        $agents | Should Match '不得偽造 capability evidence'
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks.json') | Should Be $false
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: An existing v4 configuration repeats a Skill already selected by its active profile.
    # Purpose: Normalize the legacy overlap during installation so profile compatibility remains soft in every Codex Home.
    It 'InterT36_normalizes_redundant_profile_and_includeSkills_selection_during_installation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.catalog.profiles = @('atlassian')
        $configuration.catalog.includeSkills = @('work-with-jira','plan-production-change')
        Set-TestJson -Path $configurationPath -Document $configuration

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $updated = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        @($updated.catalog.profiles) | Should Be @('atlassian')
        @($updated.catalog.includeSkills) | Should Be @('plan-production-change')
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: Existing personal configuration declares a future schema unknown to this installer.
    # Purpose: Fail closed before replacing any active runtime or configuration bytes.
    It 'InterT40_rejects_unknown_configuration_schema_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        Set-TestText -Path (Join-Path $codexHome 'ai-instructions-sync.json') -Value '{"schemaVersion":99,"excludedRepositoryUrls":[],"excludedRepositoryPaths":[]}'
        $before = Get-InstallerFullTreeSnapshot -Root $codexHome
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $result.ExitCode | Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be unsupported-version
        (Get-InstallerFullTreeSnapshot -Root $codexHome) | Should Be $before
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: The active configuration is v5 while the installed runtime bundle remains v2.
    # Purpose: Refuse a partial-generation transition before replacing active bytes.
    It 'InterT41_rejects_a_mixed_v2_v5_generation_before_installation_changes' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.schemaVersion = 5
        $configuration | Add-Member -NotePropertyName projections -NotePropertyValue ([pscustomobject]@{user=@('user-agents');project=@()})
        Set-TestJson -Path $configurationPath -Document $configuration
        $configurationBefore = [IO.File]::ReadAllBytes($configurationPath)
        $bundleBefore = [IO.File]::ReadAllBytes($bundlePath)
        $hookBefore = [IO.File]::ReadAllBytes($hookPath)

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be mixed-generation
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($hookPath)) | Should Be ([Convert]::ToBase64String($hookBefore))
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: The stable launcher sees v5 configuration with a v2 runtime bundle.
    # Purpose: Fail the mixed-generation pair before bootstrap can update, recover, or mutate consumer bytes.
    It 'InterT39_rejects_a_mixed_v2_v5_generation_in_the_launcher_before_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $launcherPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $configuration.schemaVersion = 5
        $configuration | Add-Member -NotePropertyName projections -NotePropertyValue ([pscustomobject]@{user=@('user-agents');project=@()})
        Set-TestJson -Path $configurationPath -Document $configuration
        $configurationBefore = [IO.File]::ReadAllBytes($configurationPath)
        $bundleBefore = [IO.File]::ReadAllBytes($bundlePath)
        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $launcherPath -ValidateOnly -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output -join [Environment]::NewLine)) | Should Be mixed-generation
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($bundlePath)) | Should Be ([Convert]::ToBase64String($bundleBefore))
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A supplied codeload archive does not match its declared immutable SHA-256.
    # Purpose: Reject altered download bytes before any Codex Home mutation.
    It 'InterT43_rejects_a_codeload_archive_hash_mismatch_before_mutating_CodexHome' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -InvalidArchiveHash

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match '(?s)SourceArchivePath SHA-256.*does\s+not\s+match'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A caller pairs a valid canonical commit and archive hash with an unrelated local RepositoryRoot.
    # Purpose: Bind github-codeload provenance to the archive bytes that actually supply the installed runtime.
    It 'InterT44_rejects_a_codeload_archive_that_does_not_supply_the_runtime_sources' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -UnrelatedArchive

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'archive.*runtime source|runtime source.*archive'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }
    }
}
