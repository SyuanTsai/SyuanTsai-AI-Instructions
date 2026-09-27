# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

# Protected-caller diagnostic acquisition candidate. The caller owns the saved
# event, expected identities, token and output root. Nothing here grants CI admission.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $EventPath,
    [Parameter(Mandatory = $true)][string] $RepositoryFullName,
    [Parameter(Mandatory = $true)][long] $RepositoryId,
    [Parameter(Mandatory = $true)][long] $WorkflowId,
    [Parameter(Mandatory = $true)][long] $RunId,
    [Parameter(Mandatory = $true)][int] $RunAttempt,
    [Parameter(Mandatory = $true)][long] $PullRequestNumber,
    [Parameter(Mandatory = $true)][string] $AuthorityRevision,
    [Parameter(Mandatory = $true)][string[]] $TestIds,
    [Parameter(Mandatory = $true)][Security.SecureString] $AccessToken,
    [Parameter(Mandatory = $true)][string] $OutputRoot,
    # Only a protected test caller may inject this transport. It is never read
    # from the candidate, the event payload, or a fetched response.
    [scriptblock] $Transport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-MaintenanceAcquisitionEqual {
    param($Actual, $Expected, [string] $Context)
    if ($null -eq $Actual -or [string]$Actual -cne [string]$Expected) {
        throw "BLOCKED|$Context differs from the protected invocation."
    }
}

function Get-MaintenanceAcquisitionProperty {
    param($Object, [string] $Name, [string] $Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject] -or
        $null -eq $Object.PSObject.Properties[$Name]) {
        throw "BLOCKED|$Context is missing $Name."
    }
    return $Object.PSObject.Properties[$Name].Value
}

function ConvertFrom-MaintenanceAcquisitionJson {
    param([byte[]] $Bytes, [string] $Context)
    $utf8 = New-Object Text.UTF8Encoding -ArgumentList @($false, $true)
    try { return ConvertFrom-Json -InputObject ($utf8.GetString($Bytes)) }
    catch { throw "BLOCKED|$Context is not UTF-8 JSON: $($_.Exception.Message)" }
}

function Assert-MaintenanceAcquisitionNewRoot {
    param([string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'BLOCKED|Diagnostic evidence root has a reparse-point ancestor.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([IO.Path]::DirectorySeparatorChar))
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent
    }
    if (Test-Path -LiteralPath $full) { throw 'BLOCKED|Diagnostic evidence root must be new.' }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($full)) -PathType Container)) {
        throw 'BLOCKED|Diagnostic evidence parent directory is missing.'
    }
    return $full
}

function Write-MaintenanceAcquisitionNewFile {
    param([string] $Path, [byte[]] $Bytes)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length) }
    finally { $stream.Dispose() }
}

function Invoke-MaintenanceAcquisitionDefaultTransport {
    param([string] $Uri, [hashtable] $Headers, [int] $MaximumBytes, [int] $DeadlineMilliseconds = 30000)
    if ($DeadlineMilliseconds -lt 1) { throw 'BLOCKED|HTTP deadline is invalid.' }
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = New-Object Net.Http.HttpClient($handler)
    # ResponseHeadersRead ends HttpClient.Timeout coverage when headers arrive.
    # One stopwatch bounds headers, stream creation and every body read together.
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $deadline = New-Object Threading.CancellationTokenSource
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $deadline.CancelAfter($DeadlineMilliseconds)
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, ([uri]$Uri))
    $response = $null
    $stream = $null
    $buffered = $null
    try {
        foreach ($name in $Headers.Keys) {
            if (-not $request.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name])) {
                throw 'BLOCKED|A required HTTP request header could not be set.'
            }
        }
        $sendTask = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token)
        $remaining = $DeadlineMilliseconds - [int]$watch.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $sendTask.Wait($remaining)) { throw 'BLOCKED|HTTP response exceeded the time quota.' }
        $response = $sendTask.GetAwaiter().GetResult()
        $buffered = New-Object IO.MemoryStream
        if ($null -ne $response.Content) {
            if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $MaximumBytes) {
                throw 'BLOCKED|HTTP response exceeds the byte quota.'
            }
            $streamTask = $response.Content.ReadAsStreamAsync()
            $remaining = $DeadlineMilliseconds - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0 -or -not $streamTask.Wait($remaining)) { throw 'BLOCKED|HTTP response exceeded the time quota.' }
            $stream = $streamTask.GetAwaiter().GetResult()
            $buffer = New-Object byte[] 8192
            while ($true) {
                $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token)
                $remaining = $DeadlineMilliseconds - [int]$watch.ElapsedMilliseconds
                if ($remaining -le 0 -or -not $readTask.Wait($remaining)) { throw 'BLOCKED|HTTP response exceeded the time quota.' }
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -le 0) { break }
                if ($buffered.Length + $count -gt $MaximumBytes) { throw 'BLOCKED|HTTP response exceeds the byte quota.' }
                $buffered.Write($buffer, 0, $count)
            }
        }
        $location = if ($null -eq $response.Headers.Location) { $null } else { [string]$response.Headers.Location }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Body = $buffered.ToArray()
            Location = $location
        }
    }
    catch { throw 'BLOCKED|HTTP request failed or exceeded the byte or time quota.' }
    finally {
        $deadline.Cancel()
        if ($null -ne $buffered) { $buffered.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
        $deadline.Dispose()
        $watch.Stop()
    }
}

