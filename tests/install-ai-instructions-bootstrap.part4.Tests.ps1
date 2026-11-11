. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: Residue has malformed journal bytes or a non-transaction name.
    # Purpose: Refuse the complete residue set without changing evidence or installation targets.
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

    # Scenario: A legacy installer left one of the pre-journal staging namespaces.
    # Purpose: List and preserve legacy evidence instead of interpreting it as journal v1 state.
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
        # Scenario: Windows PowerShell 5.1 starts the PowerShell-7-only installer.
        # Purpose: Return the typed baseline refusal before creating Codex Home or transaction artifacts.
        It 'InterT75_windows_powershell_5_1_returns_typed_runtime_baseline_refusal_without_mutation' {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome 2>&1
            $LASTEXITCODE | Should Not Be 0
            (Get-AiInstructionsRefusalCode ($output -join [Environment]::NewLine)) | Should Be runtime-baseline-unavailable
            Test-Path -LiteralPath $codexHome | Should Be $false
        }
    }


    # Scenario: One required capability has a real unavailable receipt with diagnostic evidence.
    # Purpose: Map capability selection to a typed installer refusal without a production override switch.
    It 'InterT76_maps_an_unavailable_capability_receipt_to_a_typed_refusal' {
        $module=Import-Module (Join-Path $repositoryRoot 'scripts\ai-instructions-install-transaction.psm1') -Force -PassThru
        $names=@('directory-lease','file-lease','file-identity','lock','publication','owned-file-removal','permissions','directory-publication')
        $receipt=[pscustomobject]@{capabilities=@($names|ForEach-Object{[pscustomobject]@{name=$_;status=$(if($_ -ceq 'publication'){'unavailable'}else{'available'});evidence=@("probe evidence for $_")}})}
        $caught=$null
        try{& $module {param($value)Assert-AiInstructionsInstallerCapabilities -Receipt $value} $receipt|Out-Null}catch{$caught=$_}
        $caught|Should Not BeNullOrEmpty
        (Get-AiInstructionsRefusalCode $caught)|Should Be capability-unavailable
        $caught.Exception.Message|Should Match 'publication=unavailable: probe evidence for publication'
    }


    # Scenario: The immutable installer source closure has a missing file or a bound hash mismatch.
    # Purpose: Return the D16 closure-invalid code before importing candidate runtime code or mutating Codex Home.
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

    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        # Scenario: The installer runs on a Linux or macOS Core host without directory publication.
        # Purpose: Refuse with capability evidence before creating or changing Codex Home.
        It 'InterT79_unix_refuses_unavailable_directory_publication_without_mutation' {
            $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
            $result.ExitCode|Should Not Be 0
            (Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            $result.Output|Should Match 'directory-publication'
            Test-Path -LiteralPath $codexHome|Should Be $false
        }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: Each failpoint grammar family kills a subprocess at a durable install or recovery boundary.
    # Purpose: Stop after recovery, prove one complete original/applied state, then install and prove an identity-stable rerun.
    It 'InterT77_recovers_the_install_journal_failpoint_matrix_to_an_idempotent_complete_state' -TestCases @(
        @{Failpoint='after-recovery-before-install';PreCrash=$null;Fresh=$true;ExpectedRecovery='no-transaction';ExpectedPhase=$null;ExpectedFinal='original'},
        @{Failpoint='after-journal-prepared';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='prepared';ExpectedFinal='original'},
        @{Failpoint='after-journal-stage-flush';PreCrash=$null;Fresh=$false;ExpectedRecovery='purge-orphan';ExpectedPhase=$null;ExpectedFinal='original'},
        @{Failpoint='after-journal-publish-before-parent-flush';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='prepared';ExpectedFinal='original'},
        @{Failpoint='before-operation-1';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='before-operation-5';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='before-operation-6';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-original-to-backup-5';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-1-before-journal';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-5-before-journal';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-6-before-journal';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-1';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-5';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-6';PreCrash=$null;Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-committed-before-cleanup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='before-cleanup-op-01-bootstrap.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='after-cleanup-op-01-bootstrap.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='before-cleanup-op-05-runtime.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='during-cleanup-op-05-runtime.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='after-cleanup-op-05-runtime.backup';PreCrash=$null;Fresh=$false;ExpectedRecovery='none';ExpectedPhase='committed';ExpectedFinal='applied'},
        @{Failpoint='after-rollback-operation-1';PreCrash='after-operation-1-before-journal';Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='rolling-back';ExpectedFinal='original'},
        @{Failpoint='after-rollback-operation-5';PreCrash='after-operation-5-before-journal';Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='rolling-back';ExpectedFinal='original'},
        @{Failpoint='after-rollback-operation-6';PreCrash='after-operation-6-before-journal';Fresh=$false;ExpectedRecovery='roll-back';ExpectedPhase='rolling-back';ExpectedFinal='original'},
        @{Failpoint='after-operation-1-before-journal';PreCrash=$null;Fresh=$true;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'},
        @{Failpoint='after-operation-5-before-journal';PreCrash=$null;Fresh=$true;ExpectedRecovery='roll-back';ExpectedPhase='applying';ExpectedFinal='original'}
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

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {

    # Scenario: A create-file crash is followed by an external replacement of the target with a directory.
    # Purpose: Refuse the type-confused observation and preserve both the external target and transaction evidence.
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

    # Scenario: A pending write-file already displaced its original into backup, then an external writer replaces the published target before the journal records applied.
    # Purpose: Refuse recovery without mutating any target, the identity-bound original backup, or the durable journal evidence.
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

    # Scenario: Recovery classifies an applied write-file target, then an external writer replaces it before restore-original runs.
    # Purpose: Bind rollback publication to operation.applied so the external bytes and permissions survive and transaction evidence remains available.
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

    # Scenario: Recovery selects restore-permissions for original bytes, then an external writer replaces the target before the permission step.
    # Purpose: Verify journal original identity and content through the target lease before changing permissions, leaving the replacement untouched on refusal.
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

    # Scenario: A committed transaction is ready for terminal cleanup, then an external writer replaces an original backup after the recovery plan is built.
    # Purpose: Delete only a backup whose full journal-bound identity and content still match, preserving a replacement and all recovery evidence on refusal.
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

    # Scenario: Recovery classifies a committed journal store, then an external writer replaces journal.json with the same valid bytes on a different inode before cleanup starts.
    # Purpose: Bind terminal cleanup to the classified journal identity as well as its content, refusing without deleting the replacement or any transaction evidence.
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

    # Scenario: Recovery classifies a valid committed journal beside a UTF-8 journal.stage whose JSON is malformed.
    # Purpose: Require journal.stage to be the current or next journal generation before cleanup, refusing and retaining all evidence otherwise.
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


    # Scenario: An existing read-only stable file is displaced, then the installer is interrupted after publishing its replacement.
    # Purpose: Recovery must publish the read-only backup through a read lease and restore its exact bytes and ReadOnly attribute.
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

    # Scenario: A prepared rollback finds original bytes and identity on a target whose ReadOnly attribute drifted to true.
    # Purpose: The restore-permissions step must reopen the read-only target without GENERIC_WRITE and restore the journal snapshot.
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
        # Scenario: The new platform lock and the legacy File.Open lock contend in both protocol directions.
        # Purpose: Preserve FileShare.Read/None compatibility while migrating only the installer lock implementation.
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
