[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][ValidateSet('3.4.0', '4.10.1')][string] $PesterVersion,
    [Parameter(Mandatory = $true)][int] $ExpectedTotalCount,
    [Parameter(Mandatory = $true)][int] $ExpectedSkippedCount,
    [string[]] $IsolatedTestFileNames = @(
        'standard-validation-runner.Tests.ps1',
        'syp101-production-smoke-contract.Tests.ps1'
    ),
    [int] $OuterTimeoutSeconds = 1800,
    [string] $CancellationPath,
    [string] $TestRoot = './tests',
    [string] $EvidenceRoot
)

$ErrorActionPreference = 'Stop'

if ($OuterTimeoutSeconds -le 0) { throw 'OuterTimeoutSeconds must be positive.' }
if (-not (Test-Path -LiteralPath $PesterModulePath -PathType Leaf)) {
    throw "Pester module path does not identify a file: $PesterModulePath"
}

$repositoryRoot = (Get-Location).Path
$resolvedTestRoot = (Resolve-Path -LiteralPath $TestRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = $env:RUNNER_TEMP }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path $repositoryRoot '.syp154-pester-evidence' }
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($CancellationPath)) {
    $CancellationPath = Join-Path $EvidenceRoot 'syp154-pester-shard.cancel'
}
Remove-Item -LiteralPath $CancellationPath -Force -ErrorAction SilentlyContinue

function Test-PesterShardProcessAlive {
    param([Parameter(Mandatory = $true)][int] $ProcessId)

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return (-not [bool]$process.HasExited)
    }
    catch {
        return $false
    }
}

function Get-PesterShardDescendantProcessIds {
    param([Parameter(Mandatory = $true)][int] $RootProcessId)

    $processes = @(
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Select-Object -Property ProcessId, ParentProcessId
    )
    $frontier = @($RootProcessId)
    $descendants = New-Object 'System.Collections.Generic.List[int]'
    while ($frontier.Count -gt 0) {
        $next = New-Object 'System.Collections.Generic.List[int]'
        foreach ($process in $processes) {
            $processId = [int]$process.ProcessId
            if (($frontier -contains [int]$process.ParentProcessId) -and
                $processId -ne $RootProcessId -and -not $descendants.Contains($processId)) {
                $descendants.Add($processId)
                $next.Add($processId)
            }
        }
        $frontier = @($next.ToArray())
    }
    return @($descendants.ToArray())
}

