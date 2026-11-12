. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    It 'InterT43_rejects_a_codeload_archive_hash_mismatch_before_mutating_CodexHome' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -InvalidArchiveHash

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match '(?s)SourceArchivePath SHA-256.*does\s+not\s+match'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT46_cleans_transaction_directories_after_staging_validation_failure' {
        $invalidSource = Join-Path $TestDrive 'invalid-staging-source'
        & git clone --quiet $repositoryRoot $invalidSource
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create invalid staging source clone.' }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\installer-safe-mutation.psm1') `
            -Destination (Join-Path $invalidSource 'scripts\installer-safe-mutation.psm1') -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\platform\WindowsInstallerMutation.cs') `
            -Destination (Join-Path $invalidSource 'scripts\platform\WindowsInstallerMutation.cs') -Force
        $platformManifest=Import-PowerShellDataFile -LiteralPath (Join-Path $repositoryRoot 'scripts\platform-runtime.psd1')
        foreach ($fileName in @(@(
            'agent-artifact-remediation.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
            'agent-environment-reconciler.psm1','update-agent-environment.ps1','license-delivery.psm1',
            'ai-instructions-runtime-contract.psm1','ai-instructions-install-transaction.psm1'
        )+@($platformManifest.FileList)|Sort-Object -Unique)) {
            $destination=Join-Path $invalidSource "scripts\$fileName"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination)|Out-Null
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$fileName") `
                -Destination $destination -Force
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licensing-scope.json') -Destination (Join-Path $invalidSource 'licensing-scope.json') -Force
        [System.IO.File]::AppendAllText((Join-Path $invalidSource 'scripts\skills-selection.psm1'), "`nfunction Invalid-StagingFixture {`n")

        $result = Invoke-InstallExpectFailure -RepositoryRoot $invalidSource -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'PowerShell parse error'
        $transactions = Join-Path $codexHome '.ai-instructions-txn'
        @(Get-ChildItem -LiteralPath $transactions -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT48_revalidates_the_expected_current_commit_inside_the_install_lock' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $bundleBefore = Get-Content -Raw -LiteralPath $bundlePath

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -ExpectedCurrentCommit ('0' * 40)

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'installed runtime changed before installation'
        (Get-Content -Raw -LiteralPath $bundlePath) | Should Be $bundleBefore
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $hookPath + '"'),'-SkipUpdateCheck')
        $fanOutOutput = Join-Path $TestDrive 'fan-out-running.stdout.txt'
        $fanOutError = Join-Path $TestDrive 'fan-out-running.stderr.txt'
        $fanOutProcess = Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $arguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $fanOutOutput -RedirectStandardError $fanOutError
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline -and -not $fanOutProcess.HasExited) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $markerPath)) {
                $diagnostic = @(
                    "exit=$(if ($fanOutProcess.HasExited) { $fanOutProcess.ExitCode } else { '<still running>' })",
                    $(if (Test-Path -LiteralPath $fanOutOutput) { Get-Content -Raw -LiteralPath $fanOutOutput } else { '<no stdout>' }),
                    $(if (Test-Path -LiteralPath $fanOutError) { Get-Content -Raw -LiteralPath $fanOutError } else { '<no stderr>' })
                ) -join [Environment]::NewLine
                throw "Verified fan-out did not start: $diagnostic"
            }

            $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'installer is already running|runtime is being installed'
        }
        finally {
            if (-not $fanOutProcess.HasExited) { Stop-Process -Id $fanOutProcess.Id -Force }
            $fanOutProcess.Dispose()
        }
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT54a_agent_environment_apply_uses_the_current_verified_runtime_without_invoking_the_updater' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
        $updaterMarker = Join-Path $TestDrive 'environment-updater-lock.marker'
        $reconcilerMarker = Join-Path $TestDrive 'environment-reconciler-lock.marker'
        $escapedInstallLockPath = $installLockPath.Replace("'","''")
        $escapedUpdaterMarker = $updaterMarker.Replace("'","''")
        $escapedReconcilerMarker = $reconcilerMarker.Replace("'","''")

        $updaterFixture = @"
