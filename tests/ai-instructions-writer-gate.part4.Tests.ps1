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
            $emptyTransactionRoot=Join-Path $seed '.ai-instructions-txn';if(Test-Path -LiteralPath $emptyTransactionRoot){Remove-Item -LiteralPath $emptyTransactionRoot -Force}
            $script:P9cSeeds[[string]$withRemediation]=$seed
        }
        $script:NoProjectSeed=Join-Path $script:ExternalRoot 'no-project-seed';New-P9bTargetRepository $script:NoProjectSeed
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cNoProjectInitial -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $script:NoProjectSeed
        if($result.ExitCode-ne0){throw "Could not create non-opt-in seed: $($result.Output)"}
        $emptyTransactionRoot=Join-Path $script:NoProjectSeed '.ai-instructions-txn';if(Test-Path -LiteralPath $emptyTransactionRoot){Remove-Item -LiteralPath $emptyTransactionRoot -Force}
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
        Test-Path -LiteralPath (Join-Path $target '.ai-instructions-txn')|Should -Be $false
    }

    # Scenario: Remediation planning reaches a durable prepared journal and stops before the first index mutation.
    # Purpose: Prove index, ref, remediation files, manifest, and shared exclude are all pending in one write-ahead journal while the complete target state is unchanged.
    It 'InterT144_journals_each_remediation_substep_before_mutation' {
        $target=Join-Path $script:ExternalRoot 'write-ahead';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse
        $before=Get-P9cPublicationStateSnapshot $target
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'write-ahead-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
        $failed.ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $target '.ai-instructions-txn') -Directory -Force)
        if($transaction.Count-ne1){throw "Prepared remediation discovery did not retain one transaction: $($failed.Output)"}
        $transaction.Count|Should -Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        [string]$journal.phase|Should -Be prepared
        @($journal.operations|Where-Object state -cne pending).Count|Should -Be 0
        foreach($role in @('git-index','git-ref','remediation-and-instruction','manifest','shared-exclude')){@($journal.operations|Where-Object role -ceq $role).Count|Should -BeGreaterThan 0}
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
            $transaction=@(Get-ChildItem -LiteralPath (Join-Path $target '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            if([string]$journal.phase-cne'applied'){throw "Expected applied journal for $role, found '$($journal.phase)': $($appliedResult.Output)"}
            $operation=@($journal.operations|Where-Object role -ceq $role|Sort-Object sequence|Select-Object -First 1);$operation.Count|Should -Be 1
            $rollbackBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "undo-interrupt-$role") -Failpoint ("after-rollback-operation-"+$operation[0].sequence) -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $rollbackBootstrap).ExitCode|Should -Not -Be 0
            Test-Path -LiteralPath (Join-Path $target '.ai-instructions-txn')|Should -Be $true
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
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $discovery '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
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
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $discovery '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $backupLeaf=[string](@($journal.operations|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.backupLeaf)}|Select-Object -First 1)[0].backupLeaf)
        [string]::IsNullOrWhiteSpace($backupLeaf)|Should -Be $false
        $expected=Join-Path $script:ExternalRoot 'cleanup-expected';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $expected -Recurse
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $expected).ExitCode|Should -Be 0
        $afterState=Get-P9cPublicationStateSnapshot $expected|ConvertFrom-Json;$afterState.indexRaw='<per-target-raw-index>';$afterState=($afterState|ConvertTo-Json -Depth 6 -Compress)
        foreach($failpoint in @("during-cleanup-$backupLeaf",'after-cleanup-journal-before-directory')){
            $snapshots=@{}
            foreach($recoveryPath in @('InProcess','NextRun')){
                $target=Join-Path $script:ExternalRoot ("cleanup-$($failpoint.Replace('.','-'))-$recoveryPath");Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
                $targetIndexPath=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($targetIndexPath)){$targetIndexPath=Join-Path $target $targetIndexPath};$targetIndexBefore=(Get-FileHash -Algorithm SHA256 -LiteralPath $targetIndexPath).Hash.ToLowerInvariant()
                $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("cleanup-runtime-"+[Guid]::NewGuid().ToString('N'))) -Failpoint $failpoint -RecoveryPath $recoveryPath
                (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
                if($recoveryPath-ceq'NextRun'){
                    $active=@(Get-ChildItem -LiteralPath (Join-Path $target '.ai-instructions-txn') -Directory -Force);$active.Count|Should -Be 1
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
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $discovery '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $instruction=@($journal.operations|Where-Object{[string]$_.role-ceq'instruction'-and[string]$_.target.value-ceq'AGENTS.md'})[0]
        $target=Join-Path $script:ExternalRoot 'third-state';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'third-state-runtime') -Failpoint ("after-operation-$($instruction.sequence)-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        [IO.File]::WriteAllText((Join-Path $target 'AGENTS.md'),"external third state`n",[Text.UTF8Encoding]::new($false));$beforeRetry=Get-P9cPublicationStateSnapshot $target
        $retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
        $retry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $retry.Output)|Should -Be interrupted-install
        (Get-P9cPublicationStateSnapshot $target)|Should -Be $beforeRetry

        $foreign=Join-Path $script:ExternalRoot 'foreign-lock';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $foreign -Recurse
        $indexPath=(& git -C $foreign rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $foreign $indexPath};$lockPath=$indexPath+'.lock'
        $indexBefore=[IO.File]::ReadAllBytes($indexPath);$lockBytes=[Text.UTF8Encoding]::new($false).GetBytes('foreign lock');[IO.File]::WriteAllBytes($lockPath,$lockBytes)
        $foreignResult=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $foreign
        $foreignResult.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $foreignResult.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))|Should -Be ([Convert]::ToBase64String($indexBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath))|Should -Be ([Convert]::ToBase64String($lockBytes))
        Test-Path -LiteralPath (Join-Path $foreign '.ai-instructions-txn')|Should -Be $false
    }

    # Scenario: Attached, detached, and unborn HEAD repositories reach applied state and crash before commit publication.
    # Purpose: Recover each mode to the exact original HEAD/ref/index/filesystem snapshot using the journaled ref and HEAD variants appropriate to that mode.
    It 'InterT150_recovers_attached_detached_and_unborn_HEAD_transactions' {
        foreach($mode in @('attached','detached','unborn')){
            $target=Join-Path $script:ExternalRoot ("head-$mode")
            if($mode-ceq'unborn'){
                New-Item -ItemType Directory -Force -Path $target|Out-Null;& git -C $target init --quiet;& git -C $target config user.name 'P9c Test';& git -C $target config user.email 'p9c@example.test'
                [IO.File]::WriteAllText((Join-Path $target 'AGENTS.md'),"tracked Agent`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $target 'product.txt'),"product`n",[Text.UTF8Encoding]::new($false));& git -C $target add -- AGENTS.md product.txt
            }else{Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse;if($mode-ceq'detached'){& git -C $target checkout --detach --quiet}}
            $before=Get-P9cPublicationStateSnapshot $target
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "head-runtime-$mode") -Failpoint before-committed-journal-write -RecoveryPath NextRun
            $failed=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap;$failed.ExitCode|Should -Not -Be 0
            $transaction=@(Get-ChildItem -LiteralPath (Join-Path $target '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
            if($mode-ceq'attached'){@($journal.operations|Where-Object kind -ceq update-git-ref).Count|Should -Be 1;@($journal.operations|Where-Object kind -ceq update-git-head).Count|Should -Be 0}
            elseif($mode-ceq'detached'){@($journal.operations|Where-Object kind -ceq update-git-ref).Count|Should -Be 1;@($journal.operations|Where-Object kind -ceq update-git-head).Count|Should -Be 1}
            else{@($journal.operations|Where-Object kind -in @('update-git-ref','update-git-head')).Count|Should -Be 0}
            $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot "head-recovery-$mode") -Failpoint RecoveryOnly
            $recovered=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery;$recovered.ExitCode|Should -Not -Be 0
            $actual=Get-P9cPublicationStateSnapshot $target;if($actual-cne$before){throw "HEAD recovery mismatch for $mode. Failure: $($failed.Output) Recovery: $($recovered.Output)"}
        }
    }

    # Scenario: A freshly created directory anchor receives an unknown child before rollback.
    # Purpose: Refuse recursive deletion, preserve the unknown child, and retain transaction evidence for manual inspection.
    It 'InterT151_refuses_to_remove_directory_anchors_with_unknown_children' {
        $discovery=Join-Path $script:ExternalRoot 'anchor-discovery';New-P9bTargetRepository $discovery
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'anchor-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Join-Path $discovery '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $anchor=@($journal.operations|Where-Object kind -ceq ensure-directory-anchor|Sort-Object sequence|Select-Object -First 1)[0]
        $target=Join-Path $script:ExternalRoot 'anchor-case';New-P9bTargetRepository $target
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'anchor-case-runtime') -Failpoint ("after-operation-$($anchor.sequence)-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        $unknown=Join-Path (Join-Path $target ([string]$anchor.target.value)) 'unknown.txt';[IO.File]::WriteAllText($unknown,"external`n",[Text.UTF8Encoding]::new($false))
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
        $result.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
        [IO.File]::ReadAllText($unknown)|Should -Be "external`n"
        Test-Path -LiteralPath (Join-Path $target '.ai-instructions-txn')|Should -Be $true
    }

    # Scenario: index.lock contains the journaled after bytes before rename, index has already been renamed before operation-state update, or an unrelated lock predates the transaction.
    # Purpose: Remove only the applying transaction's exact lock, recover both crash windows, and preserve a foreign lock plus index bytes unchanged.
    It 'InterT152_enforces_index_lock_write_ahead_atomic_replace_and_residual_lock_rules' {
        foreach($failpoint in @('after-index-lock-write-before-rename','after-index-operation-before-journal')){
            $target=Join-Path $script:ExternalRoot ("index-$failpoint");Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse;$before=Get-P9cPublicationStateSnapshot $target
            if($failpoint-ceq'after-index-operation-before-journal'){
                $discovery=Join-Path $script:ExternalRoot 'index-discovery';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $discovery -Recurse
                $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'index-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
                (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
                $transaction=@(Get-ChildItem -LiteralPath (Join-Path $discovery '.ai-instructions-txn') -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
                $sequence=@($journal.operations|Where-Object role -ceq git-index)[0].sequence;$actualFailpoint="after-operation-$sequence-before-journal"
            }else{$actualFailpoint=$failpoint}
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("index-runtime-"+[Guid]::NewGuid().ToString('N'))) -Failpoint $actualFailpoint -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
            $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("index-recovery-"+[Guid]::NewGuid().ToString('N'))) -Failpoint RecoveryOnly
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
            (Get-P9cPublicationStateSnapshot $target)|Should -Be $before
            $indexPath=(& git -C $target rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $target $indexPath};Test-Path -LiteralPath ($indexPath+'.lock')|Should -Be $false
        }
        $foreign=Join-Path $script:ExternalRoot 'index-foreign';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $foreign -Recurse
        $index=(& git -C $foreign rev-parse --git-path index|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $foreign $index};$indexBefore=[IO.File]::ReadAllBytes($index);$lockBytes=[byte[]](1,2,3,4);[IO.File]::WriteAllBytes(($index+'.lock'),$lockBytes)
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $foreign
        $result.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($index))|Should -Be ([Convert]::ToBase64String($indexBefore));[Convert]::ToBase64String([IO.File]::ReadAllBytes($index+'.lock'))|Should -Be ([Convert]::ToBase64String($lockBytes))
    }

    # Scenario: A validated v2 journal advances only its phase or operation states between durable generations.
    # Purpose: Exercise the optimized transition function and reject immutable drift, unknown properties, and reverse transitions.
    It 'UnitT153_accepts_only_phase_and_operation_state_deltas_for_validated_v2_generations' {
        $module=Import-Module $script:TransactionModulePath -Force -PassThru
        try{
            $previous=[pscustomobject][ordered]@{schemaVersion=2;kind='ai-instructions-install-transaction';transactionId=('a'*32);createdAtUtc='2026-11-12T00:00:00.0000000Z';owner=[pscustomobject][ordered]@{component='repo-bootstrap';processId=1;processStartIdentity='fixture'};platform=[pscustomobject][ordered]@{os='windows';architecture='x64'};lock=[pscustomobject][ordered]@{primitive='windows-fileshare';leaf='bootstrap-ai-instructions.lock'};generation=[pscustomobject][ordered]@{previousBundleSha256=$null;candidateBundleSha256=('b'*64)};scope=[pscustomobject][ordered]@{kind='repository'};phase='prepared';operations=@([pscustomobject][ordered]@{sequence=1;kind='create-file';target=[pscustomobject][ordered]@{value='AGENTS.md'};state='pending'})}
            $clone={param($value)$parameters=@{InputObject=($value|ConvertTo-Json -Depth 30)};if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$parameters.DateKind='String'};ConvertFrom-Json @parameters}
            $applying=&$clone $previous;$applying.phase='applying';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $previous $applying}|Should -Not -Throw
            $applied=&$clone $applying;$applied.operations[0].state='applied';{&$module {param($left,$right)Assert-InstallJournalV2TrustedTransition $left $right|Out-Null} $applying $applied}|Should -Not -Throw
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
        $bootstrap|Should -Match "GetMethod\('Replace'.*\[string\].*\[string\].*\[string\]"
        $bootstrap|Should -Match 'replaceMethod\.Invoke\(\$null.*\$lockPath.*\$indexPath.*\$null'
        $transaction|Should -Match 'after-cleanup-journal-before-directory|during-cleanup-transaction'
    }
}
