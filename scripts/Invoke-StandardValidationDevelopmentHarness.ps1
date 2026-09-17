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
    [string] $CancellationPath
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
$candidateId = $null
$candidateFull = $null
$adapterFull = $null
$trustedToolRootFull = $null
$artifactRootFull = $null
$runRoot = $null
$candidateSnapshotRoot = $null
$candidateSnapshotContentSha256 = $null
$sourceCheckoutMutated = $null
$outputFull = $null
$standardOutputPath = $null
$barrierEvidenceSha256 = $null
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
$harnessCancellationPath = [string]$CancellationPath

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
    if ($hostName -ceq 'pwsh') {
        $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $command) { $candidatePaths += [string]$command.Source }
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
    $candidateId = Get-StandardValidationTextSha256 -Value (
        "$harnessSourceRepository`n$harnessSourceRevision`n$harnessBaseRevision`n$harnessEventName`n$candidateContentSha256`n$candidateValidatorSha256"
    )

    $candidateSnapshotRoot = Join-Path $runRoot 'candidate-snapshot'
    Copy-StandardValidationSnapshot -Source $candidateFull -Destination $candidateSnapshotRoot
    Assert-StandardValidationNoReparsePoints -Root $candidateSnapshotRoot -Context 'candidate snapshot'
    $candidateSnapshotInventory = Get-StandardValidationInventory -Root $candidateSnapshotRoot -Context 'candidate snapshot'
    $candidateSnapshotContentSha256 = Get-StandardValidationInventorySha256 -Inventory $candidateSnapshotInventory
    if ($candidateSnapshotContentSha256 -cne $candidateContentSha256) {
        throw 'FAILED|Candidate snapshot identity does not match CandidateRoot.'
    }

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
        -CancellationPath $harnessCancellationPath

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
    $candidateBarrierStatus = 'passed'

    # Revalidate the source after the independent barrier and before executing
    # the candidate validator. The validator always runs from the immutable
    # copied snapshot, never from the source checkout.
    Assert-StandardValidationCandidateUnchanged `
        -CandidateRoot $candidateFull `
        -ExpectedContentSha256 $candidateContentSha256 `
        -AdapterPath $adapterFull `
        -ExpectedAdapterSha256 (Get-StandardValidationFileSha256 -Path $adapterFull -Context 'development harness adapter')
    $sourceCheckoutMutated = $false
    $candidateSnapshotValidatorFull = Get-StandardValidationFullPath `
        -Path (Join-Path $candidateSnapshotRoot ($validatorRelative -replace '/', [IO.Path]::DirectorySeparatorChar)) `
        -Context 'candidate snapshot validator'
    if ((Get-StandardValidationFileSha256 -Path $candidateSnapshotValidatorFull -Context 'candidate snapshot validator') -cne $candidateValidatorSha256) {
        throw 'FAILED|Candidate snapshot validator identity changed before execution.'
    }
    $candidateArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $candidateSnapshotValidatorFull)
    $candidateArguments += Convert-DevelopmentHarnessValidatorArguments -Arguments $harnessValidatorArguments -SnapshotRoot $candidateSnapshotRoot
    $candidateCandidateEnvironment = @{
        STANDARD_VALIDATION_DEVELOPMENT_ONLY = 'true'
        STANDARD_VALIDATION_RELEASE_ELIGIBLE = 'false'
        STANDARD_VALIDATION_CI1_PHASE = 'candidate-validator'
        STANDARD_VALIDATION_CI1_RUN_ID = $runIdText
        STANDARD_VALIDATION_CI1_BARRIER_EVIDENCE_SHA256 = $barrierEvidenceSha256
        STANDARD_VALIDATION_STAGE_ID = 'candidate-validator-development-harness'
        STANDARD_VALIDATION_TOOL_ID = 'candidate-validator'
        STANDARD_VALIDATION_CANDIDATE_ID = $candidateId
        STANDARD_VALIDATION_CANDIDATE_ROOT = $candidateSnapshotRoot
        STANDARD_VALIDATION_SOURCE_REPOSITORY = $harnessSourceRepository
        STANDARD_VALIDATION_SOURCE_REVISION = $harnessSourceRevision
        STANDARD_VALIDATION_BASE_REVISION = $harnessBaseRevision
        STANDARD_VALIDATION_EVENT_NAME = $harnessEventName
    }
    $candidateExecutionAttempted = $true
    $candidateProcessResult = Invoke-StandardValidationProcess `
        -Command $powerShellPath `
        -Arguments $candidateArguments `
        -WorkingDirectory $candidateWorkingRoot `
        -Environment $candidateCandidateEnvironment `
        -TimeoutSeconds $harnessCandidateTimeoutSeconds `
        -CancellationPath $harnessCancellationPath
    $candidateCodeExecuted = [string]$candidateProcessResult.status -notin @('startup-failed', 'cancelled')
    $candidateOutcome = [ordered]@{
        status = [string]$candidateProcessResult.status
        exitCode = [int]$candidateProcessResult.exitCode
        cleanedUp = [bool]$candidateProcessResult.cleanedUp
        outputQuotaExceeded = [bool]$candidateProcessResult.outputQuotaExceeded
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
    if ($failureMessage -match 'Candidate content changed') { $sourceCheckoutMutated = $true }
    $classification = Get-DevelopmentHarnessFailureClassification -Message $failureMessage
    $state = [string]$classification.State
    $exitCode = [int]$classification.ExitCode
}
finally {
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
        }
        authority = [ordered]@{
            status = 'local-development-only-unpinned'
            repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
            runnerPath = 'scripts/Invoke-StandardValidation.ps1'
            runnerSha256 = if ($null -eq $runnerSha256) { $null } else { [string]$runnerSha256 }
            candidateIsTrustRoot = $false
            formalAdoption = 'not-authorized'
        }
        launcher = [ordered]@{
            path = 'scripts/Invoke-StandardValidationDevelopmentHarness.ps1'
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
