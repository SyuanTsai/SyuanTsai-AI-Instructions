. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach $script:InstallAiInstructionsBootstrapBeforeEach

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: The stable launcher bytes drift from the reference copy covered by the active runtime inventory.
    # Purpose: Detect an interrupted mixed-version install before update or target bootstrap code executes.
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

    # Scenario: The stable Agent environment updater drifts from its immutable runtime reference copy.
    # Purpose: Stop an already-installed but tampered user-scoped entry point during its trusted launcher preflight.
    It 'InterT63a_agent_environment_updater_rejects_stable_entry_point_version_drift' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $environmentUpdater = Join-Path $codexHome 'hooks\update-agent-environment.ps1'
        [System.IO.File]::AppendAllText($environmentUpdater,"`n# stable Agent environment updater drift`n")
        $userHome = Join-Path $TestDrive 'environment-updater-user'
        New-Item -ItemType Directory -Path $userHome | Out-Null

        $output = & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $environmentUpdater `
            -CodexHome $codexHome -UserHome $userHome -VerifyOnly -OutputFormat Json 2>&1

        $LASTEXITCODE | Should Not Be 0
        ($output -join [Environment]::NewLine) | Should Match 'stable Agent environment updater does not match'
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: The stable Agent environment updater is missing from an otherwise installed runtime.
    # Purpose: Treat the stable entry point as required runtime inventory instead of silently accepting a partial install.
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

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
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallOperation -Operation ' |
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
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A user edits AGENTS.md after the installer snapshots stable files but before that file is replaced.
    # Purpose: Preserve the writer's bytes, restore every unaffected target to its original state, and complete transaction cleanup when no original backup was displaced.
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
        # Scenario: An active install fails after publishing a file, while external writers replace both its target and original backup before the journal records the operation as applied.
        # Purpose: Preserve both external artifacts and return the interrupted-install refusal marker with the original install error as its inner exception.
        It 'InterT83_active_install_recovery_returns_typed_refusal_when_artifacts_are_retained' {
            Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
            $candidateRoot=Join-Path $TestDrive ('active-retained-candidate-'+[Guid]::NewGuid().ToString('N'))
            New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
            $candidateTransactionModule=Join-Path $candidateRoot 'scripts\ai-instructions-install-transaction.psm1'
            $candidateTransactionBody=Get-Content -Raw -LiteralPath $candidateTransactionModule
            $probeBoundary='    Invoke-AiInstructionsInstallFailpoint -Name "after-operation-$sequence-before-journal"'
            $probeInjection=@'
    if ($sequence -eq 1 -and [Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_PROBE','Process') -ceq '1') {
        $probeHome=[Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_HOME','Process')
        $probeTransaction=@(Get-ChildItem -LiteralPath (Join-Path $probeHome '.ai-instructions-txn') -Directory -Force)[0]
        $probeTarget=Join-Path $probeHome ([string]$Operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $probeBackup=Join-Path $probeTransaction.FullName ([string]$Operation.backupLeaf)
        [IO.File]::Delete($probeTarget)
        [IO.File]::Delete($probeBackup)
        [IO.File]::WriteAllText($probeTarget,[Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_TARGET','Process'),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($probeBackup,[Environment]::GetEnvironmentVariable('P7D2_ACTIVE_RETAINED_BACKUP','Process'),[Text.UTF8Encoding]::new($false))
        throw 'active install recovery probe failure'
    }
'@
            if(-not$candidateTransactionBody.Contains($probeBoundary)){throw 'Could not locate the active installer operation-return boundary.'}
            Set-TestText -Path $candidateTransactionModule -Value ($candidateTransactionBody.Replace($probeBoundary,($probeInjection+"`n"+$probeBoundary)))
            $archivePath=Join-Path $TestDrive ('active-retained-source-'+[Guid]::NewGuid().ToString('N')+'.zip')
            $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
            $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
            $externalTarget="# external target during active install`n"
            $externalBackup="# external backup during active install`n"
            $resultPath=Join-Path $TestDrive 'active-retained-result.txt'
            $wrapperPath=Join-Path $TestDrive 'active-retained-probe.ps1'
            Set-TestText -Path $wrapperPath -Value @'
