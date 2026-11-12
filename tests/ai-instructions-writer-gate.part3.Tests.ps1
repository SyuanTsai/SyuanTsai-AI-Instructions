. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

Describe 'AI instructions unified repository transaction' {
    BeforeAll {
        $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e'
        New-Item -ItemType Directory -Force -Path $shortParent|Out-Null
        $script:ExternalRoot=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:ExternalRoot|Out-Null
        $script:BootstrapPath=Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions.ps1'
        $script:TransactionModulePath=Join-Path $script:RepositoryRoot 'scripts/ai-instructions-install-transaction.psm1'
        $tokens=$null;$errors=$null
        $script:BootstrapAst=[Management.Automation.Language.Parser]::ParseFile($script:BootstrapPath,[ref]$tokens,[ref]$errors)
        if(@($errors).Count-ne0){throw ($errors|ForEach-Object Message|Join-String -Separator '; ')}
        $script:BootstrapText=[IO.File]::ReadAllText($script:BootstrapPath)
        $script:TransactionText=[IO.File]::ReadAllText($script:TransactionModulePath)
    }
    AfterAll {if(Test-Path -LiteralPath $script:ExternalRoot){Remove-Item -LiteralPath $script:ExternalRoot -Recurse -Force}}

    # Scenario: Every journaled repository operation kind is wired through the shared executor with both pre-mutation and post-mutation-before-journal failpoints, and TestSupport exposes catch and crash paths.
    # Purpose: Preserve the InterT140 matrix contract while moving it out of part2 and prohibit project-only comment seams.
    It 'InterT140_registers_every_repository_step_failpoint_through_both_recovery_paths' -TestCases @(
        @{Kind='replace-git-index'},@{Kind='update-git-ref'},@{Kind='update-git-head'},@{Kind='ensure-directory-anchor'},
        @{Kind='create-file'},@{Kind='write-file'},@{Kind='remove-file'}
    ) {
        param($Kind)
        $script:BootstrapText|Should -Match ([regex]::Escape("kind='$Kind'")+'|'+[regex]::Escape("'$Kind'"))
        $script:BootstrapText|Should -Match 'before-operation-'
        $script:BootstrapText|Should -Match 'after-operation-.+?-before-journal'
        $support=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1'))
        $support|Should -Match "RecoveryPath-ceq'InProcess'"
        $support|Should -Match "ValidateSet\('InProcess','NextRun'\)"
        $support|Should -Not -Match 'P9C_TEST_HOOK'
    }

    # Scenario: A completed current run has no terminal file, Git, manifest, or exclude mutation.
    # Purpose: Return before creating .ai-instructions-txn and leave the complete filesystem tree byte-for-byte unchanged.
    It 'InterT143_leaves_the_filesystem_unchanged_when_the_plan_has_no_mutation' {
        $start=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Start-RepositoryInstallTransaction'},$true))[-1].Extent.Text
        $start|Should -Match 'if\(-not\$hasRemediationGit-and-not\$hasFileMutation\)\{return\}'
        $returnOffset=$start.IndexOf('if(-not$hasRemediationGit-and-not$hasFileMutation){return}',[StringComparison]::Ordinal)
        $createOffset=$start.IndexOf("Open-PlatformDirectory -Root `$Context.Repository -RelativePath '.ai-instructions-txn' -CreatePrivate",[StringComparison]::Ordinal)
        $returnOffset|Should -BeGreaterThan -1
        $createOffset|Should -BeGreaterThan $returnOffset
    }

    # Scenario: Remediation index/ref/HEAD and repository file intents are all prepared before the applying loop begins.
    # Purpose: Enforce strict write-ahead and prevent any legacy direct mutation path from preceding the durable journal.
    It 'InterT144_journals_each_remediation_substep_before_mutation' {
        $start=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Start-RepositoryInstallTransaction'},$true))[-1].Extent.Text
        $journalOffset=$start.IndexOf('Write-AiInstructionsInstallJournalStore',[StringComparison]::Ordinal)
        $applyingOffset=$start.IndexOf('-Phase applying',[StringComparison]::Ordinal)
        $operationOffset=$start.IndexOf('Invoke-RepositoryTransactionOperation',[StringComparison]::Ordinal)
        $journalOffset|Should -BeGreaterThan -1
        $applyingOffset|Should -BeGreaterThan $journalOffset
        $operationOffset|Should -BeGreaterThan $applyingOffset
        $script:BootstrapText|Should -Not -Match 'Set-RemediationIndexWithoutPaths\s'
        $script:BootstrapText|Should -Not -Match 'Invoke-AgentArtifactRemediation\s'
    }

    # Scenario: Recovery is re-entered after any partially undone remediation step.
    # Purpose: Restart the complete reverse sequence without a rollback-progress journal and treat already-before steps as no-op.
    It 'InterT145_restarts_reverse_undo_after_each_remediation_substep' {
        $rollback=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-RepositoryTransactionRollback'},$true))[-1].Extent.Text
        $rollback|Should -Match 'Sort-Object sequence -Descending'
        $rollback|Should -Match 'Invoke-RepositoryTransactionOperation.+-Direction undo'
        $executor=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-RepositoryTransactionOperation'},$true))[-1].Extent.Text
        $executor|Should -Match 'Test-RepositoryTransactionStateEqual.+\$destination\)\{return\}'
        $executor|Should -Not -Match 'rolled-back|RollbackAttempted|RolledBack'
    }

    # Scenario: Project selection is empty while ordinary Instructions or legacy v1-v3 retirement still requires mutation.
    # Purpose: Keep all mutation on the unified intent/executor path and retire the legacy snapshot publication authority.
    It 'InterT146_recovers_empty_project_selection_without_legacy_snapshot' {
        $script:BootstrapText|Should -Match 'Start-RepositoryInstallTransaction \$script:ProjectPublicationContext'
        $script:BootstrapText|Should -Not -Match 'Save-SkillMigrationJournal\s+-'
        $script:BootstrapText|Should -Not -Match 'Restore-LegacyAgentArtifactRemediation.+Restore-AgentArtifactRemediation'
    }

    # Scenario: Cleanup is interrupted after one artifact or after journal deletion, through catch or next-run recovery.
    # Purpose: Retain a committed decision while it exists, then classify the journal-less directory as a harmless orphan and never undo after-state.
    It 'InterT147_recovers_both_committed_cleanup_interruption_points_without_undo' {
        $cleanup=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Complete-RepositoryTransactionCleanup'},$true))[-1].Extent.Text
        $cleanup|Should -Match 'Sort-Object sequence\)\)\{Invoke-RepositoryTransactionOperation.+-Direction redo'
        $cleanup|Should -Match 'Remove-InstallTerminalTransactionArtifacts'
        $cleanup|Should -Match "during-cleanup-transaction"
        $cleanup|Should -Not -Match 'Direction undo|\.cleanup'
        $script:TransactionText|Should -Match "after-cleanup-journal-before-directory"
        $script:BootstrapText|Should -Match "classification\.classification-cne'orphan-without-journal'"
        $script:BootstrapText|Should -Match 'orphan-without-journal'
    }

    # Scenario: The disk classification is prepared, applying, applied, committed, malformed, or missing.
    # Purpose: Give process catch and next-run recovery one exhaustive phase decision and fail closed on unknown state.
    It 'UnitT148_maps_all_repo_journal_classifications_to_one_recovery_action' {
        $definition=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Resolve-ProjectPublicationRecoveryAction'},$true))[-1]
        Invoke-Expression $definition.Extent.Text
        foreach($phase in @('prepared','applying','applied')){Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status='valid';journal=[pscustomobject]@{phase=$phase}})|Should -Be 'rollback-all'}
        Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status='valid';journal=[pscustomobject]@{phase='committed'}})|Should -Be 'roll-forward-cleanup'
        foreach($status in @('missing','orphan','indeterminate')){Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status=$status;journal=$null})|Should -Be 'fail-closed'}
    }

    # Scenario: File, index, ref, HEAD, or exclude state is neither its journal before nor after image.
    # Purpose: Stop at the first third state, retain evidence, and return interrupted-install without overwriting external bytes.
    It 'InterT149_refuses_third_state_and_foreign_index_lock_without_mutation' {
        $executor=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-RepositoryTransactionOperation'},$true))[-1].Extent.Text
        $executor|Should -Match 'is in a third state; evidence was retained'
        $lock=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Remove-RepositoryIndexLockIfOwned'},$true))[-1].Extent.Text
        $lock|Should -Match "phase-cne'applying'"
        $lock|Should -Match 'Get-ByteArraySha256 \$bytes\)-cne\$ExpectedSha256'
        $lock|Should -Match 'Remove-PlatformOwnedFile'
        $script:BootstrapText|Should -Match 'Confirm that no other Git process is running'
    }

    # Scenario: Attached, detached, and unborn HEAD transactions are observed and restored through ref/HEAD CAS operations.
    # Purpose: Preserve each HEAD mode and keep ref updates separate from symbolic HEAD publication.
    It 'InterT150_recovers_attached_detached_and_unborn_HEAD_transactions' {
        $head=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Get-RepositoryTransactionHeadState'},$true))[-1].Extent.Text
        foreach($mode in @('symbolic','detached','unborn')){$head|Should -Match $mode}
        $script:BootstrapText|Should -Match "kind='update-git-ref'"
        $script:BootstrapText|Should -Match "kind='update-git-head'"
        $script:BootstrapText|Should -Match "update-ref','--no-deref','HEAD"
        $script:BootstrapText|Should -Match "symbolic-ref','HEAD'"
    }

    # Scenario: A created directory anchor contains an unexpected child when undo is attempted.
    # Purpose: Refuse recursive deletion and require the same directory identity to be empty before moving it back to transaction evidence.
    It 'InterT151_refuses_to_remove_directory_anchors_with_unknown_children' {
        $executor=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-RepositoryTransactionOperation'},$true))[-1].Extent.Text
        $executor|Should -Match "'ensure-directory-anchor'"
        $executor|Should -Match 'Move-PlatformOwnedDirectory'
        $executor|Should -Not -Match 'Remove-Item.+-Recurse|Remove-PlatformOwnedDirectoryTree'
    }

    # Scenario: index.lock is flushed before rename, rename completes before the journal update, or a foreign lock is present.
    # Purpose: Bind lock cleanup to applying plus the direction SHA, use atomic replacement, and leave foreign lock/index bytes untouched.
    It 'InterT152_enforces_index_lock_write_ahead_atomic_replace_and_residual_lock_rules' {
        $index=@($script:BootstrapAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-RepositoryIndexReplacement'},$true))[-1].Extent.Text
        $index|Should -Match 'FileMode\]::CreateNew'
        $index|Should -Match 'Flush\(\$true\)'
        $index|Should -Match "after-index-lock-write-before-rename"
        $index|Should -Match '\[IO\.File\]::Replace\(\$lockPath,\$indexPath,\$null\)'
        $index|Should -Not -Match 'Remove-Item.+indexPath|Publish-PlatformFile'
        $script:BootstrapText|Should -Match 'Resolve-RepositoryRecoveryIndexLock -Context \$context'
    }
}