function Get-MaintenanceAcquisitionResponse {
    param([string] $Uri, [hashtable] $Headers, [int] $MaximumBytes)
    $response = if ($null -eq $Transport) {
        Invoke-MaintenanceAcquisitionDefaultTransport -Uri $Uri -Headers $Headers -MaximumBytes $MaximumBytes
    }
    else { & $Transport $Uri $Headers $MaximumBytes }
    if ($null -eq $response -or $response -isnot [pscustomobject] -or
        $null -eq $response.PSObject.Properties['StatusCode'] -or
        $null -eq $response.PSObject.Properties['Body'] -or
        $null -eq $response.PSObject.Properties['Location'] -or
        $response.Body -isnot [byte[]] -or $response.Body.Length -gt $MaximumBytes) {
        throw 'BLOCKED|HTTP transport returned malformed or oversized evidence.'
    }
    return $response
}

if ($RepositoryFullName -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $RepositoryId -lt 1 -or $WorkflowId -lt 1 -or $RunId -lt 1 -or
    $RunAttempt -lt 1 -or $PullRequestNumber -lt 1 -or
    $AuthorityRevision -cnotmatch '^[0-9a-f]{40}$' -or $TestIds.Count -eq 0) {
    throw 'BLOCKED|Protected maintenance acquisition parameters are invalid.'
}
$evidenceRoot = Assert-MaintenanceAcquisitionNewRoot -Path $OutputRoot
if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) { throw 'BLOCKED|Saved event is missing.' }
$eventItem = Get-Item -LiteralPath $EventPath -Force
if ($eventItem.Length -gt 1048576) { throw 'BLOCKED|Saved event exceeds the byte quota.' }
$eventBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($EventPath))
$event = ConvertFrom-MaintenanceAcquisitionJson -Bytes $eventBytes -Context 'saved event'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $event 'action' 'event') 'completed' 'event action'
$eventRepository = Get-MaintenanceAcquisitionProperty $event 'repository' 'event'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $eventRepository 'id' 'event repository') $RepositoryId 'event repository id'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $eventRepository 'full_name' 'event repository') $RepositoryFullName 'event repository name'
$eventRun = Get-MaintenanceAcquisitionProperty $event 'workflow_run' 'event'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $eventRun 'id' 'event run') $RunId 'event run id'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $eventRun 'run_attempt' 'event run') $RunAttempt 'event run attempt'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $eventRun 'workflow_id' 'event run') $WorkflowId 'event workflow id'
$matchingPr = @((Get-MaintenanceAcquisitionProperty $eventRun 'pull_requests' 'event run') |
    Where-Object { [string]$_.number -ceq [string]$PullRequestNumber })
if ($matchingPr.Count -ne 1) { throw 'BLOCKED|Saved event is not uniquely linked to the protected PR number.' }

