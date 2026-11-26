$script:UnixCoreRepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $script:UnixCoreRepositoryRoot 'scripts/Get-UnixCorePlan.ps1') -DefineFunctionsOnly

function Set-UnixCoreTestJson {
    param([string] $Path, $Value)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 12), [Text.UTF8Encoding]::new($false))
}

Describe 'Unix Core shard planner' {
    # Scenario: The production inventory is planned for both Unix platforms.
    # Purpose: Prove complete coverage, skip ownership, shard bounds, and matrix payload integrity.
    It 'UnitT01_plans_the_real_repository_with_complete_platform_coverage' {
        $result = Get-UnixCorePlan -Root $script:UnixCoreRepositoryRoot `
            -ShardWeightsPath (Join-Path $script:UnixCoreRepositoryRoot 'tests/unix-core-shard-weights.json') `
            -WindowsShardWeightsPath (Join-Path $script:UnixCoreRepositoryRoot 'tests/windows-core-shard-weights.json') `
            -WorkflowRunId 'run-574' -WorkflowRunAttempt 1
        $matrix = $result.MatrixJson | ConvertFrom-Json
        $inventory = Get-Content -Raw -Encoding UTF8 (Join-Path $script:UnixCoreRepositoryRoot 'docs/standards/core-test-skip-inventory.json') | ConvertFrom-Json

        foreach ($platformId in @('linux','macos')) {
            $shards = @($result.Plan.shards | Where-Object platform -ceq $platformId)
            $shards.Count | Should Be 4
            $files = @($shards | ForEach-Object files)
            $files.Count | Should Be $result.Plan.selectedTestFiles.Count
            (@($files | Sort-Object -CaseSensitive) -join "`n") | Should Be (@($result.Plan.selectedTestFiles | Sort-Object -CaseSensitive) -join "`n")
            foreach ($skip in @($inventory.platforms.$platformId.expectedSkippedTests)) {
                $owner = @($shards | Where-Object { @($_.expectedSkippedTests) -ccontains $skip })
                $owner.Count | Should Be 1
                @($owner[0].files) -ccontains (($skip -split '::',2)[0]) | Should Be $true
            }
        }
        @($matrix.include).Count | Should Be @($result.Plan.shards).Count
        foreach ($entry in @($matrix.include)) {
            $shard = @($result.Plan.shards | Where-Object { $_.platform -ceq $entry.platform -and $_.id -ceq $entry.shard })[0]
            $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.filesBase64)) | ConvertFrom-Json
            (@($decoded) -join "`n") | Should Be (@($shard.files) -join "`n")
        }
    }

    # Scenario: Identical inputs are planned twice.
    # Purpose: Protect byte-stable canonical and matrix output.
    It 'UnitT02_is_deterministic_for_the_same_run_identity' {
        $arguments = @{
            Root = $script:UnixCoreRepositoryRoot
            ShardWeightsPath = Join-Path $script:UnixCoreRepositoryRoot 'tests/unix-core-shard-weights.json'
            WindowsShardWeightsPath = Join-Path $script:UnixCoreRepositoryRoot 'tests/windows-core-shard-weights.json'
            WorkflowRunId = 'same-run'
            WorkflowRunAttempt = 2
        }
        $first = Get-UnixCorePlan @arguments
        $second = Get-UnixCorePlan @arguments
        $second.PlanSha256 | Should Be $first.PlanSha256
        $second.MatrixJson | Should Be $first.MatrixJson
    }

    # Scenario: Six weighted files are assigned to two partitions.
    # Purpose: Lock the descending-weight, ordinal-tie, least-loaded LPT behavior.
    It 'UnitT03_assigns_small_inputs_with_exact_lpt_results' {
        $files = [string[]]@('a.Tests.ps1','b.Tests.ps1','c.Tests.ps1','d.Tests.ps1','e.Tests.ps1','f.Tests.ps1')
        $weights = @{ 'a.Tests.ps1'=10; 'b.Tests.ps1'=8; 'c.Tests.ps1'=6; 'd.Tests.ps1'=5; 'e.Tests.ps1'=3; 'f.Tests.ps1'=1 }
        $shards = @(New-UnixCoreShards -PlatformId linux -SelectedTestFiles $files -ExpectedSkippedTests @() -PartitionCount 2 -Weights $weights)
        (@($shards[0].files) -join ',') | Should Be 'a.Tests.ps1,d.Tests.ps1,f.Tests.ps1'
        (@($shards[1].files) -join ',') | Should Be 'b.Tests.ps1,c.Tests.ps1,e.Tests.ps1'
        $shards[0].weight | Should Be 16
        $shards[1].weight | Should Be 17
    }

    # Scenario: A selected file has no configured weight and the configuration contains a retired name.
    # Purpose: Preserve the weight-one fallback while tolerating stale valid weight entries.
    It 'UnitT04_defaults_unlisted_files_and_ignores_unknown_weight_names' {
        $shards = @(New-UnixCoreShards -PlatformId macos -SelectedTestFiles @('listed.Tests.ps1','new.Tests.ps1') `
            -ExpectedSkippedTests @() -PartitionCount 1 -Weights @{ 'listed.Tests.ps1'=2.5; 'retired.Tests.ps1'=99 })
        $shards.Count | Should Be 1
        $shards[0].weight | Should Be 3.5
        (@($shards[0].files) -join ',') | Should Be 'listed.Tests.ps1,new.Tests.ps1'
    }

    # Scenario: One shard proof invariant is independently corrupted.
    # Purpose: Ensure missing, duplicate, extra, and misplaced-skip plans fail closed.
    It 'UnitT05_rejects_invalid_coverage_<Mutation>' -TestCases @(
        @{ Mutation='missing' }, @{ Mutation='duplicate' }, @{ Mutation='extra' }, @{ Mutation='wrong-skip-shard' }
    ) {
        param($Mutation)
        $skip = 'a.Tests.ps1::UnitT10_skip'
        $shards = @(
            [pscustomobject][ordered]@{ id='01'; platform='linux'; files=[string[]]@('a.Tests.ps1'); expectedSkippedTests=[string[]]@($skip); weight=1.0 },
            [pscustomobject][ordered]@{ id='02'; platform='linux'; files=[string[]]@('b.Tests.ps1'); expectedSkippedTests=[string[]]@(); weight=1.0 }
        )
        switch ($Mutation) {
            'missing' { $shards[1].files = [string[]]@() }
            'duplicate' { $shards[1].files = [string[]]@('a.Tests.ps1','b.Tests.ps1') }
            'extra' { $shards[1].files = [string[]]@('b.Tests.ps1','extra.Tests.ps1') }
            'wrong-skip-shard' { $shards[0].expectedSkippedTests = [string[]]@(); $shards[1].expectedSkippedTests = [string[]]@($skip) }
        }
        { Assert-UnixCoreShardCoverage -SelectedTestFiles @('a.Tests.ps1','b.Tests.ps1') -Shards $shards -ExpectedSkippedTests @($skip) } | Should Throw
    }

    # Scenario: One weights-contract boundary is invalid.
    # Purpose: Reject unsupported schemas, unsafe data, and platform drift.
    It 'UnitT06_rejects_invalid_weights_<Mutation>' -TestCases @(
        @{ Mutation='schema' }, @{ Mutation='partition-zero' }, @{ Mutation='partition-thirteen' },
        @{ Mutation='non-positive' }, @{ Mutation='unsafe-name' }, @{ Mutation='missing-platform' }, @{ Mutation='unknown-platform' }
    ) {
        param($Mutation)
        $value = [ordered]@{
            schemaVersion = 1
            platforms = [ordered]@{
                linux = [ordered]@{ partitionCount=4; weights=[ordered]@{ 'a.Tests.ps1'=1 } }
                macos = [ordered]@{ partitionCount=5; weights=[ordered]@{ 'a.Tests.ps1'=1 } }
            }
        }
        switch ($Mutation) {
            'schema' { $value.schemaVersion = 2 }
            'partition-zero' { $value.platforms.linux.partitionCount = 0 }
            'partition-thirteen' { $value.platforms.macos.partitionCount = 13 }
            'non-positive' { $value.platforms.linux.weights['a.Tests.ps1'] = 0 }
            'unsafe-name' { $value.platforms.linux.weights = [ordered]@{ '../a.Tests.ps1'=1 } }
            'missing-platform' { $value.platforms.Remove('macos') }
            'unknown-platform' { $value.platforms.other = [ordered]@{ partitionCount=1; weights=[ordered]@{} } }
        }
        $path = Join-Path $TestDrive "$Mutation.json"
        Set-UnixCoreTestJson $path $value
        { Read-UnixCoreShardWeights -Path $path } | Should Throw
    }

    # Scenario: The executable script writes files and GitHub step outputs.
    # Purpose: Verify no-BOM canonical artifacts, hash binding, parseable matrix output, and environment restoration.
    It 'UnitT07_writes_hash_bound_plan_and_github_outputs' {
        $outputDirectory = Join-Path $TestDrive 'plan-output'
        $githubOutput = Join-Path $TestDrive 'github-output.txt'
        $summary = Join-Path $TestDrive 'summary.md'
        $saved = @{ GITHUB_OUTPUT=$env:GITHUB_OUTPUT; GITHUB_STEP_SUMMARY=$env:GITHUB_STEP_SUMMARY; GITHUB_RUN_ID=$env:GITHUB_RUN_ID; GITHUB_RUN_ATTEMPT=$env:GITHUB_RUN_ATTEMPT }
        try {
            $env:GITHUB_OUTPUT = $githubOutput
            $env:GITHUB_STEP_SUMMARY = $summary
            $env:GITHUB_RUN_ID = 'main-run'
            $env:GITHUB_RUN_ATTEMPT = '3'
            & (Join-Path $script:UnixCoreRepositoryRoot 'scripts/Get-UnixCorePlan.ps1') `
                -RepositoryRoot $script:UnixCoreRepositoryRoot -OutputDirectory $outputDirectory | Out-Null
            $canonical = (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDirectory 'plan.json')).TrimEnd("`r","`n")
            $expectedHash = Get-UnixCoreSha256 -Text $canonical
            (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDirectory 'plan.sha256')).Trim() | Should Be $expectedHash
            $outputText = Get-Content -Raw -Encoding UTF8 $githubOutput
            ([regex]::Match($outputText, '(?m)^planSha256=(.+)$').Groups[1].Value.Trim()) | Should Be $expectedHash
            ([regex]::Match($outputText, '(?ms)^matrix<<(?<d>[^\r\n]+)\r?\n(?<v>.*?)\r?\n\k<d>\r?$').Groups['v'].Value | ConvertFrom-Json).include.Count | Should BeGreaterThan 1
            $outputText | Should Match '(?m)^planRunAttempt=3$'
        }
        finally {
            $env:GITHUB_OUTPUT=$saved.GITHUB_OUTPUT; $env:GITHUB_STEP_SUMMARY=$saved.GITHUB_STEP_SUMMARY
            $env:GITHUB_RUN_ID=$saved.GITHUB_RUN_ID; $env:GITHUB_RUN_ATTEMPT=$saved.GITHUB_RUN_ATTEMPT
        }
    }
}