function Read-PesterShardOutputPrefix {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [int] $MaxChars = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    $reader = $null
    $builder = New-Object System.Text.StringBuilder
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::UTF8), $true
        $buffer = New-Object char[] 4096
        $remaining = [Math]::Max(0, $MaxChars)
        while ($remaining -gt 0) {
            $read = $reader.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
            if ($read -le 0) { break }
            [void]$builder.Append($buffer, 0, $read)
            $remaining -= $read
        }
        return $builder.ToString()
    }
    catch {
        return "<output-read-error: $($_.Exception.Message)>"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Stop-PesterShardOwnedProcessTree {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [int[]] $ObservedDescendantProcessIds = @()
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $taskKillExitCodes = New-Object 'System.Collections.Generic.List[int]'
    $knownIds = New-Object 'System.Collections.Generic.List[int]'
    foreach ($processId in @($RootProcessId) + @($ObservedDescendantProcessIds)) {
        if ($processId -gt 0 -and -not $knownIds.Contains([int]$processId)) {
            $knownIds.Add([int]$processId)
        }
    }

    $initialDescendants = @()
    try {
        $initialDescendants = @(Get-PesterShardDescendantProcessIds -RootProcessId $RootProcessId)
        foreach ($processId in $initialDescendants) {
            if ($processId -gt 0 -and -not $knownIds.Contains([int]$processId)) {
                $knownIds.Add([int]$processId)
            }
        }
    }
    catch {
        $errors.Add("initial descendant enumeration failed: $($_.Exception.Message)")
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $liveIds = @($knownIds.ToArray() | Where-Object {
            Test-PesterShardProcessAlive -ProcessId ([int]$_)
        })
        if ($liveIds.Count -eq 0) { break }

        foreach ($processId in $liveIds) {
            $taskKillOutput = @()
            $taskKillExitCode = -1
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $taskKillOutput = @(& taskkill.exe '/PID' ([string]$processId) '/T' '/F' 2>&1)
                $taskKillExitCode = [int]$LASTEXITCODE
            }
            catch {
                $taskKillOutput += $_.Exception.Message
                $errors.Add("taskkill invocation failed for owned process ${processId}: $($_.Exception.Message)")
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            $taskKillExitCodes.Add($taskKillExitCode)
            if (($taskKillExitCode -ne 0) -and
                (Test-PesterShardProcessAlive -ProcessId ([int]$processId))) {
                $errors.Add("taskkill failed for owned process $processId (exit $taskKillExitCode): $($taskKillOutput -join ' ')")
            }
        }
        Start-Sleep -Milliseconds 200

        try {
            $currentDescendants = @(Get-PesterShardDescendantProcessIds -RootProcessId $RootProcessId)
            foreach ($processId in $currentDescendants) {
                if ($processId -gt 0 -and -not $knownIds.Contains([int]$processId)) {
                    $knownIds.Add([int]$processId)
                }
            }
        }
        catch {
            $errors.Add("descendant enumeration after cleanup failed: $($_.Exception.Message)")
            break
        }
    }

    $remainingIds = @($knownIds.ToArray() | Where-Object {
        Test-PesterShardProcessAlive -ProcessId ([int]$_)
    })
    $finalDescendants = @()
    try {
        $finalDescendants = @(Get-PesterShardDescendantProcessIds -RootProcessId $RootProcessId)
    }
    catch {
        $errors.Add("final descendant enumeration failed: $($_.Exception.Message)")
    }
    $cleanedUp = ($errors.Count -eq 0 -and $remainingIds.Count -eq 0 -and $finalDescendants.Count -eq 0)
    return [pscustomobject][ordered]@{
        rootProcessId = $RootProcessId
        initialDescendantProcessIds = @($initialDescendants)
        observedProcessIds = @($knownIds.ToArray())
        remainingProcessIds = @($remainingIds)
        finalDescendantProcessIds = @($finalDescendants)
        taskKillExitCodes = @($taskKillExitCodes.ToArray())
        errors = @($errors.ToArray())
        cleanedUp = $cleanedUp
    }
}

function Invoke-PesterShardProcess {
    param(
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][string] $ModulePath,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $ChildPowerShell,
        [Parameter(Mandatory = $true)][string] $EncodedChildScript,
        [Parameter(Mandatory = $true)][string] $ResultPath,
        [Parameter(Mandatory = $true)][string] $ProcessEvidencePath,
        [Parameter(Mandatory = $true)][string] $StdoutPath,
        [Parameter(Mandatory = $true)][string] $StderrPath,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $CancelPath,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory
    )

    $process = $null
    $status = 'not-started'
    $exitCode = $null
    $startedAt = $null
    $finishedAt = $null
    $exceptionText = $null
    $cleanup = [pscustomobject][ordered]@{
        cleanedUp = $true
        reason = 'process-not-started'
    }
    $evidenceWriteError = $null

    try {
        if (Test-Path -LiteralPath $CancelPath -PathType Leaf) {
            $status = 'cancelled'
            $exceptionText = "Cancellation marker already exists: $CancelPath"
        }
        else {
            $startedAt = [DateTime]::UtcNow.ToString('o')
            $startParameters = @{
                FilePath = $ChildPowerShell
                ArgumentList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $EncodedChildScript)
                WorkingDirectory = $WorkingDirectory
                RedirectStandardOutput = $StdoutPath
                RedirectStandardError = $StderrPath
                WindowStyle = 'Hidden'
                PassThru = $true
                ErrorAction = 'Stop'
            }
            $process = Start-Process @startParameters
            $status = 'running'
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            while (-not $process.HasExited) {
                if (Test-Path -LiteralPath $CancelPath -PathType Leaf) {
                    $status = 'cancelled'
                    $exceptionText = "Cancellation marker observed: $CancelPath"
                    break
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    $status = 'timeout'
                    $exceptionText = "Outer shard deadline exceeded after $TimeoutSeconds seconds."
                    break
                }
                [void]$process.WaitForExit(1000)
            }
            if ($process.HasExited -and $status -notin @('cancelled', 'timeout')) {
                [void]$process.WaitForExit()
                $exitCode = [int]$process.ExitCode
                $status = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
            }
        }
    }
    catch {
        $exceptionText = $_.Exception.ToString()
        if ($null -eq $process) { $status = 'startup-failed' }
        elseif ($status -notin @('cancelled', 'timeout')) { $status = 'failed' }
    }
    finally {
        if ($null -ne $process) {
            try {
                $cleanup = Stop-PesterShardOwnedProcessTree -RootProcessId ([int]$process.Id)
            }
            catch {
                $cleanup = [pscustomobject][ordered]@{
                    rootProcessId = [int]$process.Id
                    initialDescendantProcessIds = @()
                    observedProcessIds = @([int]$process.Id)
                    remainingProcessIds = @()
                    finalDescendantProcessIds = @()
                    taskKillExitCodes = @()
                    errors = @("cleanup executor exception: $($_.Exception.ToString())")
                    cleanedUp = $false
                }
            }
            if (-not $cleanup.cleanedUp) { $status = 'cleanup-failed' }
            if ($process.HasExited -and $null -eq $exitCode -and
                $status -notin @('cancelled', 'timeout', 'cleanup-failed')) {
                $exitCode = [int]$process.ExitCode
            }
        }
        $finishedAt = [DateTime]::UtcNow.ToString('o')
        $resultExists = Test-Path -LiteralPath $ResultPath -PathType Leaf
        $diagnostic = [ordered]@{
            schemaVersion = 1
            kind = 'syp154-pester-shard-process'
            status = $status
            pesterVersion = $Version
            powershellVersion = [string]$PSVersionTable.PSVersion
            powershellEdition = [string]$PSVersionTable.PSEdition
            workingDirectory = $WorkingDirectory
            paths = @($Paths)
            modulePath = $ModulePath
            childPowerShell = $ChildPowerShell
            timeoutSeconds = $TimeoutSeconds
            cancellationPath = $CancelPath
            environmentNames = @(
                'SYP154_PESTER_SHARD_PATHS',
                'SYP154_PESTER_MODULE_PATH',
                'SYP154_PESTER_RESULT_PATH'
            )
            startedAt = $startedAt
            finishedAt = $finishedAt
            processId = if ($null -ne $process) { [int]$process.Id } else { $null }
            exitCode = $exitCode
            resultPath = $ResultPath
            resultExists = $resultExists
            stdoutPath = $StdoutPath
            stderrPath = $StderrPath
            pathLengths = [ordered]@{
                result = $ResultPath.Length
                stdout = $StdoutPath.Length
                stderr = $StderrPath.Length
                cancellation = $CancelPath.Length
            }
            cleanup = $cleanup
            exception = $exceptionText
            stdoutPrefix = Read-PesterShardOutputPrefix -Path $StdoutPath
            stderrPrefix = Read-PesterShardOutputPrefix -Path $StderrPath
        }
        try {
            [IO.File]::WriteAllText(
                $ProcessEvidencePath,
                ($diagnostic | ConvertTo-Json -Depth 12),
                (New-Object Text.UTF8Encoding($false))
            )
        }
        catch {
            $evidenceWriteError = $_.Exception.ToString()
        }
    }

    if ($null -ne $evidenceWriteError) {
        throw "Could not save Pester shard process evidence '$ProcessEvidencePath': $evidenceWriteError"
    }
    if ($status -notin @('completed', 'failed') -or -not $resultExists -or -not $cleanup.cleanedUp) {
        Write-Host ("Pester shard process evidence summary: status={0}; exitCode={1}; resultExists={2}; cleanedUp={3}; remainingProcessIds={4}; pathLengths=result:{5},stdout:{6},stderr:{7},cancel:{8}; evidence={9}" -f `
            $status, $exitCode, $resultExists, $cleanup.cleanedUp,
            (@($cleanup.remainingProcessIds) -join ','), $ResultPath.Length, $StdoutPath.Length,
            $StderrPath.Length, $CancelPath.Length, $ProcessEvidencePath)
        if (@($cleanup.errors).Count -gt 0) {
            Write-Host ("Pester shard cleanup errors: {0}" -f (@($cleanup.errors) -join ' | '))
        }
    }
    if ($status -notin @('completed', 'failed')) {
        throw "Pester shard process ended with status '$status'; evidence='$ProcessEvidencePath'. $exceptionText"
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "Pester shard process '$status' exited without a result file; evidence='$ProcessEvidencePath'; exit='$exitCode'."
    }
    if (-not $cleanup.cleanedUp) {
        throw "Pester shard process cleanup failed; evidence='$ProcessEvidencePath'."
    }
    return [pscustomobject][ordered]@{
        resultPath = $ResultPath
        processEvidencePath = $ProcessEvidencePath
        stdoutPath = $StdoutPath
        stderrPath = $StderrPath
        status = $status
        exitCode = $exitCode
        cleanedUp = [bool]$cleanup.cleanedUp
    }
}

Import-Module $PesterModulePath -Force -ErrorAction Stop
$loadedPester = Get-Module -Name Pester |
    Where-Object { $_.Version -eq [version]$PesterVersion } |
    Select-Object -First 1
if ($null -eq $loadedPester) {
    throw "Pester module version mismatch. Expected $PesterVersion at '$PesterModulePath'."
}
$invokePester = Get-Command Invoke-Pester -ErrorAction Stop |
    Where-Object { $_.Module.Version -eq [version]$PesterVersion } |
    Select-Object -First 1
if ($null -eq $invokePester) { throw "Invoke-Pester $PesterVersion could not be resolved." }

$allTestPaths = @(
    Get-ChildItem -LiteralPath $resolvedTestRoot -Filter '*.Tests.ps1' -File |
        Sort-Object FullName |
        ForEach-Object { [string]$_.FullName }
)
if ($allTestPaths.Count -eq 0) { throw 'No Pester test files were discovered.' }

$isolatedPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($name in $IsolatedTestFileNames) {
    $matches = @($allTestPaths | Where-Object { (Split-Path -Leaf $_) -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected exactly one isolated test file named '$name'; found $($matches.Count)." }
    $isolatedPaths.Add([string]$matches[0])
}
$bulkPaths = @($allTestPaths | Where-Object { $isolatedPaths -notcontains [string]$_ })
$partitionedPaths = @($isolatedPaths.ToArray()) + @($bulkPaths)
if (($partitionedPaths.Count -ne $allTestPaths.Count) -or
    ((($partitionedPaths | Sort-Object) -join [Environment]::NewLine) -cne
     (($allTestPaths | Sort-Object) -join [Environment]::NewLine))) {
    throw 'Pester shard inventory is not an exact partition of the discovered test files.'
}

$shards = New-Object 'System.Collections.Generic.List[object]'
foreach ($name in $IsolatedTestFileNames) {
    $shards.Add([pscustomobject]@{
        Name = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($name))
        Paths = @($isolatedPaths | Where-Object { (Split-Path -Leaf $_) -ceq $name })
    })
}
$shards.Add([pscustomobject]@{ Name = 'bulk'; Paths = $bulkPaths })

$childPowerShell = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    (Get-Command powershell -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
else {
    (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
$childScript = @(
    '$ErrorActionPreference = ''Stop'''
    '$paths = @($env:SYP154_PESTER_SHARD_PATHS | ConvertFrom-Json)'
    'if ($paths.Count -eq 0) { throw ''Pester shard has no test paths.'' }'
    'Import-Module $env:SYP154_PESTER_MODULE_PATH -Force'
    ('$invoke = Get-Command Invoke-Pester -ErrorAction Stop | Where-Object {{ $_.Module.Version -eq [version]''{0}'' }} | Select-Object -First 1' -f $PesterVersion)
    ('if ($null -eq $invoke) {{ throw ''Pester shard could not resolve version {0}.'' }}' -f $PesterVersion)
    '$invokeParameters = @{ Script = $paths; PassThru = $true }'
    '$result = & $invoke @invokeParameters'
    'if ($null -eq $result) { throw ''Pester shard did not return a result object.'' }'
    '$summary = [ordered]@{'
    '    TotalCount = [int]$result.TotalCount'
    '    PassedCount = [int]$result.PassedCount'
    '    FailedCount = [int]$result.FailedCount'
    '    SkippedCount = [int]$result.SkippedCount'
    '    PendingCount = [int]$result.PendingCount'
    '    InconclusiveCount = [int]$result.InconclusiveCount'
    '}'
    '[IO.File]::WriteAllText($env:SYP154_PESTER_RESULT_PATH, ($summary | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))'
    'if ($summary.FailedCount -gt 0 -or $summary.PendingCount -gt 0 -or $summary.InconclusiveCount -gt 0) { exit 2 }'
    'exit 0'
) -join [Environment]::NewLine
$encodedChildScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

$total = 0
$passed = 0
$failed = 0
$skipped = 0
$pending = 0
$inconclusive = 0
$failedShardProcess = $false
foreach ($shard in @($shards.ToArray())) {
    $runToken = [guid]::NewGuid().ToString('N')
    $safeName = ($shard.Name -replace '[^A-Za-z0-9_.-]', '-')
    $resultPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.json" -f $safeName, $runToken)
    $processEvidencePath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.process.json" -f $safeName, $runToken)
    $stdoutPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stdout.log" -f $safeName, $runToken)
    $stderrPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stderr.log" -f $safeName, $runToken)
    $previous = @{}
    $environment = @{
        SYP154_PESTER_SHARD_PATHS = ($shard.Paths | ConvertTo-Json -Compress)
        SYP154_PESTER_MODULE_PATH = [string]$PesterModulePath
        SYP154_PESTER_RESULT_PATH = $resultPath
    }
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        $shardParameters = @{
            Paths = $shard.Paths
            ModulePath = $PesterModulePath
            Version = $PesterVersion
            ChildPowerShell = $childPowerShell
            EncodedChildScript = $encodedChildScript
            ResultPath = $resultPath
            ProcessEvidencePath = $processEvidencePath
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
            TimeoutSeconds = $OuterTimeoutSeconds
            CancelPath = $CancellationPath
            WorkingDirectory = $repositoryRoot
        }
        $shardRun = Invoke-PesterShardProcess @shardParameters
    }
    finally {
        foreach ($entry in $environment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $previous[$entry.Key], 'Process')
        }
    }

    $resultPath = [string]$shardRun.resultPath
    $summary = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($field in @('TotalCount', 'PassedCount', 'FailedCount', 'SkippedCount', 'PendingCount', 'InconclusiveCount')) {
        if ($summary.$field -isnot [int] -and $summary.$field -isnot [long]) {
            throw "Pester shard '$($shard.Name)' returned a non-integer $field. Process evidence='$($shardRun.processEvidencePath)'."
        }
    }
    Write-Host "$($shard.Name) - Total: $($summary.TotalCount) Passed: $($summary.PassedCount) Failed: $($summary.FailedCount) Skipped: $($summary.SkippedCount)"
    $total += [int]$summary.TotalCount
    $passed += [int]$summary.PassedCount
    $failed += [int]$summary.FailedCount
    $skipped += [int]$summary.SkippedCount
    $pending += [int]$summary.PendingCount
    $inconclusive += [int]$summary.InconclusiveCount
    if ([int]$shardRun.exitCode -ne 0) { $failedShardProcess = $true }
}

if ($failedShardProcess) { throw 'At least one isolated Pester shard exited nonzero.' }
if ($total -ne $ExpectedTotalCount) { throw "Pester discovered $total tests across shards; expected exactly $ExpectedTotalCount." }
if ($failed -gt 0) { throw "Pester reported $failed failed tests." }
if ($pending -ne 0) { throw "Pester reported $pending pending tests." }
if ($inconclusive -ne 0) { throw "Pester reported $inconclusive inconclusive tests." }
if ($skipped -ne $ExpectedSkippedCount) { throw "Pester expected exactly $ExpectedSkippedCount platform/version skips; got $skipped." }
if (($passed + $skipped) -ne $total) { throw 'Pester aggregate result counts are incomplete.' }
Write-Host "Aggregate - Total: $total Passed: $passed Failed: $failed Skipped: $skipped"
