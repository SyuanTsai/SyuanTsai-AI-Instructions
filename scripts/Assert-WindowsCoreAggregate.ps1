[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $ArtifactRoot = $(if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path ([IO.Path]::GetTempPath()) 'windows-core-artifacts' } else { Join-Path $env:RUNNER_TEMP 'windows-core-artifacts' }),
    [string] $WeightsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/windows-core-shard-weights.json'),
    [string] $EventName = [string]$env:GITHUB_EVENT_NAME,
    [string] $PullRequestHeadSha = [string]$env:PULL_REQUEST_HEAD_SHA,
    [string] $ExpectedPlanSha256 = [string]$env:EXPECTED_PLAN_SHA256,
    [string] $PlannedMode = [string]$env:PLANNED_MODE,
    [string] $PlanResult = [string]$env:NEEDS_PLAN_RESULT,
    [string] $AuthorityResult = [string]$env:NEEDS_AUTHORITY_RESULT,
    [string] $PesterResult = [string]$env:NEEDS_PESTER_RESULT,
    [string] $FixturesResult = [string]$env:NEEDS_FIXTURES_RESULT,
    [string] $RunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
    [ValidateRange(1, 2147483647)][int] $RunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 }),
    [string] $OutputPath = $(if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path ([IO.Path]::GetTempPath()) 'windows-core-aggregate-result.json' } else { Join-Path $env:RUNNER_TEMP 'windows-core-aggregate-result.json' }),
    [switch] $DefineFunctionsOnly
)

$ErrorActionPreference = 'Stop'

function Assert-WindowsCoreAggregateEqualSet {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Expected,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Actual,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (@($Actual | Select-Object -Unique).Count -ne $Actual.Count) { throw "$Context contains duplicate values." }
    $expectedSorted = [string[]]@($Expected | Sort-Object -CaseSensitive)
    $actualSorted = [string[]]@($Actual | Sort-Object -CaseSensitive)
    if (($expectedSorted -join "`n") -cne ($actualSorted -join "`n")) {
        throw "$Context differs from the independently calculated plan. Expected: $($expectedSorted -join ', '). Actual: $($actualSorted -join ', ')."
    }
}

