[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $AdapterPath,
    [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
    [Parameter(Mandatory = $true)][string] $CandidateValidatorPath,
    [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
    [string] $OutputPath,
    [Parameter(Mandatory = $true)][string] $SourceRepository,
    [Parameter(Mandatory = $true)][string] $SourceRevision,
    [Parameter(Mandatory = $true)][string] $BaseRevision,
    [ValidateSet('local', 'pre-push', 'pull_request', 'push', 'workflow_dispatch')]
    [string] $EventName = 'local',
    [AllowEmptyCollection()][string[]] $ValidatorArguments = @(),
    [int] $TimeoutSeconds = 300,
    [int] $CandidateTimeoutSeconds = 0,
    [switch] $CancellationStdin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This entry point is deliberately development-only. It is a trusted central
# launcher for CI1 behavior evidence, not a Standard v1 production gate and it
# has no option that can turn its result into release approval.
$runnerPath = Join-Path $PSScriptRoot 'Invoke-StandardValidation.ps1'
$harnessRunId = [guid]::NewGuid()
$runIdText = $harnessRunId.ToString('N')
$state = 'FAILED'
$exitCode = 20
$failureMessage = 'Development harness did not complete.'
$candidateCodeExecuted = $false
$candidateExecutionAttempted = $false
$barrierProcessResult = $null
$barrierEvidence = $null
    $candidateProcessResult = $null
    $candidateContentSha256 = $null
$candidateValidatorSha256 = $null
    $candidateAdapterSha256 = $null
$validatorArgumentsSha256 = $null
$candidateId = $null
$trustedToolInventorySha256 = $null
$authorityInputRevalidatedAfterCandidate = $false
$authorityInputValidationError = $null
$candidateFull = $null
$adapterFull = $null
$trustedToolRootFull = $null
$artifactRootFull = $null
$launcherPath = $null
$launcherSha256 = $null
$runRoot = $null
$candidateSnapshotRoot = $null
$candidateSnapshotContentSha256 = $null
    $sourceCheckoutMutated = $false
    $sourceCheckoutRevalidatedAfterCandidate = $false
    $sourceCheckoutValidationError = $null
$outputFull = $null
$standardOutputPath = $null
$barrierEvidenceSha256 = $null
$barrierEvidencePostExecutionSha256 = $null
$barrierArtifactInventory = $null
$barrierArtifactInventorySha256 = $null
$barrierArtifactInventoryPostExecutionSha256 = $null
$barrierEvidenceRevalidated = $null
$runnerSha256 = $null
$powerShellSha256 = $null
$outputReservationStream = $null
$outputReservationToken = $null
$candidateArguments = @()
$candidateBarrierStatus = 'not-run'
$barrierStages = @()
$candidateOutcome = [ordered]@{ status = 'not-run'; exitCode = $null; cleanedUp = $true }
$harnessCandidateRoot = [string]$CandidateRoot
$harnessAdapterPath = [string]$AdapterPath
$harnessTrustedToolRoot = [string]$TrustedToolRoot
$harnessCandidateValidatorPath = [string]$CandidateValidatorPath
$harnessArtifactsRoot = [string]$ArtifactsRoot
$harnessOutputPath = [string]$OutputPath
$harnessSourceRepository = [string]$SourceRepository
$harnessSourceRevision = [string]$SourceRevision
$harnessBaseRevision = [string]$BaseRevision
$harnessEventName = [string]$EventName
$harnessValidatorArguments = @($ValidatorArguments)
$harnessTimeoutSeconds = [int]$TimeoutSeconds
$harnessCandidateTimeoutSeconds = if ($CandidateTimeoutSeconds -eq 0) { $harnessTimeoutSeconds } else { [int]$CandidateTimeoutSeconds }
$cancellationInputStream = $null
$cancellationInputTask = $null
$cancellationInputBuffer = New-Object byte[] 1
$cancellationRequested = $false
$cancellationProbe = $null

function Start-DevelopmentHarnessCancellationReader {
    if (-not $CancellationStdin) { return }
    if (-not [Console]::IsInputRedirected) {
        throw 'INVALID|CancellationStdin requires supervisor standard input to be redirected.'
    }
    try {
        $script:cancellationInputStream = [Console]::OpenStandardInput()
        $script:cancellationInputTask = $script:cancellationInputStream.ReadAsync($script:cancellationInputBuffer, 0, 1)
    }
    catch {
        throw "INVALID|Could not initialize the supervisor-only cancellation input: $($_.Exception.Message)"
    }
}

function Test-DevelopmentHarnessCancellationRequested {
    if (-not $CancellationStdin) { return $false }
    if ($script:cancellationRequested) { return $true }
    if ($null -eq $script:cancellationInputTask -or -not $script:cancellationInputTask.IsCompleted) { return $false }
    try {
        $bytesRead = [int]$script:cancellationInputTask.GetAwaiter().GetResult()
        if ($bytesRead -gt 0) { $script:cancellationRequested = $true }
    }
    catch {
        throw "Cancellation input read failed: $($_.Exception.Message)"
    }
    return [bool]$script:cancellationRequested
}

function Stop-DevelopmentHarnessCancellationReader {
    if ($null -ne $script:cancellationInputStream) {
        try { $script:cancellationInputStream.Dispose() } catch { }
        $script:cancellationInputStream = $null
    }
    $script:cancellationInputTask = $null
}

function Get-DevelopmentHarnessFailureClassification {
    param([Parameter(Mandatory = $true)][string] $Message)

    if ($Message -match '(?s)^INVALID\|') { return [pscustomobject]@{ State = 'INVALID'; ExitCode = 30 } }
    if ($Message -match '(?s)^BLOCKED\|') { return [pscustomobject]@{ State = 'BLOCKED'; ExitCode = 10 } }
    if ($Message -match '(?s)^CANCELLED\|') { return [pscustomobject]@{ State = 'CANCELLED'; ExitCode = 40 } }
    return [pscustomobject]@{ State = 'FAILED'; ExitCode = 20 }
}

function Get-DevelopmentHarnessPowerShellPath {
    $hostName = if ([string]$PSVersionTable.PSEdition -ceq 'Desktop') { 'powershell.exe' } else { 'pwsh' }
    $candidatePaths = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$PSHOME)) {
        $candidatePaths += Join-Path $PSHOME $hostName
    }
    # A Windows PowerShell host can itself be a hardlink or a reparse alias.
    # Prefer a separately installed direct pwsh binary when the current host
    # cannot satisfy the non-reparse identity check.
    if ($hostName -ceq 'pwsh' -or [string]$PSVersionTable.PSEdition -ceq 'Desktop') {
        foreach ($command in @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
                $candidatePaths += [string]$command.Source
            }
        }
    }
    foreach ($path in @($candidatePaths | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        try {
            $fullPath = Get-StandardValidationFullPath -Path ([string]$path) -Context 'development harness PowerShell host'
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            $item = Get-Item -Force -LiteralPath $fullPath -ErrorAction Stop
            if ($item.PSIsContainer -or (Test-StandardValidationReparseItem -Item $item)) { continue }
            return [string]$item.FullName
        }
        catch { }
    }
    throw 'INVALID|The development harness could not resolve a direct non-reparse PowerShell host.'
}

function Convert-DevelopmentHarnessValidatorArguments {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $SnapshotRoot
    )

    $result = @()
    foreach ($argument in @($Arguments)) {
        if ($argument -isnot [string] -or [string]$argument -match '[\x00-\x1F\x7F]') {
            throw 'INVALID|Candidate validator arguments must be strings without control characters.'
        }
        $text = [string]$argument
        if ($text -match '(^|[\\/])\.\.([\\/]|$)') {
            throw 'INVALID|Candidate validator arguments may not contain parent-directory traversal.'
        }
        if ($text -match '__ARTIFACTS_ROOT__') {
            throw 'INVALID|The development harness does not expose its artifact root to candidate code.'
        }
        $text = $text.Replace('__CANDIDATE_ROOT__', $SnapshotRoot)
        if ([System.IO.Path]::IsPathRooted($text) -and $text -ne $SnapshotRoot) {
            throw 'INVALID|Candidate validator arguments may not introduce absolute paths; use __CANDIDATE_ROOT__.'
        }
        $result += $text
    }
    return @($result)
}

