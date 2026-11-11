$script:WindowsCoreRepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $script:WindowsCoreRepositoryRoot 'scripts/Get-WindowsCorePlan.ps1') -DefineFunctionsOnly
. (Join-Path $script:WindowsCoreRepositoryRoot 'scripts/Assert-WindowsCoreAggregate.ps1') -DefineFunctionsOnly
$runnerTokens = $null
$runnerParseErrors = $null
$runnerAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $script:WindowsCoreRepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'),
    [ref]$runnerTokens,
    [ref]$runnerParseErrors)
if (@($runnerParseErrors).Count -ne 0) { throw 'Invoke-PesterShardProcess.ps1 must parse before its shard planner can be tested.' }
$runnerShardPlanFunctions = @($runnerAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-PesterShardPlan'
}, $true))
if ($runnerShardPlanFunctions.Count -ne 1) { throw 'Invoke-PesterShardProcess.ps1 must define New-PesterShardPlan exactly once.' }
. ([scriptblock]::Create($runnerShardPlanFunctions[0].Extent.Text))

function Set-WindowsCoreTestText {
    param([string] $Path,[string] $Value)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function New-WindowsCoreFullPlanFixture {
    param([string] $Root)
    [IO.Directory]::CreateDirectory((Join-Path $Root 'scripts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $Root 'tests')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $Root 'docs/standards')) | Out-Null
    $authority = @(
        'internal-source-continuation.Tests.ps1',
        'skill-repository-standard.Tests.ps1',
        'skill-repository-workflows.Tests.ps1',
        'standard-authority-entry-preflight.Tests.ps1',
        'standard-entry-point-binding.Tests.ps1',
        'standard-core-pester-adapter.Tests.ps1'
    )
    $authorityBody = @'
function Get-AuthorityTestPaths {
    param([string] $Root)
    @(
        'internal-source-continuation.Tests.ps1',
        'skill-repository-standard.Tests.ps1',
        'skill-repository-workflows.Tests.ps1',
        'standard-authority-entry-preflight.Tests.ps1',
        'standard-entry-point-binding.Tests.ps1',
        'standard-core-pester-adapter.Tests.ps1'
    ) | ForEach-Object { Join-Path $Root "tests/$_" }
}
'@
    Set-WindowsCoreTestText (Join-Path $Root 'scripts/Invoke-StandardAuthorityGate.ps1') $authorityBody
    foreach ($name in $authority) { Set-WindowsCoreTestText (Join-Path $Root "tests/$name") "Describe '$name' {}`n" }
    $skipInventory = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:WindowsCoreRepositoryRoot 'docs/standards/core-test-skip-inventory.json') | ConvertFrom-Json
    $skipNames = [string[]]@($skipInventory.platforms.windows.expectedSkippedTests | ForEach-Object { ($_ -split '::', 2)[0] } | Select-Object -Unique)
    $expected = [string[]]@('alpha.Tests.ps1','beta.Tests.ps1','child.Tests.ps1') + $skipNames
    foreach ($name in @($expected | Where-Object { $_ -cne 'child.Tests.ps1' })) {
        Set-WindowsCoreTestText (Join-Path $Root "tests/$name") "Describe '$name' {}`n"
    }
    Set-WindowsCoreTestText (Join-Path $Root 'tests/nested/child.Tests.ps1') "Describe 'child.Tests.ps1' {}`n"
    Set-WindowsCoreTestText (Join-Path $Root 'docs/standards/core-test-skip-inventory.json') ($skipInventory | ConvertTo-Json -Depth 8)
    $weights = [ordered]@{ schemaVersion = 1; partitionCount = 8; weights = [ordered]@{ 'alpha.Tests.ps1' = 9; 'beta.Tests.ps1' = 4 } }
    Set-WindowsCoreTestText (Join-Path $Root 'tests/windows-core-shard-weights.json') ($weights | ConvertTo-Json -Depth 6)
    return [string[]]@($expected | Sort-Object -CaseSensitive)
}

function New-WindowsCoreAggregateArtifacts {
    param($Plan,[string] $Root)
    $planRoot = Join-Path $Root 'plan'
    [IO.Directory]::CreateDirectory($planRoot) | Out-Null
    Set-WindowsCoreTestText (Join-Path $planRoot 'plan.json') ($Plan.CanonicalJson + "`n")
    Set-WindowsCoreTestText (Join-Path $planRoot 'plan.sha256') ($Plan.PlanSha256 + "`n")
    foreach ($shard in $Plan.Plan.shards) {
        $artifactRoot = Join-Path $Root "shards/windows-core-shard-$($shard.id)-run"
        [IO.Directory]::CreateDirectory($artifactRoot) | Out-Null
        $skipCount = @($shard.expectedSkippedTests).Count
        $passedCount = [Math]::Max(1, @($shard.files).Count)
        $summary = [pscustomobject][ordered]@{
            schemaVersion = 2
            type = 'standard-pester-execution-summary'
            executed = $true
            status = 'completed'
            runtime = [pscustomobject][ordered]@{ osPlatform = 'Win32NT'; psEdition = 'Core'; psVersion = '7.6.6' }
            pesterVersion = '4.10.1'
            pesterModuleSha256 = ('a' * 64)
            executorSha256 = ('b' * 64)
            testFiles = [object[]]@($shard.files | ForEach-Object { Join-Path $script:WindowsCoreRepositoryRoot "tests/$_" })
            counts = [pscustomobject][ordered]@{
                TotalCount = $passedCount + $skipCount
                PassedCount = $passedCount
                FailedCount = 0
                SkippedCount = $skipCount
                PendingCount = 0
                InconclusiveCount = 0
            }
            shards = [object[]]@($shard.files | ForEach-Object {
                [pscustomobject][ordered]@{
                    name = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension([string]$_))
                    paths = [object[]]@((Join-Path $script:WindowsCoreRepositoryRoot "tests/$_"))
                    processEvidencePath = Join-Path $artifactRoot "$_.process.json"
                    resultPath = Join-Path $artifactRoot "$_.result.json"
                    exitCode = 0
                    status = 'completed'
                    cleanedUp = $true
                    outputQuotaExceeded = $false
                }
            })
            runId = 'run-42'
            runAttempt = 1
            skippedTests = [object[]]@($shard.expectedSkippedTests)
        }
        Set-WindowsCoreTestText (Join-Path $artifactRoot "windows-core-shard-$($shard.id)-summary.json") ($summary | ConvertTo-Json -Depth 12)
    }
}

function Invoke-WindowsCoreAggregateForTest {
    param($Plan,[string] $Artifacts,[hashtable] $Overrides = @{})
    $arguments = @{
        Root = $script:WindowsCoreRepositoryRoot
        Artifacts = $Artifacts
        ShardWeightsPath = (Join-Path $script:WindowsCoreRepositoryRoot 'tests/windows-core-shard-weights.json')
        PlanSha256 = $Plan.PlanSha256
        MatrixJson = $Plan.MatrixJson
        PlanJobResult = 'success'
        AuthorityJobResult = 'success'
        PesterJobResult = 'success'
        FixturesJobResult = 'success'
        CurrentRunId = 'run-42'
        CurrentRunAttempt = 1
    }
    foreach ($key in $Overrides.Keys) { $arguments[$key] = $Overrides[$key] }
    Assert-WindowsCoreAggregate @arguments
}

Describe 'Windows Core full planner and aggregate' {
    BeforeAll {
        $script:ActualPlan = Get-WindowsCorePlan -Root $script:WindowsCoreRepositoryRoot -ShardWeightsPath (Join-Path $script:WindowsCoreRepositoryRoot 'tests/windows-core-shard-weights.json') -WorkflowRunId 'run-42' -WorkflowRunAttempt 1
    }

    # Scenario: The real repository is independently explored without invoking planner discovery helpers.
    # Purpose: Prove the full plan selects every retained source test and excludes only the six authority paths.
    It 'UnitT10_selects_the_exact_real_non_authority_test_inventory' {
        $authority = @(
            'tests/internal-source-continuation.Tests.ps1',
            'tests/skill-repository-standard.Tests.ps1',
            'tests/skill-repository-workflows.Tests.ps1',
            'tests/standard-authority-entry-preflight.Tests.ps1',
            'tests/standard-entry-point-binding.Tests.ps1',
            'tests/standard-core-pester-adapter.Tests.ps1'
        )
        $expected = [string[]]@(
            Get-ChildItem -LiteralPath (Join-Path $script:WindowsCoreRepositoryRoot 'tests') -Filter '*.Tests.ps1' -File -Recurse |
                Where-Object { $authority -cnotcontains [IO.Path]::GetRelativePath($script:WindowsCoreRepositoryRoot, $_.FullName).Replace('\','/') } |
                ForEach-Object Name |
                Sort-Object -CaseSensitive
        )
        ($script:ActualPlan.Plan.selectedTestFiles -join "`n") | Should Be ($expected -join "`n")
        $script:ActualPlan.Plan.expectedSkippedTests.Count | Should Be 5
    }

    # Scenario: A minimal fixture contains six authority tests and an explicit retained source-test set.
    # Purpose: Protect full recursive selection independently of the production repository inventory.
    It 'UnitT20_selects_the_complete_fixture_inventory' {
        $root = Join-Path $TestDrive 'full-fixture'
        $expected = New-WindowsCoreFullPlanFixture $root
        $plan = Get-WindowsCorePlan -Root $root -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json')
        ($plan.Plan.selectedTestFiles -join "`n") | Should Be ($expected -join "`n")
        @($plan.Plan.selectedTestFiles | Where-Object { $_ -ceq 'child.Tests.ps1' }).Count | Should Be 1
        @($plan.Plan.shards.files | Where-Object { $_ -ceq 'child.Tests.ps1' }).Count | Should Be 1
    }

    # Scenario: Two recursively discovered tests use the same leaf name in different directories.
    # Purpose: Fail closed because the bounded executor selects by leaf name rather than relative path.
    It 'UnitT25_rejects_duplicate_test_leaf_names_with_conflicting_paths' {
        $root = Join-Path $TestDrive 'duplicate-leaf-fixture'
        New-WindowsCoreFullPlanFixture $root | Out-Null
        Set-WindowsCoreTestText (Join-Path $root 'tests/unit/common.Tests.ps1') "Describe 'unit common' {}`n"
        Set-WindowsCoreTestText (Join-Path $root 'tests/integration/common.Tests.ps1') "Describe 'integration common' {}`n"

        $message = $null
        try { Get-WindowsCorePlan -Root $root -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') | Out-Null }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'tests/unit/common\.Tests\.ps1'
        $message | Should Match 'tests/integration/common\.Tests\.ps1'
        $message | Should Match 'leaf name.*case-insensitive.*unique'
    }

    # Scenario: Two recursively discovered tests differ only by leaf-name casing.
    # Purpose: Match the executor's OrdinalIgnoreCase leaf-name selection boundary.
    It 'UnitT27_rejects_case_only_test_leaf_name_collisions' {
        $root = Join-Path $TestDrive 'case-leaf-fixture'
        New-WindowsCoreFullPlanFixture $root | Out-Null
        Set-WindowsCoreTestText (Join-Path $root 'tests/a/Foo.Tests.ps1') "Describe 'upper foo' {}`n"
        Set-WindowsCoreTestText (Join-Path $root 'tests/b/foo.Tests.ps1') "Describe 'lower foo' {}`n"

        { Get-WindowsCorePlan -Root $root -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') } | Should Throw 'leaf name to be case-insensitive unique'
    }

    # Scenario: Each supported workflow event asks the same planner for a plan.
    # Purpose: Prevent pull requests or manual runs from regaining a reduced test path.
    It 'UnitT30_produces_the_same_full_plan_for_<Event>' -TestCases @(
        @{ Event = 'push' }, @{ Event = 'pull_request' }, @{ Event = 'workflow_dispatch' }
    ) {
        param($Event)
        $previous = $env:GITHUB_EVENT_NAME
        try {
            $env:GITHUB_EVENT_NAME = $Event
            $plan = Get-WindowsCorePlan -Root $script:WindowsCoreRepositoryRoot -ShardWeightsPath (Join-Path $script:WindowsCoreRepositoryRoot 'tests/windows-core-shard-weights.json') -WorkflowRunId 'run-42' -WorkflowRunAttempt 1
            $plan.CanonicalJson | Should Be $script:ActualPlan.CanonicalJson
            $plan.MatrixJson | Should Be $script:ActualPlan.MatrixJson
        } finally { $env:GITHUB_EVENT_NAME = $previous }
    }

    # Scenario: LPT receives more weighted files than partitions, including an unknown weight.
    # Purpose: Lock deterministic load-first then ordinal tie-breaking and skip placement.
    It 'UnitT40_assigns_a_deterministic_complete_LPT_plan' {
        $weightsPath = Join-Path $TestDrive 'weights.json'
        $weights = [ordered]@{ schemaVersion=1; partitionCount=8; weights=[ordered]@{} }
        foreach ($item in @(@('a.Tests.ps1',9),@('b.Tests.ps1',8),@('c.Tests.ps1',7),@('d.Tests.ps1',6),@('e.Tests.ps1',5),@('f.Tests.ps1',4),@('g.Tests.ps1',3),@('h.Tests.ps1',2))) { $weights.weights[$item[0]]=$item[1] }
        Set-WindowsCoreTestText $weightsPath ($weights | ConvertTo-Json -Depth 6)
        $files = @('a.Tests.ps1','b.Tests.ps1','c.Tests.ps1','d.Tests.ps1','e.Tests.ps1','f.Tests.ps1','g.Tests.ps1','h.Tests.ps1','unknown.Tests.ps1')
        $skips = @('a.Tests.ps1::UnitT05_reviewed_skip','unknown.Tests.ps1::UnitT10_reviewed_skip')
        $first = @(New-WindowsCoreShards -SelectedTestFiles $files -ExpectedSkippedTests $skips -ConfigurationPath $weightsPath)
        $second = @(New-WindowsCoreShards -SelectedTestFiles $files -ExpectedSkippedTests $skips -ConfigurationPath $weightsPath)
        (($first | ConvertTo-Json -Depth 8 -Compress)) | Should Be (($second | ConvertTo-Json -Depth 8 -Compress))
        $expectedShards = @(
            [pscustomobject]@{ id='01'; files=@('a.Tests.ps1') },
            [pscustomobject]@{ id='02'; files=@('b.Tests.ps1') },
            [pscustomobject]@{ id='03'; files=@('c.Tests.ps1') },
            [pscustomobject]@{ id='04'; files=@('d.Tests.ps1') },
            [pscustomobject]@{ id='05'; files=@('e.Tests.ps1') },
            [pscustomobject]@{ id='06'; files=@('f.Tests.ps1') },
            [pscustomobject]@{ id='07'; files=@('g.Tests.ps1') },
            [pscustomobject]@{ id='08'; files=@('h.Tests.ps1','unknown.Tests.ps1') }
        )
        $first.Count | Should Be 8
        for ($index = 0; $index -lt $expectedShards.Count; $index++) {
            $first[$index].id | Should Be $expectedShards[$index].id
            (@($first[$index].files) -join ',') | Should Be (@($expectedShards[$index].files) -join ',')
        }
        $assignedFiles = [string[]]@($first | ForEach-Object { $_.files })
        @($assignedFiles | Select-Object -Unique).Count | Should Be $files.Count
        (@($assignedFiles | Sort-Object -CaseSensitive) -join ',') | Should Be (@($files | Sort-Object -CaseSensitive) -join ',')
        foreach ($skip in $skips) {
            $skipFile = ($skip -split '::', 2)[0]
            $owner = @($first | Where-Object { @($_.expectedSkippedTests) -ccontains $skip })
            $owner.Count | Should Be 1
            @($owner[0].files) -ccontains $skipFile | Should Be $true
        }
    }

    # Scenario: A workflow shard selects one tiny fixture test and explicitly disables the runner's repository-wide isolated defaults.
    # Purpose: Reproduce the found-zero defect and prove the workflow argument set accepts a shard that contains no default isolated file.
    It 'UnitT45_accepts_an_empty_isolated_list_for_a_selected_fixture_shard' {
        $fixtureRoot = Join-Path $TestDrive 'runner-selected-fixture'
        $fixtureTests = Join-Path $fixtureRoot 'tests'
        foreach ($name in @('alpha.Tests.ps1','beta.Tests.ps1','gamma.Tests.ps1')) {
            Set-WindowsCoreTestText (Join-Path $fixtureTests $name) "Describe '$name' { It 'UnitT10_passes' { `$true | Should Be `$true } }`n"
        }
        $selectedPath = (Resolve-Path -LiteralPath (Join-Path $fixtureTests 'beta.Tests.ps1')).Path

        $workflowPlan = @(New-PesterShardPlan `
            -AllTestPaths @($selectedPath) `
            -IsolatedTestFileNames ([string[]]@()) `
            -BulkShardSize 1)
        $workflowPlan.Count | Should Be 1
        @($workflowPlan[0].Paths).Count | Should Be 1
        [IO.Path]::GetFileName([string]$workflowPlan[0].Paths[0]) | Should Be 'beta.Tests.ps1'

        $runnerDefaults = [string[]]@('standard-validation-runner.Tests.ps1','syp101-production-smoke-contract.Tests.ps1')
        { New-PesterShardPlan -AllTestPaths @($selectedPath) -IsolatedTestFileNames $runnerDefaults -BulkShardSize 1 } | Should Throw 'found 0'
    }

    # Scenario: The production planner emits eight selected-file shards and each is handed to the real runner shard planner with workflow arguments.
    # Purpose: Prove every current repository shard remains an exact one-file-per-process plan when isolated defaults are explicitly empty.
    It 'UnitT47_accepts_every_actual_repository_shard_with_workflow_runner_arguments' {
        @($script:ActualPlan.Plan.shards).Count | Should Be 8
        $actualTestPaths = @(Get-ChildItem -LiteralPath (Join-Path $script:WindowsCoreRepositoryRoot 'tests') -Filter '*.Tests.ps1' -File -Recurse)
        foreach ($workflowShard in @($script:ActualPlan.Plan.shards)) {
            $selectedPaths = [string[]]@(
                foreach ($name in @($workflowShard.files)) {
                    $matches = @($actualTestPaths | Where-Object Name -ceq ([string]$name))
                    $matches.Count | Should Be 1
                    $matches[0].FullName
                }
            )
            $runnerPlan = @(New-PesterShardPlan `
                -AllTestPaths $selectedPaths `
                -IsolatedTestFileNames ([string[]]@()) `
                -BulkShardSize 1)
            $runnerPlan.Count | Should Be @($workflowShard.files).Count
            (@($runnerPlan.Paths | ForEach-Object { [IO.Path]::GetFileName([string]$_) } | Sort-Object -CaseSensitive) -join "`n") |
                Should Be (@($workflowShard.files | Sort-Object -CaseSensitive) -join "`n")
        }
    }

    # Scenario: A legal shard object is duplicated in a matrix before expansion.
    # Purpose: Reject duplicated ids and shard counts before a matrix can fan out.
    It 'UnitT50_rejects_a_duplicate_legal_matrix_shard' {
        $matrix = $script:ActualPlan.MatrixJson | ConvertFrom-Json
        $matrix.include = [object[]]@($matrix.include) + @($matrix.include[0])
        $duplicate = ConvertTo-Json -InputObject $matrix -Depth 8 -Compress
        { Assert-WindowsCoreMatrix -MatrixJson $duplicate -ExpectedShards $script:ActualPlan.Plan.shards } | Should Throw
    }

    # Scenario: Existing callers bind every legacy argument position through IsolationRequirement.
    # Purpose: Keep new schema/run parameters append-only for positional compatibility.
    It 'UnitT60_preserves_legacy_positional_parameter_metadata' {
        $expected = @('PesterModulePath','PesterVersion','ExpectedTotalCount','ExpectedSkippedCount','ExpectedSkippedTests','IsolatedTestFileNames','BulkShardSize','OuterTimeoutSeconds','ShardPartitionCount','ShardPartitionIndex','ExpectedFullShardCount','CancellationPath','TestRoot','EvidenceRoot','SelectedTestFileNames','SummaryOutputPath','CancellationToken','IsolationRequirement')
        $parameters = @(Get-Command (Join-Path $script:WindowsCoreRepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1')).ParameterSets[0].Parameters
        foreach ($index in 0..($expected.Count - 1)) {
            $parameter = @($parameters | Where-Object Name -ceq $expected[$index])
            $parameter.Count | Should Be 1
            $parameter[0].Position | Should Be $index
        }
        (@($parameters | Where-Object Name -ceq 'SummarySchemaVersion'))[0].Position | Should Be $expected.Count
    }

    # Scenario: All full-plan artifacts and typed summaries are complete.
    # Purpose: Exercise the successful fail-closed aggregate path.
    It 'UnitT70_accepts_a_complete_full_plan' {
        $artifacts = Join-Path $TestDrive 'success'
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        $result = Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts
        $result.status | Should Be 'passed'
        $result.skippedTestCount | Should Be 5
    }

    # Scenario: A retry aggregates attempt-one plan and shard artifacts during attempt two.
    # Purpose: Preserve re-run-failed-jobs behavior while binding one workflow run id.
    It 'UnitT80_accepts_older_artifacts_from_the_same_run' {
        $artifacts = Join-Path $TestDrive 'retry'
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        (Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts @{ CurrentRunAttempt = 2 }).status | Should Be 'passed'
    }

    # Scenario: Any required upstream result is skipped, cancelled, or failed.
    # Purpose: Ensure the always-running required aggregate accepts success only.
    It 'UnitT90_rejects_<Job>_<Result>' -TestCases @(
        foreach ($job in @('PlanJobResult','AuthorityJobResult','PesterJobResult','FixturesJobResult')) {
            foreach ($result in @('skipped','cancelled','failure')) { @{ Job=$job; Result=$result } }
        }
    ) {
        param($Job,$Result)
        $artifacts = Join-Path $TestDrive "needs-$Job-$Result"
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        { Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts @{ $Job = $Result } } | Should Throw
    }

    # Scenario: Typed shard summary values are replaced with coercible strings or negative counts.
    # Purpose: Reject PowerShell truthiness and numeric coercion at the aggregate boundary.
    It 'UnitT100_rejects_invalid_summary_<Mutation>' -TestCases @(
        @{ Mutation='executed-string' }, @{ Mutation='negative-count' }, @{ Mutation='string-count' }, @{ Mutation='missing-field' }
    ) {
        param($Mutation)
        $artifacts = Join-Path $TestDrive "summary-$Mutation"
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        $path = (Get-ChildItem -LiteralPath (Join-Path $artifacts 'shards') -Filter 'windows-core-shard-*-summary.json' -File -Recurse | Select-Object -First 1).FullName
        $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        switch ($Mutation) {
            'executed-string' { $summary.executed = 'false' }
            'negative-count' { $summary.counts.PassedCount = -1 }
            'string-count' { $summary.counts.TotalCount = [string]$summary.counts.TotalCount }
            'missing-field' { $summary.PSObject.Properties.Remove('runtime') }
        }
        Set-WindowsCoreTestText $path ($summary | ConvertTo-Json -Depth 12)
        { Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts } | Should Throw
    }

    # Scenario: A shard summary contains malformed, incomplete, extended, or failed process receipts.
    # Purpose: Treat every runner-written receipt as typed fail-closed evidence.
    It 'UnitT105_rejects_invalid_shard_receipt_<Mutation>' -TestCases @(
        @{ Mutation='scalar'; Keyword='JSON object' },
        @{ Mutation='empty-object'; Keyword='property set' },
        @{ Mutation='missing-field'; Keyword='property set' },
        @{ Mutation='extra-field'; Keyword='property set' },
        @{ Mutation='failed-status'; Keyword='status must be completed' },
        @{ Mutation='replaced-path'; Keyword='receipt paths differs' },
        @{ Mutation='deleted-receipt'; Keyword='receipt paths differs' },
        @{ Mutation='duplicate-path'; Keyword='duplicate receipt path' }
    ) {
        param($Mutation,$Keyword)
        $artifacts = Join-Path $TestDrive "receipt-$Mutation"
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        $summaryFiles = @(Get-ChildItem -LiteralPath (Join-Path $artifacts 'shards') -Filter 'windows-core-shard-*-summary.json' -File -Recurse | Sort-Object FullName)
        $path = $summaryFiles[0].FullName
        if ($Mutation -in @('deleted-receipt','duplicate-path')) {
            $path = @($summaryFiles | Where-Object {
                @((Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json).shards).Count -gt 1
            })[0].FullName
        }
        $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        switch ($Mutation) {
            'scalar' { $summary.shards = [object[]]@('not-a-shard-receipt') }
            'empty-object' { $summary.shards = [object[]]@([pscustomobject]@{}) }
            'missing-field' { $summary.shards[0].PSObject.Properties.Remove('cleanedUp') }
            'extra-field' { $summary.shards[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }
            'failed-status' { $summary.shards[0].status = 'failed' }
            'replaced-path' { $summary.shards[0].paths[0] = 'C:/tampered/arbitrary.Tests.ps1' }
            'deleted-receipt' { $summary.shards = [object[]]@($summary.shards | Select-Object -Skip 1) }
            'duplicate-path' { $summary.shards[1].paths[0] = [string]$summary.shards[0].paths[0] }
        }
        Set-WindowsCoreTestText $path ($summary | ConvertTo-Json -Depth 12)
        { Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts } | Should Throw $Keyword
    }

    # Scenario: One otherwise-valid aggregate evidence field or artifact boundary is tampered with.
    # Purpose: Prove each independent aggregate invariant rejects its own targeted mutation.
    It 'UnitT107_rejects_aggregate_evidence_<Mutation>' -TestCases @(
        @{ Mutation='missing-summary'; Keyword='shard summaries' },
        @{ Mutation='duplicate-summary'; Keyword='shard summaries' },
        @{ Mutation='extra-test-file'; Keyword='receipt paths differs' },
        @{ Mutation='duplicate-test-file'; Keyword='receipt paths differs' },
        @{ Mutation='failed-count'; Keyword='FailedCount must be zero' },
        @{ Mutation='replaced-skip'; Keyword='skippedTests differs' },
        @{ Mutation='plan-artifact'; Keyword='canonical JSON differs' },
        @{ Mutation='plan-hash'; Keyword='SHA-256' },
        @{ Mutation='matrix'; Keyword='matrix output differs' }
    ) {
        param($Mutation,$Keyword)
        $artifacts = Join-Path $TestDrive "aggregate-$Mutation"
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        $summaryFiles = @(Get-ChildItem -LiteralPath (Join-Path $artifacts 'shards') -Filter 'windows-core-shard-*-summary.json' -File -Recurse | Sort-Object FullName)
        $overrides = @{}
        switch ($Mutation) {
            'missing-summary' { Remove-Item -LiteralPath $summaryFiles[0].FullName -Force }
            'duplicate-summary' {
                $copyRoot = Join-Path $artifacts 'shards/windows-core-shard-duplicate-run'
                [IO.Directory]::CreateDirectory($copyRoot) | Out-Null
                Copy-Item -LiteralPath $summaryFiles[0].FullName -Destination (Join-Path $copyRoot $summaryFiles[0].Name)
            }
            'extra-test-file' {
                $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryFiles[0].FullName | ConvertFrom-Json
                $summary.testFiles = [object[]]@($summary.testFiles) + @('C:/repo/tests/extra.Tests.ps1')
                Set-WindowsCoreTestText $summaryFiles[0].FullName ($summary | ConvertTo-Json -Depth 12)
            }
            'duplicate-test-file' {
                $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryFiles[0].FullName | ConvertFrom-Json
                $summary.testFiles = [object[]]@($summary.testFiles) + @($summary.testFiles[0])
                Set-WindowsCoreTestText $summaryFiles[0].FullName ($summary | ConvertTo-Json -Depth 12)
            }
            'failed-count' {
                $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $summaryFiles[0].FullName | ConvertFrom-Json
                $summary.counts.PassedCount = [long]$summary.counts.PassedCount - 1
                $summary.counts.FailedCount = 1
                Set-WindowsCoreTestText $summaryFiles[0].FullName ($summary | ConvertTo-Json -Depth 12)
            }
            'replaced-skip' {
                $skipSummary = @($summaryFiles | Where-Object { (Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json).counts.SkippedCount -gt 0 })[0]
                $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $skipSummary.FullName | ConvertFrom-Json
                $summary.skippedTests[0] = 'replacement.Tests.ps1::UnitT99_tampered_skip'
                Set-WindowsCoreTestText $skipSummary.FullName ($summary | ConvertTo-Json -Depth 12)
            }
            'plan-artifact' {
                $planPath = Join-Path $artifacts 'plan/plan.json'
                $planArtifact = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
                $planArtifact.partitionCount = 7
                Set-WindowsCoreTestText $planPath ($planArtifact | ConvertTo-Json -Depth 12 -Compress)
            }
            'plan-hash' { Set-WindowsCoreTestText (Join-Path $artifacts 'plan/plan.sha256') (('0' * 64) + "`n") }
            'matrix' { $overrides.MatrixJson = $script:ActualPlan.MatrixJson.Replace('"id":"01"','"id":"09"') }
        }
        { Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts $overrides } | Should Throw $Keyword
    }

    # Scenario: Plan output contains an extra duplicate but otherwise legal shard.
    # Purpose: Byte-bind the aggregate to the exact original matrix output.
    It 'UnitT110_rejects_a_matrix_with_an_extra_duplicate_shard' {
        $artifacts = Join-Path $TestDrive 'matrix-duplicate'
        New-WindowsCoreAggregateArtifacts $script:ActualPlan $artifacts
        $matrix = $script:ActualPlan.MatrixJson | ConvertFrom-Json
        $matrix.include = [object[]]@($matrix.include) + @($matrix.include[0])
        $duplicate = ConvertTo-Json -InputObject $matrix -Depth 8 -Compress
        { Invoke-WindowsCoreAggregateForTest $script:ActualPlan $artifacts @{ MatrixJson = $duplicate } } | Should Throw
    }
}