$parts = $RepositoryFullName.Split('/')
$apiRoot = "https://api.github.com/repos/$($parts[0])/$($parts[1])"
$tokenText = (New-Object Net.NetworkCredential('', $AccessToken)).Password
if ([string]::IsNullOrWhiteSpace($tokenText) -or $tokenText -match '[\r\n]') {
    throw 'BLOCKED|Actions-read token is empty or malformed.'
}
$apiHeaders = @{
    'Accept' = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'StandardValidatorMaintenanceEvidence'
    'Authorization' = "Bearer $tokenText"
}
$tokenText = $null
function Get-MaintenanceApiJson {
    param([string] $Uri, [string] $Context)
    $response = Get-MaintenanceAcquisitionResponse -Uri $Uri -Headers $apiHeaders -MaximumBytes 1048576
    if ([int]$response.StatusCode -ne 200) { throw "BLOCKED|$Context API response is not HTTP 200." }
    return [pscustomobject]@{
        bytes = $response.Body
        value = ConvertFrom-MaintenanceAcquisitionJson -Bytes $response.Body -Context $Context
    }
}
$runResponse = Get-MaintenanceApiJson -Uri "$apiRoot/actions/runs/$RunId" -Context 'run metadata'
$run = $runResponse.value
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $run 'id' 'run') $RunId 'API run id'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $run 'run_attempt' 'run') $RunAttempt 'API run attempt'
$prResponse = Get-MaintenanceApiJson -Uri "$apiRoot/pulls/$PullRequestNumber" -Context 'PR metadata'
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $prResponse.value 'number' 'PR') $PullRequestNumber 'API PR number'
$listingResponse = Get-MaintenanceApiJson -Uri "$apiRoot/actions/runs/$RunId/artifacts?per_page=100" -Context 'artifact listing'
$listing = $listingResponse.value
$artifacts = @(Get-MaintenanceAcquisitionProperty $listing 'artifacts' 'artifact listing')
Assert-MaintenanceAcquisitionEqual (Get-MaintenanceAcquisitionProperty $listing 'total_count' 'artifact listing') $artifacts.Count 'artifact total count'
if ($artifacts.Count -ne 1 -or [string]$artifacts[0].name -cne "validator-maintenance-$RunId-$RunAttempt") {
    throw 'BLOCKED|Expected exactly one run-attempt maintenance artifact.'
}
$artifactId = [long](Get-MaintenanceAcquisitionProperty $artifacts[0] 'id' 'artifact')
if ($artifactId -lt 1) { throw 'BLOCKED|Artifact id is invalid.' }
$archiveResponse = Get-MaintenanceAcquisitionResponse -Uri "$apiRoot/actions/artifacts/$artifactId/zip" -Headers $apiHeaders -MaximumBytes 1048576
[void]$apiHeaders.Remove('Authorization')
if ([int]$archiveResponse.StatusCode -ne 302 -or [string]::IsNullOrWhiteSpace([string]$archiveResponse.Location)) {
    throw 'BLOCKED|Artifact API did not provide an HTTP 302 download redirect.'
}
$redirectUri = $null
if (-not [uri]::TryCreate([string]$archiveResponse.Location, [UriKind]::Absolute, [ref]$redirectUri) -or
    $redirectUri.Scheme -cne 'https' -or -not [string]::IsNullOrEmpty($redirectUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($redirectUri.Fragment) -or
    $redirectUri.Host -cnotmatch '(^|\.)(blob\.core\.windows\.net|actions\.githubusercontent\.com)$') {
    throw 'BLOCKED|Artifact redirect host or URL is not approved.'
}
# The storage request receives no bearer token and cannot follow another redirect.
$storageHeaders = @{ 'User-Agent' = 'StandardValidatorMaintenanceEvidence' }
$zipResponse = Get-MaintenanceAcquisitionResponse -Uri $redirectUri.AbsoluteUri -Headers $storageHeaders -MaximumBytes 4194304
if ([int]$zipResponse.StatusCode -ne 200 -or $zipResponse.Body.Length -lt 1) {
    throw 'BLOCKED|Artifact storage response is not a nonempty HTTP 200 ZIP.'
}
[void](New-Item -ItemType Directory -Path $evidenceRoot -ErrorAction Stop)
$eventCopy = Join-Path $evidenceRoot 'event.json'
$runPath = Join-Path $evidenceRoot 'run.json'
$prPath = Join-Path $evidenceRoot 'pr.json'
$listingPath = Join-Path $evidenceRoot 'artifacts.json'
$zipPath = Join-Path $evidenceRoot 'artifact.zip'
Write-MaintenanceAcquisitionNewFile -Path $eventCopy -Bytes $eventBytes
Write-MaintenanceAcquisitionNewFile -Path $runPath -Bytes $runResponse.bytes
Write-MaintenanceAcquisitionNewFile -Path $prPath -Bytes $prResponse.bytes
Write-MaintenanceAcquisitionNewFile -Path $listingPath -Bytes $listingResponse.bytes
Write-MaintenanceAcquisitionNewFile -Path $zipPath -Bytes $zipResponse.Body
$verification = & (Join-Path $PSScriptRoot 'Assert-StandardValidatorMaintenanceInputs.ps1') `
    -EventPath $eventCopy -RunMetadataPath $runPath -PullRequestMetadataPath $prPath `
    -ArtifactsMetadataPath $listingPath -ArtifactZipPath $zipPath `
    -ExpectedRepositoryFullName $RepositoryFullName -ExpectedRepositoryId $RepositoryId `
    -ExpectedWorkflowId $WorkflowId -ExpectedAuthorityRevision $AuthorityRevision `
    -ExpectedTestIds $TestIds -OutputRoot (Join-Path $evidenceRoot 'verification')
return [pscustomobject][ordered]@{
    status = 'diagnostic-acquisition-binding'
    transportKind = if ($null -eq $Transport) { 'api' } else { 'injected' }
    candidateRevision = $verification.candidateRevision
    runHeadSha = $verification.runHeadSha
    archiveSha256 = $verification.archiveSha256
    verifierStatus = $verification.verifierStatus
    evidenceRoot = $evidenceRoot
    ciAdmission = 'BLOCKED'
    releaseEligible = $false
}
