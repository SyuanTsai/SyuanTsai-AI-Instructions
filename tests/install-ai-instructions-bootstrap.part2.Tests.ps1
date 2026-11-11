. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
        $platformManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repositoryRoot 'scripts\platform-runtime.psd1')
        foreach ($fileName in @(@(
            'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1',
            'safe-zip.psm1','skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
            'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
            'ai-instructions-runtime-contract.psm1','WindowsDacl.psm1','agent-artifact-remediation.psm1','repo-shared-skills-migration.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
            'ai-instructions-updater.psm1','update-ai-instructions.ps1','agent-environment-reconciler.psm1','update-agent-environment.ps1',
            'cleanup-ai-instructions-pollution.ps1','license-delivery.psm1','ai-instructions-install-transaction.psm1'
        ) + @($platformManifest.FileList) | Sort-Object -Unique)) {
            $destination = Join-Path $cloneRoot "scripts\$fileName"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$fileName") -Destination $destination -Force
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licensing-scope.json') -Destination (Join-Path $cloneRoot 'licensing-scope.json') -Force
        & git -C $cloneRoot add -- scripts licensing-scope.json
        & git -C $cloneRoot -c user.name='Installer Test' -c user.email='installer@example.test' commit --quiet --allow-empty -m 'installer fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to commit installer source fixture.' }
        $executionEvidence = Join-Path $TestDrive 'dirty-contract-executed.txt'
        $licenseExecutionEvidence = Join-Path $TestDrive 'dirty-license-module-executed.txt'
        [IO.File]::AppendAllText((Join-Path $cloneRoot 'scripts/license-delivery.psm1'), "`n[IO.File]::WriteAllText('$licenseExecutionEvidence','executed')`n")
        $committedRuntimeSource = [System.IO.File]::ReadAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1')
        ).Replace("`r`n","`n").Replace("`r","`n")
        [System.IO.File]::AppendAllText(
            (Join-Path $cloneRoot 'scripts\ai-instructions-runtime-contract.psm1'),
            "`n[System.IO.File]::WriteAllText('$executionEvidence','executed')`n"
        )
        $committedLicense = [IO.File]::ReadAllText((Join-Path $cloneRoot 'LICENSE')).Replace("`r`n","`n")
        Set-TestText -Path (Join-Path $cloneRoot 'LICENSE') -Value 'Dirty working tree license must not install'

        $savedInstallScript = $script:InstallScript
        try {
            $script:InstallScript = Join-Path $cloneRoot 'scripts/install-ai-instructions-bootstrap.ps1'
            $result = Invoke-InstallExpectFailure -RepositoryRoot $cloneRoot -CodexHome $codexHome -GitCheckout
        }
        finally { $script:InstallScript = $savedInstallScript }
        $result.ExitCode | Should Be 0
        Test-Path -LiteralPath $executionEvidence | Should Be $false
        Test-Path -LiteralPath $licenseExecutionEvidence | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $true
        [System.IO.File]::ReadAllText(
            (Join-Path $codexHome 'hooks\ai-instructions-runtime\ai-instructions-runtime-contract.psm1')
        ).Replace("`r`n","`n").Replace("`r","`n") | Should Be $committedRuntimeSource
        [IO.File]::ReadAllText((Join-Path $codexHome 'hooks/ai-instructions-runtime/licenses/source/LICENSE')).Replace("`r`n","`n") | Should Be $committedLicense
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A malformed codeload candidate fails during staged PowerShell validation.
    # Purpose: Remove the pre-journal transaction directory when failure occurs before active runtime mutation.
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: Hooks-file transformation fails before the prepared journal is made durable.
    # Purpose: Preserve launcher, runtime, configuration, Agent, and hook bytes with no target mutation.
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A projection-aware installer replaces the legacy bundle after preflight but before this installer owns the install lock.
    # Purpose: Reread schema compatibility under the lock so the legacy installer cannot overwrite the newer runtime or begin staging.
    It 'InterT52a_rejects_a_v3_bundle_replaced_while_acquiring_the_install_lock_without_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        $v3Bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        $v3Bundle.schemaVersion = 3
        $v3BundleBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((($v3Bundle | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"))
        $runtimeFilePath = Join-Path $runtimeRoot 'skills-selection.psm1'
        $runtimeFileBefore = [System.IO.File]::ReadAllBytes($runtimeFilePath)
        $configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
        $configurationBefore = [System.IO.File]::ReadAllBytes($configurationPath)
        $resultPath = Join-Path $TestDrive 'installer-v3-lock-race-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-v3-lock-race-probe.ps1'
        Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $BundlePath,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$lockLine = @(
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*try \{ \$installLockLease = Enter-PlatformLock ' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($lockLine.Count -ne 1) { throw 'Could not locate the installer lock acquisition boundary.' }
$global:InstallerV3RaceBundlePath = $BundlePath
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $lockLine[0] -Action {
    $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $global:InstallerV3RaceBundlePath | ConvertFrom-Json
    $bundle.schemaVersion = 3
    [System.IO.File]::WriteAllText(
        $global:InstallerV3RaceBundlePath,
        (($bundle | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}
try {
    $installerExit = 0
    $installerError = ''
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
    }
    catch {
        $installerExit = 1
        $installerError = $_.Exception.Message
    }
}
finally {
    Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue
    Remove-Variable -Name InstallerV3RaceBundlePath -Scope Global -ErrorAction SilentlyContinue
}
[System.IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError) -join "`n"),(New-Object System.Text.UTF8Encoding($false)))
'@
        $archivePath = Join-Path $TestDrive 'installer-v3-lock-race-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
            '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-ArchivePath',$archivePath,
            '-BundlePath',$bundlePath,
            '-ResultPath',$resultPath
        )
        $output = & $script:TestPowerShellExecutable @arguments 2>&1

        $LASTEXITCODE | Should Be 0
        (Get-Content -Raw -LiteralPath $resultPath) | Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Get-Content -Raw -LiteralPath $resultPath)) | Should Be mixed-generation
        $bundleAfter = [System.IO.File]::ReadAllBytes($bundlePath)
        [Convert]::ToBase64String($bundleAfter) | Should Be ([Convert]::ToBase64String($v3BundleBytes))
        (Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json).schemaVersion | Should Be 3
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($runtimeFilePath)) | Should Be ([Convert]::ToBase64String($runtimeFileBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configurationPath)) | Should Be ([Convert]::ToBase64String($configurationBefore))
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $hookPath + '"'))
        $launcherOutput = Join-Path $TestDrive 'launcher-updater-running.stdout.txt'
        $launcherError = Join-Path $TestDrive 'launcher-updater-running.stderr.txt'
        $launcherProcess = Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $arguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $launcherOutput -RedirectStandardError $launcherError
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $deadline -and -not $launcherProcess.HasExited) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $markerPath)) {
                $diagnostic = @(
                    "exit=$(if ($launcherProcess.HasExited) { $launcherProcess.ExitCode } else { '<still running>' })",
                    $(if (Test-Path -LiteralPath $launcherOutput) { Get-Content -Raw -LiteralPath $launcherOutput } else { '<no stdout>' }),
                    $(if (Test-Path -LiteralPath $launcherError) { Get-Content -Raw -LiteralPath $launcherError } else { '<no stderr>' })
                ) -join [Environment]::NewLine
                throw "Verified launcher update check did not start: $diagnostic"
            }
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: Apply runs while a newer AI-Instructions candidate may exist under the separate updater policy.
    # Purpose: Reconcile only the current verified runtime without invoking the updater or silently approving a candidate.
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

    # Scenario: The stable Agent environment entry creates a trusted install read lease and reconciliation then fails in the same reusable PowerShell runspace.
    # Purpose: Release the trusted lease before the entry returns through its trap so an installer can immediately acquire the exclusive install lock.
    It 'InterT54b_agent_environment_failure_releases_the_trusted_install_read_lease' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $runtimeRoot=Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $installLockPath=Join-Path $codexHome 'ai-instructions-install.lock'
        $escapedFailureLockPath=$installLockPath.Replace("'","''")
        $failureFixture=@"
