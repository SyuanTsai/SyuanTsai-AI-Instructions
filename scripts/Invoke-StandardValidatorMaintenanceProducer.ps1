# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Untrusted, read-only manual diagnostic producer; a passing report never
# grants CI admission or release eligibility.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRevision,
    [Parameter(Mandatory = $true)][string] $AuthorityRevision,
    [Parameter(Mandatory = $true)][ValidateSet('workflow_dispatch')][string] $EventName,
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
    'UnitT15_ordinary_workflows_use_verified_Windows_PowerShell_only',
    'UnitT16_plans_dynamic_inventory_with_exact_four_partition_coverage',
    'UnitT17_rejects_empty_or_untruthful_summary_counts',
    'UnitT20_keeps_two_Windows_PR_jobs_and_single_authority_gate',
    'UnitT30_checks_the_actual_event_commit_range_and_manual_commit',
    'UnitT40_routes_managed_lifecycle_changes_through_the_central_authority_gate',
    'UnitT50_keeps_upstream_interoperability_source_regressions_in_authority_ci',
    'UnitT60_checks_validation_security_policy_without_restoring_external_gate_chain',
    'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles',
    'UnitT71_accepts_markdown_setup_and_diagnostics_outside_release_admission',
    'UnitT72_rejects_release_command_with_only_an_unrelated_canonical_section',
    'UnitT73_rejects_workflow_replacement_of_the_canonical_validator',
    'UnitT74_accepts_release_example_with_fenced_comment',
    'UnitT75_rejects_release_command_with_only_an_unrelated_setext_canonical_section'
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
    'UnitT10_partitions_bulk_tests_into_independent_owned_processes_by_default',
    'InterT13_projects_candidate_bound_source_conformance_and_rejects_incomplete_evidence',
    'rejects_v1_adapter_before_supervisor_gate',
    'keeps tracked identity, safe paths, private exclusion, child failure, timeout, source mutation and output reservation fail-closed'
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
if ($null -eq $maintenance -or $maintenance.PassedCount -ne $maintenanceIds.Count -or
    $maintenance.TotalCount -ne ($maintenance.PassedCount + $maintenance.NotRunCount + $maintenance.FailedCount + $maintenance.SkippedCount) -or
    $maintenance.FailedCount -ne 0 -or $maintenance.SkippedCount -ne 0) {
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
    eventName = $EventName
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
