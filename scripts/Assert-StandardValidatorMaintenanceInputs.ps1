# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Diagnostic binding of injected workflow_run, run, PR and artifact snapshots.
# The caller must establish custody of these snapshots and downloaded ZIP separately.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $EventPath,
    [Parameter(Mandatory = $true)][string] $RunMetadataPath,
    [Parameter(Mandatory = $true)][string] $PullRequestMetadataPath,
    [Parameter(Mandatory = $true)][string] $ArtifactsMetadataPath,
    [Parameter(Mandatory = $true)][string] $ArtifactZipPath,
    [Parameter(Mandatory = $true)][string] $ExpectedRepositoryFullName,
    [Parameter(Mandatory = $true)][long] $ExpectedRepositoryId,
    [Parameter(Mandatory = $true)][long] $ExpectedWorkflowId,
    [Parameter(Mandatory = $true)][string] $ExpectedAuthorityRevision,
    [Parameter(Mandatory = $true)][string[]] $ExpectedTestIds,
    [Parameter(Mandatory = $true)][string] $OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MaintenanceRequiredProperty {
    param($Object, [string] $Name, [string] $Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject] -or
        $null -eq $Object.PSObject.Properties[$Name]) {
        throw "BLOCKED|$Context is missing $Name."
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Read-MaintenanceInjectedJson {
    param([string] $Path, [string] $Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "BLOCKED|$Context is missing." }
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw "BLOCKED|$Context exceeds the snapshot quota." }
    $utf8 = New-Object Text.UTF8Encoding -ArgumentList @($false, $true)
    try { return ConvertFrom-Json -InputObject ($utf8.GetString([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path)))) }
    catch { throw "BLOCKED|$Context is not UTF-8 JSON: $($_.Exception.Message)" }
}

function Assert-MaintenanceEqual {
    param($Actual, $Expected, [string] $Context)
    if ($null -eq $Actual -or [string]$Actual -cne [string]$Expected) {
        throw "BLOCKED|$Context differs from injected expected metadata."
    }
}

function Assert-MaintenanceRepository {
    param($Repository, [string] $Context)
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $Repository 'id' $Context) $ExpectedRepositoryId "$Context id"
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $Repository 'full_name' $Context) $ExpectedRepositoryFullName "$Context full name"
}

