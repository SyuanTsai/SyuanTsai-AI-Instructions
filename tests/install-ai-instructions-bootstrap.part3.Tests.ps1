. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    It 'InterT81_recovery_refuses_a_create_file_target_replaced_by_a_directory' {
        $archivePath=Join-Path $TestDrive 'type-confusion-source.zip'
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1-before-journal';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $target=Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        Remove-Item -LiteralPath $target -Force
        New-Item -ItemType Directory -Path $target|Out-Null
        Set-TestText -Path (Join-Path $target 'external.txt') -Value "external`n"
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Directory -Force)
        $transaction.Count|Should Be 1
        $evidenceBefore=@(Get-ChildItem -LiteralPath $transaction[0].FullName -Force -Recurse|ForEach-Object FullName)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue;$output=& $script:TestPowerShellExecutable @arguments 2>&1;$exitCode=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $exitCode|Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be interrupted-install
        Test-Path -LiteralPath (Join-Path $target 'external.txt') -PathType Leaf|Should Be $true
        @(Get-ChildItem -LiteralPath $transaction[0].FullName -Force -Recurse|ForEach-Object FullName)|Should Be $evidenceBefore
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT88_refuses_cleanup_of_a_malformed_journal_stage_generation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('journal-stage-generation-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('journal-stage-generation-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-committed-before-cleanup';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.JournalPhase|Should Be committed
        $stagePath=Join-Path $state.TransactionPath 'journal.stage'
        $malformedStage="{malformed`n"
        Set-TestText -Path $stagePath -Value $malformedStage
        $entriesBefore=@(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})

        $output=& $script:TestPowerShellExecutable @arguments 2>&1
        $recoveryExit=$LASTEXITCODE
        $result=$output-join[Environment]::NewLine

        $recoveryExit|Should Not Be 0
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (ConvertTo-TestComparableText $result)|Should Match ([regex]::Escape((ConvertTo-TestComparableText $state.TransactionPath)))
        (Get-Content -Raw -LiteralPath $stagePath)|Should Be $malformedStage
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
        @(Get-ChildItem -LiteralPath $state.TransactionPath -Force -Recurse|ForEach-Object{$_.FullName.Substring($state.TransactionPath.Length)})|Should Be $entriesBefore
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
    It 'InterT44_rejects_a_codeload_archive_that_does_not_supply_the_runtime_sources' {
        $result = Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome -UnrelatedArchive

        $result.ExitCode | Should Not Be 0
        $result.Output | Should Match 'archive.*runtime source|runtime source.*archive'
        Test-Path -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1') | Should Be $false
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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
        It 'InterT75_windows_powershell_5_1_returns_typed_runtime_baseline_refusal_without_mutation' {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome 2>&1
            $LASTEXITCODE | Should Not Be 0
            (Get-AiInstructionsRefusalCode ($output -join [Environment]::NewLine)) | Should Be runtime-baseline-unavailable
            Test-Path -LiteralPath $codexHome | Should Be $false
        }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT84_refuses_a_rollback_target_replaced_after_recovery_observation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('rollback-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('rollback-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-operation-1-before-journal';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.RecoveryAction|Should Be 'roll-back'
        $operation=@($state.Journal.operations|Where-Object sequence -eq 1)[0]
        $target=Join-Path $codexHome ([string]$operation.targetRelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $external="# external rollback target`n"

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $target -ExternalText $external -ExternalReadOnly $true -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath $target)|Should Be $external
        (Get-Item -Force -LiteralPath $target).IsReadOnly|Should Be $true
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $state.TransactionPath ([string]$operation.backupLeaf)) -PathType Leaf|Should Be $true
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT90_restores_permissions_on_a_readonly_target' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $stablePath=Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
        [byte[]]$originalBytes=[IO.File]::ReadAllBytes($stablePath)
        $candidateRoot=Join-Path $TestDrive ('readonly-permissions-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('readonly-permissions-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-journal-prepared';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly=$true
        (Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome).RecoveryAction|Should Be 'roll-back'

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-recovery-before-install';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$recoveryExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $recoveryExit|Should Not Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($stablePath))|Should Be ([Convert]::ToBase64String($originalBytes))
        (Get-Item -Force -LiteralPath $stablePath).IsReadOnly|Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $codexHome '.ai-instructions-txn') -Force -ErrorAction SilentlyContinue).Count|Should Be 0
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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

    It 'InterT80_refuses_an_invalid_installer_source_closure_without_mutation' -TestCases @(
        @{Variant='missing'},
        @{Variant='hash-mismatch'}
    ) {
        param($Variant)
        $candidateRoot=Join-Path $TestDrive ("closure-invalid-$Variant-"+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $candidateRoot|Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'catalog') -Destination $candidateRoot -Recurse
        foreach($leaf in @('LICENSE','NOTICE','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md','licensing-scope.json')){
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $leaf) -Destination (Join-Path $candidateRoot $leaf)
        }
        $boundFile=Join-Path $candidateRoot 'scripts\platform\Windows.psm1'
        if($Variant -ceq 'missing'){Remove-Item -LiteralPath $boundFile -Force}
        else{[IO.File]::AppendAllText($boundFile,"`n# invalid closure fixture`n",[Text.UTF8Encoding]::new($false))}
        $archivePath=Join-Path $TestDrive ("closure-invalid-$Variant.zip")
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join '').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $output=& $script:TestPowerShellExecutable @arguments 2>&1
        $LASTEXITCODE|Should Not Be 0
        (Get-AiInstructionsRefusalCode ($output-join[Environment]::NewLine))|Should Be closure-invalid
        Test-Path -LiteralPath $codexHome|Should Be $false
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    It 'InterT86_refuses_cleanup_of_a_replaced_transaction_artifact' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome|Out-Null
        $candidateRoot=Join-Path $TestDrive ('cleanup-cas-'+[Guid]::NewGuid().ToString('N'))
        New-InstallerFailpointCandidate -SourceRoot $repositoryRoot -DestinationRoot $candidateRoot
        $archivePath=Join-Path $TestDrive ('cleanup-cas-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $archiveSha256=New-InstallerSourceArchive -SourceRoot $candidateRoot -ArchivePath $archivePath
        $sourceCommit=(@(& git -C $repositoryRoot rev-parse HEAD)-join'').Trim()
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:InstallScript,'-RepositoryRoot',$repositoryRoot,'-CodexHome',$codexHome,'-Acquisition','github-codeload','-SourceRepository','https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git','-SourceCommit',$sourceCommit,'-ArchiveSha256',$archiveSha256,'-SourceArchivePath',$archivePath)
        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT='after-committed-before-cleanup';& $script:TestPowerShellExecutable @arguments 2>&1|Out-Null;$crashExit=$LASTEXITCODE}
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}
        $crashExit|Should Not Be 0
        $state=Get-InstallerTransactionRecoveryState -RepositoryRoot $repositoryRoot -CodexHome $codexHome
        $state.JournalPhase|Should Be committed
        $operation=@($state.Journal.operations|Where-Object{$null-ne$_.backupLeaf -and [string]$_.kind -eq 'write-file'}|Select-Object -First 1)
        $operation.Count|Should Be 1
        $backup=Join-Path $state.TransactionPath ([string]$operation[0].backupLeaf)
        $external="# external cleanup artifact`n"
        $targetsBefore=Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome

        $saved=$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT
        try{
            Remove-Item Env:\AI_INSTRUCTIONS_INSTALL_FAILPOINT -ErrorAction SilentlyContinue
            $result=Invoke-InstallerRecoveryMutationProbe -InstallerScript (Resolve-Path -LiteralPath $script:InstallScript).Path -RepositoryRoot $repositoryRoot -CodexHome $codexHome -SourceCommit $sourceCommit -ArchiveSha256 $archiveSha256 -ArchivePath $archivePath -MutationPath $backup -ExternalText $external -ExternalReadOnly $true -ProbeRoot $TestDrive
        }
        finally{$env:AI_INSTRUCTIONS_INSTALL_FAILPOINT=$saved}

        $result|Should Match '(?m)^1\r?$'
        (Get-AiInstructionsRefusalCode (Remove-TestAnsiControlSequence $result))|Should Be interrupted-install
        (Get-Content -Raw -LiteralPath $backup)|Should Be $external
        (Get-Item -Force -LiteralPath $backup).IsReadOnly|Should Be $true
        (Get-InstallerStateSnapshot -RepositoryRoot $repositoryRoot -CodexHome $codexHome)|Should Be $targetsBefore
        Test-Path -LiteralPath (Join-Path $state.TransactionPath 'journal.json') -PathType Leaf|Should Be $true
    }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        It 'InterT78_preserves_windows_install_lock_interoperability_with_the_legacy_protocol' {
            New-Item -ItemType Directory -Force -Path $codexHome|Out-Null
            Import-Module (Join-Path $repositoryRoot 'scripts\platform-runtime.psd1') -Force
            $root=Open-PlatformDirectory -Root $codexHome -RootOnly
            $lease=Enter-PlatformLock -ParentLease $root -Leaf ai-instructions-install.lock -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            try{
                $legacyCaught=$null
                try{$legacy=[IO.File]::Open((Join-Path $codexHome 'ai-instructions-install.lock'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$legacy.Dispose()}catch{$legacyCaught=$_}
                $legacyCaught|Should Not BeNullOrEmpty
            }finally{$lease.Dispose();$root.Dispose()}
            $legacy=[IO.File]::Open((Join-Path $codexHome 'ai-instructions-install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{$result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome}finally{$legacy.Dispose()}
            $result.ExitCode|Should Not Be 0
            $result.Output|Should Match 'Another AI instructions installer is already running for this Codex Home\.'
        }
    }

}
