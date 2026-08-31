$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RemediationModule = Join-Path $script:RepositoryRoot 'scripts\agent-artifact-remediation.psm1'

Describe 'Agent artifact remediation transaction' {
    BeforeAll {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $repositoryRoot 'scripts\agent-artifact-remediation.psm1') -Force
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

            $failure | Should -Match 'rollback failed'
            $failure | Should -Match 'index changed after remediation'
            $failure | Should -Match 'Agent artifact path changed after remediation'
            (Get-Content -Raw -LiteralPath (Join-Path $repository 'AGENTS.md')).Trim() | Should -Be 'external Agent bytes'
            $stagedPaths = @(& git -C $repository diff --cached --name-only)
            $stagedPaths | Should -Contain 'product.txt'
            $stagedPaths | Should -Contain 'AGENTS.md'
            [bool]$transaction.RollbackAttempted | Should -Be $true
            [bool]$transaction.RolledBack | Should -Be $false
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
            $transaction | Should -Not -BeNullOrEmpty
            @($transaction.Paths).Count | Should -Be 0
            [string]$transaction.NewCommit | Should -BeNullOrEmpty
            (@(& git -C $repository rev-parse HEAD) -join '').Trim() | Should -Be $headBefore
            Test-Path -LiteralPath (Join-Path $repository '.agents\skills\search-with-felo') | Should -BeFalse
            (Get-Content -Raw -LiteralPath (Join-Path $transaction.Backup.Root 'files\.agents\skills\search-with-felo\SKILL.md')).Trim() |
                Should -Be 'customized retired FELO'
            (Get-Content -Raw -LiteralPath $officialPath).Trim() | Should -Be 'official FELO'
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
        Test-IsReservedAgentArtifactPath -Path '/.agents/skills/example/SKILL.md' | Should -BeFalse
        Test-IsReservedAgentArtifactPath -Path '\.codex\AGENTS.md' | Should -BeFalse
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

        $failure = InModuleScope agent-artifact-remediation -Parameters @{ RepositoryPath = $repository } {
            param($RepositoryPath)
            Mock Set-RemediationGitInfoExclude {
                [System.IO.File]::WriteAllText((Join-Path $RepositoryPath 'product.txt'),"product v2`n",(New-Object System.Text.UTF8Encoding($false)))
                & git -C $RepositoryPath add -- product.txt
                return $null
            }
            try { Invoke-AgentArtifactRemediation -Repository $RepositoryPath }
            catch { return $_.Exception.Message }
            return $null
        }

        $failure | Should -Match 'Git index changed after the remediation backup'
        Test-Path -LiteralPath (Join-Path $repository 'AGENTS.md') | Should -BeTrue
        (Get-Content -Raw -LiteralPath (Join-Path $repository 'AGENTS.md')).Trim() | Should -Be 'tracked Agent'
        @(& git -C $repository diff --cached --name-only) | Should -Contain 'product.txt'
        (@(& git -C $repository rev-parse HEAD) -join '').Trim() | Should -Be $headBefore
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
            @(& git -C $repository diff-tree --no-commit-id --name-only -r HEAD) | Should -Contain '.codex/AI-Rules/Testing.md'
            @(& git -C $repository ls-files -- '.codex/AI-Rules/Testing.md' '.codex/ai-instructions.manifest.json').Count | Should -Be 0
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
            $LASTEXITCODE | Should -Not -Be 0
            @(& git -C $repository diff --cached --name-only) | Should -Contain 'product.txt'
            @(& git -C $repository diff --cached --name-only) | Should -Not -Contain 'AGENTS.md'
            Test-Path -LiteralPath (Join-Path $repository 'AGENTS.md') | Should -BeFalse
            [string]$transaction.NewCommit | Should -BeNullOrEmpty
        }
        finally {
            if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Backup.Root)) {
                Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force
            }
        }
    }
}
