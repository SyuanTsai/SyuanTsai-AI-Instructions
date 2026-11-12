[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $ArtifactRoot = $(if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Join-Path ([IO.Path]::GetTempPath()) 'windows-core-artifacts' } else { Join-Path $env:RUNNER_TEMP 'windows-core-artifacts' }),
    [string] $WeightsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/windows-core-shard-weights.json'),
    [string] $ExpectedPlanSha256 = [string]$env:EXPECTED_PLAN_SHA256,
    [string] $ExpectedMatrixJson = [string]$env:EXPECTED_MATRIX_JSON,
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

function Test-WindowsCoreJsonInteger {
    param($Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Assert-WindowsCoreExactProperties {
    param([Parameter(Mandatory = $true)] $Value,[Parameter(Mandatory = $true)][string[]] $Names,[Parameter(Mandatory = $true)][string] $Context)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw "$Context must be a JSON object." }
    $actual = [string[]]@($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $expected = [string[]]@($Names | Sort-Object -CaseSensitive)
    if (($actual -join "`n") -cne ($expected -join "`n")) { throw "$Context has an unexpected property set." }
}

function Assert-WindowsCoreShardReceipt {
    param([Parameter(Mandatory = $true)] $Receipt,[Parameter(Mandatory = $true)][string] $ShardId,[Parameter(Mandatory = $true)][int] $ReceiptIndex)

    $context = "Shard $ShardId receipt $ReceiptIndex"
    Assert-WindowsCoreExactProperties -Value $Receipt -Names @(
        'name','paths','processEvidencePath','resultPath','exitCode','status','cleanedUp','outputQuotaExceeded'
    ) -Context $context
    if ($Receipt.name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Receipt.name)) { throw "$context name must be a non-empty string." }
    if ($Receipt.paths -isnot [Array] -or @($Receipt.paths).Count -eq 0) { throw "$context paths must be a non-empty JSON array." }
    foreach ($path in @($Receipt.paths)) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$path)) { throw "$context paths must contain only non-empty strings." }
    }
    foreach ($pathName in @('processEvidencePath','resultPath')) {
        if ($Receipt.$pathName -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Receipt.$pathName)) { throw "$context $pathName must be a non-empty string." }
    }
    if (-not (Test-WindowsCoreJsonInteger $Receipt.exitCode) -or [long]$Receipt.exitCode -ne 0) { throw "$context exitCode must be the integer 0." }
    if ($Receipt.status -isnot [string] -or [string]$Receipt.status -cne 'completed') { throw "$context status must be completed." }
    if ($Receipt.cleanedUp -isnot [bool] -or $Receipt.cleanedUp -ne $true) { throw "$context cleanedUp must be the JSON Boolean true." }
    if ($Receipt.outputQuotaExceeded -isnot [bool] -or $Receipt.outputQuotaExceeded -ne $false) { throw "$context outputQuotaExceeded must be the JSON Boolean false." }
}

