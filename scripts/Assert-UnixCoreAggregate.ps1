[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $AggregateRoot,
    [Parameter(Mandatory = $true)][ValidateSet('linux','macos')][string] $Platform,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ExpectedPlanSha256,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ExpectedPlanRunAttempt,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanResult,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $AuthorityResult,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PesterResult,
    [string] $RunId = $env:GITHUB_RUN_ID,
    [ValidateRange(1, [int]::MaxValue)][int] $CurrentRunAttempt = $(if ([string]$env:GITHUB_RUN_ATTEMPT -match '^[1-9][0-9]*$') { [int]$env:GITHUB_RUN_ATTEMPT } else { 1 }),
    [AllowEmptyString()][string] $StepSummaryPath = $env:GITHUB_STEP_SUMMARY,
    [switch] $DefineFunctionsOnly
)

$ErrorActionPreference = 'Stop'

function Test-UnixCoreEvidenceAttempt {
    param(
        [Parameter(Mandatory = $true)] $Attempt,
        [Parameter(Mandatory = $true)][int] $PlanAttempt,
        [Parameter(Mandatory = $true)][int] $CurrentAttempt
    )

    $isInteger = $Attempt -is [byte] -or $Attempt -is [sbyte] -or $Attempt -is [int16] -or
        $Attempt -is [uint16] -or $Attempt -is [int32] -or $Attempt -is [uint32] -or
        $Attempt -is [int64] -or $Attempt -is [uint64]
    return $isInteger -and [int64]$Attempt -ge $PlanAttempt -and [int64]$Attempt -le $CurrentAttempt
}

function Assert-UnixCoreEvidenceAttempt {
    param(
        [Parameter(Mandatory = $true)] $Attempt,
        [Parameter(Mandatory = $true)][int] $PlanAttempt,
        [Parameter(Mandatory = $true)][int] $CurrentAttempt,
        [Parameter(Mandatory = $true)][string] $EvidenceName
    )

    if (-not (Test-UnixCoreEvidenceAttempt -Attempt $Attempt -PlanAttempt $PlanAttempt -CurrentAttempt $CurrentAttempt)) {
        throw "$EvidenceName runAttempt must be an integer from plan attempt $PlanAttempt through current attempt $CurrentAttempt; got '$Attempt'."
    }
}

function Assert-UnixCoreOrdinalListEqual {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Actual,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Message
    )

    $actualStrings = [string[]]@($Actual | ForEach-Object { [string]$_ })
    $expectedStrings = [string[]]@($Expected | ForEach-Object { [string]$_ })
    if (($actualStrings -join "`n") -cne ($expectedStrings -join "`n")) { throw $Message }
}