function Assert-DevelopmentHarnessValidatorArguments {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    foreach ($argument in @($Arguments)) {
        if ($argument -isnot [string] -or [string]$argument -match '[\x00-\x1F\x7F]') {
            throw 'INVALID|Candidate validator arguments must be strings without control characters.'
        }
        $text = [string]$argument
        if ($text -match '(^|[\\/])\.\.([\\/]|$)') {
            throw 'INVALID|Candidate validator arguments may not contain parent-directory traversal.'
        }
        if ($text -match '__ARTIFACTS_ROOT__') {
            throw 'INVALID|The development harness does not expose its artifact root to candidate code.'
        }
        if ([System.IO.Path]::IsPathRooted($text) -and $text -ne '__CANDIDATE_ROOT__') {
            throw 'INVALID|Candidate validator arguments may not introduce absolute paths; use __CANDIDATE_ROOT__.'
        }
    }
    return ,([string[]]$Arguments)
}

function Get-DevelopmentHarnessStageSummary {
    param([Parameter(Mandatory = $true)] $Evidence)

    $stages = @($Evidence.stages)
    $expected = @('controlled-acquisition', 'integrity-verification', 'package-validation', 'skillspector-static', 'repository-tests')
    if ($stages.Count -lt $expected.Count) {
        throw 'FAILED|The trusted development barrier did not emit the first five canonical stages.'
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ([string]$stages[$index].id -cne $expected[$index] -or [string]$stages[$index].status -cne 'passed') {
            throw "FAILED|The trusted development barrier stage '$($expected[$index])' did not pass before candidate execution."
        }
    }
    return @($stages | Select-Object -First 5 | ForEach-Object {
        [ordered]@{ order = [int]$_.order; id = [string]$_.id; status = [string]$_.status }
    })
}

function Assert-DevelopmentHarnessBarrierArtifactsUnchanged {
    param(
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $EvidencePath,
        [Parameter(Mandatory = $true)][string] $ExpectedEvidenceSha256,
        [Parameter(Mandatory = $true)] $ExpectedInventory,
        [Parameter(Mandatory = $true)][string] $ExpectedInventorySha256
    )

    Assert-StandardValidationNoReparsePoints -Root $ArtifactsRoot -Context 'standard barrier artifacts after candidate execution'
    Assert-StandardValidationRegularFile -Path $EvidencePath -Context 'trusted pre-candidate barrier evidence after candidate execution'
    $currentEvidenceSha256 = Get-StandardValidationFileSha256 -Path $EvidencePath -Context 'trusted pre-candidate barrier evidence after candidate execution'
    if ($currentEvidenceSha256 -cne $ExpectedEvidenceSha256) {
        throw 'FAILED|Previously authenticated trusted pre-candidate barrier evidence changed after candidate execution.'
    }
    $null = Get-StandardValidationJson -Path $EvidencePath -Context 'trusted pre-candidate barrier evidence after candidate execution'
    $currentInventory = @(Get-StandardValidationInventory -Root $ArtifactsRoot -Context 'standard barrier artifact inventory after candidate execution')
    $currentInventorySha256 = Get-StandardValidationInventorySha256 -Inventory $currentInventory
    if ($currentInventorySha256 -cne $ExpectedInventorySha256) {
        throw 'FAILED|Standard barrier artifacts changed after candidate execution.'
    }
    if (@($currentInventory).Count -ne @($ExpectedInventory).Count) {
        throw 'FAILED|Standard barrier artifact inventory count changed after candidate execution.'
    }
    return [pscustomobject][ordered]@{
        evidenceSha256 = [string]$currentEvidenceSha256
        inventorySha256 = [string]$currentInventorySha256
    }
}