function Get-WindowsCoreAggregateSingleFile {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][string] $Leaf)
    $matches = @(Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object Name -ceq $Leaf)
    if ($matches.Count -ne 1) { throw "Expected exactly one '$Leaf' artifact; found $($matches.Count)." }
    if (($matches[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Artifact '$Leaf' must be a regular file." }
    return $matches[0].FullName
}

function Read-WindowsCoreAggregateJson {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Context)
    try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$Context is not valid JSON: $($_.Exception.Message)" }
}

function Assert-WindowsCoreAggregate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Artifacts,
        [Parameter(Mandatory = $true)][string] $ShardWeightsPath,
        [Parameter(Mandatory = $true)][string] $Event,
        [string] $ExpectedPullRequestHead,
        [Parameter(Mandatory = $true)][string] $PlanSha256,
        [Parameter(Mandatory = $true)][ValidateSet('full','docs')][string] $PlanMode,
        [Parameter(Mandatory = $true)][string] $PlanJobResult,
        [Parameter(Mandatory = $true)][string] $AuthorityJobResult,
        [Parameter(Mandatory = $true)][string] $PesterJobResult,
        [Parameter(Mandatory = $true)][string] $FixturesJobResult,
        [string] $CurrentRunId = $(if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { [string]$env:GITHUB_RUN_ID }),
        [ValidateRange(1, 2147483647)][int] $CurrentRunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 })
    )
    if ([string]::IsNullOrWhiteSpace($CurrentRunId)) { throw 'The current workflow run id cannot be empty.' }
    foreach ($job in @(
        @{ Name = 'plan'; Value = $PlanJobResult },
        @{ Name = 'authority'; Value = $AuthorityJobResult },
        @{ Name = 'pester'; Value = $PesterJobResult }
    )) {
        if ($job.Value -cne 'success') { throw "Windows Core upstream '$($job.Name)' result must be success; got '$($job.Value)'." }
    }

    $planPath = Get-WindowsCoreAggregateSingleFile -Root $Artifacts -Leaf 'plan.json'
    $hashPath = Get-WindowsCoreAggregateSingleFile -Root $Artifacts -Leaf 'plan.sha256'
    $artifactJson = (Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath).TrimEnd("`r", "`n")
    $artifactPlan = Read-WindowsCoreAggregateJson -Path $planPath -Context 'Windows Core plan artifact'
    $artifactRunId = [string]$artifactPlan.runId
    $artifactRunAttempt = [long]$artifactPlan.runAttempt
    if ($artifactRunId -cne $CurrentRunId) { throw "Plan artifact runId '$artifactRunId' does not equal current run '$CurrentRunId'." }
    if ($artifactRunAttempt -lt 1 -or $artifactRunAttempt -gt $CurrentRunAttempt) {
        throw "Plan artifact runAttempt '$artifactRunAttempt' must be positive and no newer than current attempt '$CurrentRunAttempt'."
    }

    . (Join-Path $Root 'scripts/Get-WindowsCorePlan.ps1') -DefineFunctionsOnly
    $expected = Get-WindowsCorePlan -Root $Root -Event $Event -ExpectedPullRequestHead $ExpectedPullRequestHead -ShardWeightsPath $ShardWeightsPath -WorkflowRunId $artifactRunId -WorkflowRunAttempt ([int]$artifactRunAttempt)
    if ($expected.Plan.mode -cne $PlanMode) { throw "Plan output mode '$PlanMode' differs from independently calculated mode '$($expected.Plan.mode)'." }
    $requiredFixtureResult = if ($expected.Plan.mode -ceq 'full') { 'success' } else { 'skipped' }
    if ($FixturesJobResult -cne $requiredFixtureResult) {
        throw "Windows Core fixtures result must be '$requiredFixtureResult' for mode '$($expected.Plan.mode)'; got '$FixturesJobResult'."
    }

    $artifactHash = (Get-Content -Raw -Encoding UTF8 -LiteralPath $hashPath).Trim()
    if ($artifactJson -cne $expected.CanonicalJson) { throw 'Plan artifact canonical JSON differs from the independently calculated plan.' }
    $calculatedArtifactHash = Get-WindowsCoreSha256 -Text $artifactJson
    foreach ($binding in @(
        @{ Name = 'plan artifact'; Value = $artifactHash },
        @{ Name = 'plan output'; Value = $PlanSha256 },
        @{ Name = 'independent plan'; Value = $expected.PlanSha256 }
    )) {
        if ($binding.Value -notmatch '^[0-9a-f]{64}$' -or $binding.Value -cne $calculatedArtifactHash) {
            throw "Windows Core $($binding.Name) SHA-256 does not bind the canonical plan artifact."
        }
    }

    $summaryFiles = @(Get-ChildItem -LiteralPath $Artifacts -File -Recurse -Filter 'windows-core-shard-*-summary.json' | Sort-Object Name)
    if ($summaryFiles.Count -ne $expected.Plan.shards.Count) {
        throw "Expected $($expected.Plan.shards.Count) shard summaries; found $($summaryFiles.Count)."
    }
    $observedFiles = [Collections.Generic.List[string]]::new()
    $observedSkips = [Collections.Generic.List[string]]::new()
    $observedShardIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($summaryFile in $summaryFiles) {
        if ($summaryFile.Name -notmatch '^windows-core-shard-(?<id>[0-9]{2})-summary\.json$') {
            throw "Shard summary filename is invalid: $($summaryFile.Name)."
        }
        $shardId = $Matches.id
        if (-not $observedShardIds.Add($shardId)) { throw "Duplicate shard summary id '$shardId'." }
        $plannedShard = @($expected.Plan.shards | Where-Object id -ceq $shardId)
        if ($plannedShard.Count -ne 1) { throw "Unexpected shard summary id '$shardId'." }
        $summary = Read-WindowsCoreAggregateJson -Path $summaryFile.FullName -Context "Shard $shardId summary"
        if ([int]$summary.schemaVersion -ne 2 -or [string]$summary.type -cne 'standard-pester-execution-summary' -or
            -not [bool]$summary.executed -or [string]$summary.status -cne 'completed') {
            throw "Shard $shardId summary does not describe a completed bounded execution."
        }
        if ([string]$summary.runId -cne $CurrentRunId) { throw "Shard $shardId runId does not equal the current workflow run." }
        $summaryRunAttempt = [long]$summary.runAttempt
        if ($summaryRunAttempt -lt 1 -or $summaryRunAttempt -gt $CurrentRunAttempt) {
            throw "Shard $shardId runAttempt '$summaryRunAttempt' must be positive and no newer than current attempt '$CurrentRunAttempt'."
        }
        foreach ($countName in @('FailedCount','PendingCount','InconclusiveCount')) {
            $property = $summary.counts.PSObject.Properties[$countName]
            if ($null -eq $property -or [long]$property.Value -ne 0) { throw "Shard $shardId $countName must be zero." }
        }
        if ([long]$summary.counts.TotalCount -le 0 -or ([long]$summary.counts.PassedCount + [long]$summary.counts.SkippedCount) -ne [long]$summary.counts.TotalCount) {
            throw "Shard $shardId Pester counts are incomplete."
        }
        $summaryNames = [string[]]@($summary.testFiles | ForEach-Object { [IO.Path]::GetFileName([string]$_) })
        Assert-WindowsCoreAggregateEqualSet -Expected ([string[]]$plannedShard[0].files) -Actual $summaryNames -Context "Shard $shardId testFiles"
        foreach ($name in $summaryNames) { $observedFiles.Add($name) }
        $summarySkips = [string[]]@($summary.skippedTests)
        if ($summarySkips.Count -ne [long]$summary.counts.SkippedCount) { throw "Shard $shardId skippedTests count differs from SkippedCount." }
        Assert-WindowsCoreAggregateEqualSet -Expected ([string[]]$plannedShard[0].expectedSkippedTests) -Actual $summarySkips -Context "Shard $shardId skippedTests"
        foreach ($skip in $summarySkips) { $observedSkips.Add($skip) }
    }
    Assert-WindowsCoreAggregateEqualSet -Expected ([string[]]$expected.Plan.selectedTestFiles) -Actual $observedFiles.ToArray() -Context 'All shard testFiles'
    Assert-WindowsCoreAggregateEqualSet -Expected ([string[]]$expected.Plan.expectedSkippedTests) -Actual $observedSkips.ToArray() -Context 'All shard skippedTests'
    if ($expected.Plan.mode -ceq 'full' -and $observedSkips.Count -ne 5) { throw 'Full Windows Core must observe exactly five reviewed skipped tests.' }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        status = 'passed'
        mode = $expected.Plan.mode
        planSha256 = $expected.PlanSha256
        runAttempt = $CurrentRunAttempt
        runId = $CurrentRunId
        shardCount = $summaryFiles.Count
        testFileCount = $observedFiles.Count
        skippedTestCount = $observedSkips.Count
    }
}