function Assert-WindowsCoreShardSummary {
    param(
        [Parameter(Mandatory = $true)] $Summary,
        [Parameter(Mandatory = $true)][string] $ShardId,
        [Parameter(Mandatory = $true)][string] $CurrentRunId,
        [Parameter(Mandatory = $true)][int] $CurrentRunAttempt
    )
    Assert-WindowsCoreExactProperties -Value $Summary -Names @(
        'schemaVersion','type','executed','status','runtime','pesterVersion','pesterModuleSha256','executorSha256',
        'testFiles','counts','shards','runId','runAttempt','skippedTests'
    ) -Context "Shard $ShardId summary"
    if (-not (Test-WindowsCoreJsonInteger $Summary.schemaVersion) -or [long]$Summary.schemaVersion -ne 2) { throw "Shard $ShardId schemaVersion must be the integer 2." }
    if ($Summary.type -isnot [string] -or [string]$Summary.type -cne 'standard-pester-execution-summary') { throw "Shard $ShardId summary type is invalid." }
    if ($Summary.executed -isnot [bool] -or $Summary.executed -ne $true) { throw "Shard $ShardId executed must be the JSON Boolean true." }
    if ($Summary.status -isnot [string] -or [string]$Summary.status -cne 'completed') { throw "Shard $ShardId status must be completed." }
    Assert-WindowsCoreExactProperties -Value $Summary.runtime -Names @('osPlatform','psEdition','psVersion') -Context "Shard $ShardId runtime"
    foreach ($runtimeName in @('osPlatform','psEdition','psVersion')) {
        if ($Summary.runtime.$runtimeName -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Summary.runtime.$runtimeName)) { throw "Shard $ShardId runtime.$runtimeName must be a non-empty string." }
    }
    if ($Summary.pesterVersion -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Summary.pesterVersion)) { throw "Shard $ShardId pesterVersion must be a non-empty string." }
    foreach ($hashName in @('pesterModuleSha256','executorSha256')) {
        if ($Summary.$hashName -isnot [string] -or [string]$Summary.$hashName -notmatch '^[0-9a-fA-F]{64}$') { throw "Shard $ShardId $hashName must be a SHA-256 string." }
    }
    foreach ($arrayName in @('testFiles','shards','skippedTests')) {
        if ($Summary.$arrayName -isnot [Array]) { throw "Shard $ShardId $arrayName must be a JSON array." }
    }
    if (@($Summary.shards).Count -eq 0) { throw "Shard $ShardId shards must contain at least one process receipt." }
    $receiptPaths = [Collections.Generic.List[string]]::new()
    $receiptPathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($receiptIndex = 0; $receiptIndex -lt @($Summary.shards).Count; $receiptIndex++) {
        Assert-WindowsCoreShardReceipt -Receipt $Summary.shards[$receiptIndex] -ShardId $ShardId -ReceiptIndex $receiptIndex
        foreach ($receiptPath in @($Summary.shards[$receiptIndex].paths)) {
            if (-not $receiptPathSet.Add([string]$receiptPath)) { throw "Shard $ShardId contains a duplicate receipt path: '$receiptPath'." }
            $receiptPaths.Add([string]$receiptPath)
        }
    }
    foreach ($path in @($Summary.testFiles)) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$path)) { throw "Shard $ShardId testFiles must contain only non-empty strings." }
    }
    Assert-WindowsCoreAggregateEqualSet -Expected ([string[]]@($Summary.testFiles)) -Actual $receiptPaths.ToArray() -Context "Shard $ShardId receipt paths"
    foreach ($identifier in @($Summary.skippedTests)) {
        if ($identifier -isnot [string] -or [string]$identifier -notmatch '^[^:/\\]+\.Tests\.ps1::\S.+$') { throw "Shard $ShardId skippedTests contains an invalid identifier." }
    }
    Assert-WindowsCoreExactProperties -Value $Summary.counts -Names @('TotalCount','PassedCount','FailedCount','SkippedCount','PendingCount','InconclusiveCount') -Context "Shard $ShardId counts"
    $countNames = @('TotalCount','PassedCount','FailedCount','SkippedCount','PendingCount','InconclusiveCount')
    foreach ($countName in $countNames) {
        $value = $Summary.counts.$countName
        if (-not (Test-WindowsCoreJsonInteger $value) -or [long]$value -lt 0) { throw "Shard $ShardId $countName must be a non-negative JSON integer." }
    }
    if ([long]$Summary.counts.TotalCount -le 0 -or
        ([long]$Summary.counts.PassedCount + [long]$Summary.counts.FailedCount + [long]$Summary.counts.SkippedCount + [long]$Summary.counts.PendingCount + [long]$Summary.counts.InconclusiveCount) -ne [long]$Summary.counts.TotalCount) {
        throw "Shard $ShardId Pester counts do not add up to TotalCount."
    }
    foreach ($zeroName in @('FailedCount','PendingCount','InconclusiveCount')) {
        if ([long]$Summary.counts.$zeroName -ne 0) { throw "Shard $ShardId $zeroName must be zero." }
    }
    if ($Summary.runId -isnot [string] -or [string]$Summary.runId -cne $CurrentRunId) { throw "Shard $ShardId runId does not equal the current workflow run." }
    if (-not (Test-WindowsCoreJsonInteger $Summary.runAttempt)) { throw "Shard $ShardId runAttempt must be a JSON integer." }
    $summaryRunAttempt = [long]$Summary.runAttempt
    if ($summaryRunAttempt -lt 1 -or $summaryRunAttempt -gt $CurrentRunAttempt) {
        throw "Shard $ShardId runAttempt '$summaryRunAttempt' must be positive and no newer than current attempt '$CurrentRunAttempt'."
    }
}