function Assert-DevelopmentHarnessAuthorityInputsUnchanged {
    param(
        [Parameter(Mandatory = $true)][string] $RunnerPath,
        [Parameter(Mandatory = $true)][string] $ExpectedRunnerSha256,
        [Parameter(Mandatory = $true)][string] $LauncherPath,
        [Parameter(Mandatory = $true)][string] $ExpectedLauncherSha256,
        [Parameter(Mandatory = $true)][string] $PowerShellPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPowerShellSha256,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ExpectedAdapterSha256,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedTrustedToolInventorySha256
    )

    $currentRunnerSha256 = Get-StandardValidationFileSha256 -Path $RunnerPath -Context 'central validation runner revalidation'
    if ($currentRunnerSha256 -cne $ExpectedRunnerSha256) {
        throw 'FAILED|Trusted authority runner changed during validation.'
    }
    $currentLauncherSha256 = Get-StandardValidationFileSha256 -Path $LauncherPath -Context 'development harness launcher revalidation'
    if ($currentLauncherSha256 -cne $ExpectedLauncherSha256) {
        throw 'FAILED|Trusted development harness launcher changed during validation.'
    }
    $currentPowerShellSha256 = Get-StandardValidationFileSha256 -Path $PowerShellPath -Context 'development harness PowerShell host revalidation'
    if ($currentPowerShellSha256 -cne $ExpectedPowerShellSha256) {
        throw 'FAILED|Trusted authority PowerShell host changed during validation.'
    }
    $currentAdapterSha256 = Get-StandardValidationFileSha256 -Path $AdapterPath -Context 'authority adapter revalidation'
    if ($currentAdapterSha256 -cne $ExpectedAdapterSha256) {
        throw 'FAILED|Trusted authority adapter changed during validation.'
    }
    $currentTrustedToolInventory = @(Get-StandardValidationInventory -Root $TrustedToolRoot -Context 'trusted tool root revalidation')
    $currentTrustedToolInventorySha256 = Get-StandardValidationInventorySha256 -Inventory $currentTrustedToolInventory
    if ($currentTrustedToolInventorySha256 -cne $ExpectedTrustedToolInventorySha256) {
        throw 'FAILED|Trusted tool root changed during validation.'
    }
    return [pscustomobject][ordered]@{
        runnerSha256 = [string]$currentRunnerSha256
        launcherSha256 = [string]$currentLauncherSha256
        powerShellSha256 = [string]$currentPowerShellSha256
        adapterSha256 = [string]$currentAdapterSha256
        trustedToolInventorySha256 = [string]$currentTrustedToolInventorySha256
    }
}

