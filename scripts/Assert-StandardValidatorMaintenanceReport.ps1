# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Read-only, protected-side binding check for a low-privilege validator maintenance
# report. This candidate never grants canonical CI admission or release eligibility.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ReportPath,
    [Parameter(Mandatory = $true)][string] $ResultsPath,
    [Parameter(Mandatory = $true)][string] $ExpectedReportSha256,
    [Parameter(Mandatory = $true)][string] $ExpectedResultsSha256,
    [Parameter(Mandatory = $true)][string] $ExpectedCandidateRevision,
    [Parameter(Mandatory = $true)][string] $ExpectedAuthorityRevision,
    [Parameter(Mandatory = $true)][string] $ExpectedEventName,
    [Parameter(Mandatory = $true)][string] $ExpectedRunId,
    [Parameter(Mandatory = $true)][int] $ExpectedRunAttempt,
    [Parameter(Mandatory = $true)][string[]] $ExpectedTestIds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-MaintenanceShape {
    param([Parameter(Mandatory = $true)] $Value,
          [Parameter(Mandatory = $true)][string[]] $Names,
          [Parameter(Mandatory = $true)][string] $Context)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "BLOCKED|$Context must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw "BLOCKED|$Context has an unexpected property count." }
    foreach ($name in $Names) {
        if (-not ($actual -ccontains $name)) { throw "BLOCKED|$Context is missing exact property '$name'." }
    }
}

function Get-MaintenanceSnapshot {
    param([Parameter(Mandatory = $true)][string] $Path,
          [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "BLOCKED|$Context is missing."
    }
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    return [pscustomobject]@{ bytes = $bytes; sha256 = $digest }
}

foreach ($binding in @(
    [pscustomobject]@{ name = 'report SHA'; value = $ExpectedReportSha256; regex = '^[0-9a-f]{64}$' },
    [pscustomobject]@{ name = 'results SHA'; value = $ExpectedResultsSha256; regex = '^[0-9a-f]{64}$' },
    [pscustomobject]@{ name = 'candidate revision'; value = $ExpectedCandidateRevision; regex = '^[0-9a-f]{40}$' },
    [pscustomobject]@{ name = 'authority revision'; value = $ExpectedAuthorityRevision; regex = '^[0-9a-f]{40}$' },
    [pscustomobject]@{ name = 'run ID'; value = $ExpectedRunId; regex = '^[0-9a-f]{32}$' }
)) {
    if ([string]$binding.value -cnotmatch [string]$binding.regex) {
        throw "BLOCKED|Protected expected $($binding.name) is invalid."
    }
}
if ($ExpectedRunAttempt -lt 1 -or [string]::IsNullOrWhiteSpace($ExpectedEventName) -or
    $ExpectedTestIds.Count -eq 0) {
    throw 'BLOCKED|Protected event, attempt or required test inventory is invalid.'
}
$requiredIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($id in $ExpectedTestIds) {
    if ([string]::IsNullOrWhiteSpace($id) -or -not $requiredIds.Add($id)) {
        throw 'BLOCKED|Protected required test inventory contains an empty or duplicate ID.'
    }
}
if ([IO.Path]::GetFullPath($ReportPath) -ceq [IO.Path]::GetFullPath($ResultsPath)) {
    throw 'BLOCKED|Report and raw results must be separate artifacts.'
}
$reportSnapshot = Get-MaintenanceSnapshot -Path $ReportPath -Context 'Maintenance report'
$resultsSnapshot = Get-MaintenanceSnapshot -Path $ResultsPath -Context 'Raw maintenance results'
if ($reportSnapshot.sha256 -cne $ExpectedReportSha256 -or
    $resultsSnapshot.sha256 -cne $ExpectedResultsSha256) {
    throw 'BLOCKED|Protected expected artifact digest does not match the retained bytes.'
}
try {
    $utf8 = New-Object Text.UTF8Encoding -ArgumentList @($false, $true)
    $report = ConvertFrom-Json -InputObject ($utf8.GetString($reportSnapshot.bytes))
}
catch { throw "BLOCKED|Maintenance report is not valid UTF-8 JSON: $($_.Exception.Message)" }
Assert-MaintenanceShape -Value $report -Names @(
    'schemaVersion', 'evidenceType', 'status', 'candidateRevision', 'authorityRevision',
    'eventName', 'runId', 'runAttempt', 'resultsSha256', 'tests', 'releaseEligible'
) -Context 'Maintenance report'
if ($report.schemaVersion -isnot [int] -and $report.schemaVersion -isnot [long]) {
    throw 'BLOCKED|Maintenance report schema version must be an integer.'
}
if ([int]$report.schemaVersion -ne 1 -or [string]$report.evidenceType -cne 'validator-maintenance-report-v1' -or
    [string]$report.status -cne 'passed' -or $report.releaseEligible -isnot [bool] -or $report.releaseEligible) {
    throw 'BLOCKED|Maintenance report cannot establish a valid non-release test result.'
}
if ([string]$report.candidateRevision -cne $ExpectedCandidateRevision) {
    throw 'BLOCKED|Maintenance report candidate revision differs from the protected event.'
}
if ([string]$report.authorityRevision -cne $ExpectedAuthorityRevision -or
    [string]$report.eventName -cne $ExpectedEventName -or
    [string]$report.runId -cne $ExpectedRunId -or
    ($report.runAttempt -isnot [int] -and $report.runAttempt -isnot [long]) -or
    [int]$report.runAttempt -ne $ExpectedRunAttempt -or
    [string]$report.resultsSha256 -cne $ExpectedResultsSha256) {
    throw 'BLOCKED|Maintenance report authority, event, attempt or result binding differs from protected inputs.'
}
if ($report.tests -isnot [array] -or @($report.tests).Count -ne $requiredIds.Count) {
    throw 'BLOCKED|Maintenance report test coverage differs from the protected inventory.'
}
$observedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($test in $report.tests) {
    Assert-MaintenanceShape -Value $test -Names @('id', 'status') -Context 'Maintenance test record'
    if ($test.id -isnot [string] -or -not $requiredIds.Contains($test.id) -or
        -not $observedIds.Add($test.id) -or $test.status -isnot [string] -or
        $test.status -cne 'passed') {
        throw 'BLOCKED|Maintenance report contains missing, duplicate or nonpassing test coverage.'
    }
}

return [pscustomobject][ordered]@{
    schemaVersion = 1
    status = 'verified-local-binding'
    candidateRevision = $ExpectedCandidateRevision
    reportSha256 = $reportSnapshot.sha256
    resultsSha256 = $resultsSnapshot.sha256
    ciAdmission = 'BLOCKED'
    releaseEligible = $false
}
