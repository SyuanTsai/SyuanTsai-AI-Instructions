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
    It 'InterT143_leaves_the_filesystem_unchanged_when_the_plan_has_no_mutation' {
        $target=$script:P9cSeeds[[string]$false]
        $before=Get-P7eTreeSnapshot $target
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cInitial.Context -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $target
        $result.ExitCode|Should -Be 0
        (Get-P7eTreeSnapshot $target)|Should -Be $before
        Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target)|Should -Be $false
    }

    # Scenario: A next-run failpoint retains a readable prepared transaction under the active worktree Git directory.
    # Purpose: Keep durable transaction evidence without adding an untracked path or otherwise changing worktree status.
    It 'InterT160_keeps_the_worktree_clean_while_transaction_evidence_is_retained' {
        $target=Join-Path $script:ExternalRoot 'retained-evidence-clean-status';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $statusBefore=(@(& git -C $target status --porcelain=v1 --untracked-files=all)-join"`n")
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'retained-evidence-runtime') -Failpoint 'after-journal-prepared' -RecoveryPath NextRun

        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap

        $result.ExitCode|Should -Not -Be 0
        $transactions=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force)
        $transactions.Count|Should -Be 1
        Test-Path -LiteralPath (Join-Path $transactions[0].FullName 'journal.json') -PathType Leaf|Should -Be $true
        Test-Path -LiteralPath (Join-Path $target '.ai-instructions-txn')|Should -Be $false
        (@(& git -C $target status --porcelain=v1 --untracked-files=all)-join"`n")|Should -Be $statusBefore
    }

    # Scenario: Prepared repository transactions with and without tracked-artifact remediation invoke an external git add while the long index lock is held.
    # Purpose: Keep ordinary Git staging excluded from the end of preflight through transaction finalization on both planner branches.
    It 'InterT161_blocks_external_git_add_with_the_long_lock_with_and_without_remediation' {
        foreach($withRemediation in @($false,$true)){
            $target=Join-Path $script:ExternalRoot "long-lock-$withRemediation";Copy-Item -LiteralPath $script:P9cSeeds[[string]$withRemediation] -Destination $target -Recurse
            $probePath=Join-Path $script:ExternalRoot "long-lock-$withRemediation.txt"
            $bootstrap=New-P9cLongIndexLockProbeBootstrap -Root (Join-Path $script:ExternalRoot "long-lock-runtime-$withRemediation") -ProbePath $probePath

            $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap

            $result.ExitCode|Should -Not -Be 0
            $probe=[IO.File]::ReadAllText($probePath)
            $probe|Should -Match '^(?!0(?:\r?\n|$))'
            $probe|Should -Match 'index\.lock|Unable to create'
        }
    }

    # Scenario: Remediation planning reaches a durable prepared journal and stops before the first index mutation.
    # Purpose: Prove index, ref, remediation files, manifest, and shared exclude are all pending in one write-ahead journal while the complete target state is unchanged.
    It 'InterT144_journals_each_remediation_substep_before_mutation' {
        $target=Join-Path $script:ExternalRoot 'write-ahead';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse
        $before=Get-P9cPublicationStateSnapshot $target
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'write-ahead-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
        $failed.ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force)
        if($transaction.Count-ne1){throw "Prepared remediation discovery did not retain one transaction: $($failed.Output)"}
        $transaction.Count|Should -Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        [string]$journal.phase|Should -Be prepared
        @($journal.operations|Where-Object state -cne pending).Count|Should -Be 0
        foreach($role in @('git-index','git-ref','remediation-and-instruction','manifest','shared-exclude')){@($journal.operations|Where-Object role -ceq $role).Count|Should -BeGreaterThan 0}
        $evidence=@($journal.operations|Where-Object kind -ceq store-git-stash-evidence);$evidence.Count|Should -Be 1
        [string]$evidence[0].target.value|Should -BeExactly 'refs/stash'
        $evidence[0].after.exists|Should -Be $true
        $null-eq$evidence[0].after.objectId|Should -Be $true
        [string]$evidence[0].state|Should -BeExactly pending
        (Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json).files|Should -Be (($before|ConvertFrom-Json).files)
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'write-ahead-recovery') -Failpoint RecoveryOnly
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
        (Get-P9cPublicationStateSnapshot $target)|Should -Be $before
    }

    # Scenario: Recovery is interrupted immediately after undoing each remediation index, ref, or combined file step.
    # Purpose: Re-enter the full reverse walk, treat already-before steps as no-op, and complete the exact before-state without rollback-progress fields.
    It 'InterT145_restarts_reverse_undo_after_each_remediation_substep' {
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'r145') -Failpoint RecoveryOnly
        $roles=@('git-index','git-ref','remediation-and-instruction')
        $cases=@(for($index=0;$index-lt$roles.Count;$index++){$caseParent=Join-Path $script:ExternalRoot ("p145-"+$index);New-Item -ItemType Directory -Path $caseParent|Out-Null;[pscustomobject]@{Index=$index;Role=$roles[$index];CaseParent=$caseParent;Seed=$script:P9cSeeds.True;Context=$script:P9cUpdated.Context;ArchivePath=$script:P9cChanged.ArchivePath;Recovery=$recovery}})
        $worker={param($case)
            $caseParent=$case.CaseParent
            $target=Join-Path $caseParent 'repo';Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
            $before=Get-P9cPublicationStateSnapshot $target
            $appliedBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $caseParent 'ap') -Failpoint before-committed-journal-write -RecoveryPath NextRun
            $appliedResult=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $appliedBootstrap
            $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            $operation=@($journal.operations|Where-Object role -ceq $case.Role|Sort-Object sequence|Select-Object -First 1)
            if($operation.Count-ne1){return [pscustomobject]@{AppliedExitCode=$appliedResult.ExitCode;AppliedOutput=$appliedResult.Output;Phase=[string]$journal.phase;OperationCount=$operation.Count}}
            $rollbackBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $caseParent 'rb') -Failpoint ("after-rollback-operation-"+$operation[0].sequence) -RecoveryPath NextRun
            $rollbackResult=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $rollbackBootstrap
            $transactionExists=Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target)
            $attempts=@(foreach($attempt in 1,2){$result=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $case.Recovery;[pscustomobject]@{ExitCode=$result.ExitCode;Snapshot=(Get-P9cPublicationStateSnapshot $target)}})
            [pscustomobject]@{AppliedExitCode=$appliedResult.ExitCode;AppliedOutput=$appliedResult.Output;Phase=[string]$journal.phase;OperationCount=$operation.Count;RollbackExitCode=$rollbackResult.ExitCode;TransactionExists=$transactionExists;Before=$before;Attempts=$attempts}
        }
        $results=@(Invoke-P9cParallelCases -Cases $cases -Worker $worker)
        for($index=0;$index-lt$roles.Count;$index++){
            $role=$roles[$index];$result=$results[$index];if($null-ne$result.ErrorMessage){throw $result.ErrorMessage};$observation=$result.Value
            $observation.AppliedExitCode|Should -Not -Be 0
            if($observation.Phase-cne'applied'){throw "Expected applied journal for $role, found '$($observation.Phase)': $($observation.AppliedOutput)"}
            $observation.OperationCount|Should -Be 1
            $observation.RollbackExitCode|Should -Not -Be 0
            $observation.TransactionExists|Should -Be $true
            foreach($attempt in $observation.Attempts){
                $attempt.ExitCode|Should -Not -Be 0
                $attempt.Snapshot|Should -Be $observation.Before
            }
        }
    }

    # Scenario: projections.project is empty while ordinary Instructions still require an update that is interrupted after a journaled file operation.
    # Purpose: Recover through the same repository transaction without any project-Skill operation or legacy mutation snapshot authority.
    It 'InterT146_recovers_empty_project_selection_without_legacy_snapshot' {
        $discovery=Join-Path $script:ExternalRoot 'empty-discovery';Copy-Item -LiteralPath $script:NoProjectSeed -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'empty-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cNoProjectUpdated -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        @($journal.operations|Where-Object role -ceq project-skill).Count|Should -Be 0
        $sequence=[int](@($journal.operations|Where-Object role -ceq instruction|Select-Object -First 1)[0].sequence)
        $target=Join-Path $script:ExternalRoot 'empty-case';Copy-Item -LiteralPath $script:NoProjectSeed -Destination $target -Recurse;$before=Get-P9cPublicationStateSnapshot $target
        $failed=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'empty-case-runtime') -Failpoint ("after-operation-$sequence-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cNoProjectUpdated -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $failed).ExitCode|Should -Not -Be 0
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'empty-case-recovery') -Failpoint RecoveryOnly
        (Invoke-P9bRepoBootstrap -Context $script:P9cNoProjectUpdated -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
        (Get-P9cPublicationStateSnapshot $target)|Should -Be $before
    }

    # Scenario: Cleanup stops after removing one operation artifact while committed journal remains, or after deleting journal.json before removing the directory, through catch and crash recovery.
    # Purpose: Preserve the complete after-state, never undo committed work, and idempotently finish both cleanup interruption shapes.
    It 'InterT147_recovers_both_committed_cleanup_interruption_points_without_undo' {
        $discovery=Join-Path $script:ExternalRoot 'cleanup-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'cleanup-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $backupLeaf=[string](@($journal.operations|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.backupLeaf)}|Select-Object -First 1)[0].backupLeaf)
        [string]::IsNullOrWhiteSpace($backupLeaf)|Should -Be $false
        $expected=Join-Path $script:ExternalRoot 'cleanup-expected';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $expected -Recurse
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $expected).ExitCode|Should -Be 0
        $afterState=Get-P9cPublicationStateSnapshot $expected|ConvertFrom-Json;$afterState.indexRaw='<per-target-raw-index>';$afterState=($afterState|ConvertTo-Json -Depth 6 -Compress)
        $cases=New-Object System.Collections.Generic.List[object];$caseIndex=0
        foreach($failpoint in @("during-cleanup-$backupLeaf",'after-cleanup-journal-before-directory')){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $caseParent=Join-Path $script:ExternalRoot ("p147-"+$caseIndex);New-Item -ItemType Directory -Path $caseParent|Out-Null
                $cases.Add([pscustomobject]@{Index=$caseIndex;Failpoint=$failpoint;RecoveryPath=$recoveryPath;CaseParent=$caseParent;Seed=$script:P9cSeeds.False;Context=$script:P9cUpdated.Context;ArchivePath=$script:P9cChanged.ArchivePath});$caseIndex++
            }
        }
        $worker={param($case)
            $caseParent=$case.CaseParent
            $target=Join-Path $caseParent 'repo';Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
            $targetIndexBefore=[string]((Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json).indexRaw)
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $caseParent 'fp') -Failpoint $case.Failpoint -RecoveryPath $case.RecoveryPath
            $failed=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
            $observation=[ordered]@{FailedExitCode=$failed.ExitCode;TargetIndexBefore=$targetIndexBefore}
            if($case.RecoveryPath-ceq'NextRun'){
                $active=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$observation.ActiveCount=$active.Count
                if($active.Count-ne1){return [pscustomobject]$observation}
                if($case.Failpoint-like'during-cleanup-*'){$observation.JournalPhase=[string](Get-Content -Raw -LiteralPath (Join-Path $active[0].FullName 'journal.json')|ConvertFrom-Json).phase}
                else{$observation.JournalExists=Test-Path -LiteralPath (Join-Path $active[0].FullName 'journal.json')}
                $observation.RecoveryExitCode=(Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target).ExitCode
            }
            $snapshot=Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json;$observation.SnapshotIndexRaw=$snapshot.indexRaw;$snapshot.indexRaw='<per-target-raw-index>';$observation.Snapshot=($snapshot|ConvertTo-Json -Depth 6 -Compress)
            return [pscustomobject]$observation
        }
        $results=@(Invoke-P9cParallelCases -Cases $cases.ToArray() -Worker $worker);$resultIndex=0
        foreach($failpoint in @("during-cleanup-$backupLeaf",'after-cleanup-journal-before-directory')){
            $snapshots=@{}
            foreach($recoveryPath in @('InProcess','NextRun')){
                $result=$results[$resultIndex++];if($null-ne$result.ErrorMessage){throw $result.ErrorMessage};$observation=$result.Value
                $observation.FailedExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){
                    $observation.ActiveCount|Should -Be 1
                    if($failpoint-like'during-cleanup-*'){$observation.JournalPhase|Should -Be committed}
                    else{$observation.JournalExists|Should -Be $false}
                    $observation.RecoveryExitCode|Should -Be 0
                }
                $observation.SnapshotIndexRaw|Should -Be $observation.TargetIndexBefore;$snapshots[$recoveryPath]=$observation.Snapshot
                $snapshots[$recoveryPath]|Should -Be $afterState
            }
            $snapshots.InProcess|Should -Be $snapshots.NextRun
        }
    }

    # Scenario: Disk classification is prepared, applying, applied, committed, malformed, or missing.
    # Purpose: Exercise the actual decision function used by process catch and next-run recovery.
    It 'UnitT148_maps_all_repo_journal_classifications_to_one_recovery_action' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($script:BootstrapPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should -Be 0
        $definition=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Resolve-ProjectPublicationRecoveryAction'},$true))[-1];Invoke-Expression $definition.Extent.Text
        foreach($phase in @('prepared','applying','applied')){Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status='valid';journal=[pscustomobject]@{phase=$phase}})|Should -Be rollback-all}
        Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status='valid';journal=[pscustomobject]@{phase='committed'}})|Should -Be 'roll-forward-cleanup'
        foreach($status in @('missing','orphan','indeterminate')){Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status=$status;journal=$null})|Should -Be 'fail-closed'}
    }

    # Scenario: A journaled file becomes a third state after mutation, and a separate run starts with an unrelated index.lock.
    # Purpose: Retain both external byte changes and transaction evidence while refusing to delete a lock that cannot be attributed to the applying journal.
    It 'InterT149_refuses_third_state_and_foreign_index_lock_without_mutation' {
        $discovery=Join-Path $script:ExternalRoot 'third-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'third-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $instruction=@($journal.operations|Where-Object{[string]$_.role-ceq'instruction'-and[string]$_.target.value-ceq'AGENTS.md'})[0]
        $target=Join-Path $script:ExternalRoot 'third-state';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'third-state-runtime') -Failpoint ("after-operation-$($instruction.sequence)-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        [IO.File]::WriteAllText((Join-Path $target 'AGENTS.md'),"external third state`n",[Text.UTF8Encoding]::new($false))
        $thirdStateIndex=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($thirdStateIndex)){$thirdStateIndex=Join-Path $target $thirdStateIndex};$indexBeforeRetry=[IO.File]::ReadAllBytes($thirdStateIndex)
        $beforeRetry=Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json;$beforeRetry.indexRaw='<direct-byte-assertion>';$beforeRetry=$beforeRetry|ConvertTo-Json -Depth 6 -Compress
        $retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
        $retry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $retry.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($thirdStateIndex))|Should -Be ([Convert]::ToBase64String($indexBeforeRetry))
        $afterRetry=Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json;$afterRetry.indexRaw='<direct-byte-assertion>';($afterRetry|ConvertTo-Json -Depth 6 -Compress)|Should -Be $beforeRetry

        $foreign=Join-Path $script:ExternalRoot 'foreign-lock';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $foreign -Recurse
        $indexPath=(& git -C $foreign rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $foreign $indexPath};$lockPath=$indexPath+'.lock'
        $indexBefore=[IO.File]::ReadAllBytes($indexPath);$lockBytes=[Text.UTF8Encoding]::new($false).GetBytes('foreign lock');[IO.File]::WriteAllBytes($lockPath,$lockBytes)
        $foreignResult=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $foreign
        $foreignResult.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $foreignResult.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))|Should -Be ([Convert]::ToBase64String($indexBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath))|Should -Be ([Convert]::ToBase64String($lockBytes))
        Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $foreign)|Should -Be $false
    }

    # Scenario: One applied manifest operation is externally drifted while earlier operations still require reverse undo.
    # Purpose: Continue the exact reverse walk after the third-state refusal and report the aggregate terminal result as interrupted-install.
    It 'InterT166_continues_reverse_undo_after_a_third_state_and_reports_interrupted_install' {
        $scenario=New-P9cDriftRollbackScenario -Root (Join-Path $script:ExternalRoot 'drift-terminal') -Seed $script:P9cSeeds.False -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath

        $scenario.retry.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $scenario.retry.Output)|Should -Be interrupted-install
        ($scenario.unaffectedAfter|ConvertTo-Json -Depth 8 -Compress)|Should -Be ($scenario.unaffectedBefore|ConvertTo-Json -Depth 8 -Compress)
    }

    # Scenario: Recovery already restored unaffected operations, retained the journal, and encounters the same drift again on the next run.
    # Purpose: Treat restored operations as no-op while the drifted operation remains a stable refusal across repeated recovery.
    It 'InterT167_retains_the_journal_and_idempotently_refuses_the_same_drift_on_next_recovery' {
        $scenario=New-P9cDriftRollbackScenario -Root (Join-Path $script:ExternalRoot 'drift-repeat') -Seed $script:P9cSeeds.False -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath
        Test-Path -LiteralPath $scenario.journalPath -PathType Leaf|Should -Be $true
        $unaffectedAfterFirst=Get-P9cFileEvidence $scenario.unaffectedPath

        $retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $scenario.target

        $retry.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $retry.Output)|Should -Be interrupted-install
        Test-Path -LiteralPath $scenario.journalPath -PathType Leaf|Should -Be $true
        (Get-P9cFileEvidence $scenario.unaffectedPath|ConvertTo-Json -Depth 8 -Compress)|Should -Be ($unaffectedAfterFirst|ConvertTo-Json -Depth 8 -Compress)
    }

    # Scenario: A drifted operation is observed before recovery and after the reverse walk has processed every remaining operation.
    # Purpose: Preserve the drifted operation's bytes, native identity, permissions, and file attributes exactly.
    It 'InterT168_preserves_all_drift_evidence_while_undo_continues' {
        $scenario=New-P9cDriftRollbackScenario -Root (Join-Path $script:ExternalRoot 'drift-evidence') -Seed $script:P9cSeeds.False -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath

        $scenario.retry.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $scenario.retry.Output)|Should -Be interrupted-install
        ($scenario.driftAfter|ConvertTo-Json -Depth 8 -Compress)|Should -Be ($scenario.driftBefore|ConvertTo-Json -Depth 8 -Compress)
        Test-Path -LiteralPath $scenario.journalPath -PathType Leaf|Should -Be $true
    }

    # Scenario: A Windows create-file publication is interrupted after mutation but before the applied journal generation binds observedAfter.
    # Purpose: Keep the documented crash window recoverable by comparing bytes and identity only when observedAfter is still null.
    It 'InterT169_undoes_a_file_when_observedAfter_is_empty_in_the_post_mutation_window' {
        $discovery=Join-Path $script:ExternalRoot 'observed-after-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'observed-after-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $created=@($journal.operations|Where-Object{[string]$_.kind-ceq'create-file'}|Select-Object -First 1);$created.Count|Should -Be 1

        $target=Join-Path $script:ExternalRoot 'observed-after-window';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'observed-after-window-runtime') -Failpoint ("after-operation-$($created[0].sequence)-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        $active=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$active.Count|Should -Be 1
        $liveJournal=Get-Content -Raw -LiteralPath (Join-Path $active[0].FullName 'journal.json')|ConvertFrom-Json
        $liveOperation=@($liveJournal.operations|Where-Object sequence -eq $created[0].sequence)[0]
        $null-eq$liveOperation.observedAfter|Should -Be $true
        $createdPath=Join-Path $target ([string]$liveOperation.target.value);(Get-Item -Force -LiteralPath $createdPath).IsReadOnly=$true

        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'observed-after-recovery') -Failpoint RecoveryOnly
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
        Test-Path -LiteralPath $createdPath|Should -Be $false
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
    }
}
