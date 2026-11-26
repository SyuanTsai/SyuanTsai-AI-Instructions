[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('linux','macos')][string] $PlatformId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{2}$')][string] $ShardId,
    [Parameter(Mandatory = $true)][string] $FilesBase64,
    [Parameter(Mandatory = $true)][string] $SkipsBase64,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $PlanSha256,
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][string] $OutputRoot,
    [Parameter(Mandatory = $true)][ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })][string] $RunId,
    [Parameter(Mandatory = $true)][ValidateRange(1, [int]::MaxValue)][int] $RunAttempt,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $TestRoot = './tests',
    [string] $ExecutorPath = (Join-Path $PSScriptRoot 'Invoke-PesterShardProcess.ps1'),
    [ValidateRange(1, [int]::MaxValue)][int] $OuterTimeoutSeconds = 4800,
    [AllowEmptyString()][string] $StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

$ErrorActionPreference = 'Stop'

function Write-UnixCoreJson {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)] $Value)

    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
}

function ConvertTo-UnixCoreCommandMessage {
    param([AllowEmptyString()][string] $Message)

    return $Message.Replace('%','%25').Replace("`r",'%0D').Replace("`n",'%0A')
}

try {
    $decodedFiles = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($FilesBase64)) | ConvertFrom-Json -NoEnumerate
    $decodedSkips = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SkipsBase64)) | ConvertFrom-Json -NoEnumerate
    if ($decodedFiles -isnot [Array] -or @($decodedFiles | Where-Object { $_ -isnot [string] }).Count -ne 0) {
        throw 'The shard file payload must be a JSON string array.'
    }
    if ($decodedSkips -isnot [Array] -or @($decodedSkips | Where-Object { $_ -isnot [string] }).Count -ne 0) {
        throw 'The shard skip payload must be a JSON string array.'
    }
    $selectedTestNames = [string[]]@($decodedFiles)
    $expectedSkippedTests = [string[]]@($decodedSkips)

    $selectedSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($selectedTestNames.Count -eq 0) { throw 'The shard file list is empty.' }
    foreach ($name in $selectedTestNames) {
        if (-not $selectedSeen.Add($name)) { throw "The shard file list contains a duplicate: '$name'." }
        if ($name -notmatch '^[^/\\]+\.Tests\.ps1$') { throw "Unsafe shard test filename '$name'." }
    }

    $allTestFiles = @(Get-ChildItem -LiteralPath $TestRoot -Filter '*.Tests.ps1' -File -Recurse)
    foreach ($name in $selectedTestNames) {
        if (@($allTestFiles | Where-Object Name -ceq $name).Count -ne 1) {
            throw "Shard test filename must resolve exactly once: '$name'."
        }
    }

    . (Join-Path $RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1') -DefineFunctionsOnly
    $authorityNames = @(Get-AuthorityTestPaths -Root $RepositoryRoot | ForEach-Object { [IO.Path]::GetFileName($_) })
    foreach ($name in $selectedTestNames) {
        if ($authorityNames -ccontains $name) { throw "Authority test cannot enter a Pester shard: '$name'." }
    }

    $skipSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($identifier in $expectedSkippedTests) {
        if (-not $skipSeen.Add($identifier)) { throw "The shard skip list contains a duplicate: '$identifier'." }
        if ($identifier -notmatch '^[^:/\\]+\.Tests\.ps1::\S.+$' -or
            $selectedTestNames -cnotcontains (($identifier -split '::', 2)[0])) {
            throw "Shard skip identifier is invalid or belongs to another shard: '$identifier'."
        }
    }
}
catch {
    throw "The Unix Core shard payload is invalid: $($_.Exception.Message)"
}