function Assert-WindowsCoreAggregate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Artifacts,
        [Parameter(Mandatory = $true)][string] $ShardWeightsPath,
        [Parameter(Mandatory = $true)][string] $PlanSha256,
        [Parameter(Mandatory = $true)][string] $MatrixJson,
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
        @{ Name = 'pester'; Value = $PesterJobResult },
        @{ Name = 'fixtures'; Value = $FixturesJobResult }
    )) {
        if ($job.Value -cne 'success') { throw "Windows Core upstream '$($job.Name)' result must be success; got '$($job.Value)'." }
    }

    $planPath = Get-WindowsCoreAggregateSingleFile -Root $Artifacts -Leaf 'plan.json'
    $hashPath = Get-WindowsCoreAggregateSingleFile -Root $Artifacts -Leaf 'plan.sha256'
    $artifactJson = (Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath).TrimEnd("`r", "`n")
    $artifactPlan = Read-WindowsCoreAggregateJson -Path $planPath -Context 'Windows Core plan artifact'
    if ($artifactPlan.runId -isnot [string] -or [string]$artifactPlan.runId -cne $CurrentRunId) { throw 'Plan artifact runId does not equal the current workflow run.' }
    if (-not (Test-WindowsCoreJsonInteger $artifactPlan.runAttempt)) { throw 'Plan artifact runAttempt must be a JSON integer.' }
    $artifactRunAttempt = [long]$artifactPlan.runAttempt
    if ($artifactRunAttempt -lt 1 -or $artifactRunAttempt -gt $CurrentRunAttempt) { throw 'Plan artifact runAttempt must be positive and no newer than the current attempt.' }

    . (Join-Path $Root 'scripts/Get-WindowsCorePlan.ps1') -DefineFunctionsOnly
    $expected = Get-WindowsCorePlan -Root $Root -ShardWeightsPath $ShardWeightsPath -WorkflowRunId ([string]$artifactPlan.runId) -WorkflowRunAttempt ([int]$artifactRunAttempt)
    if ($MatrixJson -cne $expected.MatrixJson) { throw 'Plan matrix output differs byte-for-byte from the independently calculated matrix JSON.' }
    Assert-WindowsCoreMatrix -MatrixJson $MatrixJson -ExpectedShards $expected.Plan.shards

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

    $summaryFiles = @(Get-ChildItem -LiteralPath $Artifacts -File -Recurse -Filter 'windows-core-shard-*-summary.json' | Sort-Object FullName)
    if ($summaryFiles.Count -ne $expected.Plan.shards.Count) { throw "Expected $($expected.Plan.shards.Count) shard summaries; found $($summaryFiles.Count)." }
    $artifactDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($summaryFile in $summaryFiles) {
        $relative = [IO.Path]::GetRelativePath($Artifacts, $summaryFile.FullName).Replace('\', '/')
        $parts = [string[]]@($relative -split '/')
        if ($parts.Count -lt 3 -or $parts[0] -cne 'shards' -or -not $artifactDirectories.Add($parts[1])) {
            throw 'Each shard summary must retain its own downloaded artifact directory boundary.'
        }
    }

    $observedFiles = [Collections.Generic.List[string]]::new()
    $observedSkips = [Collections.Generic.List[string]]::new()
    $observedShardIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($summaryFile in $summaryFiles) {
        if ($summaryFile.Name -notmatch '^windows-core-shard-(?<id>[0-9]{2})-summary\.json$') { throw "Shard summary filename is invalid: $($summaryFile.Name)." }
        $shardId = $Matches.id
        if (-not $observedShardIds.Add($shardId)) { throw "Duplicate shard summary id '$shardId'." }
        $plannedShard = @($expected.Plan.shards | Where-Object id -ceq $shardId)
        if ($plannedShard.Count -ne 1) { throw "Unexpected shard summary id '$shardId'." }
        $summary = Read-WindowsCoreAggregateJson -Path $summaryFile.FullName -Context "Shard $shardId summary"
        Assert-WindowsCoreShardSummary -Summary $summary -ShardId $shardId -CurrentRunId $CurrentRunId -CurrentRunAttempt $CurrentRunAttempt
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
    if ($observedSkips.Count -ne 5) { throw 'Full Windows Core must observe exactly five reviewed skipped tests.' }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        status = 'passed'
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
            -ShardWeightsPath ([IO.Path]::GetFullPath($WeightsPath)) -PlanSha256 $ExpectedPlanSha256 -MatrixJson $ExpectedMatrixJson `
            -PlanJobResult $PlanResult -AuthorityJobResult $AuthorityResult -PesterJobResult $PesterResult -FixturesJobResult $FixturesResult `
            -CurrentRunId $RunId -CurrentRunAttempt $RunAttempt
        Write-WindowsCoreAggregateResult -Path $OutputPath -Result $aggregate
        Write-Host "Windows Core aggregate passed: $($aggregate.testFileCount) files across $($aggregate.shardCount) shards."
    }
    catch {
        Write-WindowsCoreAggregateResult -Path $OutputPath -Result ([pscustomobject][ordered]@{ schemaVersion = 1; status = 'failed'; error = $_.Exception.Message })
        throw
    }
}