function Invoke-UnixCoreAggregateAssertion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][ValidateSet('linux','macos')][string] $PlatformId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanSha256,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanRunAttempt,
        [Parameter(Mandatory = $true)][string] $PlanJobResult,
        [Parameter(Mandatory = $true)][string] $AuthorityJobResult,
        [Parameter(Mandatory = $true)][string] $PesterJobResult,
        [Parameter(Mandatory = $true)][string] $WorkflowRunId,
        [Parameter(Mandatory = $true)][int] $WorkflowRunAttempt,
        [AllowEmptyString()][string] $SummaryPath = ''
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $resultPath = Join-Path $resolvedRoot 'aggregate-result.json'
    try {
        foreach ($upstreamJob in @(
            [pscustomobject]@{ name='plan'; result=$PlanJobResult },
            [pscustomobject]@{ name='authority'; result=$AuthorityJobResult },
            [pscustomobject]@{ name='pester'; result=$PesterJobResult }
        )) {
            if ([string]$upstreamJob.result -cne 'success') {
                throw "Unix Core upstream '$($upstreamJob.name)' result must be success; got '$($upstreamJob.result)'."
            }
        }
        if ($PlanSha256 -notmatch '^[0-9a-f]{64}$') {
            throw "Unix Core expected plan SHA-256 '$PlanSha256' must be 64 lowercase hexadecimal characters."
        }
        if ($PlanRunAttempt -notmatch '^[1-9][0-9]*$') {
            throw "Unix Core expected plan run attempt '$PlanRunAttempt' must be a positive integer."
        }
        try {
            [int]$validatedPlanRunAttempt = $PlanRunAttempt
        }
        catch {
            throw "Unix Core expected plan run attempt '$PlanRunAttempt' must be a positive integer."
        }

        $planPath = Join-Path $resolvedRoot 'plan/plan.json'
        $planHashPath = Join-Path $resolvedRoot 'plan/plan.sha256'
        $planJson = (Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath).TrimEnd("`r","`n")
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $actualPlanSha256 = ([BitConverter]::ToString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($planJson)))).Replace('-','').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
        $artifactPlanSha256 = (Get-Content -Raw -Encoding UTF8 -LiteralPath $planHashPath).Trim()
        if ($actualPlanSha256 -cne $artifactPlanSha256 -or $actualPlanSha256 -cne $PlanSha256) {
            throw "Unix Core plan SHA-256 evidence differs for '$planPath'."
        }
        $plan = $planJson | ConvertFrom-Json
        if ($plan.schemaVersion -isnot [int64] -and $plan.schemaVersion -isnot [int32]) { throw "Unix Core plan '$planPath' schemaVersion must be integer 2." }
        if ([int64]$plan.schemaVersion -ne 2) { throw "Unix Core plan '$planPath' schemaVersion must be 2." }
        if ([string]$plan.runId -cne $WorkflowRunId) { throw "Unix Core plan '$planPath' runId differs." }
        if (($plan.runAttempt -isnot [int64] -and $plan.runAttempt -isnot [int32]) -or [int64]$plan.runAttempt -ne $validatedPlanRunAttempt) {
            throw "Unix Core plan '$planPath' runAttempt must equal expected plan attempt $validatedPlanRunAttempt."
        }
        if ($validatedPlanRunAttempt -lt 1 -or $validatedPlanRunAttempt -gt $WorkflowRunAttempt) {
            throw "Unix Core plan '$planPath' runAttempt must be from 1 through current attempt $WorkflowRunAttempt."
        }

        $platformShards = @($plan.shards | Where-Object platform -ceq $PlatformId)
        $platformExpectedSkips = [string[]]@($platformShards | ForEach-Object { @($_.expectedSkippedTests) })
        . (Join-Path $PSScriptRoot 'Get-UnixCorePlan.ps1') -DefineFunctionsOnly
        Assert-UnixCoreShardCoverage -SelectedTestFiles ([string[]]@($plan.selectedTestFiles)) `
            -Shards $platformShards -ExpectedSkippedTests $platformExpectedSkips

        $plannedShardById = @{}
        $plannedShardByFile = @{}
        foreach ($plannedShard in $platformShards) {
            $shardId = [string]$plannedShard.id
            if ($plannedShardById.ContainsKey($shardId)) { throw "Planned shard '$shardId' is duplicated for $PlatformId." }
            $plannedShardById[$shardId] = $plannedShard
            foreach ($file in @($plannedShard.files)) { $plannedShardByFile[[string]$file] = $plannedShard }
        }

        $shardsRoot = Join-Path $resolvedRoot 'shards'
        $shardSummaryFiles = @(Get-ChildItem -LiteralPath $shardsRoot -Filter 'shard-summary.json' -File -Recurse |
            Where-Object Name -CEQ 'shard-summary.json')
        $shardSummaryById = @{}
        foreach ($shardSummaryFile in $shardSummaryFiles) {
            $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardSummaryFile.FullName | ConvertFrom-Json
            $shardId = [string]$summary.shard
            if (-not $plannedShardById.ContainsKey($shardId) -or $shardSummaryById.ContainsKey($shardId)) {
                throw "Shard summary '$($shardSummaryFile.FullName)' has unexpected or duplicate shard '$shardId'."
            }
            if ([int]$summary.schemaVersion -ne 2 -or [string]$summary.platform -cne $PlatformId -or
                [string]$summary.planSha256 -cne $actualPlanSha256 -or [string]$summary.runId -cne $WorkflowRunId -or
                [string]$summary.status -cne 'passed') {
                throw "Shard summary '$($shardSummaryFile.FullName)' did not pass its identity and status contract."
            }
            Assert-UnixCoreEvidenceAttempt -Attempt $summary.runAttempt -PlanAttempt $validatedPlanRunAttempt `
                -CurrentAttempt $WorkflowRunAttempt -EvidenceName "Shard summary '$($shardSummaryFile.FullName)'"
            Assert-UnixCoreOrdinalListEqual -Actual @($summary.files | ForEach-Object file) `
                -Expected @($plannedShardById[$shardId].files) `
                -Message "Shard summary '$($shardSummaryFile.FullName)' file list differs from planned shard '$shardId'."
            $shardSummaryById[$shardId] = $summary
        }
        foreach ($shardId in $plannedShardById.Keys) {
            if (-not $shardSummaryById.ContainsKey($shardId)) { throw "Missing shard-summary.json for planned shard '$shardId'." }
        }

        $fileSummaryFiles = @(Get-ChildItem -LiteralPath $shardsRoot -Filter 'summary.json' -File -Recurse |
            Where-Object Name -CEQ 'summary.json')
        $expectedFileCount = @($plan.selectedTestFiles).Count
        $observedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [long]$passed = 0; [long]$failed = 0; [long]$skipped = 0
        foreach ($fileSummaryFile in $fileSummaryFiles) {
            $summary = Get-Content -Raw -Encoding UTF8 -LiteralPath $fileSummaryFile.FullName | ConvertFrom-Json
            $file = [string]$summary.file
            if (-not $plannedShardByFile.ContainsKey($file) -or -not $observedFiles.Add($file)) {
                throw "Per-file summary '$($fileSummaryFile.FullName)' is unexpected or duplicates file '$file'."
            }
            $plannedShard = $plannedShardByFile[$file]
            $shardId = [string]$plannedShard.id
            if ([int]$summary.schemaVersion -ne 2 -or [string]$summary.platform -cne $PlatformId -or
                [string]$summary.shard -cne $shardId -or [string]$summary.planSha256 -cne $actualPlanSha256 -or
                [string]$summary.runId -cne $WorkflowRunId -or [string]$summary.status -cne 'passed' -or
                [string]$summary.executorOutcome -cne 'success') {
                throw "Per-file summary '$($fileSummaryFile.FullName)' for '$file' did not pass its identity and status contract."
            }
            Assert-UnixCoreEvidenceAttempt -Attempt $summary.runAttempt -PlanAttempt $validatedPlanRunAttempt `
                -CurrentAttempt $WorkflowRunAttempt -EvidenceName "Per-file summary '$($fileSummaryFile.FullName)'"
            if ([int64]$summary.runAttempt -ne [int64]$shardSummaryById[$shardId].runAttempt) {
                throw "Per-file summary '$($fileSummaryFile.FullName)' runAttempt differs from shard summary '$shardId'."
            }
            $expectedSkips = [string[]]@($plannedShard.expectedSkippedTests | Where-Object { ([string]$_).StartsWith("${file}::", [StringComparison]::Ordinal) })
            [Array]::Sort($expectedSkips, [StringComparer]::Ordinal)
            $recordedExpectedSkips = [string[]]@($summary.expectedSkippedTests); [Array]::Sort($recordedExpectedSkips, [StringComparer]::Ordinal)
            $recordedSkips = [string[]]@($summary.skippedTests); [Array]::Sort($recordedSkips, [StringComparer]::Ordinal)
            Assert-UnixCoreOrdinalListEqual -Actual $recordedExpectedSkips -Expected $expectedSkips -Message "Per-file skip evidence differs for '$file' in '$($fileSummaryFile.FullName)'."
            Assert-UnixCoreOrdinalListEqual -Actual $recordedSkips -Expected $expectedSkips -Message "Per-file skip evidence differs for '$file' in '$($fileSummaryFile.FullName)'."
            if ([int]$summary.counts.failed -ne 0 -or [int]$summary.counts.pending -ne 0 -or
                [int]$summary.counts.inconclusive -ne 0 -or @($summary.failedTests).Count -ne 0) {
                throw "Per-file result evidence is not clean for '$file' in '$($fileSummaryFile.FullName)'."
            }
            $passed += [long]$summary.counts.passed
            $failed += [long]$summary.counts.failed
            $skipped += [long]$summary.counts.skipped
        }
        foreach ($file in @($plan.selectedTestFiles)) {
            if (-not $observedFiles.Contains([string]$file)) { throw "Missing per-file summary.json for planned file '$file'." }
        }
        if ($observedFiles.Count -ne $expectedFileCount) {
            throw "Expected $expectedFileCount unique per-file summaries for $PlatformId; found $($observedFiles.Count)."
        }

        $authorityRoot = Join-Path $resolvedRoot 'authority'
        $authorityFiles = @(Get-ChildItem -LiteralPath $authorityRoot -Filter 'authority-result.json' -File -Recurse |
            Where-Object Name -CEQ 'authority-result.json')
        if ($authorityFiles.Count -ne 1) { throw "Expected one authority-result.json for $PlatformId; found $($authorityFiles.Count)." }
        $authority = Get-Content -Raw -Encoding UTF8 -LiteralPath $authorityFiles[0].FullName | ConvertFrom-Json
        if ([string]$authority.status -cne 'passed' -or $authority.executed -ne $true) {
            throw "Authority result '$($authorityFiles[0].FullName)' did not pass."
        }
        $identityFiles = @(Get-ChildItem -LiteralPath $authorityRoot -Filter 'authority-identity.json' -File -Recurse |
            Where-Object Name -CEQ 'authority-identity.json')
        if ($identityFiles.Count -ne 1) { throw "Expected one authority-identity.json for $PlatformId; found $($identityFiles.Count)." }
        $identity = Get-Content -Raw -Encoding UTF8 -LiteralPath $identityFiles[0].FullName | ConvertFrom-Json
        if ([string]$identity.runId -cne $WorkflowRunId) { throw "Authority identity '$($identityFiles[0].FullName)' runId differs." }
        Assert-UnixCoreEvidenceAttempt -Attempt $identity.runAttempt -PlanAttempt $validatedPlanRunAttempt `
            -CurrentAttempt $WorkflowRunAttempt -EvidenceName "Authority identity '$($identityFiles[0].FullName)'"
        $authoritySha256 = (Get-FileHash -LiteralPath $authorityFiles[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([string]$identity.authoritySha256 -cne $authoritySha256) { throw "Authority identity '$($identityFiles[0].FullName)' SHA-256 differs." }

        $aggregate = [pscustomobject][ordered]@{
            schemaVersion=2; status='passed'; platform=$PlatformId; planSha256=$actualPlanSha256
            planRunAttempt=$validatedPlanRunAttempt; runId=$WorkflowRunId; runAttempt=$WorkflowRunAttempt
            shardCount=$platformShards.Count; fileCount=$observedFiles.Count
            passed=$passed; failed=$failed; skipped=$skipped
        }
        [IO.Directory]::CreateDirectory($resolvedRoot) | Out-Null
        [IO.File]::WriteAllText($resultPath, ($aggregate | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
        if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
            $markdown = "### $PlatformId Core`n`n- Shards: $($aggregate.shardCount)`n- Files: $($aggregate.fileCount)`n- Passed: $passed`n- Failed: $failed`n- Skipped: $skipped`n"
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SummaryPath))) | Out-Null
            [IO.File]::AppendAllText($SummaryPath, $markdown, [Text.UTF8Encoding]::new($false))
        }
        return $aggregate
    }
    catch {
        [IO.Directory]::CreateDirectory($resolvedRoot) | Out-Null
        $failure = [pscustomobject][ordered]@{ schemaVersion=2; status='failed'; platform=$PlatformId; error=[string]$_.Exception.Message }
        [IO.File]::WriteAllText($resultPath, ($failure | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
        throw
    }
}

if (-not $DefineFunctionsOnly) {
    Invoke-UnixCoreAggregateAssertion -Root $AggregateRoot -PlatformId $Platform `
        -PlanSha256 $ExpectedPlanSha256 -PlanRunAttempt $ExpectedPlanRunAttempt `
        -PlanJobResult $PlanResult -AuthorityJobResult $AuthorityResult -PesterJobResult $PesterResult `
        -WorkflowRunId $RunId -WorkflowRunAttempt $CurrentRunAttempt -SummaryPath $StepSummaryPath | Out-Null
}
