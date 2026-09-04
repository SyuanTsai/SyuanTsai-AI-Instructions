$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RemediationModule = Join-Path $script:RepositoryRoot 'scripts\agent-artifact-remediation.psm1'

Describe 'Agent artifact remediation transaction' {
    BeforeAll {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:RemediationModule = Join-Path $repositoryRoot 'scripts\agent-artifact-remediation.psm1'
        Import-Module $script:RemediationModule -Force

        function script:Assert-TestCondition {
            param(
                [Parameter(Mandatory = $true)][bool] $Condition,
                [Parameter(Mandatory = $true)][string] $Message
            )

            if (-not $Condition) { throw "Assertion failed: $Message" }
        }
    }

    # Scenario: A tracked declaration is placed under a managed instruction license namespace.
    # Purpose: Reserve only Agent delivery paths while protecting product LICENSE and NOTICE files.
    It 'UnitT05_classifies_license_delivery_without_reserving_product_licenses' {
        foreach ($path in @('.codex/ai-instructions-licenses/source/LICENSE','.github/ai-instructions-licenses/delivery.json')) {
            (Test-IsReservedAgentArtifactPath -Path $path) | Should Be $true
        }
        foreach ($path in @('LICENSE','NOTICE','docs/LICENSE','.codex/ai-instructions-licenses/../../LICENSE')) {
            (Test-IsReservedAgentArtifactPath -Path $path) | Should Be $false
        }
    }

    # Given: Remediation removed a tracked Agent file, then an external editor recreates it and an external Git process stages product work.
    # When: A later bootstrap failure asks remediation to roll back.
    # Then: Applied-state drift is reported and both external file bytes and index entries are preserved for automatic retry.
    It 'InterT10_preserves_concurrent_file_and_index_drift_during_rollback' {
        $repository = Join-Path $TestDrive 'concurrent-rollback'
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository 'AGENTS.md'),"tracked Agent`n",(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product v1`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- AGENTS.md product.txt
        & git -C $repository commit --quiet -m 'fixture'

        $transaction = Invoke-AgentArtifactRemediation -Repository $repository
        try {
            [System.IO.File]::WriteAllText((Join-Path $repository 'AGENTS.md'),"external Agent bytes`n",(New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product v2`n",(New-Object System.Text.UTF8Encoding($false)))
            & git -C $repository add -- product.txt

            $failure = $null
            try { Restore-AgentArtifactRemediation -Transaction $transaction }
            catch { $failure = $_.Exception.Message }

            Assert-TestCondition -Condition ($failure -match 'rollback failed') -Message 'The rollback failure was not reported.'
            Assert-TestCondition -Condition ($failure -match 'index changed after remediation') -Message 'Concurrent index drift was not reported.'
            Assert-TestCondition -Condition ($failure -match 'Agent artifact path changed after remediation') -Message 'Concurrent Agent file drift was not reported.'
            Assert-TestCondition -Condition ((Get-Content -Raw -LiteralPath (Join-Path $repository 'AGENTS.md')).Trim() -eq 'external Agent bytes') -Message 'External Agent bytes were not preserved.'
            $stagedPaths = @(& git -C $repository diff --cached --name-only)
            Assert-TestCondition -Condition (@($stagedPaths | Where-Object { $_ -eq 'product.txt' }).Count -eq 1) -Message 'The concurrently staged product file was not preserved.'
            Assert-TestCondition -Condition (@($stagedPaths | Where-Object { $_ -eq 'AGENTS.md' }).Count -eq 1) -Message 'The staged Agent file was not preserved after rollback drift.'
            Assert-TestCondition -Condition ([bool]$transaction.RollbackAttempted) -Message 'The transaction did not record the rollback attempt.'
            Assert-TestCondition -Condition (-not [bool]$transaction.RolledBack) -Message 'A drifted rollback was incorrectly marked as successful.'
        }
        finally {
            if (Test-Path -LiteralPath $transaction.Backup.Root) { Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force }
        }
    }

    # Given: A repository has only an untracked customized implementation in the exact retired search-with-felo directory.
    # When: Remediation runs without any tracked reserved path.
    # Then: It backs up and removes the retired implementation without creating a commit or touching official Felo outside the repository.
    It 'InterT20_backs_up_and_removes_untracked_retired_custom_FELO_without_a_commit' {
        $repository = Join-Path $TestDrive 'untracked-retired-felo'
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- product.txt
        & git -C $repository commit --quiet -m 'fixture'
        $retiredPath = Join-Path $repository '.agents\skills\search-with-felo\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $retiredPath) | Out-Null
        [System.IO.File]::WriteAllText($retiredPath,"customized retired FELO`n",(New-Object System.Text.UTF8Encoding($false)))
        $officialPath = Join-Path $TestDrive 'official-felo-search\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $officialPath) | Out-Null
        [System.IO.File]::WriteAllText($officialPath,"official FELO`n",(New-Object System.Text.UTF8Encoding($false)))
        $headBefore = (@(& git -C $repository rev-parse HEAD) -join '').Trim()

        $transaction = Invoke-AgentArtifactRemediation -Repository $repository
        try {
            Assert-TestCondition -Condition ($null -ne $transaction) -Message 'The remediation transaction was not returned.'
            Assert-TestCondition -Condition (@($transaction.Paths).Count -eq 0) -Message 'Untracked FELO cleanup was incorrectly treated as tracked remediation.'
            Assert-TestCondition -Condition ([string]::IsNullOrEmpty([string]$transaction.NewCommit)) -Message 'Untracked-only cleanup created a commit.'
            Assert-TestCondition -Condition (((@(& git -C $repository rev-parse HEAD) -join '').Trim()) -eq $headBefore) -Message 'Untracked-only cleanup changed HEAD.'
            Assert-TestCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $repository '.agents\skills\search-with-felo'))) -Message 'The retired customized FELO directory remains active.'
            $retiredBackup = (Get-Content -Raw -LiteralPath (Join-Path $transaction.Backup.Root 'files\.agents\skills\search-with-felo\SKILL.md')).Trim()
            Assert-TestCondition -Condition ($retiredBackup -eq 'customized retired FELO') -Message 'The retired customized FELO file was not backed up exactly.'
            Assert-TestCondition -Condition ((Get-Content -Raw -LiteralPath $officialPath).Trim() -eq 'official FELO') -Message 'The official FELO file was changed.'
        }
        finally {
            if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Backup.Root)) {
                Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force
            }
        }
    }

    # Given: A manifest-like path starts at the filesystem root but otherwise resembles a reserved Agent path.
    # When: The reserved-path classifier validates it.
    # Then: It rejects the absolute path instead of silently converting it to a Repository-relative path.
    It 'InterT30_rejects_rooted_paths_before_reserved_path_classification' {
        Assert-TestCondition -Condition (-not (Test-IsReservedAgentArtifactPath -Path '/.agents/skills/example/SKILL.md')) -Message 'A rooted slash path was accepted.'
        Assert-TestCondition -Condition (-not (Test-IsReservedAgentArtifactPath -Path '\.codex\AGENTS.md')) -Message 'A rooted backslash path was accepted.'
    }

    # Given: Another Git process stages product work after remediation creates its backup but before it mutates the index.
    # When: Remediation reaches the index compare-and-swap boundary.
    # Then: It stops without replacing the concurrent index, keeps the Agent file, and preserves the newly staged product work.
    It 'InterT40_preserves_index_drift_between_backup_and_index_mutation' {
        $repository = Join-Path $TestDrive 'concurrent-before-index-mutation'
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository 'AGENTS.md'),"tracked Agent`n",(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product v1`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- AGENTS.md product.txt
        & git -C $repository commit --quiet -m 'fixture'
        $headBefore = (@(& git -C $repository rev-parse HEAD) -join '').Trim()

        $global:RemediationTestRepositoryPath = $repository
        try {
            Mock Set-RemediationGitInfoExclude {
                [System.IO.File]::WriteAllText((Join-Path $global:RemediationTestRepositoryPath 'product.txt'),"product v2`n",(New-Object System.Text.UTF8Encoding($false)))
                & git -C $global:RemediationTestRepositoryPath add -- product.txt
                return $null
            } -ModuleName agent-artifact-remediation
            try { $failure = Invoke-AgentArtifactRemediation -Repository $repository }
            catch { $failure = $_.Exception.Message }
        }
        finally {
            Remove-Variable -Name RemediationTestRepositoryPath -Scope Global -ErrorAction SilentlyContinue
            Import-Module $script:RemediationModule -Force
        }

        Assert-TestCondition -Condition ($failure -match 'Git index changed after the remediation backup') -Message 'The compare-and-swap index guard did not stop remediation.'
        Assert-TestCondition -Condition ($failure -notmatch 'rollback failed|Cannot bind argument') -Message 'A pre-mutation failure caused a secondary rollback error.'
        Assert-TestCondition -Condition (Test-Path -LiteralPath (Join-Path $repository 'AGENTS.md')) -Message 'The Agent file was changed before the index guard stopped remediation.'
        Assert-TestCondition -Condition ((Get-Content -Raw -LiteralPath (Join-Path $repository 'AGENTS.md')).Trim() -eq 'tracked Agent') -Message 'The tracked Agent file bytes changed.'
        Assert-TestCondition -Condition (@(& git -C $repository diff --cached --name-only | Where-Object { $_ -eq 'product.txt' }).Count -eq 1) -Message 'Concurrent product index work was not preserved.'
        Assert-TestCondition -Condition (((@(& git -C $repository rev-parse HEAD) -join '').Trim()) -eq $headBefore) -Message 'The remediation guard unexpectedly changed HEAD.'
    }

    # Given: A tracked legacy manifest explicitly owns a Traditional Chinese Codex rule runtime file.
    # When: Reserved artifact remediation parses the manifest's safe Agent target.
    # Then: It removes both tracked runtime paths in the isolated remediation commit instead of treating the rule as production scope.
    It 'InterT50_accepts_manifest_owned_localized_Codex_rule_artifacts' {
        $repository = Join-Path $TestDrive 'localized-codex-rule'
        New-Item -ItemType Directory -Force -Path (Join-Path $repository '.codex\AI-Rules') | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository '.codex\AI-Rules\Testing.md'),"# 測試規則`n",(New-Object System.Text.UTF8Encoding($false)))
        $manifest = [ordered]@{ schemaVersion = 2; files = @([ordered]@{ targetPath = '.codex/AI-Rules/Testing.md' }) }
        [System.IO.File]::WriteAllText((Join-Path $repository '.codex\ai-instructions.manifest.json'),(($manifest | ConvertTo-Json -Depth 5) + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- '.codex/AI-Rules/Testing.md' '.codex/ai-instructions.manifest.json'
        & git -C $repository commit --quiet -m 'tracked localized runtime fixture'

        $transaction = Invoke-AgentArtifactRemediation -Repository $repository
        try {
            Assert-TestCondition -Condition (@(& git -C $repository diff-tree --no-commit-id --name-only -r HEAD | Where-Object { $_ -eq '.codex/AI-Rules/Testing.md' }).Count -eq 1) -Message 'The localized Codex rule was not included in the remediation commit.'
            Assert-TestCondition -Condition (@(& git -C $repository ls-files -- '.codex/AI-Rules/Testing.md' '.codex/ai-instructions.manifest.json').Count -eq 0) -Message 'Managed localized runtime artifacts remain tracked.'
        }
        finally {
            if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Backup.Root)) {
                Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force
            }
        }
    }

    # Given: A newly initialized Repository has no HEAD yet, with a staged Agent artifact and unrelated staged product work.
    # When: Remediation handles the index-only Agent entry.
    # Then: It removes only the Agent entry without inventing a root commit and preserves the unborn branch plus product index state.
    It 'InterT60_handles_index_only_reserved_artifacts_on_an_unborn_branch' {
        $repository = Join-Path $TestDrive 'unborn-index-only'
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        [System.IO.File]::WriteAllText((Join-Path $repository 'AGENTS.md'),"tracked Agent`n",(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- AGENTS.md product.txt

        $transaction = Invoke-AgentArtifactRemediation -Repository $repository
        try {
            $null = & git -C $repository rev-parse --verify HEAD 2>$null
            Assert-TestCondition -Condition ($LASTEXITCODE -ne 0) -Message 'Remediation invented a commit on the unborn branch.'
            Assert-TestCondition -Condition (@(& git -C $repository diff --cached --name-only | Where-Object { $_ -eq 'product.txt' }).Count -eq 1) -Message 'Unborn-branch product index work was not preserved.'
            Assert-TestCondition -Condition (@(& git -C $repository diff --cached --name-only | Where-Object { $_ -eq 'AGENTS.md' }).Count -eq 0) -Message 'The reserved Agent artifact remains staged.'
            Assert-TestCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $repository 'AGENTS.md'))) -Message 'The index-only Agent artifact remains in the worktree.'
            Assert-TestCondition -Condition ([string]::IsNullOrEmpty([string]$transaction.NewCommit)) -Message 'Index-only remediation created a commit without a parent.'
        }
        finally {
            if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Backup.Root)) {
                Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force
            }
        }
    }
}
