# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Untrusted, read-only diagnostic producer. The protected workflow verifies
# these bytes independently; a passing report never grants CI admission.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRevision,
    [Parameter(Mandatory = $true)][string] $AuthorityRevision,
    [Parameter(Mandatory = $true)][long] $RunId,
    [Parameter(Mandatory = $true)][int] $RunAttempt,
    [Parameter(Mandatory = $true)][string] $OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($CandidateRevision -cnotmatch '^[0-9a-f]{40}$' -or
    $AuthorityRevision -cnotmatch '^[0-9a-f]{40}$' -or
    $RunId -lt 1 -or $RunAttempt -lt 1) {
    throw 'Invalid diagnostic producer identity.'
}
$sourceRoot = Split-Path -Parent $PSScriptRoot
$testPath = Join-Path $sourceRoot 'tests/skill-repository-workflows.Tests.ps1'
if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw 'Fixed workflow contract test file is missing.'
}
$destination = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $destination) { throw 'Diagnostic output root must be new.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $destination) -PathType Container)) {
    throw 'Diagnostic output parent is missing.'
}
$workflowIds = @(
    'UnitT10_pins_every_checkout_and_disables_persisted_credentials',
    'UnitT15_runs_linux_callback_containment_before_full_suites_and_authority_gate',
    'UnitT20_runs_dedicated_authority_CI_for_every_authority_file_and_bridge_change',
    'UnitT30_checks_the_actual_event_commit_range_instead_of_an_empty_main_range',
    'UnitT40_routes_managed_lifecycle_changes_through_the_central_authority_gate',
    'UnitT50_routes_upstream_interoperability_changes_through_the_central_authority_gate',
    'UnitT60_routes_validation_security_gate_changes_through_the_central_authority_gate',
    'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles'
)
Remove-Module Pester -Force -ErrorAction SilentlyContinue
$pester = Get-Module Pester -ListAvailable |
    Where-Object { $_.Version -eq [version]'4.10.1' } | Select-Object -First 1
if ($null -eq $pester) { throw 'Pester 4.10.1 is unavailable.' }
Import-Module $pester.Path -Force
$run = Invoke-Pester -Script $testPath -PassThru -Show Summary
if ($null -eq $run -or $run.TotalCount -ne $workflowIds.Count -or
    $run.PassedCount -ne $workflowIds.Count -or $run.FailedCount -ne 0 -or
    $run.SkippedCount -ne 0 -or $run.PendingCount -ne 0 -or
    $run.InconclusiveCount -ne 0) {
    throw 'Fixed workflow contract suite did not pass in full.'
}
$observed = @($run.TestResult | ForEach-Object { [string]$_.Name })
if ($observed.Count -ne $workflowIds.Count -or
    ($observed | Sort-Object -CaseSensitive) -join "`n" -cne
    (($workflowIds | Sort-Object -CaseSensitive) -join "`n")) {
    throw 'Pester test IDs differ from the fixed diagnostic inventory.'
}
$workflowResults = @($run.TestResult | ForEach-Object {
    [ordered]@{ id = [string]$_.Name; result = [string]$_.Result }
})
$maintenanceIds = @(
    'UnitT03_rejects_wrong_candidate_maintenance_report_from_protected_inputs',
    'UnitT50_binds_injected_maintenance_metadata_and_rejects_cross_run_or_archive_drift'
)
Remove-Module Pester -Force -ErrorAction SilentlyContinue
$maintenancePester = Get-Module Pester -ListAvailable |
    Where-Object { $_.Version -eq [version]'5.9.0' } | Select-Object -First 1
if ($null -eq $maintenancePester) { throw 'Pester 5.9.0 is unavailable.' }
Import-Module $maintenancePester.Path -Force
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $sourceRoot 'tests/standard-validation-runner.Tests.ps1'
$configuration.Filter.FullName = @($maintenanceIds | ForEach-Object { "*$_" })
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Minimal'
$maintenance = Invoke-Pester -Configuration $configuration
if ($null -eq $maintenance -or $maintenance.TotalCount -ne 51 -or
    $maintenance.PassedCount -ne $maintenanceIds.Count -or
    $maintenance.NotRunCount -ne 49 -or $maintenance.FailedCount -ne 0 -or
    $maintenance.SkippedCount -ne 0) {
    throw 'Fixed maintenance behavior tests did not pass in full.'
}
$expected = @($workflowIds) + @($maintenanceIds)
$raw = [ordered]@{
    schemaVersion = 1
    runner = 'Pester 4.10.1 and 5.9.0'
    total = [int]$expected.Count
    passed = [int]$expected.Count
    failed = 0
    skipped = 0
    tests = @($workflowResults) + @($maintenanceIds | ForEach-Object {
        [ordered]@{ id = $_; result = 'Passed' }
    })
}
$utf8 = New-Object Text.UTF8Encoding($false)
$resultsBytes = $utf8.GetBytes(($raw | ConvertTo-Json -Depth 8 -Compress) + "`n")
$sha = [Security.Cryptography.SHA256]::Create()
try { $resultsSha = ([BitConverter]::ToString($sha.ComputeHash($resultsBytes))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
$report = [ordered]@{
    schemaVersion = 1
    evidenceType = 'validator-maintenance-report-v1'
    status = 'passed'
    candidateRevision = $CandidateRevision
    authorityRevision = $AuthorityRevision
    eventName = 'pull_request'
    runId = ('{0:x32}' -f $RunId)
    runAttempt = $RunAttempt
    resultsSha256 = $resultsSha
    tests = @($expected | ForEach-Object { [ordered]@{ id = $_; status = 'passed' } })
    releaseEligible = $false
}
$reportBytes = $utf8.GetBytes(($report | ConvertTo-Json -Depth 8 -Compress) + "`n")
[void](New-Item -ItemType Directory -Path $destination -ErrorAction Stop)
[IO.File]::WriteAllBytes((Join-Path $destination 'results.json'), $resultsBytes)
[IO.File]::WriteAllBytes((Join-Path $destination 'report.json'), $reportBytes)
return [pscustomobject]@{
    status = 'untrusted-maintenance-producer'
    resultsSha256 = $resultsSha
    ciAdmission = 'BLOCKED'
    releaseEligible = $false
}
