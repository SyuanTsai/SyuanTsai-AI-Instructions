. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'install-ai-instructions-bootstrap' {
    BeforeEach {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $codexHome = Join-Path $TestDrive ('.codex-' + [Guid]::NewGuid().ToString('N'))
    }

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

    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        It 'InterT79_unix_refuses_unavailable_directory_publication_without_mutation' {
            $result=Invoke-InstallExpectFailure -RepositoryRoot $repositoryRoot -CodexHome $codexHome
            $result.ExitCode|Should Not Be 0
            (Get-AiInstructionsRefusalCode $result.Output)|Should Be capability-unavailable
            $result.Output|Should Match 'directory-publication'
            Test-Path -LiteralPath $codexHome|Should Be $false
        }
    }

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
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

}
