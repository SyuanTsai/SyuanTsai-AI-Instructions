. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

Describe 'AI instructions unified repository transaction failpoint matrix' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
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
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: With and without tracked-artifact remediation, representative index, ref, file, Skill, license, manifest, and shared-exclude roles stop immediately before mutation or after mutation but before journal update, through both process catch and next-run recovery.
    # Purpose: Preserve every fix4 InterT140 state assertion, select sequences by durable role instead of number, and prove both recovery paths produce identical complete repository snapshots.
    It 'InterT140_recovers_each_repository_role_failpoint_without_remediation_through_both_paths' {
        Invoke-P9cInterT140FailpointMatrix -ExternalRoot $script:ExternalRoot -Seed $script:P9cSeed `
            -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath `
            -WithRemediation $false -RepositoryRoot $script:RepositoryRoot
    }

    # Scenario: Every prepared, applying operation-state, applied, and committed repo-v2 generation stops after stage flush or after journal publication before the parent-directory flush.
    # Purpose: Classify the exact durable generation on the next run and converge by the same rollback-all versus roll-forward-cleanup phase decision used in production recovery.
    It 'InterT179_recovers_each_repo_v2_generation_durability_window_by_durable_phase' {
        Invoke-P9cJournalDurabilityRecoveryMatrix -ExternalRoot (Join-Path $script:ExternalRoot 'journal-durability') `
            -Seed $script:P9cSeed -Context $script:P9cUpdated.Context -ArchivePath $script:P9cChanged.ArchivePath
    }
}
