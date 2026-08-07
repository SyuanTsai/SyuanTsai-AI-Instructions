Set-StrictMode -Version Latest

function Invoke-CapturedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [hashtable] $Environment = @{},

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 30
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = $null

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Command
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

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Process '$Command' did not start."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $finished) {
            try {
                $process.Kill($true)
                $process.WaitForExit()
            }
            catch {
                # The process may already have exited while the timeout was handled.
            }
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
        $resolvedCommand = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
        $isMissing = $null -eq $resolvedCommand
        $resolvedSource = if ($null -ne $resolvedCommand -and $resolvedCommand.CommandType -eq 'Application') {
            [string] $resolvedCommand.Source
        }
        else {
            $null
        }
        if (-not $isMissing -and -not [string]::IsNullOrWhiteSpace($resolvedSource)) {
            $suppliedPath = try { [System.IO.Path]::GetFullPath($Command) } catch { $Command }
            if (-not $resolvedSource.Equals($suppliedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return Invoke-CapturedProcess `
                    -Command $resolvedSource `
                    -Arguments $Arguments `
                    -Environment $Environment `
                    -TimeoutSeconds $TimeoutSeconds
            }
        }
        $startError = if ($isMissing) { 'command_not_found' } else { $null }
        $exception = $_.Exception
        while ($null -ne $exception -and $null -eq $startError) {
            if ($exception -is [System.UnauthorizedAccessException] -or
                ($exception -is [System.ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 5)) {
                $startError = 'permission_denied'
            }
            $exception = $exception.InnerException
        }

        return [pscustomobject]@{
            started = $false
            exitCode = $null
            stdout = ''
            stderr = $_.Exception.Message
            commandNotFound = $isMissing
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

function Invoke-InteractiveProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [hashtable] $Environment = @{}
    )

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Command
        $startInfo.UseShellExecute = $false

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

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $process.Dispose()
        return $exitCode -eq 0
    }
    catch {
        $resolvedCommand = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
        $resolvedSource = if ($null -ne $resolvedCommand -and $resolvedCommand.CommandType -eq 'Application') {
            [string] $resolvedCommand.Source
        }
        else {
            $null
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedSource)) {
            $suppliedPath = try { [System.IO.Path]::GetFullPath($Command) } catch { $Command }
            if (-not $resolvedSource.Equals($suppliedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return Invoke-InteractiveProcess `
                    -Command $resolvedSource `
                    -Arguments $Arguments `
                    -Environment $Environment
            }
        }
        return $false
    }
}
