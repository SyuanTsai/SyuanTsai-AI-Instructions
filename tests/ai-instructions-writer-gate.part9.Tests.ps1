. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

Describe 'AI instructions unified repository transaction recovery behaviors' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:BootstrapPath=Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1'
        $script:TransactionModulePath=Join-Path $script:RepositoryRoot 'scripts/ai-instructions-install-transaction.psm1'
        $script:P9cBaseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'baseline-work') -ArchivePath (Join-Path $script:ExternalRoot 'baseline.zip') -Marker baseline
        $script:P9cChanged=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'changed-work') -ArchivePath (Join-Path $script:ExternalRoot 'changed.zip') -Marker changed
        $initialFiles=@{'work-with-jira'=@{'resources/state.txt'="jira old`n"};'manage-task-handoff'=@{'resources/state.txt'="handoff old`n"}}
        $updatedFiles=@{'work-with-jira'=@{'resources/state.txt'="jira new`n";'resources/added.txt'="jira added`n"};'manage-task-handoff'=@{'resources/state.txt'="handoff new`n";'resources/added.txt'="handoff added`n"}}
        $script:P9cInitial=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'initial') -ProjectionIds @('project-agents') -AdditionalSkillFiles $initialFiles
        $script:P9cUpdated=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'updated') -ProjectionIds @('project-agents') -AdditionalSkillFiles $updatedFiles
        $script:P9cNoProjectInitial=New-P9bBootstrapContext -Root (Join-Path $script:ExternalRoot 'no-project-initial') -CodexHome $script:P9cInitial.Home -ProjectProjectionIds @()
        $script:P9cNoProjectUpdated=New-P9bBootstrapContext -Root (Join-Path $script:ExternalRoot 'no-project-updated') -CodexHome $script:P9cUpdated.Home -ProjectProjectionIds @()
        $script:P9cSeeds=@{}
        foreach($withRemediation in @($false,$true)){
            $seed=Join-Path $script:ExternalRoot ("seed-$withRemediation");New-P9bTargetRepository $seed
            $result=Invoke-P9bRepoBootstrap -Context $script:P9cInitial.Context -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $seed
            if($result.ExitCode-ne0){throw "Could not create recovery seed: $($result.Output)"}
            if($withRemediation){& git -C $seed add -f -- AGENTS.md;& git -C $seed commit --quiet -m 'tracked Agent artifact fixture';if($LASTEXITCODE-ne0){throw 'Could not create remediation seed.'}}
            $emptyTransactionRoot=Get-P9cRepositoryTransactionRoot -Repository $seed;if(Test-Path -LiteralPath $emptyTransactionRoot){Remove-Item -LiteralPath $emptyTransactionRoot -Force}
            $script:P9cSeeds[[string]$withRemediation]=$seed
        }
        $script:NoProjectSeed=Join-Path $script:ExternalRoot 'no-project-seed';New-P9bTargetRepository $script:NoProjectSeed
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cNoProjectInitial -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $script:NoProjectSeed
        if($result.ExitCode-ne0){throw "Could not create non-opt-in seed: $($result.Output)"}
        $emptyTransactionRoot=Get-P9cRepositoryTransactionRoot -Repository $script:NoProjectSeed;if(Test-Path -LiteralPath $emptyTransactionRoot){Remove-Item -LiteralPath $emptyTransactionRoot -Force}
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: A fully current project fixture is bootstrapped again with no file, Git, manifest, or exclude intent.
    # Purpose: Leave every file-tree byte unchanged and avoid creating .ai-instructions-txn for a no-op run.
    # Scenario: index.lock contains the journaled after bytes before rename, index has just been renamed before long-lock reacquisition, index has been published before operation-state update, or an unrelated lock predates the transaction.
    # Purpose: Roll forward only the applying transaction's exact lock, recover all three index publication crash windows, and preserve a foreign lock plus index bytes unchanged.
    It 'InterT152_enforces_index_lock_write_ahead_atomic_replace_and_residual_lock_rules' {
        $discovery=Join-Path $script:ExternalRoot 'index-discovery';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'index-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $sequence=@($journal.operations|Where-Object role -ceq git-index)[0].sequence
        $expectedTarget=Join-Path $script:ExternalRoot 'index-expected';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $expectedTarget -Recurse
        $expectedResult=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $expectedTarget
        if($expectedResult.ExitCode-ne0){throw "Index expected-state bootstrap failed: $($expectedResult.Output)"}
        $expectedAgentsBytes=[IO.File]::ReadAllBytes((Join-Path $expectedTarget 'AGENTS.md'))
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'r152') -Failpoint RecoveryOnly
        $failpointCases=New-Object System.Collections.Generic.List[object];$caseIndex=0
        foreach($failpoint in @('after-index-lock-write-before-rename','after-index-rename-before-reacquire','after-index-operation-before-journal')){
            $actualFailpoint=if($failpoint-ceq'after-index-operation-before-journal'){"after-operation-$sequence-before-journal"}else{$failpoint}
            foreach($recoveryPath in @('InProcess','NextRun')){
                $failpointCases.Add([pscustomobject]@{Index=$caseIndex;Failpoint=$failpoint;ActualFailpoint=$actualFailpoint;RecoveryPath=$recoveryPath;ExternalRoot=$script:ExternalRoot;Seed=$script:P9cSeeds.True;Context=$script:P9cUpdated.Context;ArchivePath=$script:P9cChanged.ArchivePath;Recovery=$recovery});$caseIndex++
            }
        }
        $failpointWorker={param($case)
            $caseParent=Join-Path $case.ExternalRoot ("p152f-"+$case.Index);New-Item -ItemType Directory -Path $caseParent|Out-Null
            $target=Join-Path $caseParent 'repo';Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse;$before=Get-P9cPublicationStateSnapshot $target
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $caseParent 'fp') -Failpoint $case.ActualFailpoint -RecoveryPath $case.RecoveryPath
            $failed=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
            $observation=[ordered]@{FailedExitCode=$failed.ExitCode;Before=$before}
            if($case.RecoveryPath-ceq'NextRun'){$observation.RecoveryExitCode=(Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $case.Recovery).ExitCode}
            $observation.AfterRecovery=Get-P9cPublicationStateSnapshot $target
            $indexPath=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $target $indexPath};$observation.LockExists=Test-Path -LiteralPath ($indexPath+'.lock')
            $rerun=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target;$observation.RerunExitCode=$rerun.ExitCode;$observation.RerunOutput=$rerun.Output
            if($rerun.ExitCode-eq0){$agentsPath=Join-Path $target 'AGENTS.md';$observation.AgentsExists=Test-Path -LiteralPath $agentsPath -PathType Leaf;if($observation.AgentsExists){$observation.AgentsBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsPath))}}
            return [pscustomobject]$observation
        }
        $failpointResults=@(Invoke-P9cParallelCases -Cases $failpointCases.ToArray() -Worker $failpointWorker);$resultIndex=0
        foreach($failpoint in @('after-index-lock-write-before-rename','after-index-rename-before-reacquire','after-index-operation-before-journal')){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $result=$failpointResults[$resultIndex++];if($null-ne$result.ErrorMessage){throw $result.ErrorMessage};$observation=$result.Value
                $observation.FailedExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){$observation.RecoveryExitCode|Should -Not -Be 0}
                $observation.AfterRecovery|Should -Be $observation.Before
                $observation.LockExists|Should -Be $false
                if($observation.RerunExitCode-ne0){throw "Index recovery rerun failed for $failpoint/$recoveryPath`: $($observation.RerunOutput)"}
                $observation.AgentsExists|Should -Be $true
                $observation.AgentsBytes|Should -Be ([Convert]::ToBase64String($expectedAgentsBytes))
            }
        }
        $tamperCases=New-Object System.Collections.Generic.List[object];$caseIndex=0
        foreach($tamperKind in @('EmptyBytes','MismatchedBytes','CommittedPhase','NoJournal')){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $tamperCases.Add([pscustomobject]@{Index=$caseIndex;TamperKind=$tamperKind;RecoveryPath=$recoveryPath;ExternalRoot=$script:ExternalRoot;Seed=$script:P9cSeeds.True;Context=$script:P9cUpdated.Context;ArchivePath=$script:P9cChanged.ArchivePath});$caseIndex++
            }
        }
        $tamperWorker={param($case)
            $caseParent=Join-Path $case.ExternalRoot ("p152t-"+$case.Index);New-Item -ItemType Directory -Path $caseParent|Out-Null
            $target=Join-Path $caseParent 'repo';Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
            Get-P9cPublicationStateSnapshot $target|Out-Null
            $index=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $target $index};$indexBefore=[IO.File]::ReadAllBytes($index)
            $bootstrap=New-P9cIndexLockTamperBootstrap -Root (Join-Path $caseParent 'fp') -TamperKind $case.TamperKind -RecoveryPath $case.RecoveryPath
            $failed=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
            $observation=[ordered]@{FailedExitCode=$failed.ExitCode;IndexBefore=[Convert]::ToBase64String($indexBefore)}
            if($case.RecoveryPath-ceq'NextRun'){$retry=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target;$observation.RetryExitCode=$retry.ExitCode;$observation.RetryRefusalCode=Get-AiInstructionsRefusalCode $retry.Output}
            $observation.IndexAfter=[Convert]::ToBase64String([IO.File]::ReadAllBytes($index));$observation.LockExists=Test-Path -LiteralPath ($index+'.lock') -PathType Leaf
            return [pscustomobject]$observation
        }
        $tamperResults=@(Invoke-P9cParallelCases -Cases $tamperCases.ToArray() -Worker $tamperWorker);$resultIndex=0
        foreach($tamperKind in @('EmptyBytes','MismatchedBytes','CommittedPhase','NoJournal')){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $result=$tamperResults[$resultIndex++];if($null-ne$result.ErrorMessage){throw $result.ErrorMessage};$observation=$result.Value
                $observation.FailedExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){$observation.RetryExitCode|Should -Not -Be 0;$observation.RetryRefusalCode|Should -Be interrupted-install}
                $observation.IndexAfter|Should -Be $observation.IndexBefore
                $observation.LockExists|Should -Be $true
            }
        }
        $foreign=Join-Path $script:ExternalRoot 'index-foreign';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $foreign -Recurse
        $index=(& git -C $foreign rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $foreign $index};$indexBefore=[IO.File]::ReadAllBytes($index);$lockBytes=[byte[]](1,2,3,4);[IO.File]::WriteAllBytes(($index+'.lock'),$lockBytes)
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $foreign
        $result.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($index))|Should -Be ([Convert]::ToBase64String($indexBefore));[Convert]::ToBase64String([IO.File]::ReadAllBytes($index+'.lock'))|Should -Be ([Convert]::ToBase64String($lockBytes))
    }

    # Scenario: A later operation fails, rollback restores the index, and an external writer creates index.lock in the rename-to-reacquire window of the undo index step.
    # Purpose: Continue reverse three-state rollback, report interrupted-install, and preserve the externally acquired lock byte-for-byte.
    It 'InterT162_preserves_an_external_lock_stolen_during_undo_reacquisition' {
        $discovery=Join-Path $script:ExternalRoot 'index-theft-discovery';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'index-theft-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force)
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $laterSequence=@($journal.operations|Where-Object role -ceq shared-exclude)[0].sequence
        $target=Join-Path $script:ExternalRoot 'index-theft-case';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse
        $index=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $target $index}
        $statusBefore=(@(& git -C $target status --porcelain=v1 --untracked-files=all)-join"`n");$indexBefore=[IO.File]::ReadAllBytes($index);$agentsBefore=[IO.File]::ReadAllBytes((Join-Path $target 'AGENTS.md'))
        $bootstrap=New-P9cIndexReacquireTheftBootstrap -Root (Join-Path $script:ExternalRoot 'index-theft-runtime') -RollbackFailpoint ("after-operation-$laterSequence-before-journal")

        $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap

        $failed.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $failed.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($index))|Should -Be ([Convert]::ToBase64String($indexBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($index+'.lock'))|Should -Be ([Convert]::ToBase64String([byte[]](7,6,5,4)))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target 'AGENTS.md')))|Should -Be ([Convert]::ToBase64String($agentsBefore))
        (@(& git -C $target status --porcelain=v1 --untracked-files=all)-join"`n")|Should -Be $statusBefore
        Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target)|Should -Be $true
    }

    # Scenario: A hard stop leaves the durably prefilled long index lock in prepared, applying, applied, committed, or a transaction without an index step.
    # Purpose: Attribute every recorded before/after lock image to the transaction and converge by phase without manual lock removal.
    It 'InterT163_recovers_prefilled_long_locks_for_every_phase_and_transactions_without_index_steps' {
        $discovery=Join-Path $script:ExternalRoot 'prefill-phase-discovery';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $discovery -Recurse
        $preparedBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'prefill-phase-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $preparedBootstrap).ExitCode|Should -Not -Be 0
        $discoveryTransaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force)
        $discoveryJournal=Get-Content -Raw -LiteralPath (Join-Path $discoveryTransaction[0].FullName 'journal.json')|ConvertFrom-Json
        $indexSequence=[int](@($discoveryJournal.operations|Where-Object kind -ceq replace-git-index)[0].sequence)
        $cases=@(
            [pscustomobject]@{Name='prepared-before';Seed=$script:P9cSeeds.True;Failpoint='after-journal-prepared';Phase='prepared';Expected='before';HasIndex=$true},
            [pscustomobject]@{Name='applying-before';Seed=$script:P9cSeeds.True;Failpoint="before-operation-$indexSequence";Phase='applying';Expected='before';HasIndex=$true},
            [pscustomobject]@{Name='applied-after';Seed=$script:P9cSeeds.True;Failpoint='before-committed-journal-write';Phase='applied';Expected='after';HasIndex=$true},
            [pscustomobject]@{Name='committed-after';Seed=$script:P9cSeeds.True;Failpoint='after-committed-journal-write';Phase='committed';Expected='after';HasIndex=$true},
            [pscustomobject]@{Name='prepared-no-index';Seed=$script:P9cSeeds.False;Failpoint='after-journal-prepared';Phase='prepared';Expected='prefill';HasIndex=$false}
        )
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'r163') -Failpoint RecoveryOnly
        $parallelCases=@(for($index=0;$index-lt$cases.Count;$index++){[pscustomobject]@{Index=$index;Name=$cases[$index].Name;Seed=$cases[$index].Seed;Failpoint=$cases[$index].Failpoint;Phase=$cases[$index].Phase;Expected=$cases[$index].Expected;HasIndex=$cases[$index].HasIndex;ExternalRoot=$script:ExternalRoot;Context=$script:P9cUpdated.Context;ArchivePath=$script:P9cChanged.ArchivePath;Recovery=$recovery}})
        $worker={param($case)
            $caseParent=Join-Path $case.ExternalRoot ("p163-"+$case.Index);New-Item -ItemType Directory -Path $caseParent|Out-Null
            $target=Join-Path $caseParent 'repo';Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $caseParent 'fp') -Failpoint $case.Failpoint -RecoveryPath NextRun
            $failed=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
            $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force)
            $observation=[ordered]@{FailedExitCode=$failed.ExitCode;TransactionCount=$transaction.Count}
            if($transaction.Count-ne1){return [pscustomobject]$observation}
            $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            $lockPath=([string]$journal.scope.indexPath)+'.lock'
            $observation.JournalPhase=[string]$journal.phase;$observation.LockPath=$lockPath;$observation.LockExistsBeforeRecovery=Test-Path -LiteralPath $lockPath -PathType Leaf
            if(-not$observation.LockExistsBeforeRecovery){return [pscustomobject]$observation}
            $lockSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $lockPath).Hash.ToLowerInvariant();$observation.LockSha=$lockSha
            if($case.HasIndex){
                $indexOperation=@($journal.operations|Where-Object kind -ceq replace-git-index)[0]
                $observation.IndexBeforeSha=[string]$indexOperation.before.sha256;$observation.ScopeLockSha=[string]$journal.scope.indexLockContentSha256
                $observation.ExpectedLockSha=if($case.Expected-ceq'before'){[string]$indexOperation.before.sha256}else{[string]$indexOperation.after.sha256}
            }else{$observation.IndexOperationCount=@($journal.operations|Where-Object kind -ceq replace-git-index).Count;$observation.ScopeLockSha=[string]$journal.scope.indexLockContentSha256}
            $observation.RecoveryExitCode=(Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $case.Recovery).ExitCode
            $observation.LockExistsAfterRecovery=Test-Path -LiteralPath $lockPath
            $observation.ResidueCount=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count
            return [pscustomobject]$observation
        }
        $results=@(Invoke-P9cParallelCases -Cases $parallelCases -Worker $worker)
        for($index=0;$index-lt$cases.Count;$index++){
            $case=$cases[$index];$result=$results[$index];if($null-ne$result.ErrorMessage){throw $result.ErrorMessage};$observation=$result.Value
            $observation.FailedExitCode|Should -Not -Be 0
            $observation.TransactionCount|Should -Be 1
            $observation.JournalPhase|Should -BeExactly $case.Phase
            $observation.LockExistsBeforeRecovery|Should -Be $true
            if($case.HasIndex){
                $observation.IndexBeforeSha|Should -BeExactly $observation.ScopeLockSha
                $observation.LockSha|Should -BeExactly $observation.ExpectedLockSha
            }else{$observation.IndexOperationCount|Should -Be 0;$observation.LockSha|Should -BeExactly $observation.ScopeLockSha}
            $observation.RecoveryExitCode|Should -Not -Be 0
            $observation.LockExistsAfterRecovery|Should -Be $false
            $observation.ResidueCount|Should -Be 0
        }
    }

    # Scenario: A residual lock has an unknown SHA, is empty after CreateNew, or is prefilled before any prepared journal exists.
    # Purpose: Refuse both known acquisition windows and every unrecorded lock image while preserving the lock byte-for-byte.
    It 'InterT164_refuses_unknown_and_known_limit_index_lock_windows_without_removing_the_lock' {
        $mismatchTarget=Join-Path $script:ExternalRoot 'prefill-refusal-mismatch';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $mismatchTarget -Recurse
        $mismatchBootstrap=New-P9cIndexLockTamperBootstrap -Root (Join-Path $script:ExternalRoot 'prefill-refusal-mismatch-runtime') -TamperKind MismatchedBytes -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $mismatchTarget -BootstrapPath $mismatchBootstrap).ExitCode|Should -Not -Be 0
        $mismatchIndex=(& git -C $mismatchTarget rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($mismatchIndex)){$mismatchIndex=Join-Path $mismatchTarget $mismatchIndex};$mismatchLock=$mismatchIndex+'.lock';$mismatchBytes=[IO.File]::ReadAllBytes($mismatchLock)
        $mismatchRetry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $mismatchTarget
        $mismatchRetry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $mismatchRetry.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($mismatchLock))|Should -Be ([Convert]::ToBase64String($mismatchBytes))
        foreach($window in @('AfterCreateBeforeWrite','AfterAcquireBeforePrepared')){
            $target=Join-Path $script:ExternalRoot ("prefill-known-limit-"+$window);Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
            $bootstrap=New-P9cIndexLockKnownLimitBootstrap -Root (Join-Path $script:ExternalRoot ("prefill-known-limit-runtime-"+$window)) -Window $window
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
            $index=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $target $index};$lock=$index+'.lock';Test-Path -LiteralPath $lock -PathType Leaf|Should -Be $true
            $lockBytes=[IO.File]::ReadAllBytes($lock)
            if($window-ceq'AfterCreateBeforeWrite'){$lockBytes.Count|Should -Be 0}else{[Convert]::ToBase64String($lockBytes)|Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($index)))}
            $retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
            $retry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $retry.Output)|Should -Be interrupted-install
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($lock))|Should -Be ([Convert]::ToBase64String($lockBytes))
        }
    }

    # Scenario: Finalization hard-stops after releasing the long index lock but before deleting the committed journal.
    # Purpose: Keep the committed journal as the last recovery authority and finish roll-forward cleanup on the next run.
    It 'InterT165_releases_the_long_index_lock_before_committed_journal_cleanup' {
        $target=Join-Path $script:ExternalRoot 'release-before-journal';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'release-before-journal-runtime') -Failpoint after-index-lock-release-before-journal-cleanup -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        $index=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $target $index};Test-Path -LiteralPath ($index+'.lock')|Should -Be $false
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
        [string](Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json).phase|Should -BeExactly committed
        $retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
        $retry.ExitCode|Should -Be 0
        Test-Path -LiteralPath ($index+'.lock')|Should -Be $false
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
    }

    # Scenario: A validated v2 journal advances only its phase or operation states between durable generations.
    # Purpose: Exercise the optimized transition function and reject immutable drift, unknown properties, and reverse transitions.
    It 'UnitT153_accepts_only_phase_and_operation_state_deltas_for_validated_v2_generations' {
        $module=Import-Module $script:TransactionModulePath -Force -PassThru
        try{
            $scopeRoot=[IO.Path]::GetFullPath((Join-Path $TestDrive 'trusted-transition-repo'));$git=Join-Path $scopeRoot '.git'
            $identity=[pscustomobject][ordered]@{kind='windows-file-id';device='00000001';fileId='00000002'};$permissions=[pscustomobject][ordered]@{kind='windows-sddl';sddl='D:PAI(A;;FA;;;SY)';readOnly=$false}
            $previous=[pscustomobject][ordered]@{schemaVersion=2;kind='ai-instructions-install-transaction';transactionId=('a'*32);createdAtUtc='2026-11-12T00:00:00.0000000Z';owner=[pscustomobject][ordered]@{component='repo-bootstrap';processId=1;processStartIdentity='fixture'};platform=[pscustomobject][ordered]@{os='windows';architecture='x64'};lock=[pscustomobject][ordered]@{primitive='windows-fileshare';leaf='bootstrap-ai-instructions.lock'};generation=[pscustomobject][ordered]@{previousBundleSha256=$null;candidateBundleSha256=('b'*64)};scope=[pscustomobject][ordered]@{kind='repository';repositoryRoot=$scopeRoot;repositoryRootIdentity=$identity;commonGitDirectory=$git;gitDirectory=$git;indexPath=(Join-Path $git 'index');indexLockContentSha256=('9'*64);objectFormat='sha1';externalBackup=$null};retainedManifestPaths=@();phase='prepared';operations=@([pscustomobject][ordered]@{sequence=1;kind='create-file';role='instruction';method='stage-rename';target=[pscustomobject][ordered]@{kind='repository-relative';value='AGENTS.md'};before=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;permissions=$null};after=[pscustomobject][ordered]@{exists=$true;sha256=('a'*64);length=3;identity=$identity;permissions=$permissions};observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf='operation-1.stage';backupLeaf=$null;quarantineLeaf=$null;state='pending'},[pscustomobject][ordered]@{sequence=2;kind='store-git-stash-evidence';role='personal-agent-evidence';method='stash-store';target=[pscustomobject][ordered]@{kind='git-stash-evidence';value='refs/stash'};before=[pscustomobject][ordered]@{exists=$false;objectId=$null};after=[pscustomobject][ordered]@{exists=$true;objectId=$null};observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$null;backupLeaf=$null;quarantineLeaf=$null;state='pending'})}
            $clone={param($value)$parameters=@{InputObject=($value|ConvertTo-Json -Depth 30)};if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$parameters.DateKind='String'};ConvertFrom-Json @parameters}
            $applying=&$clone $previous;$applying.phase='applying';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $previous $applying}|Should -Not -Throw
            $withEvidence=&$clone $applying;$withEvidence.operations[1].after.objectId=('c'*40);$withEvidence.operations[1].state='applied';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $applying $withEvidence}|Should -Not -Throw
            $rebound=&$clone $withEvidence;$rebound.operations[1].after.objectId=('d'*40);{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $withEvidence $rebound}|Should -Throw
            $applied=&$clone $applying;$applied.operations[0].observedAfter=[pscustomobject][ordered]@{dacl=[pscustomobject][ordered]@{isNull=$true;isProtected=$false;aclBase64=$null};readOnly=$false};$applied.operations[0].state='applied';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $applying $applied}|Should -Not -Throw
            $drift=&$clone $applying;$drift.operations[0].target.value='CLAUDE.md';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $applying $drift}|Should -Throw
            $unknown=&$clone $applying;$unknown|Add-Member unexpected $true;{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $applying $unknown}|Should -Throw
            $reverse=&$clone $applying;$reverse.phase='prepared';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $applying $reverse}|Should -Throw
        }finally{Remove-Module $module -Force}
    }

    # Scenario: Source wiring is inspected in addition to the behavior tests above.
    # Purpose: Keep comment seams and direct legacy mutation calls absent without treating static checks as recovery evidence.
    It 'UnitT154_keeps_only_supplemental_static_transaction_guards' {
        $bootstrap=[IO.File]::ReadAllText($script:BootstrapPath);$transaction=[IO.File]::ReadAllText($script:TransactionModulePath)
        $bootstrap|Should -Not -Match 'P9C_TEST_HOOK|Invoke-AgentArtifactRemediation\s|Set-RemediationIndexWithoutPaths\s'
        $bootstrap|Should -Match 'Remove-InstallTerminalTransactionArtifacts'
        $bootstrap|Should -Match 'Move-Item\s+-LiteralPath\s+\$lockPath\s+-Destination\s+\$indexPath\s+-Force'
        $bootstrap|Should -Not -Match "\$replaceMethod\s*=\s*\[IO\.File\]\.GetMethod\('Replace'|ReadWriteDelete|Remove-RepositoryIndexLockIfOwned"
        $transaction|Should -Match 'after-cleanup-journal-before-directory|during-cleanup-transaction'
    }
}
Describe 'install journal serialization formats' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:JournalSerializationRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $script:JournalSerializationRoot|Out-Null
        $script:TransactionModulePath=Join-Path $script:RepositoryRoot 'scripts/ai-instructions-install-transaction.psm1'
    }
    AfterAll {if(Test-Path -LiteralPath $script:JournalSerializationRoot){Remove-Item -LiteralPath $script:JournalSerializationRoot -Recurse -Force}}

    # Scenario: A USER-family schema-v1 journal is written through the shared durable journal store.
    # Purpose: Preserve the pre-repo-v2 pretty JSON, LF normalization, terminal LF, and exact UTF-8 bytes for every non-repo writer.
    It 'InterT177_preserves_non_repo_journal_writer_bytes_exactly' {
        $fixturePath=Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-install-journal-v1.example.json'
        $journal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json (Get-Content -Raw -Encoding UTF8 -LiteralPath $fixturePath)
        $transactionRoot=Join-Path $script:JournalSerializationRoot '.ai-instructions-txn';New-Item -ItemType Directory -Force -Path $transactionRoot|Out-Null
        $transactionPath=Join-Path $transactionRoot ([string]$journal.transactionId);New-Item -ItemType Directory -Path $transactionPath|Out-Null
        $module=Import-Module $script:TransactionModulePath -Force -PassThru;$lease=Open-PlatformDirectory -Root $transactionPath -RootOnly
        try{
            $states=[ordered]@{}
            $null=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $journal -PlatformOs windows -JournalStoreStates $states
            [byte[]]$expected=[Text.UTF8Encoding]::new($false).GetBytes((($journal|ConvertTo-Json -Depth 30).Replace("`r`n","`n"))+"`n")
            [byte[]]$actual=[IO.File]::ReadAllBytes((Join-Path $transactionPath 'journal.json'))
            [Convert]::ToBase64String($actual)|Should -BeExactly ([Convert]::ToBase64String($expected))
        }finally{$lease.Dispose();Remove-Module $module -Force}
    }
}