param(
    [Parameter(Mandatory = $true)][string] $InstallerScript,
    [Parameter(Mandatory = $true)][string] $RepositoryRoot,
    [Parameter(Mandatory = $true)][string] $CodexHome,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $ArchiveSha256,
    [Parameter(Mandatory = $true)][string] $ArchivePath,
    [Parameter(Mandatory = $true)][string] $ExternalTarget,
    [Parameter(Mandatory = $true)][string] $ExternalBackup,
    [Parameter(Mandatory = $true)][string] $ResultPath
)
$env:P7D2_ACTIVE_RETAINED_PROBE='1'
$env:P7D2_ACTIVE_RETAINED_HOME=$CodexHome
$env:P7D2_ACTIVE_RETAINED_TARGET=$ExternalTarget
$env:P7D2_ACTIVE_RETAINED_BACKUP=$ExternalBackup
try {
    try {
        & $InstallerScript -RepositoryRoot $RepositoryRoot -CodexHome $CodexHome `
            -Acquisition github-codeload -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceCommit $SourceCommit -ArchiveSha256 $ArchiveSha256 -SourceArchivePath $ArchivePath | Out-Null
        $installerExit=0
        $installerError=''
        $innerError=''
    }
    catch {
        $installerExit=1
        $installerError=$_.Exception.Message
        $innerError=if($null-ne$_.Exception.InnerException){$_.Exception.InnerException.Message}else{''}
    }
}
finally {
    Remove-Item Env:\P7D2_ACTIVE_RETAINED_PROBE,Env:\P7D2_ACTIVE_RETAINED_HOME,Env:\P7D2_ACTIVE_RETAINED_TARGET,Env:\P7D2_ACTIVE_RETAINED_BACKUP -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText($ResultPath,(@($installerExit,$installerError,$innerError)-join"`n"),[Text.UTF8Encoding]::new($false))
'@
            $arguments=@(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapperPath,
                '-InstallerScript',(Resolve-Path -LiteralPath $script:InstallScript).Path,
                '-RepositoryRoot',$repositoryRoot,
                '-CodexHome',$codexHome,
                '-SourceCommit',$sourceCommit,
                '-ArchiveSha256',$archiveSha256,
                '-ArchivePath',$archivePath,
                '-ExternalTarget',$externalTarget,
                '-ExternalBackup',$externalBackup,
                '-ResultPath',$resultPath
            )

            $output=& $script:TestPowerShellExecutable @arguments 2>&1

            $LASTEXITCODE|Should Be 0
            $result=Get-Content -Raw -LiteralPath $resultPath
            $result|Should Match '(?m)^1\r?$'
            (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
            (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText (Join-Path $codexHome '.ai-instructions-txn'))))
            (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText 'active install recovery probe failure')))
            $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
            $transaction.Count|Should Be 1
            $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            $operation=@($journal.operations|Where-Object sequence -eq 1)[0]
            (Get-Content -Raw -LiteralPath (Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)))|Should Be $externalTarget
            (Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName ([string]$operation.backupLeaf)))|Should Be $externalBackup
        }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A crash leaves an applied launcher and its original backup, then the backup bytes are modified.
    # Purpose: Refuse journal recovery without changing either the applied target or any transaction evidence.
    It 'InterT68_preserves_concurrent_stable_file_bytes_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $candidateRoot = Join-Path $TestDrive 'installer-backup-tamper-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)
        }
        [IO.File]::AppendAllText((Join-Path $candidateRoot 'scripts\bootstrap-ai-instructions-installed.ps1'),"`n# crash candidate`n",[Text.UTF8Encoding]::new($false))
        $archivePath = Join-Path $TestDrive 'installer-backup-tamper-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $arguments = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,
            '-RepositoryRoot',$repositoryRoot,
            '-CodexHome',$codexHome,
            '-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
            '-SourceCommit',$sourceCommit,
            '-ArchiveSha256',$archiveSha256,
            '-SourceArchivePath',$archivePath
        )
        $savedFailpoint=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$LASTEXITCODE|Should Not Be 0}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$savedFailpoint}
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transaction.Count|Should Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $operation=@($journal.operations|Where-Object sequence -eq 1)[0]
        $backupPath=Join-Path $transaction[0].FullName ([string]$operation.backupLeaf)
        Set-TestText -Path $backupPath -Value "tampered backup evidence`n"
        $targetPath=Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/','\')
        $targetBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))
        $evidenceBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($backupPath))

        $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $result.ExitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be $targetBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($backupPath))|Should Be $evidenceBefore
        Test-Path -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|Should Be $true
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A crash leaves the candidate runtime active, then an external writer adds a file to that complete tree.
    # Purpose: Refuse recovery and retain both the drifted target and the original runtime backup in the journal transaction.
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
    # Scenario: The active journal transaction directory is swapped for an outside junction when recovery begins.
    # Purpose: Hold a no-delete-sharing directory lease so the swap cannot redirect rollback, and retain journal evidence at .ai-instructions-txn/<txid> after the guarded refusal.
    It 'InterT70_blocks_a_backup_root_junction_swap_during_rollback' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $candidateRoot=Join-Path $TestDrive 'installer-transaction-guard-candidate'
        New-Item -ItemType Directory -Force -Path $candidateRoot|Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)}
        [IO.File]::AppendAllText((Join-Path $candidateRoot 'scripts\bootstrap-ai-instructions-installed.ps1'),"`n# transaction guard candidate`n",[Text.UTF8Encoding]::new($false))
        $archivePath = Join-Path $TestDrive 'installer-transaction-guard-source.zip'
        $archiveSha256 = New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit = (@(& git -C $repositoryRoot rev-parse HEAD) -join '').Trim()
        $crashArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $savedFailpoint=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1';& $script:TestPowerShellExecutable @crashArguments 2>&1|Out-Null;$LASTEXITCODE|Should Not Be 0}finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$savedFailpoint}
        $outsideRoot = Join-Path $TestDrive 'installer-transaction-guard-outside'
        $savedBackupRoot = Join-Path $TestDrive 'transaction-root-swapped'
        $resultPath = Join-Path $TestDrive 'installer-transaction-guard-result.txt'
        $wrapperPath = Join-Path $TestDrive 'installer-transaction-guard-probe.ps1'
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
    Select-String -LiteralPath $InstallerScript -Pattern '^\s*Invoke-AiInstructionsInstallRecoveryPlan -Journal \$record\.Classification\.journal' |
        Select-Object -First 1 -ExpandProperty LineNumber
)
if ($rollbackLine.Count -ne 1) { throw 'Could not locate the installer rollback boundary.' }
$global:InstallerBackupGuardCodexHome = $CodexHome
$global:InstallerBackupGuardOutside = $OutsideRoot
$global:InstallerBackupGuardSaved = $SavedBackupRoot
$global:InstallerBackupGuardSwapResult = 'not-attempted'
$breakpoint = Set-PSBreakpoint -Script $InstallerScript -Line $rollbackLine[0] -Action {
    try {
        $backupRoot = @(Get-ChildItem -LiteralPath (Join-Path $global:InstallerBackupGuardCodexHome '.ai-instructions-txn') -Directory -Force)
        if ($backupRoot.Count -ne 1) { throw 'Could not identify the active installer backup root.' }
        Move-Item -LiteralPath $backupRoot[0].FullName -Destination $global:InstallerBackupGuardSaved -ErrorAction Stop
        New-Item -ItemType Junction -Path $backupRoot[0].FullName -Target $global:InstallerBackupGuardOutside -ErrorAction Stop | Out-Null
        $global:InstallerBackupGuardSwapResult = 'swapped'
    }
    catch {
        $global:InstallerBackupGuardSwapResult = 'blocked: ' + $_.Exception.Message
        if($null-eq$record-or$null-eq$record.Plan){throw 'Could not bind the active recovery plan after the guarded swap was blocked.'}
        $record.Plan.action='refuse'
    }
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
        $transactions=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transactions.Count | Should Be 1
        $transactions[0].LinkType | Should BeNullOrEmpty
        $journalPath=Join-Path $transactions[0].FullName 'journal.json'
        Test-Path -LiteralPath $journalPath -PathType Leaf | Should Be $true
        $journal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json (Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath) -ExpectedTransactionId $transactions[0].Name
        @($journal.operations).Count | Should BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $transactions[0].FullName -Force -Recurse).Count | Should BeGreaterThan 1
        if(Test-Path -LiteralPath $savedBackupRoot){@(Get-ChildItem -LiteralPath $savedBackupRoot -Force).Count|Should Be 0}
        @(Get-ChildItem -LiteralPath $outsideRoot -Force).Count | Should Be 0
    }
    }


    # Scenario: The transaction module publishes the complete failpoint grammar used by subprocess crash tests.
    # Purpose: Keep every journal, operation, cleanup, and rollback crash boundary discoverable without enabling it.
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
    # Scenario: A killed pre-journal process leaves only a private transaction directory.
    # Purpose: Purge an orphan before preparing the next install and leave the retained store empty.
    It 'InterT72_purges_an_orphan_transaction_before_installing' {
        $transaction = Join-Path $codexHome ('.ai-instructions-txn\' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $transaction | Out-Null
        Set-TestText -Path (Join-Path $transaction 'journal.stage') -Value "partial`n"

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome | Out-Null

        Test-Path -LiteralPath $transaction | Should Be $false
        @(Get-ChildItem -Force -LiteralPath (Join-Path $codexHome '.ai-instructions-txn')).Count | Should Be 0
    }
    }
}
