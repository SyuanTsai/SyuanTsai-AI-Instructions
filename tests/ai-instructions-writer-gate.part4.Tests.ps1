. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

function New-P9cDriftRollbackScenario {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Seed,
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$ArchivePath
    )
    New-Item -ItemType Directory -Force -Path $Root|Out-Null
    $target=Join-Path $Root 'target';Copy-Item -LiteralPath $Seed -Destination $target -Recurse
    $unaffectedPath=Join-Path $target 'AGENTS.md';$unaffectedBefore=Get-P9cFileEvidence $unaffectedPath
    $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $Root 'applied-runtime') -Failpoint before-committed-journal-write -RecoveryPath NextRun
    $applied=Invoke-P9bRepoBootstrap -Context $Context -ArchivePath $ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
    if($applied.ExitCode-eq0){throw 'The drift fixture did not retain an applied transaction.'}
    $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force)
    if($transaction.Count-ne1){throw 'The drift fixture did not retain exactly one transaction.'}
    $journalPath=Join-Path $transaction[0].FullName 'journal.json';$journal=Get-Content -Raw -LiteralPath $journalPath|ConvertFrom-Json
    if([string]$journal.phase-cne'applied'){throw "The drift fixture expected phase applied, found '$($journal.phase)'."}
    $manifestPath=Join-Path $target '.codex/ai-instructions.manifest.json'
    [IO.File]::WriteAllBytes($manifestPath,[Text.UTF8Encoding]::new($false).GetBytes("external manifest drift`n"))
    $driftBefore=Get-P9cFileEvidence $manifestPath
    $retry=Invoke-P9bRepoBootstrap -Context $Context -ArchivePath $ArchivePath -TargetRoot $target
    return [pscustomobject][ordered]@{
        target=$target;journalPath=$journalPath;manifestPath=$manifestPath;unaffectedPath=$unaffectedPath
        unaffectedBefore=$unaffectedBefore;unaffectedAfter=(Get-P9cFileEvidence $unaffectedPath)
        driftBefore=$driftBefore;driftAfter=(Get-P9cFileEvidence $manifestPath);retry=$retry
    }
}

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
        foreach($role in @('git-index','git-ref','remediation-and-instruction')){
            $target=Join-Path $script:ExternalRoot ("undo-$role");Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse
            $before=Get-P9cPublicationStateSnapshot $target
            $appliedBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "undo-applied-$role") -Failpoint before-committed-journal-write -RecoveryPath NextRun
            $appliedResult=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $appliedBootstrap;$appliedResult.ExitCode|Should -Not -Be 0
            $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            if([string]$journal.phase-cne'applied'){throw "Expected applied journal for $role, found '$($journal.phase)': $($appliedResult.Output)"}
            $operation=@($journal.operations|Where-Object role -ceq $role|Sort-Object sequence|Select-Object -First 1);$operation.Count|Should -Be 1
            $rollbackBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "undo-interrupt-$role") -Failpoint ("after-rollback-operation-"+$operation[0].sequence) -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $rollbackBootstrap).ExitCode|Should -Not -Be 0
            Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target)|Should -Be $true
            foreach($attempt in 1,2){
                $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "undo-recovery-$role-$attempt") -Failpoint RecoveryOnly
                (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
                (Get-P9cPublicationStateSnapshot $target)|Should -Be $before
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
        foreach($failpoint in @("during-cleanup-$backupLeaf",'after-cleanup-journal-before-directory')){
            $snapshots=@{}
            foreach($recoveryPath in @('InProcess','NextRun')){
                $target=Join-Path $script:ExternalRoot ("cleanup-$($failpoint.Replace('.','-'))-$recoveryPath");Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
                $targetIndexBefore=[string]((Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json).indexRaw)
                $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("cleanup-runtime-"+[Guid]::NewGuid().ToString('N'))) -Failpoint $failpoint -RecoveryPath $recoveryPath
                (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){
                    $active=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$active.Count|Should -Be 1
                    if($failpoint-like'during-cleanup-*'){[string](Get-Content -Raw -LiteralPath (Join-Path $active[0].FullName 'journal.json')|ConvertFrom-Json).phase|Should -Be committed}
                    else{Test-Path -LiteralPath (Join-Path $active[0].FullName 'journal.json')|Should -Be $false}
                    (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target).ExitCode|Should -Be 0
                }
                $snapshot=Get-P9cPublicationStateSnapshot $target|ConvertFrom-Json;$snapshot.indexRaw|Should -Be $targetIndexBefore;$snapshot.indexRaw='<per-target-raw-index>';$snapshots[$recoveryPath]=($snapshot|ConvertTo-Json -Depth 6 -Compress)
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

    # Scenario: Attached and detached repositories reach applied state and crash before commit publication, while an unborn repository follows main's pre-mutation skip contract.
    # Purpose: Recover committed-HEAD modes exactly and prove the unborn skip changes neither Git object bytes nor any ref.
    It 'InterT150_recovers_attached_detached_and_unborn_HEAD_transactions' {
        foreach($mode in @('attached','detached','unborn')){
            $target=Join-Path $script:ExternalRoot ("head-$mode")
            if($mode-ceq'unborn'){
                New-Item -ItemType Directory -Force -Path $target|Out-Null;& git -C $target init --quiet;& git -C $target config user.name 'P9c Test';& git -C $target config user.email 'p9c@example.test'
                [IO.File]::WriteAllText((Join-Path $target 'AGENTS.md'),"tracked Agent`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $target 'product.txt'),"product`n",[Text.UTF8Encoding]::new($false));& git -C $target add -- AGENTS.md product.txt
            }else{Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse;if($mode-ceq'detached'){& git -C $target checkout --detach --quiet}}
            $before=Get-P9cPublicationStateSnapshot $target
            if($mode-ceq'unborn'){
                $objectsRoot=Join-Path $target '.git/objects'
                $objectsBefore=@(Get-ChildItem -LiteralPath $objectsRoot -Recurse -Force -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($objectsRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/'))`t$([Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)))"})-join"`n"
                $refsBefore=@(& git -C $target for-each-ref '--format=%(refname)%09%(objectname)')-join"`n"
                $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
                $result.ExitCode|Should -Be 0
                ($result.Output-join[Environment]::NewLine)|Should -Match 'target repository has no commit'
                $objectsAfter=@(Get-ChildItem -LiteralPath $objectsRoot -Recurse -Force -File|Sort-Object FullName|ForEach-Object{"$($_.FullName.Substring($objectsRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/'))`t$([Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)))"})-join"`n"
                $objectsAfter|Should -BeExactly $objectsBefore
                (@(& git -C $target for-each-ref '--format=%(refname)%09%(objectname)')-join"`n")|Should -BeExactly $refsBefore
                (Get-P9cPublicationStateSnapshot $target)|Should -BeExactly $before
                Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target)|Should -Be $false
                continue
            }
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "head-runtime-$mode") -Failpoint before-committed-journal-write -RecoveryPath NextRun
            $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap;$failed.ExitCode|Should -Not -Be 0
            $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            $evidence=@($journal.operations|Where-Object kind -ceq store-git-stash-evidence);$evidence.Count|Should -Be 1
            if($mode-ceq'attached'){@($journal.operations|Where-Object kind -ceq update-git-ref).Count|Should -Be 1;@($journal.operations|Where-Object kind -ceq update-git-head).Count|Should -Be 0}
            else{@($journal.operations|Where-Object kind -ceq update-git-ref).Count|Should -Be 1;@($journal.operations|Where-Object kind -ceq update-git-head).Count|Should -Be 1}
            $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "head-recovery-$mode") -Failpoint RecoveryOnly
            $recovered=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery;$recovered.ExitCode|Should -Not -Be 0
            $actual=Get-P9cPublicationStateSnapshot $target;if($actual-cne$before){throw "HEAD recovery mismatch for $mode. Failure: $($failed.Output) Recovery: $($recovered.Output)"}
            (@(& git -C $target rev-parse --verify refs/stash)|Select-Object -First 1)|Should -Be ([string]$evidence[0].after.objectId)
        }
    }

    # Scenario: Recovery interrupts after prepared, before stash store, after stash store before binding, or after the one-time binding through catch and next-run paths.
    # Purpose: Pre-register the evidence operation, leave its after.objectId explicitly pending until store succeeds, and retain any created evidence while rolling back all ordinary targets.
    It 'InterT155_pre_registers_late_binds_and_recovers_PersonalAgent_evidence_through_both_paths' {
        $discovery=Join-Path $script:ExternalRoot 'evidence-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'evidence-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $preparedTransaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force)
        $preparedJournal=Get-Content -Raw -LiteralPath (Join-Path $preparedTransaction[0].FullName 'journal.json')|ConvertFrom-Json
        $preparedEvidence=@($preparedJournal.operations|Where-Object kind -ceq store-git-stash-evidence);$preparedEvidence.Count|Should -Be 1
        $evidenceSequence=[int]$preparedEvidence[0].sequence
        [string]$preparedEvidence[0].state|Should -BeExactly pending
        $null-eq$preparedEvidence[0].after.objectId|Should -Be $true

        $cases=@(
            [pscustomobject]@{Name='prepared';Failpoint='after-journal-prepared';Stored=$false;Bound=$false},
            [pscustomobject]@{Name='before-store';Failpoint="before-operation-$evidenceSequence";Stored=$false;Bound=$false},
            [pscustomobject]@{Name='after-store-before-bind';Failpoint="after-operation-$evidenceSequence-before-journal";Stored=$true;Bound=$false},
            [pscustomobject]@{Name='after-bind';Failpoint="after-operation-$evidenceSequence";Stored=$true;Bound=$true}
        )
        foreach($case in $cases){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $target=Join-Path $script:ExternalRoot "evidence-$($case.Name)-$recoveryPath";Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
                $before=Get-P9cPublicationStateSnapshot $target
                $stashBefore=(@(& git -C $target rev-parse --verify refs/stash 2>$null)|Select-Object -First 1)
                $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "evidence-runtime-$($case.Name)-$recoveryPath") -Failpoint $case.Failpoint -RecoveryPath $recoveryPath
                (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
                $stashAfterFailure=(@(& git -C $target rev-parse --verify refs/stash 2>$null)|Select-Object -First 1)
                if($case.Stored){[string]$stashAfterFailure|Should -Not -Be ([string]$stashBefore)}else{[string]$stashAfterFailure|Should -Be ([string]$stashBefore)}

                if($recoveryPath-ceq'NextRun'){
                    $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
                    $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
                    $evidence=@($journal.operations|Where-Object kind -ceq store-git-stash-evidence);$evidence.Count|Should -Be 1
                    [int]$evidence[0].sequence|Should -Be $evidenceSequence
                    if($case.Name-ceq'prepared'){[string]$journal.phase|Should -BeExactly prepared}else{[string]$journal.phase|Should -BeExactly applying}
                    if($case.Bound){[string]$evidence[0].state|Should -BeExactly applied;[string]$evidence[0].after.objectId|Should -BeExactly ([string]$stashAfterFailure)}
                    else{[string]$evidence[0].state|Should -BeExactly pending;$null-eq$evidence[0].after.objectId|Should -Be $true}
                    $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "evidence-recovery-$($case.Name)") -Failpoint RecoveryOnly
                    (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
                }
                (Get-P9cPublicationStateSnapshot $target)|Should -BeExactly $before
                $stashAfterRecovery=(@(& git -C $target rev-parse --verify refs/stash 2>$null)|Select-Object -First 1)
                if($case.Stored){[string]$stashAfterRecovery|Should -BeExactly ([string]$stashAfterFailure)}else{[string]$stashAfterRecovery|Should -BeExactly ([string]$stashBefore)}
                @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
            }
        }
    }

    # Scenario: refs/stash is changed by an external Git writer immediately after the prepared journal for both new-store and existing-evidence reuse decisions.
    # Purpose: Revalidate the decision-time stash ref with an expected-old CAS and fail closed without overwriting the external ref.
    It 'InterT159_refuses_refs_stash_changes_after_prepared_for_store_and_reuse_decisions' {
        $cases=@(
            [pscustomobject]@{Name='store';Seed=$script:P9cSeeds.False;Context=$script:P9cUpdated.Context;Archive=$script:P9cChanged.ArchivePath},
            [pscustomobject]@{Name='reuse';Seed=$script:P9cSeeds.True;Context=$script:P9cInitial.Context;Archive=$script:P9cBaseline.ArchivePath}
        )
        foreach($case in $cases){
            $target=Join-Path $script:ExternalRoot ("stash-cas-"+$case.Name);Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
            $stashBefore=(@(& git -C $target rev-parse --verify refs/stash)|Select-Object -First 1).Trim()
            $bootstrap=New-P9cStashTamperAfterPreparedBootstrap -Root (Join-Path $script:ExternalRoot ("stash-cas-runtime-"+$case.Name))
            $result=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.Archive -TargetRoot $target -BootstrapPath $bootstrap
            $result.ExitCode|Should -Not -Be 0
            (Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
            $stashAfter=(@(& git -C $target rev-parse --verify refs/stash)|Select-Object -First 1).Trim()
            $stashAfter|Should -Not -BeExactly $stashBefore
            $result.Output|Should -Match 'refs/stash changed after the prepared decision|third state'
        }
    }

    # Scenario: A freshly created directory anchor receives an unknown child before rollback.
    # Purpose: Refuse recursive deletion, preserve the unknown child, and retain transaction evidence for manual inspection.
    It 'InterT151_refuses_to_remove_directory_anchors_with_unknown_children' {
        $discovery=Join-Path $script:ExternalRoot 'anchor-discovery';New-P9bTargetRepository $discovery
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'anchor-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $anchor=@($journal.operations|Where-Object kind -ceq ensure-directory-anchor|Sort-Object sequence|Select-Object -First 1)[0]
        $target=Join-Path $script:ExternalRoot 'anchor-case';New-P9bTargetRepository $target
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'anchor-case-runtime') -Failpoint ("after-operation-$($anchor.sequence)-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        $unknown=Join-Path (Join-Path $target ([string]$anchor.target.value)) 'unknown.txt';[IO.File]::WriteAllText($unknown,"external`n",[Text.UTF8Encoding]::new($false))
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
        $result.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
        [IO.File]::ReadAllText($unknown)|Should -Be "external`n"
        Test-Path -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target)|Should -Be $true
    }

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
        foreach($failpoint in @('after-index-lock-write-before-rename','after-index-rename-before-reacquire','after-index-operation-before-journal')){
            $actualFailpoint=if($failpoint-ceq'after-index-operation-before-journal'){"after-operation-$sequence-before-journal"}else{$failpoint}
            foreach($recoveryPath in @('InProcess','NextRun')){
                $target=Join-Path $script:ExternalRoot ("index-$failpoint-$recoveryPath");Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse;$before=Get-P9cPublicationStateSnapshot $target
                $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("index-runtime-"+[Guid]::NewGuid().ToString('N'))) -Failpoint $actualFailpoint -RecoveryPath $recoveryPath
                (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){
                    $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("index-recovery-"+[Guid]::NewGuid().ToString('N'))) -Failpoint RecoveryOnly
                    (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
                }
                (Get-P9cPublicationStateSnapshot $target)|Should -Be $before
                $indexPath=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $target $indexPath};Test-Path -LiteralPath ($indexPath+'.lock')|Should -Be $false
                $rerun=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
                if($rerun.ExitCode-ne0){throw "Index recovery rerun failed for $failpoint/$recoveryPath`: $($rerun.Output)"}
                $agentsPath=Join-Path $target 'AGENTS.md';Test-Path -LiteralPath $agentsPath -PathType Leaf|Should -Be $true
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($agentsPath))|Should -Be ([Convert]::ToBase64String($expectedAgentsBytes))
            }
        }
        foreach($tamperKind in @('EmptyBytes','MismatchedBytes','CommittedPhase','NoJournal')){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $target=Join-Path $script:ExternalRoot ("index-refusal-$tamperKind-$recoveryPath");Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse
                Get-P9cPublicationStateSnapshot $target|Out-Null
                $index=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $target $index};$indexBefore=[IO.File]::ReadAllBytes($index)
                $bootstrap=New-P9cIndexLockTamperBootstrap -Root (Join-Path $script:ExternalRoot ("index-refusal-runtime-"+[Guid]::NewGuid().ToString('N'))) -TamperKind $tamperKind -RecoveryPath $recoveryPath
                $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap;$failed.ExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){$retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target;$retry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $retry.Output)|Should -Be interrupted-install}
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($index))|Should -Be ([Convert]::ToBase64String($indexBefore))
                Test-Path -LiteralPath ($index+'.lock') -PathType Leaf|Should -Be $true
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
        foreach($case in $cases){
            $target=Join-Path $script:ExternalRoot ("prefill-phase-"+$case.Name);Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("prefill-phase-runtime-"+$case.Name)) -Failpoint $case.Failpoint -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
            $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
            $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            [string]$journal.phase|Should -BeExactly $case.Phase
            $lockPath=([string]$journal.scope.indexPath)+'.lock';Test-Path -LiteralPath $lockPath -PathType Leaf|Should -Be $true
            $lockSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $lockPath).Hash.ToLowerInvariant()
            if($case.HasIndex){
                $indexOperation=@($journal.operations|Where-Object kind -ceq replace-git-index)[0]
                [string]$indexOperation.before.sha256|Should -BeExactly ([string]$journal.scope.indexLockContentSha256)
                $expectedSha=if($case.Expected-ceq'before'){[string]$indexOperation.before.sha256}else{[string]$indexOperation.after.sha256}
                $lockSha|Should -BeExactly $expectedSha
            }else{@($journal.operations|Where-Object kind -ceq replace-git-index).Count|Should -Be 0;$lockSha|Should -BeExactly ([string]$journal.scope.indexLockContentSha256)}
            $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("prefill-phase-recovery-"+$case.Name)) -Failpoint RecoveryOnly
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
            Test-Path -LiteralPath $lockPath|Should -Be $false
            @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
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
            $previous=[pscustomobject][ordered]@{schemaVersion=2;kind='ai-instructions-install-transaction';transactionId=('a'*32);createdAtUtc='2026-11-12T00:00:00.0000000Z';owner=[pscustomobject][ordered]@{component='repo-bootstrap';processId=1;processStartIdentity='fixture'};platform=[pscustomobject][ordered]@{os='windows';architecture='x64'};lock=[pscustomobject][ordered]@{primitive='windows-fileshare';leaf='bootstrap-ai-instructions.lock'};generation=[pscustomobject][ordered]@{previousBundleSha256=$null;candidateBundleSha256=('b'*64)};scope=[pscustomobject][ordered]@{kind='repository';repositoryRoot=$scopeRoot;repositoryRootIdentity=$identity;commonGitDirectory=$git;gitDirectory=$git;indexPath=(Join-Path $git 'index');indexLockContentSha256=('9'*64);objectFormat='sha1';externalBackup=$null};phase='prepared';operations=@([pscustomobject][ordered]@{sequence=1;kind='create-file';role='instruction';method='stage-rename';target=[pscustomobject][ordered]@{kind='repository-relative';value='AGENTS.md'};before=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;permissions=$null};after=[pscustomobject][ordered]@{exists=$true;sha256=('a'*64);length=3;identity=$identity;permissions=$permissions};observedAfter=$null;stageLeaf='operation-1.stage';backupLeaf=$null;quarantineLeaf=$null;state='pending'},[pscustomobject][ordered]@{sequence=2;kind='store-git-stash-evidence';role='personal-agent-evidence';method='stash-store';target=[pscustomobject][ordered]@{kind='git-stash-evidence';value='refs/stash'};before=[pscustomobject][ordered]@{exists=$false;objectId=$null};after=[pscustomobject][ordered]@{exists=$true;objectId=$null};observedAfter=$null;stageLeaf=$null;backupLeaf=$null;quarantineLeaf=$null;state='pending'})}
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

    # Scenario: A repo-v2 journal generation is read back, returned to its caller, and then the caller mutates top-level and nested values.
    # Purpose: Keep the cache's trusted content and disk identity independent from every caller-owned journal object.
    It 'InterT156_keeps_trusted_journal_cache_content_isolated_from_the_caller' {
        $target=Join-Path $script:ExternalRoot 'journal-cache-caller';Copy-Item -LiteralPath $script:JournalCacheSeed -Destination $target -Recurse
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transaction.Count|Should -Be 1
        $transactionPath=$transaction[0].FullName;$journalPath=Join-Path $transactionPath 'journal.json'
        $module=Import-Module $script:TransactionModulePath -Force -PassThru;$lease=Open-PlatformDirectory -Root $transactionPath -RootOnly
        try{
            $states=[ordered]@{};foreach($leaf in @('journal.json','journal.prev','journal.stage')){$states[$leaf]=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath (Join-Path $transactionPath $leaf) -PlatformOs windows}
            $previous=Get-Content -Raw -LiteralPath $journalPath|ConvertFrom-Json;$next=$previous|ConvertTo-Json -Depth 30|ConvertFrom-Json;$next.phase='applying'
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
            $previous=Get-Content -Raw -LiteralPath $journalPath|ConvertFrom-Json;$applying=$previous|ConvertTo-Json -Depth 30|ConvertFrom-Json;$applying.phase='applying'
            $returned=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $applying -PreviousJournal $previous -PlatformOs windows -JournalStoreStates $states
            $next=$returned|ConvertTo-Json -Depth 30|ConvertFrom-Json;$next.operations[0].state='applied'
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
            $previous=Get-Content -Raw -LiteralPath $journalPath|ConvertFrom-Json;$applying=$previous|ConvertTo-Json -Depth 30|ConvertFrom-Json;$applying.phase='applying'
            $returned=Write-AiInstructionsInstallJournalStore -TransactionLease $lease -TransactionPath $transactionPath -Journal $applying -PreviousJournal $previous -PlatformOs windows -JournalStoreStates $states
            $next=$returned|ConvertTo-Json -Depth 30|ConvertFrom-Json;$next.operations[0].state='applied'
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