$resolvedOutputRoot = [IO.Path]::GetFullPath($OutputRoot)
[IO.Directory]::CreateDirectory($resolvedOutputRoot) | Out-Null
$executorHostPath = Join-Path $resolvedOutputRoot '.invoke-executor.ps1'
$executorHostText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ArgumentsPath,
    [Parameter(Mandatory = $true)][string] $OutcomePath
)
$ErrorActionPreference = 'Stop'
try {
    $request = Import-Clixml -LiteralPath $ArgumentsPath
    $executorArguments = $request.ExecutorArguments
    & ([string]$request.ExecutorPath) @executorArguments
    if (-not $?) { throw 'The Pester shard executor returned an unsuccessful invocation status.' }
    $outcome = [pscustomobject]@{ outcome = 'success'; error = $null }
    $exitCode = 0
}
catch {
    $outcome = [pscustomobject]@{ outcome = 'failure'; error = [string]$_.Exception.Message }
    $exitCode = 1
}
[IO.File]::WriteAllText($OutcomePath, ($outcome | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
exit $exitCode
'@
[IO.File]::WriteAllText($executorHostPath, $executorHostText, [Text.UTF8Encoding]::new($false))

$fileSummaries = [Collections.Generic.List[object]]::new()
$failedFiles = [Collections.Generic.List[string]]::new()
$pwshPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$fileCount = $selectedTestNames.Count

for ($fileIndex = 0; $fileIndex -lt $fileCount; $fileIndex++) {
    $position = $fileIndex + 1
    $positionText = '{0:D2}' -f $position
    $fileName = $selectedTestNames[$fileIndex]
    $fileRoot = Join-Path $resolvedOutputRoot "files/$positionText"
    $evidenceRoot = Join-Path $fileRoot 'evidence'
    [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
    $fileExpectedSkips = [string[]]@($expectedSkippedTests | Where-Object { $_.StartsWith("${fileName}::", [StringComparison]::Ordinal) })
    [Array]::Sort($fileExpectedSkips, [StringComparer]::Ordinal)

    $executorArguments = @{
        PesterModulePath = $PesterModulePath
        PesterVersion = '4.10.1'
        ExpectedSkippedCount = $fileExpectedSkips.Count
        ExpectedSkippedTests = $fileExpectedSkips
        IsolatedTestFileNames = [string[]]@()
        BulkShardSize = 1
        ShardPartitionCount = 1
        ShardPartitionIndex = 0
        OuterTimeoutSeconds = $OuterTimeoutSeconds
        TestRoot = $TestRoot
        EvidenceRoot = $evidenceRoot
        SelectedTestFileNames = [string[]]@($fileName)
        SummaryOutputPath = Join-Path $evidenceRoot 'executor-summary.json'
        SummarySchemaVersion = 2
        SummaryRunId = $RunId
        SummaryRunAttempt = $RunAttempt
        IsolationRequirement = 'cooperative'
    }
    $argumentsPath = Join-Path $fileRoot 'executor-arguments.clixml'
    $outcomePath = Join-Path $fileRoot 'executor-outcome.json'
    [pscustomobject]@{ ExecutorPath = [IO.Path]::GetFullPath($ExecutorPath); ExecutorArguments = $executorArguments } |
        Export-Clixml -LiteralPath $argumentsPath -Depth 8

    $executorOutcome = 'failure'
    $executorError = $null
    $process = $null
    Write-Host "::group::$PlatformId shard $ShardId [$position/$fileCount] $fileName"
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.WorkingDirectory = (Get-Location).ProviderPath
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$executorHostPath,'-ArgumentsPath',$argumentsPath,'-OutcomePath',$outcomePath)) {
            $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        if (Test-Path -LiteralPath $outcomePath -PathType Leaf) {
            $executorResult = Get-Content -Raw -Encoding UTF8 -LiteralPath $outcomePath | ConvertFrom-Json
            $executorOutcome = [string]$executorResult.outcome
            $executorError = if ($null -eq $executorResult.error) { $null } else { [string]$executorResult.error }
        }
        elseif ($process.ExitCode -ne 0) {
            $executorError = "The executor host exited with code $($process.ExitCode) without an outcome."
        }
        else {
            $executorError = 'The executor host did not write an outcome.'
        }
        if ($process.ExitCode -ne 0 -and $executorOutcome -ceq 'success') {
            $executorOutcome = 'failure'
            $executorError = "The executor host exited with code $($process.ExitCode)."
        }
    }
    catch {
        $executorOutcome = 'failure'
        $executorError = [string]$_.Exception.Message
    }
    finally {
        Write-Host '::endgroup::'
        if ($null -ne $process) { $process.Dispose() }
    }

    $counts = [ordered]@{ total=0; passed=0; failed=0; skipped=0; pending=0; inconclusive=0 }
    $skippedTests = [string[]]@()
    $failedTests = [string[]]@()
    $resultFiles = @(Get-ChildItem -LiteralPath $evidenceRoot -Filter 'pester-shard-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.process.json' -and $_.Name -notlike '*.cases.json' })
    if ($resultFiles.Count -ne 1) {
        $failedTests = [string[]]@("[runner failure] expected exactly one Pester child result; found $($resultFiles.Count)")
        $passed = $false
    }
    else {
        try {
            $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultFiles[0].FullName | ConvertFrom-Json
            $casePath = $resultFiles[0].FullName + '.cases.json'
            $cases = if (Test-Path -LiteralPath $casePath -PathType Leaf) {
                @((Get-Content -Raw -Encoding UTF8 -LiteralPath $casePath | ConvertFrom-Json).cases)
            } else { @() }
            $skippedTests = [string[]]@($cases | Where-Object result -ceq 'Skipped' |
                ForEach-Object { "${fileName}::$($_.name)" } | Sort-Object -CaseSensitive)
            $failedTests = [string[]]@($cases | Where-Object { $_.result -notin @('Passed','Skipped') } |
                ForEach-Object { [string]$_.name } | Sort-Object -CaseSensitive)
            if ($failedTests.Count -eq 0 -and [int]$result.FailedCount -gt 0) {
                $failedTests = [string[]]@($(if ([string]::IsNullOrWhiteSpace([string]$result.failurePhase)) {
                    '[runner failure]'
                } else { '[runner failure] ' + [string]$result.failurePhase }))
            }
            $counts = [ordered]@{
                total=[int]$result.TotalCount; passed=[int]$result.PassedCount; failed=[int]$result.FailedCount
                skipped=[int]$result.SkippedCount; pending=[int]$result.PendingCount; inconclusive=[int]$result.InconclusiveCount
            }
            $skipInventoryMatches = (($fileExpectedSkips -join "`n") -ceq ($skippedTests -join "`n"))
            $passed = ($executorOutcome -ceq 'success' -and [string]$result.status -ceq 'completed' -and
                [int]$result.FailedCount -eq 0 -and [int]$result.PendingCount -eq 0 -and
                [int]$result.InconclusiveCount -eq 0 -and $skipInventoryMatches)
        }
        catch {
            $failedTests = [string[]]@('[runner failure] ' + [string]$_.Exception.Message)
            $passed = $false
        }
    }

    $status = if ($passed) { 'passed' } else { 'failed' }
    $fileSummary = [pscustomobject][ordered]@{
        schemaVersion = 2; platform = $PlatformId; shard = $ShardId; planSha256 = $PlanSha256
        file = $fileName; runId = $RunId; runAttempt = $RunAttempt; status = $status
        executorOutcome = $executorOutcome; error = $executorError
        counts = [pscustomobject]$counts
        expectedSkippedTests = $fileExpectedSkips; skippedTests = $skippedTests; failedTests = $failedTests
    }
    Write-UnixCoreJson -Path (Join-Path $fileRoot 'summary.json') -Value $fileSummary
    $fileSummaries.Add($fileSummary)
    $label = if ($passed) { 'PASSED' } else { 'FAILED' }
    Write-Host "[$position/$fileCount] $fileName : $label (passed $($counts.passed), failed $($counts.failed), skipped $($counts.skipped))"
    if (-not $passed) {
        $failedFiles.Add($fileName)
        $failureText = if ($failedTests.Count -eq 0) { '[runner failure]' } else { $failedTests -join '; ' }
        if ($failureText.Length -gt 1000) { $failureText = $failureText.Substring(0, 1000) }
        Write-Host "::error title=Unix Core $PlatformId shard $ShardId::$(ConvertTo-UnixCoreCommandMessage "$fileName failed: $failureText")"
    }
}

