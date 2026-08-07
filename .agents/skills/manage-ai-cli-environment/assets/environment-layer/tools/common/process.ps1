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

function ConvertTo-PowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function New-UserControlledPowerShellLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string] $WindowTitle,

        [string[]] $Instructions = @(),

        [switch] $WaitForExit
    )

    $resolvedWorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
        throw "Working directory does not exist: $resolvedWorkingDirectory"
    }

    $resolvedCommand = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $resolvedCommand) {
        throw "Command was not found: $Command"
    }

    $commandPath = if (-not [string]::IsNullOrWhiteSpace([string] $resolvedCommand.Source)) {
        [string] $resolvedCommand.Source
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string] $resolvedCommand.Path)) {
        [string] $resolvedCommand.Path
    }
    else {
        [string] $resolvedCommand.Name
    }

    $powerShellPath = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        $powerShellPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    $commandLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $commandPath
    $workingDirectoryLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $resolvedWorkingDirectory
    $windowTitleLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $WindowTitle
    $argumentLiterals = @($Arguments | ForEach-Object { ConvertTo-PowerShellSingleQuotedLiteral -Value ([string] $_) })
    $argumentText = if ($argumentLiterals.Count -gt 0) { ' ' + ($argumentLiterals -join ' ') } else { '' }

    $scriptLines = [System.Collections.Generic.List[string]]::new()
    $scriptLines.Add('$ErrorActionPreference = ''Stop''')
    $scriptLines.Add("`$Host.UI.RawUI.WindowTitle = $windowTitleLiteral")
    $scriptLines.Add("Set-Location -LiteralPath $workingDirectoryLiteral")
    $scriptLines.Add("Write-Host $windowTitleLiteral -ForegroundColor Cyan")
    foreach ($instruction in $Instructions) {
        $instructionLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value ([string] $instruction)
        $scriptLines.Add("Write-Host $instructionLiteral")
    }
    $scriptLines.Add("Write-Host ''")
    $scriptLines.Add('$providerExitCode = 1')
    $scriptLines.Add('try {')
    $scriptLines.Add("    & $commandLiteral$argumentText")
    $scriptLines.Add('    $providerExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }')
    $scriptLines.Add('}')
    $scriptLines.Add('catch {')
    $scriptLines.Add('    Write-Host (''Unable to start CLI: '' + $_.Exception.Message) -ForegroundColor Red')
    $scriptLines.Add('}')
    $scriptLines.Add("Write-Host ''")
    $scriptLines.Add("Write-Host 'The CLI session has exited. Review the result above.' -ForegroundColor DarkGray")
    $scriptLines.Add("[void] (Read-Host 'Press Enter to close this window')")
    $scriptLines.Add('exit $providerExitCode')

    $encodedCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes(($scriptLines -join [Environment]::NewLine))
    )

    return [pscustomobject]@{
        filePath = $powerShellPath
        arguments = @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedCommand)
        workingDirectory = $resolvedWorkingDirectory
        windowStyle = 'Normal'
        waitForExit = [bool] $WaitForExit
    }
}

function Start-UserControlledPowerShellProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string] $WindowTitle,

        [string[]] $Instructions = @(),

        [switch] $WaitForExit,

        [scriptblock] $ProcessStarter = {
            param($Launch)
            Start-Process `
                -FilePath $Launch.filePath `
                -ArgumentList $Launch.arguments `
                -WorkingDirectory $Launch.workingDirectory `
                -WindowStyle $Launch.windowStyle `
                -PassThru
        }
    )

    try {
        $launch = New-UserControlledPowerShellLaunch `
            -Command $Command `
            -Arguments $Arguments `
            -WorkingDirectory $WorkingDirectory `
            -WindowTitle $WindowTitle `
            -Instructions $Instructions `
            -WaitForExit:$WaitForExit
        $process = & $ProcessStarter $launch

        $exitCode = $null
        if ($WaitForExit) {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }

        return [pscustomobject]@{
            started = $true
            processId = [int] $process.Id
            exitCode = $exitCode
            reason = $null
        }
    }
    catch {
        return [pscustomobject]@{
            started = $false
            processId = $null
            exitCode = $null
            reason = $_.Exception.Message
        }
    }
}
