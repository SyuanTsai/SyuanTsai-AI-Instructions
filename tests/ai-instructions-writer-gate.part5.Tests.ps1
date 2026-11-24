. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

Describe 'AI instructions unified repository transaction remediation failpoint matrix' {
    BeforeAll {
        $shortParent=Get-P7eTestTempRoot
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:P9cBaseline=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'baseline-work') -ArchivePath (Join-Path $script:ExternalRoot 'baseline.zip') -Marker baseline
        $script:P9cChanged=New-P9bInstructionArchive -WorkingRoot (Join-Path $script:ExternalRoot 'changed-work') -ArchivePath (Join-Path $script:ExternalRoot 'changed.zip') -Marker changed
        $initialFiles=@{'work-with-jira'=@{'resources/state.txt'="jira old`n"};'manage-task-handoff'=@{'resources/state.txt'="handoff old`n"}}
        $updatedFiles=@{'work-with-jira'=@{'resources/state.txt'="jira new`n";'resources/added.txt'="jira added`n"};'manage-task-handoff'=@{'resources/state.txt'="handoff new`n";'resources/added.txt'="handoff added`n"}}
        $script:P9cInitial=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'initial') -ProjectionIds @('project-agents') -AdditionalSkillFiles $initialFiles
        $script:P9cUpdated=New-P9cProjectFixture -Root (Join-Path $script:ExternalRoot 'updated') -ProjectionIds @('project-agents') -AdditionalSkillFiles $updatedFiles
        $script:P9cSeed=Join-Path $script:ExternalRoot 'seed';New-P9bTargetRepository $script:P9cSeed
        $result=Invoke-P9bRepoBootstrap -Context $script:P9cInitial.Context -ArchivePath $script:P9cBaseline.ArchivePath -TargetRoot $script:P9cSeed
        if($result.ExitCode-ne0){throw "Could not create InterT140 seed: $($result.Output)"}
        & git -C $script:P9cSeed add -f -- AGENTS.md
        & git -C $script:P9cSeed commit --quiet -m 'tracked Agent artifact fixture'
        if($LASTEXITCODE-ne0){throw 'Could not create remediation seed.'}
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: With and without tracked-artifact remediation, representative index, ref, file, Skill, license, manifest, and shared-exclude roles stop immediately before mutation or after mutation but before journal update, through both process catch and next-run recovery.
    # Purpose: Preserve every fix4 InterT140 state assertion, select sequences by durable role instead of number, and prove both recovery paths produce identical complete repository snapshots.
    It 'InterT140_recovers_each_repository_role_failpoint_with_remediation_through_both_paths' {
        Invoke-P9cInterT140FailpointMatrix -ExternalRoot $script:ExternalRoot -Seed $script:P9cSeed `
            -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath `
            -WithRemediation $true -RepositoryRoot $script:RepositoryRoot
    }

    # Scenario: A detached HEAD remediation stops immediately before the update-git-head mutation or immediately after its atomic mutation but before the operation-state generation.
    # Purpose: Next-run rollback must restore the exact detached HEAD, index, refs, files, shared exclude, and empty transaction store in both crash windows.
    It 'InterT180_recovers_detached_HEAD_before_and_after_the_atomic_HEAD_operation' {
        $discovery=Join-Path $script:ExternalRoot 'detached-discovery';Copy-Item -LiteralPath $script:P9cSeed -Destination $discovery -Recurse;& git -C $discovery checkout --detach --quiet
        $prepared=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot 'detached-discovery-runtime') -Failpoint after-journal-prepared -RecoveryPath NextRun
        (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $discovery -BootstrapPath $prepared).ExitCode|Should -Not -Be 0
        $transactions=@(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $discovery) -Directory -Force);$transactions.Count|Should -Be 1
        $journal=Get-Content -Raw -LiteralPath (Join-Path $transactions[0].FullName 'journal.json')|ConvertFrom-Json
        $headOperation=@($journal.operations|Where-Object{[string]$_.kind-ceq'update-git-head'});$headOperation.Count|Should -Be 1
        $sequence=[int]$headOperation[0].sequence
        foreach($case in @(
            [pscustomobject]@{Name='before';Failpoint="before-operation-$sequence"},
            [pscustomobject]@{Name='after-before-journal';Failpoint="after-operation-$sequence-before-journal"}
        )){
            $target=Join-Path $script:ExternalRoot ("detached-"+$case.Name);Copy-Item -LiteralPath $script:P9cSeed -Destination $target -Recurse;& git -C $target checkout --detach --quiet
            $before=Get-P9cPublicationStateSnapshot $target
            $bootstrap=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("detached-runtime-"+$case.Name)) -Failpoint $case.Failpoint -RecoveryPath NextRun
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $bootstrap).ExitCode|Should -Not -Be 0
            $recovery=New-P9cProjectPublicationFailpointBootstrap -Root (Join-Path $script:ExternalRoot ("detached-recovery-"+$case.Name)) -Failpoint RecoveryOnly
            (Invoke-P9bRepoBootstrap -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath -TargetRoot $target -BootstrapPath $recovery).ExitCode|Should -Not -Be 0
            (Get-P9cPublicationStateSnapshot $target)|Should -BeExactly $before
            @(Get-ChildItem -LiteralPath (Get-P9cRepositoryTransactionRoot -Repository $target) -Directory -Force -ErrorAction SilentlyContinue).Count|Should -Be 0
        }
    }
}