if ($ExpectedRepositoryId -lt 1 -or $ExpectedWorkflowId -lt 1 -or
    $ExpectedRepositoryFullName -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $ExpectedAuthorityRevision -cnotmatch '^[0-9a-f]{40}$' -or $ExpectedTestIds.Count -eq 0) {
    throw 'BLOCKED|Protected issuer parameters are invalid.'
}
$event = Read-MaintenanceInjectedJson $EventPath 'Saved workflow event'
$run = Read-MaintenanceInjectedJson $RunMetadataPath 'Saved run metadata'
$pr = Read-MaintenanceInjectedJson $PullRequestMetadataPath 'Saved PR metadata'
$listing = Read-MaintenanceInjectedJson $ArtifactsMetadataPath 'Saved artifact metadata'

Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $event 'action' 'event') 'completed' 'event action'
Assert-MaintenanceRepository (Get-MaintenanceRequiredProperty $event 'repository' 'event') 'event repository'
$eventRun = Get-MaintenanceRequiredProperty $event 'workflow_run' 'event'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $eventRun 'id' 'event run') (Get-MaintenanceRequiredProperty $run 'id' 'run') 'run id'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $eventRun 'run_attempt' 'event run') (Get-MaintenanceRequiredProperty $run 'run_attempt' 'run') 'run attempt'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $eventRun 'head_sha' 'event run') (Get-MaintenanceRequiredProperty $run 'head_sha' 'run') 'run head SHA'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $eventRun 'workflow_id' 'event run') $ExpectedWorkflowId 'event workflow id'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $run 'workflow_id' 'run') $ExpectedWorkflowId 'run workflow id'
Assert-MaintenanceRepository (Get-MaintenanceRequiredProperty $eventRun 'repository' 'event run') 'event run repository'
Assert-MaintenanceRepository (Get-MaintenanceRequiredProperty $run 'repository' 'run') 'run repository'
foreach ($metadata in @($eventRun, $run)) {
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $metadata 'event' 'run') 'pull_request' 'run event'
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $metadata 'status' 'run') 'completed' 'run status'
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $metadata 'conclusion' 'run') 'success' 'run conclusion'
}
$maintenanceRunId = [long](Get-MaintenanceRequiredProperty $run 'id' 'run')
$attempt = [int](Get-MaintenanceRequiredProperty $run 'run_attempt' 'run')
$runHead = [string](Get-MaintenanceRequiredProperty $run 'head_sha' 'run')
if ($maintenanceRunId -lt 1 -or $attempt -lt 1 -or $runHead -cnotmatch '^[0-9a-f]{40}$') {
    throw 'BLOCKED|Run identity is invalid.'
}
$prNumber = [long](Get-MaintenanceRequiredProperty $pr 'number' 'PR')
if ($prNumber -lt 1) { throw 'BLOCKED|PR number is invalid.' }
Assert-MaintenanceRepository (Get-MaintenanceRequiredProperty (Get-MaintenanceRequiredProperty $pr 'base' 'PR') 'repo' 'PR base') 'PR base repository'
$prHead = Get-MaintenanceRequiredProperty $pr 'head' 'PR'
$candidateRevision = [string](Get-MaintenanceRequiredProperty $prHead 'sha' 'PR head')
if ($candidateRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'BLOCKED|PR head revision is invalid.' }
$headRepo = Get-MaintenanceRequiredProperty $prHead 'repo' 'PR head'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $headRepo 'id' 'PR head repository') (Get-MaintenanceRequiredProperty (Get-MaintenanceRequiredProperty $run 'head_repository' 'run') 'id' 'run head repository') 'head repository id'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $headRepo 'full_name' 'PR head repository') (Get-MaintenanceRequiredProperty (Get-MaintenanceRequiredProperty $run 'head_repository' 'run') 'full_name' 'run head repository') 'head repository name'
foreach ($snapshot in @(
    [pscustomobject]@{ value = $eventRun; context = 'event run' },
    [pscustomobject]@{ value = $run; context = 'run' }
)) {
    $links = @(Get-MaintenanceRequiredProperty $snapshot.value 'pull_requests' $snapshot.context)
    $matches = @($links | Where-Object { [string]$_.number -ceq [string]$prNumber })
    if ($matches.Count -ne 1) { throw "BLOCKED|$($snapshot.context) is not uniquely linked to the PR." }
    $frozenHead = Get-MaintenanceRequiredProperty $matches[0] 'head' "$($snapshot.context) PR linkage"
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $frozenHead 'sha' "$($snapshot.context) PR head") $candidateRevision "$($snapshot.context) frozen PR head SHA"
    $frozenRepository = Get-MaintenanceRequiredProperty $frozenHead 'repo' "$($snapshot.context) PR head"
    Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $frozenRepository 'id' "$($snapshot.context) PR head repository") (Get-MaintenanceRequiredProperty $headRepo 'id' 'PR head repository') "$($snapshot.context) frozen PR head repository id"
}

$artifacts = @(Get-MaintenanceRequiredProperty $listing 'artifacts' 'artifact listing')
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $listing 'total_count' 'artifact listing') $artifacts.Count 'artifact count'
$artifactName = "validator-maintenance-$maintenanceRunId-$attempt"
$selected = @($artifacts | Where-Object { $_.name -ceq $artifactName })
if ($selected.Count -ne 1 -or $artifacts.Count -ne 1) {
    throw 'BLOCKED|Expected one unique maintenance artifact for this run attempt.'
}
$artifact = $selected[0]
if ((Get-MaintenanceRequiredProperty $artifact 'expired' 'artifact') -isnot [bool] -or $artifact.expired) {
    throw 'BLOCKED|Artifact is expired or has invalid expiry metadata.'
}
$artifactRun = Get-MaintenanceRequiredProperty $artifact 'workflow_run' 'artifact'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $artifactRun 'id' 'artifact run') $maintenanceRunId 'artifact run id'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $artifactRun 'repository_id' 'artifact run') $ExpectedRepositoryId 'artifact repository id'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $artifactRun 'head_repository_id' 'artifact run') (Get-MaintenanceRequiredProperty $headRepo 'id' 'PR head repository') 'artifact head repository id'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $artifactRun 'head_sha' 'artifact run') $runHead 'artifact run head SHA'