param([string]`$CodexHome,[switch]`$ForceCheck,[switch]`$InstallApproved)
[System.IO.File]::WriteAllText('$escapedUpdaterMarker','unexpected-invocation')
throw 'Agent environment reconciliation must not invoke the AI-Instructions updater.'
"@
        Set-TestText -Path (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') -Value $updaterFixture
        Set-TestText -Path (Join-Path $runtimeRoot 'update-ai-instructions.ps1') -Value $updaterFixture

        $reconcilerFixture = @"
Set-StrictMode -Version 2.0
function Assert-UserProjectionRuntimeGate {
    param([string]`$RuntimeRoot)
    throw 'Projection runtime gate is not expected for the v2/v4 fixture.'
}
function New-AgentEnvironmentInstallReadLeaseEvidence {
    param([System.IO.FileStream]`$Lease)
    `$trustedStream=[System.IO.File]::Open(`$Lease.Name,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    `$evidence=[pscustomobject]@{Stream=`$trustedStream}
    `$evidence|Add-Member -MemberType ScriptMethod -Name Dispose -Value { `$this.Stream.Dispose() }
    return `$evidence
}
function Get-UserSkillsDesiredState {
    param(
        [string]`$RuntimeRoot,
        [object]`$Configuration,
        [string]`$CatalogRepository,
        [string]`$CatalogCommit,
        [string]`$WorkingRoot
    )
    `$exclusive = `$null
    `$lockOutcome = 'exclusive-acquired'
    try {
        `$exclusive = [System.IO.File]::Open(
            '$escapedInstallLockPath',
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] { `$lockOutcome = 'blocked-by-read-lock' }
    finally { if (`$null -ne `$exclusive) { `$exclusive.Dispose() } }
    [System.IO.File]::WriteAllText('$escapedReconcilerMarker',`$lockOutcome)
    return [pscustomobject]@{
        RuntimeRoot = `$RuntimeRoot
        Catalog = [pscustomobject]@{ skills = @() }
        Files = @()
        Manifest = [pscustomobject]@{
            catalogRepository = `$CatalogRepository
            catalogCommit = `$CatalogCommit
            lockSha256 = ('a' * 64)
        }
    }
}
function Invoke-UserSkillsReconciliation {
    param(
        [object]`$DesiredState,
        [string]`$UserHome,
        [string]`$Mode,
        [switch]`$ForceReinstallManagedSkills,
        [switch]`$MigrateLegacyCatalogSkills,
        [object]`$InstallReadLease
    )
    return [pscustomobject]@{
        schemaVersion=1; outcome='current'; exitCode=0
        catalogCommit=[string]`$DesiredState.Manifest.catalogCommit
        catalogLockSha256=[string]`$DesiredState.Manifest.lockSha256
        installed=@(); updated=@(); removed=@(); preserved=@(); failed=@()
        rollbackState='not-started'; backupPath=`$null
    }
}
function Invoke-UserSkillsRecovery {
    param(
        [string]`$UserHome,
        [object]`$InstallReadLease,
        [ValidateSet('Apply','VerifyOnly','WhatIf')][string]`$Mode = 'Apply'
    )
    if (`$Mode -in @('VerifyOnly','WhatIf')) {
        return [pscustomobject]@{
            schemaVersion=1; outcome='nothing-to-recover'; exitCode=0; rollbackState='not-needed'
        }
    }
    throw 'Apply recovery is not expected in this fixture.'
}
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
"@
        Set-TestText -Path (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Value $reconcilerFixture

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

        $environmentUpdater = Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        $userHome = Join-Path $TestDrive 'locked-environment-user'
        New-Item -ItemType Directory -Path $userHome | Out-Null
        $runspaceResult=Invoke-TestAgentEnvironmentEntryWithExclusiveLockProbe -EntryPath $environmentUpdater -CodexHome $codexHome -UserHome $userHome -InstallLockPath $installLockPath
        $output=$runspaceResult.EntryOutput
        $entryResult=($output[-1]|ConvertFrom-Json)

        $entryResult.exitCode | Should Be 0
        ($output -join [Environment]::NewLine) | Should Match '"outcome":"current"'
        Test-Path -LiteralPath $updaterMarker | Should Be $false
        [System.IO.File]::ReadAllText($reconcilerMarker) | Should Be 'blocked-by-read-lock'
        @($runspaceResult.ExclusiveOutput)[-1]|Should Be 'exclusive-acquired'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
        $outputText = $output -join [Environment]::NewLine
        $outputText | Should Match 'recovery refused to run while another AI instructions installer is active'
        $outputText | Should Match 'classification=concurrency; retryable=false'
        $outputText | Should Not Match 'classification=operational'
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json).catalog.ref |
            Should Be ('0' * 40)
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    }

    It 'InterT71_exports_the_install_failpoint_v1_patterns' {
        $module = Import-Module (Join-Path $repositoryRoot 'scripts\ai-instructions-install-transaction.psm1') -Force -PassThru
        @(& $module { Get-AiInstructionsInstallFailpointPatterns }) | Should Be @(
            'after-journal-prepared','after-journal-stage-flush','after-journal-publish-before-parent-flush',
            'after-recovery-before-install',
            'before-operation-<sequence>','after-original-to-backup-<sequence>',
            'after-operation-<sequence>-before-journal','after-operation-<sequence>',
            'after-committed-before-cleanup','before-cleanup-<artifact-leaf>',
            'during-cleanup-<artifact-leaf>','after-cleanup-<artifact-leaf>','after-rollback-operation-<sequence>'
        )
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT72_purges_an_orphan_transaction_before_installing' {
        $transaction = Join-Path $codexHome ('.ai-instructions-txn\' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $transaction | Out-Null
        Set-TestText -Path (Join-Path $transaction 'journal.stage') -Value "partial`n"

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome | Out-Null

        Test-Path -LiteralPath $transaction | Should Be $false
        @(Get-ChildItem -Force -LiteralPath (Join-Path $codexHome '.ai-instructions-txn')).Count | Should Be 0
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT74_refuses_and_preserves_legacy_installer_residue' -TestCases @(
        @{Leaf='.ai-instructions-install-0123456789abcdef0123456789abcdef'},
        @{Leaf='.ai-instructions-backup-0123456789abcdef0123456789abcdef'}
    ) {
        param($Leaf)
        $residue = Join-Path $codexHome $Leaf
        New-Item -ItemType Directory -Force -Path $residue | Out-Null
        Set-TestText -Path (Join-Path $residue 'evidence.txt') -Value "preserve`n"

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match ([regex]::Escape($residue))
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be interrupted-install
        (Get-Content -Raw -LiteralPath (Join-Path $residue 'evidence.txt')) | Should Be "preserve`n"
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT85_refuses_permission_restore_for_a_replaced_target' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('permission-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('permission-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-journal-prepared';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $operation=@($state.Journal.operations|Where-Object sequence -eq 1)[0]
        $target=Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        (Get-Item -Force -LiteralPath $target).IsReadOnly=$true
        (Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome).RecoveryAction|Should Be 'roll-back'
        $external="# external permission target`n"

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $target -ExternalText $external -ExternalReadOnly $false -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath $target)|Should Be $external
        (Get-Item -Force -LiteralPath $target).IsReadOnly|Should Be $false
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    It 'InterT63b_installed_launcher_rejects_a_missing_stable_agent_environment_updater' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $environmentUpdater = Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        Remove-Item -LiteralPath $environmentUpdater -Force
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match '(?s)runtime is incomplete:.*update-agent-environment\.ps1'
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT69_preserves_concurrent_runtime_content_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimePath = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $candidateRoot = Join-Path $TestDrive 'installer-runtime-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)}
        $candidateSourcePath = Join-Path $candidateRoot 'scripts\safe-zip.psm1'
        [System.IO.File]::AppendAllText($candidateSourcePath,"`n# runtime rollback candidate`n",(New-Object System.Text.UTF8Encoding($false)))
        $archivePath = Join-Path $TestDrive 'installer-runtime-rollback-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,
            '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath
        )
        $savedFailpoint=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$LASTEXITCODE|Should Not Be 0}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$savedFailpoint}
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transaction.Count|Should Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $runtimeOperation=@($journal.operations|Where-Object kind -eq 'swap-directory')[0]
        $runtimeOperation.sequence|Should Be 1
        $externalRuntimeContent="Concurrent runtime content`n"
        Set-TestText -Path (Join-Path $runtimePath 'concurrent-runtime-note.txt') -Value $externalRuntimeContent
        $backupPath=Join-Path $transaction[0].FullName ([string]$runtimeOperation.backupLeaf)
        $backupDigest=(Get-FileHash -LiteralPath (Join-Path $backupPath 'safe-zip.psm1') -Algorithm SHA256).Hash

        $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath (Join-Path $runtimePath 'concurrent-runtime-note.txt'))|Should Be $externalRuntimeContent
        (Get-FileHash -LiteralPath (Join-Path $backupPath 'safe-zip.psm1') -Algorithm SHA256).Hash|Should Be $backupDigest
        Test-Path -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|Should Be $true
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT87_refuses_cleanup_of_a_same_bytes_replaced_journal_store_file' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('journal-store-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('journal-store-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-committed-before-cleanup';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.JournalPhase|Should Be committed
        $journalPath=Join-Path $state.TransactionPath 'journal.json'
        [byte[]]$journalBytes=[IO.File]::ReadAllBytes($journalPath)
        $journalText=[Text.UTF8Encoding]::new($false,$true).GetString($journalBytes)
        $transactionRelative='.ai-instructions-txn/'+(Split-Path -Leaf $state.TransactionPath)
        $transactionLease=Open-PlatformDirectory -Root $codexHome -RelativePath $transactionRelative
        try{$originalState=Get-AiInstructionsInstallFileState -ParentLease $transactionLease -Leaf journal.json -LiteralPath $journalPath -PlatformOs windows}
        finally{$transactionLease.Dispose()}
        $entriesBefore=@(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $journalPath -ExternalText $journalText -ExternalReadOnly $false -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText $state.TransactionPath)))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should Be ([Convert]::ToBase64String($journalBytes))
        $transactionLease=Open-PlatformDirectory -Root $codexHome -RelativePath $transactionRelative
        try{$replacementState=Get-AiInstructionsInstallFileState -ParentLease $transactionLease -Leaf journal.json -LiteralPath $journalPath -PlatformOs windows}
        finally{$transactionLease.Dispose()}
        ($replacementState.identity|ConvertTo-Json -Compress)|Should Not Be ($originalState.identity|ConvertTo-Json -Compress)
        @(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})|Should Be $entriesBefore
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    It 'InterT63_installed_launcher_rejects_stable_launcher_version_drift' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [System.IO.File]::AppendAllText($hookPath,"`n# stable launcher drift`n")

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $hookPath -SkipUpdateCheck 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stable launcher does not match'
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT67_preserves_a_concurrent_stable_file_edit_before_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $archivePath = Join-Path $TestDrive 'installer-cas-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $hookPath = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        $bundlePath = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $agentsPath = Join-Path $codexHome 'AGENTS.md'
        Set-TestText -Path $agentsPath -Value "# Personal instructions before the concurrent edit`n"
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
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallOperation -Operation ' |
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
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT73_refuses_malformed_and_invalid_name_transaction_residue_without_mutation' -TestCases @(
        @{Name=[Guid]::NewGuid().ToString('N');Journal='{not-json'},
        @{Name='invalid-transaction-name';Journal=$null}
    ) {
        param($Name,$Journal)
        $transaction = Join-Path $codexHome ".ai-instructions-txn\$Name"
        New-Item -ItemType Directory -Force -Path $transaction | Out-Null
        if($null -ne $Journal){Set-TestText -Path (Join-Path $transaction 'journal.json') -Value $Journal}
        $evidenceBefore = @(Get-ChildItem -LiteralPath $transaction -Force -Recurse | ForEach-Object { $_.FullName })

        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode | Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output) | Should Be interrupted-install
        @(Get-ChildItem -LiteralPath $transaction -Force -Recurse | ForEach-Object { $_.FullName }) | Should Be $evidenceBefore
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT82_refuses_a_pending_write_with_a_valid_original_backup_and_external_target' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('valid-backup-external-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('valid-backup-external-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1-before-journal';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0

        $recoveryState=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $operation=@($recoveryState.Journal.operations|Where-Object sequence -eq 1)[0]
        $operation.state|Should Be 'pending'
        $operation.backupLeaf|Should Not BeNullOrEmpty
        $target=Join-Path $codexHome ($operation.targetRelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))
        Set-TestText -Path $target -Value "# external replacement after original backup`n"
        $backup=Join-Path $recoveryState.TransactionPath ([string]$operation.backupLeaf)
        Test-Path -LiteralPath $backup -PathType Leaf|Should Be $true

        $targetsBefore=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $backupBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))
        $journalPath=Join-Path $recoveryState.TransactionPath 'journal.json'
        $journalBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))
        $entriesBefore=@(Get-ChildItem -LiteralPath $recoveryState.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($recoveryState.TransactionPath.Length)})

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$output=& $script:TestPowerShellExecutable @arguments 2>&1;$exitCode=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $exitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be interrupted-install
        (Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome)|Should Be $targetsBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))|Should Be $backupBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should Be $journalBefore
        @(Get-ChildItem -LiteralPath $recoveryState.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($recoveryState.TransactionPath.Length)})|Should Be $entriesBefore
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT89_rolls_back_a_readonly_stable_file_after_an_operation_interrupt' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $stablePath=Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [byte[]]$originalBytes=[IO.File]::ReadAllBytes($stablePath)
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly=$true
        $candidateRoot=Join-Path $TestDrive ('readonly-rollback-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('readonly-rollback-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $operation=@($state.Journal.operations|Where-Object{[string]$_.targetRelativePath-ceq'hooks/bootstrap-ai-instructions.ps1'})
        $operation.Count|Should Be 1
        (Get-Item -Force -LiteralPath (Join-Path $state.TransactionPath ([string]$operation[0].backupLeaf))).IsReadOnly|Should Be $true

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-recovery-before-install';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$recoveryExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $recoveryExit|Should Not Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($stablePath))|Should Be ([Convert]::ToBase64String($originalBytes))
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly|Should Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT77_recovers_the_install_journal_failpoint_matrix_to_an_idempotent_complete_state' -TestCases @(
        @{Failpoint='after-recovery-before-install';PreCrash=$null;Fresh=$true;ExpectedRecovery='no-transaction';ExpectedPhase=$null;ExpectedFinal='original'},
        @{Failpoint='after-journal-prepared';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='prepared';ExpectedFinal='original'},
        @{Failpoint='after-journal-stage-flush';PreCrash=$null;Fresh=$false;ExpectedRecovery='purge-orphan';ExpectedPhase=$null;ExpectedFinal='original'},
        @{Failpoint='after-journal-publish-before-parent-flush';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='prepared';ExpectedFinal='original'},
        @{Failpoint='before-operation-1';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'}
    ) {
        param($Failpoint,$PreCrash,$Fresh,$ExpectedRecovery,$ExpectedPhase,$ExpectedFinal)
        if(-not$Fresh){
            Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
            Set-TestJson -Path (Join-Path $codexHome 'hooks.json') -Document ([ordered]@{hooks=[ordered]@{SessionStart=@([ordered]@{matcher='startup';hooks=@([ordered]@{type='command';command="powershell.exe -File `"$(Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1')`""})})}})
        }
        $originalSnapshot=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $candidateRoot=Join-Path $TestDrive ("failpoint-candidate-"+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ("failpoint-source-"+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $invokeCrash={param($Name)$saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT;try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$Name;& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;return $LASTEXITCODE}finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}}
        if($null-ne$PreCrash){(& $invokeCrash $PreCrash)|Should Not Be 0}
        (& $invokeCrash $Failpoint)|Should Not Be 0
        $recoveryState=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $recoveryState.RecoveryAction|Should Be $ExpectedRecovery
        $recoveryState.JournalPhase|Should Be $ExpectedPhase
        $appliedSnapshot=Get-InstallerAppliedSnapshotFromTransaction -CodexHome $codexHome -OriginalSnapshot $originalSnapshot
        (& $invokeCrash 'after-recovery-before-install')|Should Not Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
        $recoveredSnapshot=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        if($ExpectedFinal-ceq'original'){$recoveredSnapshot|Should Be $originalSnapshot}
        else{
            $ExpectedFinal|Should Be 'applied'
            $appliedSnapshot|Should Not BeNullOrEmpty
            $recoveredSnapshot|Should Be $appliedSnapshot
        }

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$installOutput=& $script:TestPowerShellExecutable @arguments 2>&1;$installExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $installExit|Should Be 0
        $stableMarkerSources=[ordered]@{
            'bootstrap-ai-instructions.ps1'='bootstrap-ai-instructions-installed.ps1'
            'update-ai-instructions.ps1'='update-ai-instructions.ps1'
            'update-agent-environment.ps1'='update-agent-environment.ps1'
            'cleanup-ai-instructions-pollution.ps1'='cleanup-ai-instructions-pollution.ps1'
        }
        foreach($relative in @($stableMarkerSources.Keys)){
            (Get-Content -Raw -LiteralPath (Join-Path $codexHome "hooks\$relative"))|Should Match ([regex]::Escape("# failpoint candidate: $($stableMarkerSources[$relative])"))
        }
        (Get-Content -Raw -LiteralPath (Join-Path $codexHome 'hooks\ai-instructions-runtime\safe-zip.psm1'))|Should Match '# failpoint candidate: safe-zip\.psm1'
        $before=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$idempotentOutput=& $script:TestPowerShellExecutable @arguments 2>&1;$idempotentExit=$LASTEXITCODE}finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $idempotentExit|Should Be 0
        (Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome)|Should Be $before
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
    }
    }

}
