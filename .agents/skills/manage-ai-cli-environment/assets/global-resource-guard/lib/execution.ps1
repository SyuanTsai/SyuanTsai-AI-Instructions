Set-StrictMode -Version Latest

function Invoke-GlobalCapturedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [hashtable] $Environment = @{},

        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory,

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 86400
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Command
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        foreach ($argument in $Arguments) {
            $startInfo.ArgumentList.Add([string] $argument)
        }
        foreach ($entry in $Environment.GetEnumerator()) {
            if ($null -eq $entry.Value) {
                $startInfo.Environment.Remove([string] $entry.Key) | Out-Null
            }
            else {
                $startInfo.Environment[[string] $entry.Key] = [string] $entry.Value
            }
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Process '$Command' did not start."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            try { $process.Kill($true); $process.WaitForExit() } catch { }
        }
        $stopwatch.Stop()
        return [pscustomobject]@{
            started = $true
            exitCode = if ($finished) { $process.ExitCode } else { $null }
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
            commandNotFound = $false
            timedOut = -not $finished
            startError = $null
            durationMs = $stopwatch.ElapsedMilliseconds
        }
    }
    catch {
        $stopwatch.Stop()
        $commandExists = $null -ne (Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1)
        $startError = if (-not $commandExists) {
            'command_not_found'
        }
        elseif ($_.Exception -is [UnauthorizedAccessException] -or
            ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 5)) {
            'permission_denied'
        }
        else {
            'start_failed'
        }
        return [pscustomobject]@{
            started = $false
            exitCode = $null
            stdout = ''
            stderr = ''
            commandNotFound = -not $commandExists
            timedOut = $false
            startError = $startError
            durationMs = $stopwatch.ElapsedMilliseconds
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-GlobalExecutionFailureReason {
    param([Parameter(Mandatory = $true)][psobject] $ProcessResult)

    if ($ProcessResult.commandNotFound -or $ProcessResult.startError -eq 'command_not_found') {
        return 'command_not_found'
    }
    if ($ProcessResult.startError -eq 'permission_denied') {
        return 'permission_denied'
    }
    if ($ProcessResult.timedOut) {
        return 'timeout'
    }
    $message = "$($ProcessResult.stderr)`n$($ProcessResult.stdout)"
    if ($message -match '(?i)not logged in|please sign in|authentication required|unauthori[sz]ed|invalid credential|\b401\b') {
        return 'authentication_required'
    }
    if ($message -match '(?i)permission denied|access is denied|forbidden|\b403\b') {
        return 'permission_denied'
    }
    return 'provider_error'
}

function Invoke-GlobalResourceExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [string] $GlobalRoot,

        [string[]] $Arguments = @(),

        [string] $WorkingDirectory = (Get-Location).Path,

        [scriptblock] $ResourceRuntimeResolver,

        [scriptblock] $ProcessRunner
    )

    $resolvedRoot = Resolve-GlobalAiResourceGuardRoot -GlobalRoot $GlobalRoot
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
        return [pscustomobject]@{
            resource = $ResourceName
            success = $false
            executed = $false
            reason = 'working_directory_missing'
            warning = $null
            evaluation = $null
            exitCode = $null
            result = $null
            durationMs = $null
        }
    }

    $evaluation = Resolve-GlobalResourceAvailability -ResourceName $ResourceName -GlobalRoot $resolvedRoot
    if (-not $evaluation.available) {
        return [pscustomobject]@{
            resource = $ResourceName
            success = $false
            executed = $false
            reason = $evaluation.reason
            warning = $evaluation.warning
            evaluation = $evaluation
            exitCode = $null
            result = $null
            durationMs = $null
        }
    }

    if ($null -eq $ResourceRuntimeResolver) {
        $ResourceRuntimeResolver = {
            param($Name, $Root)
            Get-GlobalResourceRuntime -ResourceName $Name -GlobalRoot $Root
        }
    }
    try {
        $runtime = & $ResourceRuntimeResolver $ResourceName $resolvedRoot
    }
    catch {
        return [pscustomobject]@{
            resource = $ResourceName
            success = $false
            executed = $false
            reason = if ($_.Exception.Message -eq 'provider_tools_missing') { 'provider_tools_missing' } else { 'resource_runtime_invalid' }
            warning = $evaluation.warning
            evaluation = $evaluation
            exitCode = $null
            result = $null
            durationMs = $null
        }
    }
    if ($null -ne $runtime.PSObject.Properties['ready'] -and -not [bool] $runtime.ready) {
        return [pscustomobject]@{
            resource = $ResourceName
            success = $false
            executed = $false
            reason = [string] $runtime.reason
            warning = $evaluation.warning
            evaluation = $evaluation
            exitCode = $null
            result = $null
            durationMs = $null
        }
    }

    $configuration = Read-GlobalAiResourceGuardConfiguration -GlobalRoot $resolvedRoot
    $timeoutSeconds = if ($null -ne $configuration.PSObject.Properties['commandTimeoutSeconds']) {
        [int] $configuration.commandTimeoutSeconds
    }
    else {
        86400
    }
    if ($null -eq $ProcessRunner) {
        $ProcessRunner = {
            param($Command, $Arguments, $Environment, $WorkingDirectory, $TimeoutSeconds)
            Invoke-GlobalCapturedProcess `
                -Command $Command `
                -Arguments $Arguments `
                -Environment $Environment `
                -WorkingDirectory $WorkingDirectory `
                -TimeoutSeconds $TimeoutSeconds
        }
    }

    $resourceArguments = @($runtime.argumentsPrefix) + @($Arguments)
    $execution = & $ProcessRunner `
        ([string] $runtime.command) `
        ([string[]] $resourceArguments) `
        ([hashtable] $runtime.environment) `
        $resolvedWorkingDirectory `
        $timeoutSeconds
    $success = $execution.started -and -not $execution.timedOut -and $execution.exitCode -eq 0
    return [pscustomobject]@{
        resource = $ResourceName
        success = $success
        executed = [bool] $execution.started
        reason = if ($success) { $null } else { Get-GlobalExecutionFailureReason -ProcessResult $execution }
        warning = $evaluation.warning
        evaluation = $evaluation
        exitCode = $execution.exitCode
        result = if ($success) { $execution.stdout } else { $null }
        durationMs = $execution.durationMs
    }
}
