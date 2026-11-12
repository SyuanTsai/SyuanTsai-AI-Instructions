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
        foreach ($path in @('.codex/ai-instructions-licenses/source/LICENSE','.github/ai-instructions-licenses/delivery.json','.claude/ai-instructions-licenses/source/LICENSE','.claude/AI-Rules/Testing.en.md')) {
            (Test-IsReservedAgentArtifactPath -Path $path) | Should Be $true
        }
        foreach ($path in @('LICENSE','NOTICE','docs/LICENSE','CLAUDE.md','.codex/ai-instructions-licenses/../../LICENSE','.claude/skills/example/SKILL.md','.github/skills/example/SKILL.md')) {
            (Test-IsReservedAgentArtifactPath -Path $path) | Should Be $false
        }
    }

    # Given: A repository root contains non-ASCII characters and a child PowerShell starts with a legacy console encoding.
    # When: Remediation asks Git for the repository top-level path.
    # Then: Git output is decoded as UTF-8 and the caller's console encoding is restored.
    It 'InterT07_decodes_non_ascii_repository_paths_as_utf8_and_restores_console_output_encoding' {
        $repository = Join-Path $TestDrive (([string][char]0x5DE5) + ([string][char]0x4F5C) + ([string][char]0x6A39) + '-' + ([string][char]0x00FC) + '-remediation')
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- product.txt
        & git -C $repository commit --quiet -m 'fixture'

        $moduleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:RemediationModule))
        $repositoryBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repository))
        $childScript = @'
$modulePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__MODULE_PATH__'))
$expectedRepository = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REPOSITORY__'))
$module = Import-Module $modulePath -Force -PassThru
$originalEncoding = [Console]::OutputEncoding
try {
    $nonUtf8Encoding = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [Text.Encoding]::GetEncoding('windows-1252') } else { [Text.Encoding]::GetEncoding('ISO-8859-1') }
    [Console]::OutputEncoding = $nonUtf8Encoding
    $expectedEncodingCodePage = [Console]::OutputEncoding.CodePage
    $actualRepository = ((& $module { param($repository) Invoke-RemediationGit -Repository $repository -GitExecutable 'git' -Arguments @('rev-parse','--show-toplevel') } $expectedRepository) | Select-Object -First 1).Trim()
    $expectedNormalized = [IO.Path]::GetFullPath($expectedRepository)
    $actualNormalized = [IO.Path]::GetFullPath($actualRepository)
    if (-not [string]::Equals($actualNormalized,$expectedNormalized,[StringComparison]::Ordinal)) { throw "Remediation Git returned '$actualRepository' instead of '$expectedRepository'." }
    if ([Console]::OutputEncoding.CodePage -ne $expectedEncodingCodePage) { throw 'Invoke-RemediationGit did not restore Console.OutputEncoding.' }
}
finally {
    [Console]::OutputEncoding = $originalEncoding
}
'@.Replace('__MODULE_PATH__',$moduleBase64).Replace('__REPOSITORY__',$repositoryBase64)
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>&1

        $LASTEXITCODE | Should Be 0
        @($output) | Should BeNullOrEmpty
    }

    # Given: Shared-Skill migration observes a repository root containing non-ASCII characters under a legacy console encoding.
    # When: Its Git helper asks Git for the repository top-level path.
    # Then: The returned path is exact and the child process retains its prior console encoding.
    It 'InterT08_decodes_non_ascii_repository_paths_for_shared_skill_migration_and_restores_console_output_encoding' {
        $repository = Join-Path $TestDrive (([string][char]0x5DE5) + ([string][char]0x4F5C) + ([string][char]0x6A39) + '-' + ([string][char]0x00FC) + '-skill-migration')
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- product.txt
        & git -C $repository commit --quiet -m 'fixture'

        $modulePath = Join-Path $script:RepositoryRoot 'scripts\repo-shared-skills-migration.psm1'
        $moduleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($modulePath))
        $repositoryBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repository))
        $childScript = @'
$modulePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__MODULE_PATH__'))
$expectedRepository = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REPOSITORY__'))
$module = Import-Module $modulePath -Force -PassThru
$originalEncoding = [Console]::OutputEncoding
try {
    $nonUtf8Encoding = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [Text.Encoding]::GetEncoding('windows-1252') } else { [Text.Encoding]::GetEncoding('ISO-8859-1') }
    [Console]::OutputEncoding = $nonUtf8Encoding
    $expectedEncodingCodePage = [Console]::OutputEncoding.CodePage
    $actualRepository = ((& $module { param($repository) Invoke-RepoSkillGit -Repository $repository -GitExecutable 'git' -Arguments @('rev-parse','--show-toplevel') } $expectedRepository) | Select-Object -First 1).Trim()
    $expectedNormalized = [IO.Path]::GetFullPath($expectedRepository)
    $actualNormalized = [IO.Path]::GetFullPath($actualRepository)
    if (-not [string]::Equals($actualNormalized,$expectedNormalized,[StringComparison]::Ordinal)) { throw "Shared-Skill migration Git returned '$actualRepository' instead of '$expectedRepository'." }
    if ([Console]::OutputEncoding.CodePage -ne $expectedEncodingCodePage) { throw 'Invoke-RepoSkillGit did not restore Console.OutputEncoding.' }
}
finally {
    [Console]::OutputEncoding = $originalEncoding
}
'@.Replace('__MODULE_PATH__',$moduleBase64).Replace('__REPOSITORY__',$repositoryBase64)
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>&1

        $LASTEXITCODE | Should Be 0
        @($output) | Should BeNullOrEmpty
    }

    # Given: Remediation planning captures a tracked Agent file without publishing its candidate state.
    # When: An external editor later changes the file and an external Git process stages product work.
    # Then: The plan remains inert and no legacy rollback API exists that could overwrite either change.
    It 'InterT10_keeps_the_remediation_plan_inert_during_later_file_and_index_drift' {
        $repository = Join-Path $TestDrive 'concurrent-rollback'
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [System.IO.File]::WriteAllText((Join-Path $repository 'AGENTS.md'),"tracked Agent`n",(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product v1`n",(New-Object System.Text.UTF8Encoding($false)))
        & git -C $repository add -- AGENTS.md product.txt
        & git -C $repository commit --quiet -m 'fixture'

        $transaction = New-AgentArtifactRemediationPlan -Repository $repository
        try {
            [System.IO.File]::WriteAllText((Join-Path $repository 'AGENTS.md'),"external Agent bytes`n",(New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product v2`n",(New-Object System.Text.UTF8Encoding($false)))
            & git -C $repository add -- product.txt

            Assert-TestCondition -Condition ((Get-Content -Raw -LiteralPath (Join-Path $repository 'AGENTS.md')).Trim() -eq 'external Agent bytes') -Message 'External Agent bytes were not preserved.'
            $stagedPaths = @(& git -C $repository diff --cached --name-only)
            Assert-TestCondition -Condition (@($stagedPaths | Where-Object { $_ -eq 'product.txt' }).Count -eq 1) -Message 'The concurrently staged product file was not preserved.'
            Assert-TestCondition -Condition (@($stagedPaths | Where-Object { $_ -eq 'AGENTS.md' }).Count -eq 0) -Message 'Planning unexpectedly staged the Agent file.'
            Assert-TestCondition -Condition ($null -eq (Get-Command Restore-AgentArtifactRemediation -ErrorAction SilentlyContinue)) -Message 'The legacy remediation rollback API remains available.'
        }
        finally {
            if (Test-Path -LiteralPath $transaction.Backup.Root) { Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force }
        }
    }

    # Given: A repository has only an untracked customized implementation in the exact retired search-with-felo directory.
    # When: Remediation runs without any tracked reserved path.
    # Then: It preserves the unowned implementation and official Felo without mutation.
    It 'InterT20_preserves_unowned_customized_Skills_without_a_commit' {
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

        # When
        $transaction = New-AgentArtifactRemediationPlan -Repository $repository
        # Then
        Assert-TestCondition -Condition ($null -eq $transaction) -Message 'Unowned/customized Skills must not enter reserved remediation.'
        Assert-TestCondition -Condition (((@(& git -C $repository rev-parse HEAD) -join '').Trim()) -eq $headBefore) -Message 'Skill preservation changed HEAD.'
        Assert-TestCondition -Condition ((Get-Content -Raw -LiteralPath $retiredPath).Trim() -eq 'customized retired FELO') -Message 'Unowned Skill changed.'
        Assert-TestCondition -Condition ((Get-Content -Raw -LiteralPath $officialPath).Trim() -eq 'official FELO') -Message 'Official FELO changed.'
    }

    # Given: A manifest-like path starts at the filesystem root but otherwise resembles a reserved Agent path.
    # When: The reserved-path classifier validates it.
    # Then: It rejects the absolute path instead of silently converting it to a Repository-relative path.
    It 'InterT30_rejects_rooted_paths_before_reserved_path_classification' {
        Assert-TestCondition -Condition (-not (Test-IsReservedAgentArtifactPath -Path '/.agents/skills/example/SKILL.md')) -Message 'A rooted slash path was accepted.'
        Assert-TestCondition -Condition (-not (Test-IsReservedAgentArtifactPath -Path '\.codex\AGENTS.md')) -Message 'A rooted backslash path was accepted.'
    }

    # Given: Remediation planning prepares an index after-image while the live index still contains the Agent path.
    # When: Another Git process stages product work after the plan is created.
    # Then: Planning never replaces the live index, keeps the Agent file, and preserves the newly staged product work.
    It 'InterT40_preserves_index_drift_after_plan_creation' {
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

        $transaction = $null
        try {
            $transaction = New-AgentArtifactRemediationPlan -Repository $repository
            [System.IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product v2`n",(New-Object System.Text.UTF8Encoding($false)))
            & git -C $repository add -- product.txt
        }
        finally {
            if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Backup.Root)) { Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force }
        }

        Assert-TestCondition -Condition ($null -ne $transaction.IndexPlan) -Message 'The remediation index plan was not produced.'
        Assert-TestCondition -Condition ($transaction.IndexPlan.BeforeSha256 -ne $transaction.IndexPlan.AfterSha256) -Message 'The remediation index plan did not describe a change.'
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

        $headBefore = (@(& git -C $repository rev-parse HEAD) -join '').Trim()
        $transaction = New-AgentArtifactRemediationPlan -Repository $repository
        try {
            Assert-TestCondition -Condition (@(& git -C $repository diff-tree --no-commit-id --name-only -r $transaction.NewCommit | Where-Object { $_ -eq '.codex/AI-Rules/Testing.md' }).Count -eq 1) -Message 'The localized Codex rule was not included in the remediation candidate commit.'
            Assert-TestCondition -Condition (@(& git -C $repository ls-files -- '.codex/AI-Rules/Testing.md' '.codex/ai-instructions.manifest.json').Count -eq 2) -Message 'Planning changed the live index.'
            Assert-TestCondition -Condition (((@(& git -C $repository rev-parse HEAD) -join '').Trim()) -eq $headBefore) -Message 'Planning changed HEAD.'
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

        $transaction = New-AgentArtifactRemediationPlan -Repository $repository
        try {
            $null = & git -C $repository rev-parse --verify HEAD 2>$null
            Assert-TestCondition -Condition ($LASTEXITCODE -ne 0) -Message 'Remediation invented a commit on the unborn branch.'
            Assert-TestCondition -Condition (@(& git -C $repository diff --cached --name-only | Where-Object { $_ -eq 'product.txt' }).Count -eq 1) -Message 'Unborn-branch product index work was not preserved.'
            Assert-TestCondition -Condition (@(& git -C $repository diff --cached --name-only | Where-Object { $_ -eq 'AGENTS.md' }).Count -eq 1) -Message 'Planning changed the staged reserved Agent artifact.'
            Assert-TestCondition -Condition (Test-Path -LiteralPath (Join-Path $repository 'AGENTS.md')) -Message 'Planning removed the index-only Agent artifact from the worktree.'
            Assert-TestCondition -Condition ([string]::IsNullOrEmpty([string]$transaction.NewCommit)) -Message 'Index-only remediation created a commit without a parent.'
            Assert-TestCondition -Condition ($transaction.IndexPlan.BeforeSha256 -ne $transaction.IndexPlan.AfterSha256) -Message 'The unborn-branch index plan did not describe removal of the Agent entry.'
        }
        finally {
            if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Backup.Root)) {
                Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force
            }
        }
    }

    # Scenario: Remediation reads a valid multi-host v4 manifest containing Claude instructions and project Skill projections.
    # Purpose: Revalidate v4, reserve only Claude Rules/licenses, and keep CLAUDE.md plus every project Skill root outside remediation scope.
    It 'UnitT61_reads_v4_ownership_without_reserving_Claude_base_or_Skills' {
        $repository=Join-Path $TestDrive 'v4-remediation-reader'
        New-Item -ItemType Directory -Force -Path (Join-Path $repository '.codex')|Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/managed-manifest-v4.example.json') -Destination (Join-Path $repository '.codex/ai-instructions.manifest.json')
        $module=Get-Module agent-artifact-remediation
        $paths=& $module {
            param($repository)
            $comparer=[StringComparer]::Ordinal
            $tracked=[pscustomobject]@{
                Index=(New-Object 'System.Collections.Generic.HashSet[string]' $comparer)
                Head=(New-Object 'System.Collections.Generic.HashSet[string]' $comparer)
            }
            $set=Get-RemediationLegacyManifestPaths -Repository $repository -Comparer $comparer -TrackedSets $tracked -ProtectedPaths @()
            @($set)
        } $repository
        ($paths-contains'.claude/AI-Rules/CodeReview.en.md')|Should Be $true
        ($paths|Where-Object{$_-like'.claude/ai-instructions-licenses/*'}).Count|Should BeGreaterThan 0
        ($paths-contains'CLAUDE.md')|Should Be $false
        ($paths|Where-Object{$_-like'*/skills/*'}).Count|Should Be 0
    }

    # Scenario: Bootstrap has already imported the Catalog contract before it force-loads the remediation module in the same PowerShell process.
    # Purpose: Keep the caller's exported worktree parser available across the nested remediation import on Windows PowerShell 5.1 and PowerShell 7.
    It 'InterT62_keeps_the_callers_catalog_commands_loaded_after_remediation_import' {
        $catalogModule=Join-Path $script:RepositoryRoot 'scripts\skills-catalog-contract.psm1'
        $remediationModule=Join-Path $script:RepositoryRoot 'scripts\agent-artifact-remediation.psm1'
        $catalogLiteral=$catalogModule.Replace("'","''")
        $remediationLiteral=$remediationModule.Replace("'","''")
        $probe=@"
`$ErrorActionPreference='Stop'
Import-Module '$catalogLiteral' -Force -ErrorAction Stop
if(-not(Get-Command ConvertFrom-GitWorktreePorcelainZ -ErrorAction SilentlyContinue)){exit 61}
Import-Module '$remediationLiteral' -Force -ErrorAction Stop
if(-not(Get-Command ConvertFrom-GitWorktreePorcelainZ -ErrorAction SilentlyContinue)){exit 62}
"@
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $engine=(Get-Process -Id $PID).Path
        $output=& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        $LASTEXITCODE|Should Be 0
        ($output-join[Environment]::NewLine)|Should Not Match 'CommandNotFoundException'
    }

    # Scenario: Claude-family paths arrive with mixed separators, trailing slashes, and Windows casing at the shared guard.
    # Purpose: Keep one normalized protection decision for every remediation, bootstrap, and cleanup sink.
    It 'UnitT63_normalizes_the_single_Claude_family_protection_guard' {
        (Test-IsProtectedClaudeFamilyPath -Path 'CLAUDE.md' -ProtectedPaths @('CLAUDE.md/')) | Should Be $true
        (Test-IsProtectedClaudeFamilyPath -Path '.claude\AI-Rules\Testing.en.md' -ProtectedPaths @('.claude/AI-Rules/')) | Should Be $true
        (Test-IsProtectedClaudeFamilyPath -Path '.claude/ai-instructions-licenses/a/delivery.json' -ProtectedPaths @('.claude\ai-instructions-licenses\')) | Should Be $true
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            (Test-IsProtectedClaudeFamilyPath -Path '.CLAUDE/ai-rules/Testing.en.md' -ProtectedPaths @('.claude/AI-Rules')) | Should Be $true
        }
        (Test-IsProtectedClaudeFamilyPath -Path '.claude/skills/example/SKILL.md' -ProtectedPaths @('CLAUDE.md','.claude/AI-Rules','.claude/ai-instructions-licenses')) | Should Be $false
    }

    # Scenario: Every remediation planning sink that consumes path inventory is reviewed as one table row.
    # Purpose: Prevent candidate bytes from including a protected Claude-family path before the unified executor receives the plan.
    It 'UnitT64_classifies_<Function>_for_the_single_Claude_family_guard' -TestCases @(
        @{File='scripts/agent-artifact-remediation.psm1';Function='Get-RemediationLegacyManifestPaths';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/agent-artifact-remediation.psm1';Function='New-AgentArtifactRemediationBackup';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/agent-artifact-remediation.psm1';Function='New-RemediationIndexPlan';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/agent-artifact-remediation.psm1';Function='New-RemediationCommitObject';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/agent-artifact-remediation.psm1';Function='New-AgentArtifactRemediationPlan';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Set-ManagedGitInfoExclude';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Restore-GitInfoExcludeSnapshot';Applicability='not applicable';Reason='rollback only restores pre-mutation snapshot'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='New-TargetMutationSnapshot';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Invoke-AtomicFilePublication';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Remove-TargetMutationFileAtomically';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Set-TargetMutationFileBytes';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Remove-TargetMutationFile';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Restore-TargetMutationSnapshot';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Update-PersonalAgentStash';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Save-SkillMigrationJournal';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/bootstrap-ai-instructions.ps1';Function='Restore-SkillMigrationJournal';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/cleanup-ai-instructions-pollution.ps1';Function='Remove-CleanupIndexEntriesAtomically';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/cleanup-ai-instructions-pollution.ps1';Function='Restore-CleanupIndexSnapshot';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/cleanup-ai-instructions-pollution.ps1';Function='Set-CleanupExcludeBlock';Applicability='applies';Reason='forward mutation sink'},
        @{File='scripts/cleanup-ai-instructions-pollution.ps1';Function='Restore-CleanupExcludeMutation';Applicability='not applicable';Reason='rollback only restores pre-mutation snapshot'}
    ) {
        param($File,$Function,$Applicability,$Reason)
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot $File),[ref]$tokens,[ref]$parseErrors)
        @($parseErrors).Count|Should Be 0
        $definition=@($ast.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$Function},$true))
        $definition.Count|Should Be 1
        if($Applicability-ceq'applies'){
            $Reason|Should Be 'forward mutation sink'
            $definition[0].Extent.Text|Should Match 'Test-IsProtectedClaudeFamilyPath'
        }else{
            $Applicability|Should Be 'not applicable'
            $Reason|Should Be 'rollback only restores pre-mutation snapshot'
            $definition[0].Extent.Text|Should Not Match 'Test-IsProtectedClaudeFamilyPath'
        }
    }

    # Scenario: The shared guard receives either a deliberately computed empty protection set or a missing null set.
    # Purpose: Permit ordinary repositories with no project-owned Claude family while refusing to treat an uncomputed set as unprotected.
    It 'UnitT65_accepts_empty_but_rejects_null_Claude_family_protection' {
        (Test-IsProtectedClaudeFamilyPath -Path 'CLAUDE.md' -ProtectedPaths @()) | Should Be $false
        { Test-IsProtectedClaudeFamilyPath -Path 'CLAUDE.md' -ProtectedPaths $null } | Should Throw
    }

    # Scenario: Each Claude base, Rule, and license path is tracked or untracked under v2, v3, and v4 manifest ownership while the manifest itself is tracked.
    # Purpose: Preserve protected bytes and index state, omit the path from remediation commits, and emit a reason at the complete remediation sink chain.
    It 'InterT65_preserves_<PathKind>_<Tracking>_under_v<SchemaVersion>_across_remediation_sinks' -TestCases @(
        foreach($schemaVersion in 2,3,4){foreach($tracking in 'tracked','untracked'){foreach($pathCase in @(
            @{PathKind='base';Path='CLAUDE.md'},
            @{PathKind='rule';Path='.claude/AI-Rules/CodeReview.en.md'},
            @{PathKind='license';Path='.claude/ai-instructions-licenses/0123456789abcdef0123456789abcdef01234567/delivery.json'}
        )){@{SchemaVersion=$schemaVersion;Tracking=$tracking;PathKind=$pathCase.PathKind;ProtectedPath=$pathCase.Path}}}}
    ) {
        param($SchemaVersion,$Tracking,$PathKind,$ProtectedPath)
        $repository=Join-Path $TestDrive ("protected-v$SchemaVersion-$Tracking-$PathKind")
        New-Item -ItemType Directory -Force -Path (Join-Path $repository '.codex')|Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product`n",[Text.UTF8Encoding]::new($false))
        & git -C $repository add -- product.txt
        & git -C $repository commit --quiet -m fixture
        $fullPath=Join-Path $repository $ProtectedPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullPath)|Out-Null
        [IO.File]::WriteAllText($fullPath,"protected $SchemaVersion $Tracking $PathKind`n",[Text.UTF8Encoding]::new($false))
        $manifestPath=Join-Path $repository '.codex/ai-instructions.manifest.json'
        if($SchemaVersion-eq4){
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/managed-manifest-v4.example.json') -Destination $manifestPath -Force
        }else{
            $manifest=[ordered]@{schemaVersion=$SchemaVersion;files=@([ordered]@{targetPath=$ProtectedPath})}
            [IO.File]::WriteAllText($manifestPath,(($manifest|ConvertTo-Json -Depth 5)+"`n"),[Text.UTF8Encoding]::new($false))
        }
        & git -C $repository add -- '.codex/ai-instructions.manifest.json'
        if($Tracking-ceq'tracked'){& git -C $repository add -f -- $ProtectedPath}
        & git -C $repository commit --quiet -m 'tracked manifest fixture'
        if($Tracking-ceq'untracked'){
            [IO.File]::WriteAllText($fullPath,"protected $SchemaVersion $Tracking $PathKind`n",[Text.UTF8Encoding]::new($false))
        }
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($fullPath))
        $diagnostics=@(New-AgentArtifactRemediationPlan -Repository $repository -ProtectedPathPrefixes @('CLAUDE.md/','.claude\AI-Rules\','.claude/ai-instructions-licenses/') 3>&1)
        $transaction=@($diagnostics|Where-Object{$null-ne$_.PSObject.Properties['Backup']}|Select-Object -First 1)[0]
        try{
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($fullPath))|Should Be $before
            (@(& git -C $repository diff --cached --name-only -- $ProtectedPath)-join'')|Should BeNullOrEmpty
            if($null-ne$transaction-and-not[string]::IsNullOrWhiteSpace([string]$transaction.NewCommit)){
                (@(& git -C $repository show --pretty=format: --name-only $transaction.NewCommit -- $ProtectedPath)-join'')|Should BeNullOrEmpty
            }
            ($diagnostics-join[Environment]::NewLine)|Should Match ([regex]::Escape($ProtectedPath))
            ($diagnostics-join[Environment]::NewLine)|Should Match 'project-owned Claude family'
        }finally{
            if($null-ne$transaction-and(Test-Path -LiteralPath $transaction.Backup.Root)){Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force}
        }
    }

    # Scenario: A tracked manifest names an unknown tracked production path under each supported ownership generation.
    # Purpose: Keep the protected-family exception narrow; paths outside both the protected set and reserved scope must still fail closed.
    It 'InterT66_rejects_an_unknown_non_reserved_path_under_v<SchemaVersion>' -TestCases @(
        @{SchemaVersion=2},@{SchemaVersion=3},@{SchemaVersion=4}
    ) {
        param($SchemaVersion)
        $repository=Join-Path $TestDrive ("unknown-v$SchemaVersion")
        New-Item -ItemType Directory -Force -Path (Join-Path $repository '.codex')|Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [IO.File]::WriteAllText((Join-Path $repository 'production.txt'),"production`n",[Text.UTF8Encoding]::new($false))
        $manifestPath=Join-Path $repository '.codex/ai-instructions.manifest.json'
        $manifest=if($SchemaVersion-eq4){
            $candidate=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'catalog/examples/managed-manifest-v4.example.json')|ConvertFrom-Json
            $candidate.files[0].targetPath='production.txt'
            $candidate
        }else{[ordered]@{schemaVersion=$SchemaVersion;files=@([ordered]@{targetPath='production.txt'})}}
        [IO.File]::WriteAllText($manifestPath,(($manifest|ConvertTo-Json -Depth 5)+"`n"),[Text.UTF8Encoding]::new($false))
        & git -C $repository add -- production.txt '.codex/ai-instructions.manifest.json'
        & git -C $repository commit --quiet -m fixture
        $failure=$null
        try{New-AgentArtifactRemediationPlan -Repository $repository -ProtectedPathPrefixes @('CLAUDE.md','.claude/AI-Rules','.claude/ai-instructions-licenses')|Out-Null}catch{$failure=$_.Exception.Message}
        [string]::IsNullOrWhiteSpace($failure)|Should Be $false
        if($SchemaVersion-in2,3){$failure|Should Match 'outside the reserved Agent artifact scope.*production\.txt'}
        (Get-Content -Raw -LiteralPath (Join-Path $repository 'production.txt')).Trim()|Should Be 'production'
    }

    # Scenario: The active worktree permits Claude Rule remediation while a linked worktree makes the Claude family repository-wide protected for shared exclusions.
    # Purpose: Remove the active tracked Rule without adding a shared exclude line that would hide a linked worktree's project-owned Claude file.
    It 'InterT67_separates_active_remediation_from_repository-wide_shared_exclude_protection' {
        $repository=Join-Path $TestDrive 'separate-remediation-exclude-scopes'
        $rulePath='.claude/AI-Rules/Testing.en.md'
        New-Item -ItemType Directory -Force -Path (Join-Path $repository '.claude/AI-Rules')|Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Remediation Test'
        & git -C $repository config user.email 'remediation@example.test'
        [IO.File]::WriteAllText((Join-Path $repository 'product.txt'),"product`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repository $rulePath),"managed Claude Rule`n",[Text.UTF8Encoding]::new($false))
        & git -C $repository add -- product.txt $rulePath
        & git -C $repository commit --quiet -m fixture
        $excludePath=(& git -C $repository rev-parse --git-path info/exclude|Select-Object -First 1).Trim()
        if(-not[IO.Path]::IsPathRooted($excludePath)){$excludePath=Join-Path $repository $excludePath}
        [IO.File]::AppendAllText($excludePath,"`n# BEGIN Codex AI Instructions remediated paths`n/$rulePath`n# END Codex AI Instructions remediated paths`n",[Text.UTF8Encoding]::new($false))

        $excludeBefore=[IO.File]::ReadAllBytes($excludePath)
        $headBefore=(@(& git -C $repository rev-parse HEAD)-join'').Trim()
        $transaction=New-AgentArtifactRemediationPlan -Repository $repository `
            -ProtectedPathPrefixes @('CLAUDE.md') `
            -SharedExcludeProtectedPathPrefixes @('CLAUDE.md','.claude/AI-Rules/','.claude/ai-instructions-licenses/')
        try {
            @($transaction.Paths)|Should Contain $rulePath
            Test-Path -LiteralPath (Join-Path $repository $rulePath)|Should Be $true
            (@(& git -C $repository ls-files -- $rulePath)-join'')|Should Be $rulePath
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))|Should Be ([Convert]::ToBase64String($excludeBefore))
            ((@(& git -C $repository rev-parse HEAD)-join'').Trim())|Should Be $headBefore
            $transaction.IndexPlan.BeforeSha256|Should Not Be $transaction.IndexPlan.AfterSha256
        }
        finally {
            if(Test-Path -LiteralPath $transaction.Backup.Root){Remove-Item -LiteralPath $transaction.Backup.Root -Recurse -Force}
        }
    }
}