try {
    # Load only the central runner functions. The runner remains the oracle for
    # package -> Static -> repository-test ordering and owns child containment.
    . $runnerPath `
        -CandidateRoot (Join-Path $PSScriptRoot 'ci1-function-load-candidate') `
        -AdapterPath $runnerPath `
        -ArtifactsRoot (Join-Path $PSScriptRoot 'ci1-function-load-artifacts') `
        -SourceRepository 'https://example.com/ci1/function-load.git' `
        -SourceRevision ('a' * 40) `
        -BaseRevision ('b' * 40) `
        -EventName 'local' `
        -TrustedToolRoot $PSScriptRoot `
        -DefineFunctionsOnly

    if ($harnessTimeoutSeconds -lt 1) { throw 'INVALID|TimeoutSeconds must be at least one second.' }
    if ($harnessCandidateTimeoutSeconds -lt 1) { throw 'INVALID|CandidateTimeoutSeconds must be at least one second.' }
    Assert-StandardValidationSourceRepository -Value $harnessSourceRepository
    Assert-StandardValidationRevision -Value $harnessSourceRevision -Context 'SourceRevision'
    Assert-StandardValidationRevision -Value $harnessBaseRevision -Context 'BaseRevision'

    $candidateFull = Assert-StandardValidationCanonicalRootPath -Path $harnessCandidateRoot -Context 'CandidateRoot'
    $adapterFull = Assert-StandardValidationCanonicalRootPath -Path $harnessAdapterPath -Context 'AdapterPath'
    $trustedToolRootFull = Assert-StandardValidationCanonicalRootPath -Path $harnessTrustedToolRoot -Context 'TrustedToolRoot'
    $artifactRootFull = Assert-StandardValidationCanonicalRootPath -Path $harnessArtifactsRoot -Context 'ArtifactsRoot'
    $centralRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

    if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) { throw 'INVALID|CandidateRoot is not a directory.' }
    if (-not (Test-Path -LiteralPath $adapterFull -PathType Leaf)) { throw 'INVALID|AdapterPath is not a file.' }
    if (-not (Test-Path -LiteralPath $trustedToolRootFull -PathType Container)) { throw 'INVALID|TrustedToolRoot is not a directory.' }
    [void](New-Item -ItemType Directory -Path $artifactRootFull -Force)
    Assert-StandardValidationDistinctRoots -First $candidateFull -Second $artifactRootFull -Context 'CandidateRoot and ArtifactsRoot'
    Assert-StandardValidationDistinctRoots -First $artifactRootFull -Second $centralRoot -Context 'ArtifactsRoot and central authority root'
    Assert-StandardValidationOutsideRoot -Path $trustedToolRootFull -Root $candidateFull -Context 'TrustedToolRoot'
    Assert-StandardValidationDistinctRoots -First $trustedToolRootFull -Second $artifactRootFull -Context 'TrustedToolRoot and ArtifactsRoot'
    Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $candidateFull -Context 'AdapterPath'
    Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $artifactRootFull -Context 'AdapterPath'
    Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $trustedToolRootFull -Context 'AdapterPath'
    Assert-StandardValidationNoReparsePoints -Root $candidateFull -Context 'CandidateRoot'
    Assert-StandardValidationNoReparsePoints -Root $trustedToolRootFull -Context 'TrustedToolRoot'
    Assert-StandardValidationNoReparsePoints -Root $artifactRootFull -Context 'ArtifactsRoot'
    Assert-StandardValidationRegularFile -Path $adapterFull -Context 'AdapterPath'

    # Keep the owned run path compact. The central runner appends a candidate
    # identity and event ID to child working paths; staying well below the
    # Windows MAX_PATH boundary is part of making this launcher portable.
    $runRoot = Join-Path $artifactRootFull "ci1-$runIdText"
    if (Test-Path -LiteralPath $runRoot) { throw 'INVALID|The development harness run root already exists.' }
    [void](New-Item -ItemType Directory -Path $runRoot -Force)
    Assert-StandardValidationNoReparsePoints -Root $runRoot -Context 'development harness run root'
    $outputFull = if ([string]::IsNullOrWhiteSpace($harnessOutputPath)) {
        Join-Path $runRoot 'evidence.json'
    }
    else {
        Get-StandardValidationFullPath -Path $harnessOutputPath -Context 'OutputPath'
    }
    if (-not (Test-StandardValidationPathWithin -Path $outputFull -Root $artifactRootFull -IncludeRoot)) {
        throw 'INVALID|OutputPath must be under ArtifactsRoot.'
    }
    $outputReservation = New-StandardValidationOutputReservation -Path $outputFull
    $outputReservationStream = $outputReservation.stream
    $outputReservationToken = [string]$outputReservation.token

    $candidateItem = Get-Item -Force -LiteralPath $candidateFull -ErrorAction Stop
    if ($candidateItem.PSIsContainer -eq $false) { throw 'INVALID|CandidateRoot is not a directory.' }
    $validatorRelative = $harnessCandidateValidatorPath.Replace('\', '/')
    while ($validatorRelative.StartsWith('./', [StringComparison]::Ordinal)) { $validatorRelative = $validatorRelative.Substring(2) }
    Assert-StandardValidationSafeRelativePath -Value $validatorRelative -Context 'CandidateValidatorPath'
    $validatorFull = Get-StandardValidationFullPath -Path (Join-Path $candidateFull ($validatorRelative -replace '/', [IO.Path]::DirectorySeparatorChar)) -Context 'CandidateValidatorPath'
    if (-not (Test-StandardValidationPathWithin -Path $validatorFull -Root $candidateFull -IncludeRoot)) {
        throw 'INVALID|CandidateValidatorPath is outside CandidateRoot.'
    }
    Assert-StandardValidationRegularFile -Path $validatorFull -Context 'CandidateValidatorPath'

    $adapter = Get-StandardValidationJson -Path $adapterFull -Context 'development harness adapter'
    if ([string]$adapter.canonicalValidatorPath -cne $validatorRelative) {
        throw "INVALID|The development harness adapter canonicalValidatorPath '$($adapter.canonicalValidatorPath)' does not match '$validatorRelative'."
    }
    $candidateInventory = Get-StandardValidationInventory -Root $candidateFull -Context 'development harness candidate'
    $candidateContentSha256 = Get-StandardValidationInventorySha256 -Inventory $candidateInventory
    $candidateValidatorSha256 = Get-StandardValidationFileSha256 -Path $validatorFull -Context 'CandidateValidatorPath'
    $candidateAdapterSha256 = Get-StandardValidationFileSha256 -Path $adapterFull -Context 'development harness adapter'
    $candidateSnapshotRoot = Join-Path $runRoot 'candidate-snapshot'
    Copy-StandardValidationSnapshot -Source $candidateFull -Destination $candidateSnapshotRoot
    Assert-StandardValidationNoReparsePoints -Root $candidateSnapshotRoot -Context 'candidate snapshot'
    $candidateSnapshotInventory = Get-StandardValidationInventory -Root $candidateSnapshotRoot -Context 'candidate snapshot'
    $candidateSnapshotContentSha256 = Get-StandardValidationInventorySha256 -Inventory $candidateSnapshotInventory
    if ($candidateSnapshotContentSha256 -cne $candidateContentSha256) {
        throw 'FAILED|Candidate snapshot identity does not match CandidateRoot.'
    }
    # Reject unsafe candidate arguments before spending time on the trusted
    # barrier; the snapshot root is already fixed and is the only substitution
    # target accepted by the argument contract.
    $candidateValidatorArguments = Convert-DevelopmentHarnessValidatorArguments `
        -Arguments (Assert-DevelopmentHarnessValidatorArguments -Arguments $harnessValidatorArguments) `
        -SnapshotRoot $candidateSnapshotRoot
    $validatorArgumentsLogical = Assert-DevelopmentHarnessValidatorArguments -Arguments $harnessValidatorArguments
    $validatorArgumentsCanonical = ConvertTo-Json -InputObject ([string[]]$validatorArgumentsLogical) -Compress
    $validatorArgumentsSha256 = Get-StandardValidationTextSha256 -Value $validatorArgumentsCanonical
    $candidateId = Get-StandardValidationTextSha256 -Value (
        "$harnessSourceRepository`n$harnessSourceRevision`n$harnessBaseRevision`n$harnessEventName`n$candidateContentSha256`n$candidateValidatorSha256`n$candidateAdapterSha256`n$validatorArgumentsSha256"
    )

    $standardArtifactsRoot = Join-Path $runRoot 'std'
    $standardOutputPath = Join-Path $standardArtifactsRoot 'evidence.json'
    $barrierWorkingRoot = Join-Path $runRoot 'barrier'
    $candidateWorkingRoot = Join-Path $runRoot 'candidate'
    [void](New-Item -ItemType Directory -Path $standardArtifactsRoot -Force)
    [void](New-Item -ItemType Directory -Path $barrierWorkingRoot -Force)
    [void](New-Item -ItemType Directory -Path $candidateWorkingRoot -Force)
    Assert-StandardValidationNoReparsePoints -Root $standardArtifactsRoot -Context 'standard barrier artifacts'
    Assert-StandardValidationNoReparsePoints -Root $barrierWorkingRoot -Context 'barrier working root'
    Assert-StandardValidationNoReparsePoints -Root $candidateWorkingRoot -Context 'candidate working root'

    $powerShellPath = Get-DevelopmentHarnessPowerShellPath
    $powerShellSha256 = Get-StandardValidationFileSha256 -Path $powerShellPath -Context 'development harness PowerShell host'
    $runnerSha256 = Get-StandardValidationFileSha256 -Path $runnerPath -Context 'central validation runner'
    if ([string]::IsNullOrWhiteSpace([string]$PSCommandPath)) {
        throw 'INVALID|The development harness launcher path is unavailable from PSCommandPath.'
    }
    $launcherPath = Get-StandardValidationFullPath -Path ([string]$PSCommandPath) -Context 'development harness launcher'
    Assert-StandardValidationRegularFile -Path $launcherPath -Context 'development harness launcher'
    $launcherSha256 = Get-StandardValidationFileSha256 -Path $launcherPath -Context 'development harness launcher'
    $trustedToolInventory = @(Get-StandardValidationInventory -Root $trustedToolRootFull -Context 'trusted tool root')
    $trustedToolInventorySha256 = Get-StandardValidationInventorySha256 -Inventory $trustedToolInventory
    if ($CancellationStdin) {
        Start-DevelopmentHarnessCancellationReader
        $cancellationProbe = { Test-DevelopmentHarnessCancellationRequested }
    }

    # The central development runner is the independent pre-candidate oracle.
    # Its adapter/tool roots are caller-supplied but remain outside the
    # candidate and artifact roots; production mode is impossible here.
    $barrierArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $runnerPath,
        '-CandidateRoot', $candidateFull,
        '-AdapterPath', $adapterFull,
        '-ArtifactsRoot', $standardArtifactsRoot,
        '-OutputPath', $standardOutputPath,
        '-SourceRepository', $harnessSourceRepository,
        '-SourceRevision', $harnessSourceRevision,
        '-BaseRevision', $harnessBaseRevision,
        '-EventName', $harnessEventName,
        '-TimeoutSeconds', [string]$harnessTimeoutSeconds,
        '-TrustedToolRoot', $trustedToolRootFull,
        '-DevelopmentHarness',
        '-RunId', $runIdText
    )
    $barrierEnvironment = @{
        STANDARD_VALIDATION_DEVELOPMENT_ONLY = 'true'
        STANDARD_VALIDATION_CI1_PHASE = 'trusted-pre-candidate-barrier'
        STANDARD_VALIDATION_CI1_RUN_ID = $runIdText
        STANDARD_VALIDATION_CI1_CANDIDATE_ID = $candidateId
    }
    $barrierProcessResult = Invoke-StandardValidationProcess `
        -Command $powerShellPath `
        -Arguments $barrierArguments `
        -WorkingDirectory $barrierWorkingRoot `
        -Environment $barrierEnvironment `
        -TimeoutSeconds $harnessTimeoutSeconds `
        -CancellationProbe $cancellationProbe

    $candidateBarrierStatus = [string]$barrierProcessResult.status
    if ([string]$barrierProcessResult.status -eq 'cancelled') { throw 'CANCELLED|The trusted pre-candidate barrier was cancelled.' }
    if ([string]$barrierProcessResult.status -ne 'passed' -or [int]$barrierProcessResult.exitCode -ne 0 -or
        -not [bool]$barrierProcessResult.cleanedUp) {
        throw "FAILED|The trusted pre-candidate barrier process did not pass (status=$($barrierProcessResult.status), exitCode=$($barrierProcessResult.exitCode), cleanedUp=$($barrierProcessResult.cleanedUp))."
    }
    if (-not (Test-Path -LiteralPath $standardOutputPath -PathType Leaf)) {
        throw 'FAILED|The trusted pre-candidate barrier did not create its external evidence artifact.'
    }
    $barrierEvidence = Get-StandardValidationJson -Path $standardOutputPath -Context 'trusted pre-candidate barrier evidence'
    if ([string]$barrierEvidence.state -cne 'PASS' -or
        $barrierEvidence.releaseEligible -isnot [bool] -or [bool]$barrierEvidence.releaseEligible) {
        throw 'BLOCKED|The trusted pre-candidate barrier did not produce a development-only PASS with releaseEligible=false.'
    }
    $barrierStages = Get-DevelopmentHarnessStageSummary -Evidence $barrierEvidence
    $barrierEvidenceSha256 = Get-StandardValidationFileSha256 -Path $standardOutputPath -Context 'trusted pre-candidate barrier evidence'
    $barrierArtifactInventory = @(Get-StandardValidationInventory -Root $standardArtifactsRoot -Context 'standard barrier artifact inventory')
    $barrierArtifactInventorySha256 = Get-StandardValidationInventorySha256 -Inventory $barrierArtifactInventory
    $candidateBarrierStatus = 'passed'

    # Revalidate the source after the independent barrier and before executing
    # the candidate validator. The validator always runs from the immutable
    # copied snapshot, never from the source checkout.
    Assert-StandardValidationCandidateUnchanged `
        -CandidateRoot $candidateFull `
        -ExpectedContentSha256 $candidateContentSha256 `
        -AdapterPath $adapterFull `
        -ExpectedAdapterSha256 $candidateAdapterSha256
    $null = Assert-DevelopmentHarnessAuthorityInputsUnchanged `
        -RunnerPath $runnerPath `
        -ExpectedRunnerSha256 $runnerSha256 `
        -LauncherPath $launcherPath `
        -ExpectedLauncherSha256 $launcherSha256 `
        -PowerShellPath $powerShellPath `
        -ExpectedPowerShellSha256 $powerShellSha256 `
        -AdapterPath $adapterFull `
        -ExpectedAdapterSha256 $candidateAdapterSha256 `
        -TrustedToolRoot $trustedToolRootFull `
        -ExpectedTrustedToolInventorySha256 $trustedToolInventorySha256
    $candidateSnapshotValidatorFull = Get-StandardValidationFullPath `
        -Path (Join-Path $candidateSnapshotRoot ($validatorRelative -replace '/', [IO.Path]::DirectorySeparatorChar)) `
        -Context 'candidate snapshot validator'
    if ((Get-StandardValidationFileSha256 -Path $candidateSnapshotValidatorFull -Context 'candidate snapshot validator') -cne $candidateValidatorSha256) {
        throw 'FAILED|Candidate snapshot validator identity changed before execution.'
    }
    $candidateArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $candidateSnapshotValidatorFull)
    $candidateArguments += @($candidateValidatorArguments)
    $candidateCandidateEnvironment = @{
        STANDARD_VALIDATION_DEVELOPMENT_ONLY = 'true'
        STANDARD_VALIDATION_RELEASE_ELIGIBLE = 'false'
        STANDARD_VALIDATION_CI1_PHASE = 'candidate-validator'
        STANDARD_VALIDATION_CI1_RUN_ID = $runIdText
        STANDARD_VALIDATION_CI1_BARRIER_EVIDENCE_SHA256 = $barrierEvidenceSha256
        STANDARD_VALIDATION_STAGE_ID = 'candidate-validator-development-harness'
        STANDARD_VALIDATION_TOOL_ID = 'candidate-validator'
        STANDARD_VALIDATION_CANDIDATE_ID = $candidateId
        STANDARD_VALIDATION_CANDIDATE_ARGUMENTS_SHA256 = $validatorArgumentsSha256
        STANDARD_VALIDATION_CANDIDATE_ROOT = $candidateSnapshotRoot
        STANDARD_VALIDATION_SOURCE_REPOSITORY = $harnessSourceRepository
        STANDARD_VALIDATION_SOURCE_REVISION = $harnessSourceRevision
        STANDARD_VALIDATION_BASE_REVISION = $harnessBaseRevision
        STANDARD_VALIDATION_EVENT_NAME = $harnessEventName
    }
    $candidateExecutionAttempted = $true
    # Keep this conservative until the process primitive reports whether its
    # owned process actually started. If invocation itself throws, the evidence
    # must not claim that candidate side effects were impossible.
    $candidateCodeExecuted = $true
    try {
        $candidateProcessResult = Invoke-StandardValidationProcess `
            -Command $powerShellPath `
            -Arguments $candidateArguments `
            -WorkingDirectory $candidateWorkingRoot `
            -Environment $candidateCandidateEnvironment `
            -TimeoutSeconds $harnessCandidateTimeoutSeconds `
            -CancellationProbe $cancellationProbe
        if ($candidateProcessResult.PSObject.Properties.Name -contains 'processStarted') {
            $candidateCodeExecuted = [bool]$candidateProcessResult.processStarted
        }
        $candidateOutcome = [ordered]@{
            status = [string]$candidateProcessResult.status
            exitCode = [int]$candidateProcessResult.exitCode
            cleanedUp = [bool]$candidateProcessResult.cleanedUp
            processStarted = if ($candidateProcessResult.PSObject.Properties.Name -contains 'processStarted') {
                [bool]$candidateProcessResult.processStarted
            }
            else {
                $false
            }
            outputQuotaExceeded = if ($candidateProcessResult.PSObject.Properties.Name -contains 'outputQuotaExceeded') {
                [bool]$candidateProcessResult.outputQuotaExceeded
            }
            else {
                $false
            }
        }
    }
    finally {
        $barrierRevalidationError = $null
        if ($candidateExecutionAttempted -and $null -ne $barrierEvidenceSha256) {
            try {
                $barrierRevalidation = Assert-DevelopmentHarnessBarrierArtifactsUnchanged `
                    -ArtifactsRoot $standardArtifactsRoot `
                    -EvidencePath $standardOutputPath `
                    -ExpectedEvidenceSha256 $barrierEvidenceSha256 `
                    -ExpectedInventory $barrierArtifactInventory `
                    -ExpectedInventorySha256 $barrierArtifactInventorySha256
                $barrierEvidencePostExecutionSha256 = [string]$barrierRevalidation.evidenceSha256
                $barrierArtifactInventoryPostExecutionSha256 = [string]$barrierRevalidation.inventorySha256
                $barrierEvidenceRevalidated = $true
            }
            catch {
                $barrierEvidenceRevalidated = $false
                $barrierRevalidationError = [string]$_.Exception.Message
            }
        }
        # The candidate is executed from an immutable snapshot, but the source
        # checkout and adapter remain untrusted inputs to this development
        # harness. Revalidate them after every attempted candidate execution,
        # including timeout/cancellation and barrier-revalidation failures.
        if ($candidateExecutionAttempted) {
            try {
                Assert-StandardValidationCandidateUnchanged `
                    -CandidateRoot $candidateFull `
                    -ExpectedContentSha256 $candidateContentSha256 `
                    -AdapterPath $adapterFull `
                    -ExpectedAdapterSha256 $candidateAdapterSha256
                $sourceCheckoutRevalidatedAfterCandidate = $true
            }
            catch {
                $sourceCheckoutValidationError = [string]$_.Exception.Message
                # Any failed revalidation leaves the source trust state
                # unknown, even when the diagnostic is a missing/reparse/
                # permission error rather than a content-diff message.
                $sourceCheckoutMutated = $true
            }
        }
        if ($candidateExecutionAttempted) {
            try {
                $authorityInputRevalidation = Assert-DevelopmentHarnessAuthorityInputsUnchanged `
                    -RunnerPath $runnerPath `
                    -ExpectedRunnerSha256 $runnerSha256 `
                    -LauncherPath $launcherPath `
                    -ExpectedLauncherSha256 $launcherSha256 `
                    -PowerShellPath $powerShellPath `
                    -ExpectedPowerShellSha256 $powerShellSha256 `
                    -AdapterPath $adapterFull `
                    -ExpectedAdapterSha256 $candidateAdapterSha256 `
                    -TrustedToolRoot $trustedToolRootFull `
                    -ExpectedTrustedToolInventorySha256 $trustedToolInventorySha256
                $authorityInputRevalidatedAfterCandidate = $true
            }
            catch {
                $authorityInputValidationError = [string]$_.Exception.Message
            }
        }
    }
    $postCandidateRevalidationErrors = @()
    if (-not [string]::IsNullOrWhiteSpace($barrierRevalidationError)) {
        $postCandidateRevalidationErrors += $barrierRevalidationError
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceCheckoutValidationError)) {
        $postCandidateRevalidationErrors += "FAILED|Post-candidate source checkout revalidation failed: $sourceCheckoutValidationError"
    }
    if (-not [string]::IsNullOrWhiteSpace($authorityInputValidationError)) {
        $postCandidateRevalidationErrors += "FAILED|Post-candidate authority input revalidation failed: $authorityInputValidationError"
    }
    if ($postCandidateRevalidationErrors.Count -gt 0) {
        throw ($postCandidateRevalidationErrors -join ' | ')
    }
    Assert-StandardValidationSnapshotUnchanged -SnapshotRoot $candidateSnapshotRoot -ExpectedSnapshotContentSha256 $candidateSnapshotContentSha256
    if ([string]$candidateProcessResult.status -eq 'cancelled') { throw 'CANCELLED|The candidate validator was cancelled.' }
    if ([string]$candidateProcessResult.status -eq 'timeout') { throw 'FAILED|The candidate validator timed out inside the owned process boundary.' }
    if (-not [bool]$candidateProcessResult.cleanedUp) { throw 'FAILED|The candidate validator cleanup boundary did not close.' }
    if ([string]$candidateProcessResult.status -ne 'passed' -or [int]$candidateProcessResult.exitCode -ne 0) {
        throw "FAILED|The candidate validator returned status '$($candidateProcessResult.status)' and exit code $($candidateProcessResult.exitCode)."
    }

    $state = 'PASS'
    $exitCode = 0
    $failureMessage = $null
}
catch {
    $failureMessage = [string]$_.Exception.Message
    if ($failureMessage -match 'Candidate content changed|Adapter configuration changed' -or
        -not [string]::IsNullOrWhiteSpace($sourceCheckoutValidationError)) {
        $sourceCheckoutMutated = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceCheckoutValidationError) -and
        $failureMessage -notmatch [regex]::Escape($sourceCheckoutValidationError)) {
        $failureMessage = "$failureMessage | post-candidate source revalidation: $sourceCheckoutValidationError"
    }
    $classification = Get-DevelopmentHarnessFailureClassification -Message $failureMessage
    $state = [string]$classification.State
    $exitCode = [int]$classification.ExitCode
}
finally {
    Stop-DevelopmentHarnessCancellationReader
    $snapshotEvidence = [ordered]@{
        sourcePath = if ($null -eq $candidateFull) { $null } else { [string]$candidateFull }
        snapshotPath = if ($null -eq $candidateSnapshotRoot) { $null } else { [string]$candidateSnapshotRoot }
        contentSha256 = if ($null -eq $candidateSnapshotContentSha256) { $null } else { [string]$candidateSnapshotContentSha256 }
        validatorPath = [string]$harnessCandidateValidatorPath
        validatorSha256 = if ($null -eq $candidateValidatorSha256) { $null } else { [string]$candidateValidatorSha256 }
    }
    $finalEvidence = [ordered]@{
        schemaVersion = 1
        evidenceType = 'standard-validation-development-harness'
        mode = 'development-harness'
        runId = $harnessRunId.ToString('D')
        state = $state
        exitCode = [int]$exitCode
        decision = if ($state -ceq 'PASS') { 'PASS' } else { 'BLOCK' }
        releaseEligible = $false
        candidateCodeExecuted = [bool]$candidateCodeExecuted
        candidateExecutionAttempted = [bool]$candidateExecutionAttempted
        candidateId = $candidateId
        identity = [ordered]@{
            sourceRepository = $harnessSourceRepository
            sourceRevision = $harnessSourceRevision
            baseRevision = $harnessBaseRevision
            eventName = $harnessEventName
            contentSha256 = $candidateContentSha256
            validatorSha256 = $candidateValidatorSha256
            adapterSha256 = $candidateAdapterSha256
            validatorArgumentsSha256 = $validatorArgumentsSha256
        }
        authority = [ordered]@{
            status = 'local-development-only-unpinned'
            repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
            runnerPath = 'scripts/Invoke-StandardValidation.ps1'
            runnerSha256 = if ($null -eq $runnerSha256) { $null } else { [string]$runnerSha256 }
            launcherPath = if ($null -eq $launcherPath) { $null } else { [string]$launcherPath }
            launcherSha256 = if ($null -eq $launcherSha256) { $null } else { [string]$launcherSha256 }
            trustedToolRoot = if ($null -eq $trustedToolRootFull) { $null } else { [string]$trustedToolRootFull }
            trustedToolInventorySha256 = if ($null -eq $trustedToolInventorySha256) { $null } else { [string]$trustedToolInventorySha256 }
            inputsRevalidatedAfterCandidate = [bool]$authorityInputRevalidatedAfterCandidate
            inputRevalidationError = $authorityInputValidationError
            candidateIsTrustRoot = $false
            formalAdoption = 'not-authorized'
        }
        launcher = [ordered]@{
            path = if ($null -eq $launcherPath) { $null } else { [string]$launcherPath }
            sha256 = if ($null -eq $launcherSha256) { $null } else { [string]$launcherSha256 }
            processHostSha256 = if ($null -eq $powerShellSha256) { $null } else { [string]$powerShellSha256 }
            artifactRoot = $artifactRootFull
            networkIsolation = 'not-proven; no network-dependent candidate fixture is permitted'
            secrets = 'not-provided-to-owned-children'
            releaseSideEffects = $false
        }
        snapshot = $snapshotEvidence
        preCandidateBarrier = [ordered]@{
            status = $candidateBarrierStatus
            oracle = 'central-development-runner'
            evidencePath = if ($null -eq $standardOutputPath) { $null } else { [string]$standardOutputPath }
            evidenceSha256 = if ($null -eq $barrierEvidenceSha256) { $null } else { [string]$barrierEvidenceSha256 }
            evidencePostExecutionSha256 = if ($null -eq $barrierEvidencePostExecutionSha256) { $null } else { [string]$barrierEvidencePostExecutionSha256 }
            artifactInventory = if ($null -eq $barrierArtifactInventory) { @() } else { @($barrierArtifactInventory) }
            artifactInventorySha256 = if ($null -eq $barrierArtifactInventorySha256) { $null } else { [string]$barrierArtifactInventorySha256 }
            artifactInventoryPostExecutionSha256 = if ($null -eq $barrierArtifactInventoryPostExecutionSha256) { $null } else { [string]$barrierArtifactInventoryPostExecutionSha256 }
            evidenceUnchangedAfterCandidate = $barrierEvidenceRevalidated
            firstFiveStages = @($barrierStages)
        }
        candidateOutcome = $candidateOutcome
        process = [ordered]@{
            barrier = $barrierProcessResult
            candidate = $candidateProcessResult
        }
        recovery = [ordered]@{
            status = 'fail-closed'
            onFailure = 'stop-candidate-promotion-preserve-external-evidence-and-require-a-new-reviewed-run'
            sourceCheckoutMutated = $sourceCheckoutMutated
            sourceCheckoutRevalidatedAfterCandidate = $sourceCheckoutRevalidatedAfterCandidate
            sourceCheckoutValidationError = $sourceCheckoutValidationError
            rollback = 'development-only; no release or install side effect performed'
        }
        failure = if ([string]::IsNullOrWhiteSpace([string]$failureMessage)) { $null } else { [ordered]@{ state = $state; message = [string]$failureMessage } }
    }
    if ($null -ne $outputReservationStream) {
        try {
            Write-StandardValidationJsonReserved `
                -Path $outputFull `
                -Stream $outputReservationStream `
                -Token $outputReservationToken `
                -Value $finalEvidence
        }
        catch {
            $state = 'FAILED'
            $exitCode = 20
            $failureMessage = "Final development harness evidence write failed: $($_.Exception.Message)"
            $finalEvidence.state = $state
            $finalEvidence.exitCode = $exitCode
            $finalEvidence.decision = 'BLOCK'
            $finalEvidence.failure = [ordered]@{ state = $state; message = $failureMessage }
        }
        finally {
            $outputReservationStream.Dispose()
            $outputReservationStream = $null
        }
    }
}

$finalEvidence | ConvertTo-Json -Depth 100
exit ([int]$exitCode)