$shardStatus = if ($failedFiles.Count -eq 0) { 'passed' } else { 'failed' }
$shardSummary = [pscustomobject][ordered]@{
    schemaVersion = 2; platform = $PlatformId; shard = $ShardId; planSha256 = $PlanSha256
    runId = $RunId; runAttempt = $RunAttempt; status = $shardStatus
    files = [object[]]@($fileSummaries | ForEach-Object {
        [pscustomobject][ordered]@{
            index = [int]($fileSummaries.IndexOf($_) + 1); file = $_.file; status = $_.status
            passed = [int]$_.counts.passed; failed = [int]$_.counts.failed; skipped = [int]$_.counts.skipped
        }
    })
}
Write-UnixCoreJson -Path (Join-Path $resolvedOutputRoot 'shard-summary.json') -Value $shardSummary

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $markdown = [Text.StringBuilder]::new()
    [void]$markdown.AppendLine("### $PlatformId shard $ShardId")
    [void]$markdown.AppendLine()
    [void]$markdown.AppendLine('| # | File | Status | Passed | Failed | Skipped | Failing tests |')
    [void]$markdown.AppendLine('|---:|---|---|---:|---:|---:|---|')
    for ($index = 0; $index -lt $fileSummaries.Count; $index++) {
        $item = $fileSummaries[$index]
        $failing = if (@($item.failedTests).Count -eq 0) { 'none' } else { @($item.failedTests) -join '; ' }
        $cells = @([string]($index + 1), [string]$item.file, [string]$item.status,
            [string]$item.counts.passed, [string]$item.counts.failed, [string]$item.counts.skipped, $failing) |
            ForEach-Object { $_.Replace('|','\|').Replace("`r",' ').Replace("`n",' ') }
        [void]$markdown.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    if ($failedFiles.Count -gt 0) {
        [void]$markdown.AppendLine()
        [void]$markdown.AppendLine('**Failed files:** ' + ($failedFiles -join ', '))
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StepSummaryPath))) | Out-Null
    [IO.File]::AppendAllText($StepSummaryPath, $markdown.ToString(), [Text.UTF8Encoding]::new($false))
}

if ($failedFiles.Count -gt 0) {
    throw "Unix Core $PlatformId shard $ShardId failed: $($failedFiles -join ', ')"
}