Describe 'repo v2 journal cache conditions' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:TransactionModulePath=Join-Path $script:RepositoryRoot 'scripts/ai-instructions-install-transaction.psm1'
        $baseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'baseline-work') -ArchivePath (Join-Path $script:ExternalRoot 'baseline.zip') -Marker baseline
        $changed=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'changed-work') -ArchivePath (Join-Path $script:ExternalRoot 'changed.zip') -Marker changed
        $initial=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'initial') -ProjectionIds @('project-agents')
        $updated=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'updated') -ProjectionIds @('project-agents') -AdditionalSkillFiles @{'work-with-jira'=@{'resources/cache.txt'="changed`n"}}
        $seed=Join-Path $script:ExternalRoot 'seed';New-P9bTargetRepository $seed
        $seedResult=Invoke-P9bRepoBootstrap -Context $initial.Context -ArchivePath $baseline.ArchivePath -TargetRoot $seed
        if($seedResult.ExitCode-ne0){throw "Could not create journal cache seed: $($seedResult.Output)"}
        $emptyTransactionRoot=Get-P9cRepositoryTransactionRoot -Repository $seed;if(Test-Path -LiteralPath $emptyTransactionRoot){Remove-Item -LiteralPath $emptyTransactionRoot -Force}
        $script:JournalCacheSeed=Join-Path $script:ExternalRoot 'journal-cache-seed';Copy-Item -LiteralPath $seed -Destination $script:JournalCacheSeed -Recurse
        $cacheBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'journal-cache-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        $cacheResult=Invoke-P9bRepoBootstrap -Context $updated.Context -ArchivePath $changed.ArchivePath -TargetRoot $script:JournalCacheSeed -BootstrapPath $cacheBootstrap
        if($cacheResult.ExitCode-eq0){throw 'Could not retain the prepared repository journal cache fixture.'}
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: A compact repo-v2 journal is advanced while no trusted-object cache entry exists for the previous generation.
    # Purpose: Recompute the previous compact bytes for raw SHA/length comparison and keep the newly published generation compact.
    It 'InterT178_uses_compact_repo_v2_bytes_on_cache_miss_and_publication' {
        $target=Join-Path $script:ExternalRoot 'journal-cache-miss-format';Copy-Item -LiteralPath $script:JournalCacheSeed -Destination $target -Recurse
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
        $transactionPath=$transaction[0].FullName;$journalPath=Join-Path $transactionPath 'journal.json'
        $module=Import-Module $script:TransactionModulePath -Force -PassThru;$lease=Open-PlatformDirectory -Root $transactionPath -RootOnly
        try{
            $states=[ordered]@{};foreach($leaf in @('journal.json','journal.prev','journal.stage')){$states[$leaf]=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath (Join-Path $transactionPath $leaf) -PlatformOs windows}
            $previous=&$module {param($transactionLease,$transactionId) Read-AiInstructionsInstallJournalLeaf -TransactionLease $transactionLease -Leaf 'journal.json' -TransactionId $transactionId -ExpectedOwnerComponent 'repo-bootstrap'} $lease ([IO.Path]::GetFileName($transactionPath))
            $states.Contains('__repoV2TrustedJournal')|Should -Be $false
            [byte[]]$expectedPrevious=[Text.UTF8Encoding]::new($false).GetBytes(($previous|ConvertTo-Json -Depth 30 -Compress)+"`n")
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should -BeExactly ([Convert]::ToBase64String($expectedPrevious))
            $next=Copy-P9cJournalPreservingStrings $previous;$next.phase='applying'
            $returned=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $next -PreviousJournal $previous -PlatformOs windows -JournalStoreStates $states
            [byte[]]$expectedNext=[Text.UTF8Encoding]::new($false).GetBytes(($next|ConvertTo-Json -Depth 30 -Compress)+"`n")
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should -BeExactly ([Convert]::ToBase64String($expectedNext))
            [object]::ReferenceEquals($returned,$next)|Should -Be $true
        }finally{$lease.Dispose();Remove-Module $module -Force}
    }

    # Scenario: A repo-v2 journal generation is read back, returned to its caller, and then the caller mutates top-level and nested values.
    # Purpose: Keep the cache's trusted content and disk identity independent from every caller-owned journal object.
    It 'InterT156_keeps_trusted_journal_cache_content_isolated_from_the_caller' {
        $target=Join-Path $script:ExternalRoot 'journal-cache-caller';Copy-Item -LiteralPath $script:JournalCacheSeed -Destination $target -Recurse
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
        $transactionPath=$transaction[0].FullName;$journalPath=Join-Path $transactionPath 'journal.json'
        $module=Import-Module $script:TransactionModulePath -Force -PassThru;$lease=Open-PlatformDirectory -Root $transactionPath -RootOnly
        try{
            $states=[ordered]@{};foreach($leaf in @('journal.json','journal.prev','journal.stage')){$states[$leaf]=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath (Join-Path $transactionPath $leaf) -PlatformOs windows}
            $previous=&$module {param($transactionLease,$transactionId) Read-AiInstructionsInstallJournalLeaf -TransactionLease $transactionLease -Leaf 'journal.json' -TransactionId $transactionId -ExpectedOwnerComponent 'repo-bootstrap'} $lease ([IO.Path]::GetFileName($transactionPath));$next=Copy-P9cJournalPreservingStrings $previous;$next.phase='applying'
            $returned=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $next -PreviousJournal $previous -PlatformOs windows -JournalStoreStates $states
            $cache=$states['__repoV2TrustedJournal'];$cache|Should -Not -BeNullOrEmpty
            $cache.trustedJournal|Should -Not -BeNullOrEmpty
            [string]$cache.sha256|Should -Match '^[0-9a-f]{64}$'
            [int64]$cache.length|Should -BeGreaterThan 0
            [object]::ReferenceEquals($cache.trustedJournal,$returned)|Should -Be $false
            $trustedBefore=$cache.trustedJournal|ConvertTo-Json -Depth 30 -Compress;$shaBefore=[string]$cache.sha256;$lengthBefore=[int64]$cache.length
            $returned.phase='committed';$returned.operations[0].state='applied'
            ($cache.trustedJournal|ConvertTo-Json -Depth 30 -Compress)|Should -BeExactly $trustedBefore
            [string]$cache.sha256|Should -BeExactly $shaBefore
            [int64]$cache.length|Should -Be $lengthBefore
        }finally{$lease.Dispose();Remove-Module $module -Force}
    }

    # Scenario: journal.json is externally rewritten between two transitions while the caller reuses the previously returned object.
    # Purpose: Require both caller object identity and current raw SHA-256/length, clear the stale cache, and fail closed without overwriting external bytes.
    It 'InterT157_rejects_external_journal_bytes_and_clears_the_trusted_cache' {
        $target=Join-Path $script:ExternalRoot 'journal-cache-external';Copy-Item -LiteralPath $script:JournalCacheSeed -Destination $target -Recurse
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
        $transactionPath=$transaction[0].FullName;$journalPath=Join-Path $transactionPath 'journal.json'
        $module=Import-Module $script:TransactionModulePath -Force -PassThru;$lease=Open-PlatformDirectory -Root $transactionPath -RootOnly
        try{
            $states=[ordered]@{};foreach($leaf in @('journal.json','journal.prev','journal.stage')){$states[$leaf]=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath (Join-Path $transactionPath $leaf) -PlatformOs windows}
            $previous=&$module {param($transactionLease,$transactionId) Read-AiInstructionsInstallJournalLeaf -TransactionLease $transactionLease -Leaf 'journal.json' -TransactionId $transactionId -ExpectedOwnerComponent 'repo-bootstrap'} $lease ([IO.Path]::GetFileName($transactionPath));$applying=Copy-P9cJournalPreservingStrings $previous;$applying.phase='applying'
            $returned=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $applying -PreviousJournal $previous -PlatformOs windows -JournalStoreStates $states
            $next=Copy-P9cJournalPreservingStrings $returned;$next.operations[0].state='applied'
            $external=[byte[]](@([IO.File]::ReadAllBytes($journalPath))+[byte][char]' ');[IO.File]::WriteAllBytes($journalPath,$external)
            {Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $next -PreviousJournal $returned -PlatformOs windows -JournalStoreStates $states}|Should -Throw
            $states.Contains('__repoV2TrustedJournal')|Should -Be $false
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))|Should -BeExactly ([Convert]::ToBase64String($external))
        }finally{$lease.Dispose();Remove-Module $module -Force}
    }

    # Scenario: publication succeeds but the final journal readback is changed before exact-byte verification.
    # Purpose: Clear the prior trusted cache whenever expected readback bytes do not match the published journal.
    It 'InterT158_clears_the_trusted_cache_when_final_readback_bytes_differ' {
        $target=Join-Path $script:ExternalRoot 'journal-cache-readback';Copy-Item -LiteralPath $script:JournalCacheSeed -Destination $target -Recurse
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
        $transactionPath=$transaction[0].FullName;$journalPath=Join-Path $transactionPath 'journal.json'
        $module=Import-Module $script:TransactionModulePath -Force -PassThru;$lease=Open-PlatformDirectory -Root $transactionPath -RootOnly
        try{
            $states=[ordered]@{};foreach($leaf in @('journal.json','journal.prev','journal.stage')){$states[$leaf]=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath (Join-Path $transactionPath $leaf) -PlatformOs windows}
            $previous=&$module {param($transactionLease,$transactionId) Read-AiInstructionsInstallJournalLeaf -TransactionLease $transactionLease -Leaf 'journal.json' -TransactionId $transactionId -ExpectedOwnerComponent 'repo-bootstrap'} $lease ([IO.Path]::GetFileName($transactionPath));$applying=Copy-P9cJournalPreservingStrings $previous;$applying.phase='applying'
            $returned=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $applying -PreviousJournal $previous -PlatformOs windows -JournalStoreStates $states
            $next=Copy-P9cJournalPreservingStrings $returned;$next.operations[0].state='applied'
            &$module {param($Path)
                $script:Fix5gOriginalJournalRead=(Get-Command Read-AiInstructionsInstallJournalLeaf).ScriptBlock;$script:Fix5gJournalPath=$Path
                function script:Read-AiInstructionsInstallJournalLeaf {
                    param([Parameter(Mandatory=$true)]$TransactionLease,[Parameter(Mandatory=$true)][string]$Leaf,[Parameter(Mandatory=$true)][string]$TransactionId,[string]$ExpectedOwnerComponent,[AllowNull()][byte[]]$ExpectedBytes)
                    if($Leaf-ceq'journal.json'-and$PSBoundParameters.ContainsKey('ExpectedBytes')){[IO.File]::WriteAllBytes($script:Fix5gJournalPath,[Text.UTF8Encoding]::new($false).GetBytes('{}'))}
                    &$script:Fix5gOriginalJournalRead @PSBoundParameters
                }
            } $journalPath
            {Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $next -PreviousJournal $returned -PlatformOs windows -JournalStoreStates $states}|Should -Throw
            $states.Contains('__repoV2TrustedJournal')|Should -Be $false
        }finally{$lease.Dispose();Remove-Module $module -Force}
    }
}