if (-not (Test-Path -LiteralPath $ArtifactZipPath -PathType Leaf)) { throw 'BLOCKED|Downloaded artifact ZIP is missing.' }
$archiveSize = (Get-Item -LiteralPath $ArtifactZipPath).Length
if ($archiveSize -gt 4194304 -or $archiveSize -lt 1) { throw 'BLOCKED|Artifact ZIP exceeds the archive quota.' }
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $artifact 'size_in_bytes' 'artifact') $archiveSize 'artifact archive size'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path $PSScriptRoot 'Invoke-StandardValidation.ps1'
. $runnerPath -DefineFunctionsOnly -CandidateRoot $repositoryRoot -AdapterPath $runnerPath `
    -ArtifactsRoot $OutputRoot -SourceRepository 'https://example.com/diagnostic.git' `
    -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -EventName 'local'
$archiveSha = Get-StandardValidationFileSha256 -Path $ArtifactZipPath -Context 'injected artifact ZIP'
Assert-MaintenanceEqual (Get-MaintenanceRequiredProperty $artifact 'digest' 'artifact') "sha256:$archiveSha" 'artifact digest'

# Preflight quotas precede the shared safe archive extractor.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArtifactZipPath))
try {
    if ($zip.Entries.Count -ne 2) { throw 'BLOCKED|Maintenance ZIP must contain exactly two files.' }
    foreach ($entry in $zip.Entries) {
        if ($entry.Length -gt 1048576) { throw 'BLOCKED|Maintenance ZIP entry exceeds the file quota.' }
    }
}
finally { $zip.Dispose() }
$OutputRoot = Assert-StandardValidationCanonicalRootPath -Path $OutputRoot -Context 'maintenance extraction root'
if (Test-Path -LiteralPath $OutputRoot) { throw 'BLOCKED|Maintenance extraction root must be new.' }
$extract = Get-StandardValidationArchiveInventory -ArchivePath $ArtifactZipPath `
    -ExtractionRoot $OutputRoot -ArchivePrefix '' -Context 'maintenance artifact'
if ((Get-StandardValidationFileSha256 -Path $ArtifactZipPath -Context 'injected artifact ZIP revalidation') -cne $archiveSha) {
    throw 'BLOCKED|Maintenance ZIP changed during extraction.'
}
$inventory = @($extract.inventory[0])
if ($inventory.Count -ne 2 -or @($inventory | Where-Object { $_.path -ceq 'report.json' }).Count -ne 1 -or
    @($inventory | Where-Object { $_.path -ceq 'results.json' }).Count -ne 1) {
    throw "BLOCKED|Maintenance ZIP contains missing or extra files: count=$($inventory.Count), paths=$(@($inventory | ForEach-Object { $_.path }) -join ',')."
}
$reportPath = Join-Path $OutputRoot 'report.json'
$resultsPath = Join-Path $OutputRoot 'results.json'
$reportSha = Get-StandardValidationFileSha256 -Path $reportPath -Context 'retained maintenance report'
$resultsSha = Get-StandardValidationFileSha256 -Path $resultsPath -Context 'retained raw results'
$verification = & (Join-Path $PSScriptRoot 'Assert-StandardValidatorMaintenanceReport.ps1') `
    -ReportPath $reportPath -ResultsPath $resultsPath `
    -ExpectedReportSha256 $reportSha -ExpectedResultsSha256 $resultsSha `
    -ExpectedCandidateRevision $candidateRevision -ExpectedAuthorityRevision $ExpectedAuthorityRevision `
    -ExpectedEventName 'pull_request' -ExpectedRunId ('{0:x32}' -f $maintenanceRunId) `
    -ExpectedRunAttempt $attempt -ExpectedTestIds $ExpectedTestIds
return [pscustomobject][ordered]@{
    status = 'injected-metadata-binding'
    candidateRevision = $candidateRevision
    runHeadSha = $runHead
    archiveSha256 = $archiveSha
    reportSha256 = $reportSha
    resultsSha256 = $resultsSha
    verifierStatus = $verification.status
    ciAdmission = 'BLOCKED'
    releaseEligible = $false
}
