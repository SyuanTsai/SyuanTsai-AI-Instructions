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
    # Scenario: A displacing write-file operation is still pending when the process stops, then the user changes only the target's read-only attribute.
    # Purpose: Never apply prepared displaced metadata to an operation that was never displaced; recovery keeps the user's bytes, identity, permissions, and attributes exactly.
    It 'InterT173_recovery_never_applies_displaced_metadata_to_a_pending_operation' {
        $discovery=Join-Path $script:ExternalRoot 'pending-metadata-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'pending-metadata-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $written=@($journal.operations|Where-Object{[string]$_.kind-ceq'write-file'-and[string]$_.target.kind-ceq'repository-relative'}|Sort-Object sequence|Select-Object -First 1);$written.Count|Should -Be 1

        $target=Join-Path $script:ExternalRoot 'pending-metadata';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'pending-metadata-runtime') -Failpoint ("before-operation-$($written[0].sequence)") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
        $active=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$active.Count|Should -Be 1
        $liveJournal=Get-Content -Raw -LiteralPath (Join-Path $active[0].FullName 'journal.json')|ConvertFrom-Json
        $liveOperation=@($liveJournal.operations|Where-Object sequence -eq $written[0].sequence)[0]
        [string]$liveOperation.state|Should -Be pending
        $null-eq$liveOperation.displacedAfterMetadata|Should -Be $true
        $null-ne$liveOperation.displacedMetadata|Should -Be $true
        $targetPath=Join-Path $target ([string]$liveOperation.target.value)
        (Get-Item -Force -LiteralPath $targetPath).IsReadOnly=$true
        $evidenceBefore=Get-P9cFileEvidence $targetPath

        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'pending-metadata-recovery') -Failpoint RecoveryOnly
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0

        (Get-P9cFileEvidence $targetPath|ConvertTo-Json -Depth 8 -Compress)|Should -Be ($evidenceBefore|ConvertTo-Json -Depth 8 -Compress)
        (Get-Item -Force -LiteralPath $targetPath).IsReadOnly|Should -Be $true
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
    }

    # Scenario: A failpoint stops rollback after P7 moves the original shared exclude back, while live metadata exactly equals durable observedAfter.
    # Purpose: Accept only that journaled P7 undo intermediate state, restore the original metadata through P7, and finish recovery without residue.
    It 'InterT176_recovers_the_journaled_P7_undo_metadata_intermediate_state' {
        $discovery=Join-Path $script:ExternalRoot 'metadata-undo-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'metadata-undo-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $discoveryTransaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$discoveryJournal=Get-Content -Raw -LiteralPath (Join-Path $discoveryTransaction[0].FullName 'journal.json')|ConvertFrom-Json
        $excludeOperation=@($discoveryJournal.operations|Where-Object{[string]$_.role-ceq'shared-exclude'-and[string]$_.kind-ceq'write-file'}|Select-Object -First 1);$excludeOperation.Count|Should -Be 1

        $target=Join-Path $script:ExternalRoot 'metadata-undo-intermediate';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
        $excludePath=(@(& git -C $target rev-parse --git-path info/exclude)|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $target $excludePath}
        $indexPath=(@(& git -C $target rev-parse --git-path index)|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $target $indexPath}
        $excludeBefore=Get-P9cFileEvidence $excludePath
        $indexBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
        $probePath=Join-Path $script:ExternalRoot 'metadata-undo-intermediate.json'
        $bootstrap=New-P9cMetadataUndoIntermediateFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'metadata-undo-intermediate-runtime') -Sequence ([int]$excludeOperation[0].sequence) -ProbePath $probePath

        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap

        $result.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
        $probe=Get-Content -Raw -LiteralPath $probePath|ConvertFrom-Json
        [int]$probe.sequence|Should -Be ([int]$excludeOperation[0].sequence)
        [bool]$probe.matchesObservedAfter|Should -Be $true
        ($probe.live|ConvertTo-Json -Depth 8 -Compress)|Should -Be ($probe.expected|ConvertTo-Json -Depth 8 -Compress)
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force).Count|Should -Be 1
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'metadata-undo-recovery-runtime') -Failpoint RecoveryOnly
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
        (Get-P9cFileEvidence $excludePath|ConvertTo-Json -Depth 8 -Compress)|Should -Be ($excludeBefore|ConvertTo-Json -Depth 8 -Compress)
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))|Should -Be $indexBefore
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
        $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'r155') -Failpoint RecoveryOnly
        $parallelCases=New-Object System.Collections.Generic.List[object];$caseIndex=0
        foreach($case in $cases){foreach($recoveryPath in @('InProcess','NextRun')){
            $parallelCases.Add([pscustomobject]@{Index=$caseIndex;Name=$case.Name;Failpoint=$case.Failpoint;Stored=$case.Stored;Bound=$case.Bound;RecoveryPath=$recoveryPath;EvidenceSequence=$evidenceSequence;ExternalRoot=$script:ExternalRoot;Seed=$script:P9cSeeds.False;Context=$script:P9cUpdated.Context;ArchivePath=$script:P9cChanged.ArchivePath;Recovery=$recovery});$caseIndex++
        }}
        $worker={param($case)
                $caseParent=Join-Path $case.ExternalRoot ("p155-"+$case.Index);New-Item -ItemType Directory -Path $caseParent|Out-Null
                $target=Join-Path $caseParent 'repo';Copy-Item -LiteralPath $case.Seed -Destination $target -Recurse
                $before=Get-P9cPublicationStateSnapshot $target
                $stashBefore=(@(& git -C $target rev-parse --verify refs/stash 2>$null)|Select-Object -First 1)
                $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $caseParent 'fp') -Failpoint $case.Failpoint -RecoveryPath $case.RecoveryPath
                $failed=Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
                $stashAfterFailure=(@(& git -C $target rev-parse --verify refs/stash 2>$null)|Select-Object -First 1)
                $observation=[ordered]@{FailedExitCode=$failed.ExitCode;Before=$before;StashBefore=[string]$stashBefore;StashAfterFailure=[string]$stashAfterFailure}
                if($case.RecoveryPath-ceq'NextRun'){
                    $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$observation.TransactionCount=$transaction.Count
                    if($transaction.Count-ne1){return [pscustomobject]$observation}
                    $journal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
                    $evidence=@($journal.operations|Where-Object kind -ceq store-git-stash-evidence)
                    $observation.EvidenceCount=$evidence.Count
                    if($evidence.Count-ne1){return [pscustomobject]$observation}
                    $observation.EvidenceSequence=[int]$evidence[0].sequence;$observation.JournalPhase=[string]$journal.phase
                    $observation.EvidenceState=[string]$evidence[0].state;$observation.EvidenceObjectId=[string]$evidence[0].after.objectId;$observation.EvidenceObjectIdIsNull=$null-eq$evidence[0].after.objectId
                    $observation.RecoveryExitCode=(Invoke-P9bRepoBootstrap -Context $case.Context -ArchivePath $case.ArchivePath -TargetRoot $target -BootstrapPath $case.Recovery).ExitCode
                }
                $observation.AfterRecovery=Get-P9cPublicationStateSnapshot $target
                $stashAfterRecovery=(@(& git -C $target rev-parse --verify refs/stash 2>$null)|Select-Object -First 1)
                $observation.StashAfterRecovery=[string]$stashAfterRecovery
                $observation.ResidueCount=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count
                return [pscustomobject]$observation
        }
        $results=@(Invoke-P9cParallelCases -Cases $parallelCases.ToArray() -Worker $worker);$resultIndex=0
        foreach($case in $cases){
            foreach($recoveryPath in @('InProcess','NextRun')){
                $result=$results[$resultIndex++];if($null-ne$result.ErrorMessage){throw $result.ErrorMessage};$observation=$result.Value
                $observation.FailedExitCode|Should -Not -Be 0
                if($case.Stored){$observation.StashAfterFailure|Should -Not -Be $observation.StashBefore}else{$observation.StashAfterFailure|Should -Be $observation.StashBefore}

                if($recoveryPath-ceq'NextRun'){
                    $observation.TransactionCount|Should -Be 1
                    $observation.EvidenceCount|Should -Be 1
                    $observation.EvidenceSequence|Should -Be $evidenceSequence
                    if($case.Name-ceq'prepared'){$observation.JournalPhase|Should -BeExactly prepared}else{$observation.JournalPhase|Should -BeExactly applying}
                    if($case.Bound){$observation.EvidenceState|Should -BeExactly applied;$observation.EvidenceObjectId|Should -BeExactly $observation.StashAfterFailure}
                    else{$observation.EvidenceState|Should -BeExactly pending;$observation.EvidenceObjectIdIsNull|Should -Be $true}
                    $observation.RecoveryExitCode|Should -Not -Be 0
                }
                $observation.AfterRecovery|Should -BeExactly $observation.Before
                if($case.Stored){$observation.StashAfterRecovery|Should -BeExactly $observation.StashAfterFailure}else{$observation.StashAfterRecovery|Should -BeExactly $observation.StashBefore}
                $observation.ResidueCount|Should -Be 0
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

    # Scenario: A retained manifest path drifts after the manifest operation is durably applied but before the terminal closure gate, and again while a committed transaction awaits next-run cleanup.
    # Purpose: Roll back the applying transaction through the shared phase decision, roll forward only the committed cleanup, and preserve external drift bytes in both windows.
    It 'InterT170_uses_shared_rollback_and_roll_forward_decisions_for_terminal_retained_path_drift' {
        $discovery=Join-Path $script:ExternalRoot 'terminal-closure-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'terminal-closure-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$transaction.Count|Should -Be 1
        $preparedJournal=Get-Content -Raw -LiteralPath (Join-Path $transaction[0].FullName 'journal.json')|ConvertFrom-Json
        $retained=@($preparedJournal.retainedManifestPaths|Select-Object -First 1);$retained.Count|Should -Be 1
        $manifestOperation=@($preparedJournal.operations|Where-Object{[string]$_.role-ceq'manifest'});$manifestOperation.Count|Should -Be 1
        $withoutExternalRetainedDrift={param([string]$Snapshot,[string]$RelativePath)$state=$Snapshot|ConvertFrom-Json;$state.files=@($state.files|Where-Object{$columns=([string]$_)-split"`t",3;$columns.Count-lt2-or$columns[1]-cne$RelativePath});return ($state|ConvertTo-Json -Depth 6 -Compress)}

        $terminalTarget=Join-Path $script:ExternalRoot 'terminal-closure-applying';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $terminalTarget -Recurse
        $terminalPath=Join-Path $terminalTarget ([string]$retained[0].targetPath);$terminalBefore=[IO.File]::ReadAllBytes($terminalPath);$terminalBeforeState=Get-P9cPublicationStateSnapshot $terminalTarget
        $terminalBootstrap=New-P9cRetainedPathTerminalTamperBootstrap -Root (Join-Path $script:ExternalRoot 'terminal-closure-applying-runtime') -Failpoint ("after-operation-"+$manifestOperation[0].sequence) -TargetPath $terminalPath
        $terminalResult=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $terminalTarget -BootstrapPath $terminalBootstrap
        $terminalResult.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $terminalResult.Output)|Should -Be interrupted-install
        $terminalResult.Output|Should -Match 'terminal closure gate found retained path drift'
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $terminalTarget) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
        (&$withoutExternalRetainedDrift (Get-P9cPublicationStateSnapshot $terminalTarget) ([string]$retained[0].targetPath))|Should -BeExactly (&$withoutExternalRetainedDrift $terminalBeforeState ([string]$retained[0].targetPath))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($terminalPath))|Should -BeExactly ([Convert]::ToBase64String([byte[]]($terminalBefore+[Text.UTF8Encoding]::new($false).GetBytes("terminal retained drift`n"))))

        $committedTarget=Join-Path $script:ExternalRoot 'terminal-closure-committed';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $committedTarget -Recurse
        $committedBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'terminal-closure-committed-runtime') -Failpoint after-committed-journal-write -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $committedTarget -BootstrapPath $committedBootstrap).ExitCode|Should -Not -Be 0
        $committedTransactions=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $committedTarget) -Directory -Force);$committedTransactions.Count|Should -Be 1
        $committedJournal=Get-Content -Raw -LiteralPath (Join-Path $committedTransactions[0].FullName 'journal.json')|ConvertFrom-Json;[string]$committedJournal.phase|Should -BeExactly committed
        $committedRetained=@($committedJournal.retainedManifestPaths|Select-Object -First 1);$committedRetained.Count|Should -Be 1
        $committedPath=Join-Path $committedTarget ([string]$committedRetained[0].targetPath);[IO.File]::AppendAllText($committedPath,"committed retained drift`n",[Text.UTF8Encoding]::new($false));$committedDrift=[IO.File]::ReadAllBytes($committedPath)
        $committedRetry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $committedTarget
        $committedRetry.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $committedRetry.Output)|Should -Be interrupted-install
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $committedTarget) -Directory -Force).Count|Should -Be 1
        Test-Path -LiteralPath (Join-Path $committedTransactions[0].FullName 'journal.json') -PathType Leaf|Should -Be $true
        [string](Get-Content -Raw -LiteralPath (Join-Path $committedTransactions[0].FullName 'journal.json')|ConvertFrom-Json).phase|Should -BeExactly committed
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($committedPath))|Should -BeExactly ([Convert]::ToBase64String($committedDrift))
    }

    # Scenario: Applying next-run recovery sees a replacement worktree root, a journaled common Git directory mismatch, or a journaled active index path mismatch.
    # Purpose: Rebind the complete repository scope before lock roll-forward or undo and preserve target files, index, refs, shared exclude, and journal evidence byte-for-byte on every mismatch.
    It 'InterT171_refuses_all_recovery_scope_mismatches_before_any_mutation' {
        $discovery=Join-Path $script:ExternalRoot 'scope-discovery';Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $discovery -Recurse
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'scope-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $discoveryTransaction=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$discoveryJournal=Get-Content -Raw -LiteralPath (Join-Path $discoveryTransaction[0].FullName 'journal.json')|ConvertFrom-Json
        $sequence=[int](@($discoveryJournal.operations|Where-Object{[string]$_.role-ceq'instruction'}|Select-Object -First 1)[0].sequence)
        foreach($kind in @('CommonGitDirectory','IndexPath')){
            $target=Join-Path $script:ExternalRoot ("scope-"+$kind);Copy-Item -LiteralPath $script:P9cSeeds.False -Destination $target -Recurse
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("scope-runtime-"+$kind)) -Failpoint ("after-operation-$sequence-before-journal") -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
            $transactions=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force);$transactions.Count|Should -Be 1
            $journalPath=Join-Path $transactions[0].FullName 'journal.json';Set-P9cRepositoryJournalScopeMismatch -JournalPath $journalPath -Kind $kind
            $before=Get-P9cPublicationStateSnapshot $target
            $retry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target
            $retry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $retry.Output)|Should -Be interrupted-install
            (Get-P9cPublicationStateSnapshot $target)|Should -BeExactly $before
            Test-Path -LiteralPath $journalPath -PathType Leaf|Should -Be $true
        }

        $main=Join-Path $script:ExternalRoot 'scope-root-main';New-P9bTargetRepository $main
        $rootTarget=Join-Path $script:ExternalRoot 'scope-root-target';& git -C $main worktree add --quiet -b p9c-scope-root $rootTarget
        (Invoke-P9bRepoBootstrap -Context $script:P9cInitial.Context -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $rootTarget).ExitCode|Should -Be 0
        $rootBootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'scope-root-runtime') -Failpoint ("after-operation-$sequence-before-journal") -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $rootTarget -BootstrapPath $rootBootstrap).ExitCode|Should -Not -Be 0
        $oldRoot=$rootTarget+'-replaced';Move-Item -LiteralPath $rootTarget -Destination $oldRoot
        New-Item -ItemType Directory -Path $rootTarget|Out-Null
        Copy-Item -LiteralPath (Join-Path $oldRoot '.git') -Destination (Join-Path $rootTarget '.git')
        foreach($item in @(Get-ChildItem -Force -LiteralPath $oldRoot|Where-Object Name -cne '.git')){Copy-Item -LiteralPath $item.FullName -Destination $rootTarget -Recurse -Force}
        $rootJournal=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $rootTarget) -Directory -Force);$rootJournal.Count|Should -Be 1
        $rootJournalPath=Join-Path $rootJournal[0].FullName 'journal.json';$rootBefore=Get-P9cPublicationStateSnapshot $rootTarget
        $rootRetry=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $rootTarget
        $rootRetry.ExitCode|Should -Not -Be 0;(Get-AiInstructionsRefusalCode $rootRetry.Output)|Should -Be interrupted-install
        (Get-P9cPublicationStateSnapshot $rootTarget)|Should -BeExactly $rootBefore
        Test-Path -LiteralPath $rootJournalPath -PathType Leaf|Should -Be $true
    }

    # Scenario: A durable remediation transaction observes refs/stash, then an external writer changes that ref immediately before the evidence compare-and-swap.
    # Purpose: Preserve the external ref exactly, roll back every other operation through the shared applying-phase decision, and remove the successfully rolled-back transaction store.
    It 'InterT172_preserves_external_refs_stash_and_rolls_back_other_operations_on_durable_evidence_CAS_loss' {
        $target=Join-Path $script:ExternalRoot 'stash-durable-race';Copy-Item -LiteralPath $script:P9cSeeds.True -Destination $target -Recurse
        $stashBefore=(@(& git -C $target rev-parse --verify refs/stash)|Select-Object -First 1).Trim();$external=(@(& git -C $target rev-parse HEAD)|Select-Object -First 1).Trim();$stashBefore|Should -Not -BeExactly $external;$before=Get-P9cPublicationStateSnapshot $target
        $bootstrap=New-P9cStashCasRaceBootstrap -Root (Join-Path $script:ExternalRoot 'stash-durable-race-runtime') -ExternalObjectId $external
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap
        $result.ExitCode|Should -Not -Be 0
        (Get-AiInstructionsRefusalCode $result.Output)|Should -Be interrupted-install
        ((@(& git -C $target rev-parse --verify refs/stash)|Select-Object -First 1).Trim())|Should -BeExactly $external
        (Get-P9cPublicationStateSnapshot $target)|Should -BeExactly $before
        @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
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
}