Set-StrictMode -Version 2.0
function Assert-UserProjectionRuntimeGate { param([string]`$RuntimeRoot);throw 'Projection runtime gate is not expected for the v2/v4 fixture.' }
function New-AgentEnvironmentInstallReadLeaseEvidence {
    param([System.IO.FileStream]`$Lease)
    `$trustedStream=[System.IO.File]::Open('$escapedFailureLockPath',[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    `$evidence=[pscustomobject]@{Stream=`$trustedStream}
    `$evidence|Add-Member -MemberType ScriptMethod -Name Dispose -Value { `$this.Stream.Dispose() }
    return `$evidence
}
function Get-UserSkillsDesiredState {
    param([string]`$RuntimeRoot,[object]`$Configuration,[string]`$CatalogRepository,[string]`$CatalogCommit,[string]`$WorkingRoot)
    throw 'injected reconciliation setup failure after trusted lease creation'
}
function Invoke-UserSkillsReconciliation { param([object]`$DesiredState,[string]`$UserHome,[string]`$Mode,[switch]`$ForceReinstallManagedSkills,[switch]`$MigrateLegacyCatalogSkills,[object]`$InstallReadLease);throw 'unexpected reconciliation call' }
function Invoke-UserSkillsRecovery { param([string]`$UserHome,[object]`$InstallReadLease,[ValidateSet('Apply','VerifyOnly','WhatIf')][string]`$Mode='Apply');throw 'unexpected recovery call' }
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
"@
        Set-TestText -Path (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Value $failureFixture
        $runtimeContractPath=Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
        Import-Module $runtimeContractPath -Force
        $bundlePath=Join-Path $runtimeRoot 'runtime-bundle.json'
        $bundle=Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath|ConvertFrom-Json
        $updatedBundle=New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository ([string]$bundle.repository) -Commit ([string]$bundle.commit) -Acquisition ([string]$bundle.acquisition) -ArchiveSha256 ([string]$bundle.archiveSha256)
        Set-TestJson -Path $bundlePath -Document $updatedBundle
        $entryPath=Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        $userHome=Join-Path $TestDrive 'failed-environment-user';New-Item -ItemType Directory -Path $userHome|Out-Null

        $runspaceResult=Invoke-TestAgentEnvironmentEntryWithExclusiveLockProbe -EntryPath $entryPath -CodexHome $codexHome -UserHome $userHome -InstallLockPath $installLockPath
        $entryResult=(@($runspaceResult.EntryOutput)[-1]|ConvertFrom-Json)

        $entryResult.outcome|Should Be 'failed'
        $entryResult.exitCode|Should Be 1
        @($entryResult.failed)[0]|Should Match 'injected reconciliation setup failure'
        @($runspaceResult.ExclusiveOutput)[-1]|Should Be 'exclusive-acquired'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
        ($output -join [Environment]::NewLine) | Should Match 'classification=integrity; retryable=false'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
        $outputText = $output -join [Environment]::NewLine
        $outputText | Should Match 'recovery refused to run while another AI instructions installer is active'
        $outputText | Should Match 'classification=concurrency; retryable=false'
        $outputText | Should Not Match 'classification=operational'
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json).catalog.ref |
            Should Be ('0' * 40)
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
        ($output -join [Environment]::NewLine) | Should Match 'classification=configuration; retryable=false'
    }
    }
}