function Write-WindowsCoreAggregateResult {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)] $Result)
    $fullPath = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath)) | Out-Null
    [IO.File]::WriteAllText($fullPath, (ConvertTo-Json -InputObject $Result -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
}

if (-not $DefineFunctionsOnly) {
    try {
        $aggregate = Assert-WindowsCoreAggregate -Root ([IO.Path]::GetFullPath($RepositoryRoot)) -Artifacts ([IO.Path]::GetFullPath($ArtifactRoot)) `
            -ShardWeightsPath ([IO.Path]::GetFullPath($WeightsPath)) -Event $EventName -ExpectedPullRequestHead $PullRequestHeadSha `
            -PlanSha256 $ExpectedPlanSha256 -PlanMode $PlannedMode -PlanJobResult $PlanResult -AuthorityJobResult $AuthorityResult `
            -PesterJobResult $PesterResult -FixturesJobResult $FixturesResult -CurrentRunId $RunId -CurrentRunAttempt $RunAttempt
        Write-WindowsCoreAggregateResult -Path $OutputPath -Result $aggregate
        Write-Host "Windows Core aggregate passed: $($aggregate.testFileCount) files across $($aggregate.shardCount) shards."
    }
    catch {
        $failure = [pscustomobject][ordered]@{
            schemaVersion = 1
            status = 'failed'
            error = $_.Exception.Message
        }
        Write-WindowsCoreAggregateResult -Path $OutputPath -Result $failure
        throw
    }
}
