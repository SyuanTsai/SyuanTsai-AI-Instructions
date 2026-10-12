# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Diagnostic protected-caller entry point. The workflow must supply its own
# saved event, repository/workflow identity, token and new output root.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $EventName,
    [Parameter(Mandatory = $true)][string] $EventPath,
    [Parameter(Mandatory = $true)][string] $RepositoryFullName,
    [Parameter(Mandatory = $true)][long] $RepositoryId,
    [Parameter(Mandatory = $true)][long] $WorkflowId,
    [Parameter(Mandatory = $true)][string] $AuthorityRevision,
    [Parameter(Mandatory = $true)][string[]] $TestIds,
    [Parameter(Mandatory = $true)][Security.SecureString] $AccessToken,
    [Parameter(Mandatory = $true)][string] $OutputRoot,
    [scriptblock] $Transport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($EventName -cne 'workflow_run') { throw 'BLOCKED|Protected consumer requires a workflow_run event.' }
if ($RepositoryFullName -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $RepositoryId -lt 1 -or $WorkflowId -lt 1 -or
    $AuthorityRevision -cnotmatch '^[0-9a-f]{40}$' -or $TestIds.Count -lt 1) {
    throw 'BLOCKED|Protected consumer identity or authority parameters are invalid.'
}
if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) { throw 'BLOCKED|Protected saved event is missing.' }
$eventItem = Get-Item -LiteralPath $EventPath -Force -ErrorAction Stop
if ($eventItem.Length -lt 1 -or $eventItem.Length -gt 1048576) {
    throw 'BLOCKED|Protected saved event exceeds the byte quota.'
}
$utf8 = New-Object Text.UTF8Encoding -ArgumentList @($false, $true)
try { $event = ConvertFrom-Json -InputObject ($utf8.GetString([IO.File]::ReadAllBytes($eventItem.FullName))) }
catch { throw 'BLOCKED|Protected saved event is not UTF-8 JSON.' }
if ($null -eq $event -or $null -eq $event.PSObject.Properties['action'] -or
    [string]$event.action -cne 'completed' -or
    $null -eq $event.PSObject.Properties['repository'] -or
    $null -eq $event.PSObject.Properties['workflow_run']) {
    throw 'BLOCKED|Protected saved event lacks a completed workflow run.'
}
$repository = $event.repository
$run = $event.workflow_run
if ($null -eq $repository -or $null -eq $repository.PSObject.Properties['id'] -or
    $null -eq $repository.PSObject.Properties['full_name'] -or
    [string]$repository.id -cne [string]$RepositoryId -or
    [string]$repository.full_name -cne $RepositoryFullName -or
    $null -eq $run -or $null -eq $run.PSObject.Properties['id'] -or
    $null -eq $run.PSObject.Properties['run_attempt'] -or
    $null -eq $run.PSObject.Properties['workflow_id'] -or
    $null -eq $run.PSObject.Properties['pull_requests'] -or
    [string]$run.workflow_id -cne [string]$WorkflowId) {
    throw 'BLOCKED|Protected saved event differs from the invocation identity.'
}
$runId = [long]$run.id
$runAttempt = [int]$run.run_attempt
$pullRequests = @($run.pull_requests)
if ($runId -lt 1 -or $runAttempt -lt 1 -or $pullRequests.Count -ne 1 -or
    $null -eq $pullRequests[0] -or $null -eq $pullRequests[0].PSObject.Properties['number']) {
    throw 'BLOCKED|Protected saved event lacks one valid PR run.'
}
$prNumber = [long]$pullRequests[0].number
if ($prNumber -lt 1) { throw 'BLOCKED|Protected saved event PR number is invalid.' }

$acquired = & (Join-Path $PSScriptRoot 'Get-StandardValidatorMaintenanceEvidence.ps1') `
    -EventPath $eventItem.FullName -RepositoryFullName $RepositoryFullName `
    -RepositoryId $RepositoryId -WorkflowId $WorkflowId `
    -RunId $runId -RunAttempt $runAttempt -PullRequestNumber $prNumber `
    -AuthorityRevision $AuthorityRevision -TestIds $TestIds `
    -AccessToken $AccessToken -OutputRoot $OutputRoot -Transport $Transport
return [pscustomobject][ordered]@{
    status = 'protected-consumer-diagnostic'
    transportKind = $acquired.transportKind
    runId = $runId
    runAttempt = $runAttempt
    pullRequestNumber = $prNumber
    evidenceRoot = $acquired.evidenceRoot
    verifierStatus = $acquired.verifierStatus
    ciAdmission = 'BLOCKED'
    releaseEligible = $false
}
