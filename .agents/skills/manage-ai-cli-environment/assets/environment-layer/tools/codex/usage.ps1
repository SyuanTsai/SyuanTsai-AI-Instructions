Set-StrictMode -Version Latest

function Get-CodexPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-CodexPercent {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value -or $Value -is [bool]) {
        return $null
    }

    $number = 0.0
    if (-not [double]::TryParse(
        [string] $Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref] $number
    )) {
        return $null
    }
    return [Math]::Round([Math]::Min(100, [Math]::Max(0, $number)), 4)
}

function Get-CodexWindowScope {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $DurationMinutes,

        [string] $Fallback = 'unknown'
    )

    if ($null -eq $DurationMinutes) {
        return $Fallback
    }

    $minutes = 0.0
    if (-not [double]::TryParse(
        [string] $DurationMinutes,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref] $minutes
    )) {
        return $Fallback
    }
    if ($minutes -le 360) {
        return 'session'
    }
    if ($minutes -ge 8640) {
        return 'weekly'
    }
    return "window-$([Math]::Round($minutes, 2))m"
}

function New-CodexUnknownUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    return [pscustomobject]@{
        known = $false
        usedPercent = $null
        remainingPercent = $null
        scope = $null
        details = @()
        source = $Source
        reason = $Reason
        rateLimitReachedType = $null
        individualLimit = $null
        spendControlReached = $null
    }
}

function ConvertFrom-CodexAppServerWindow {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Window,

        [string] $FallbackScope
    )

    if ($null -eq $Window) {
        return $null
    }

    $usedPercent = ConvertTo-CodexPercent -Value (Get-CodexPropertyValue -InputObject $Window -Name 'usedPercent')
    if ($null -eq $usedPercent) {
        return $null
    }
    $durationMinutes = Get-CodexPropertyValue -InputObject $Window -Name 'windowDurationMins'

    return [pscustomobject]@{
        scope = Get-CodexWindowScope -DurationMinutes $durationMinutes -Fallback $FallbackScope
        usedPercent = $usedPercent
        remainingPercent = [Math]::Round(100 - $usedPercent, 4)
        windowDurationMinutes = $durationMinutes
        resetsAt = Get-CodexPropertyValue -InputObject $Window -Name 'resetsAt'
    }
}

function ConvertFrom-CodexAppServerSnapshot {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [Parameter(Mandatory = $true)]
        [string] $Source,

        [string] $MissingReason = 'usage_meter_unavailable'
    )

    if ($null -eq $Snapshot) {
        return New-CodexUnknownUsage -Source $Source -Reason $MissingReason
    }

    $details = [System.Collections.Generic.List[object]]::new()
    $primary = ConvertFrom-CodexAppServerWindow `
        -Window (Get-CodexPropertyValue -InputObject $Snapshot -Name 'primary') `
        -FallbackScope 'primary'
    if ($null -ne $primary) {
        $details.Add($primary)
    }
    $secondary = ConvertFrom-CodexAppServerWindow `
        -Window (Get-CodexPropertyValue -InputObject $Snapshot -Name 'secondary') `
        -FallbackScope 'secondary'
    if ($null -ne $secondary) {
        $details.Add($secondary)
    }

    if ($details.Count -eq 0) {
        return New-CodexUnknownUsage -Source $Source -Reason 'usage_response_invalid'
    }

    $usedPercent = [double] (($details | Measure-Object -Property usedPercent -Maximum).Maximum)
    return [pscustomobject]@{
        known = $true
        usedPercent = $usedPercent
        remainingPercent = [Math]::Round(100 - $usedPercent, 4)
        scope = 'most-consumed-rate-limit'
        details = $details.ToArray()
        source = $Source
        reason = $null
        rateLimitReachedType = Get-CodexPropertyValue -InputObject $Snapshot -Name 'rateLimitReachedType'
        individualLimit = Get-CodexPropertyValue -InputObject $Snapshot -Name 'individualLimit'
        spendControlReached = Get-CodexPropertyValue -InputObject $Snapshot -Name 'spendControlReached'
    }
}

function Get-CodexNamedRateLimitSnapshots {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Collection
    )

    $snapshots = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Collection) {
        return $snapshots.ToArray()
    }

    if ($Collection -is [System.Collections.IDictionary]) {
        foreach ($key in $Collection.Keys) {
            $snapshots.Add([pscustomobject]@{ id = [string] $key; value = $Collection[$key] })
        }
        return $snapshots.ToArray()
    }

    foreach ($property in $Collection.PSObject.Properties) {
        $snapshots.Add([pscustomobject]@{ id = $property.Name; value = $property.Value })
    }
    return $snapshots.ToArray()
}

function ConvertFrom-CodexRateLimitsResult {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Result
    )

    $source = 'codex-app-server'
    $mainSnapshot = Get-CodexPropertyValue -InputObject $Result -Name 'rateLimits'
    $sparkSnapshot = $null
    $namedSnapshots = Get-CodexNamedRateLimitSnapshots `
        -Collection (Get-CodexPropertyValue -InputObject $Result -Name 'rateLimitsByLimitId')

    foreach ($namedSnapshot in $namedSnapshots) {
        $limitName = Get-CodexPropertyValue -InputObject $namedSnapshot.value -Name 'limitName'
        $identity = "$($namedSnapshot.id) $limitName"
        if ($identity -match '(?i)spark') {
            $sparkSnapshot = $namedSnapshot.value
            continue
        }
        if ($namedSnapshot.id -eq 'codex') {
            $mainSnapshot = $namedSnapshot.value
        }
    }

    $mainUsage = ConvertFrom-CodexAppServerSnapshot `
        -Snapshot $mainSnapshot `
        -Source $source `
        -MissingReason 'usage_response_invalid'
    $sparkUsage = ConvertFrom-CodexAppServerSnapshot `
        -Snapshot $sparkSnapshot `
        -Source $source `
        -MissingReason 'usage_meter_unavailable'

    return [pscustomobject]@{
        provider = 'codex'
        source = $source
        queriedAt = (Get-Date).ToString('o')
        resources = [pscustomobject]@{
            codexMain = $mainUsage
            codexSpark = $sparkUsage
        }
        rateLimitResetCredits = Get-CodexPropertyValue -InputObject $Result -Name 'rateLimitResetCredits'
    }
}

function Read-CodexAppServerResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process] $Process,

        [Parameter(Mandatory = $true)]
        [int] $Id,

        [Parameter(Mandatory = $true)]
        [DateTime] $Deadline
    )

    while ((Get-Date) -lt $Deadline) {
        $remainingMilliseconds = [Math]::Max(1, [int] ($Deadline - (Get-Date)).TotalMilliseconds)
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remainingMilliseconds)) {
            throw 'codex app-server response timed out'
        }

        $line = $readTask.Result
        if ($null -eq $line) {
            throw 'codex app-server closed before returning a response'
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $message = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($null -eq $message.PSObject.Properties['id'] -or [int] $message.id -ne $Id) {
            continue
        }
        if ($null -ne $message.PSObject.Properties['error']) {
            throw 'codex app-server rejected the request'
        }
        return $message.result
    }

    throw 'codex app-server response timed out'
}

function Resolve-CodexCliLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command
    )

    $resolvedCommand = Get-Command $Command -ErrorAction Stop | Select-Object -First 1
    $commandPath = if (-not [string]::IsNullOrWhiteSpace([string] $resolvedCommand.Source)) {
        [string] $resolvedCommand.Source
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string] $resolvedCommand.Path)) {
        [string] $resolvedCommand.Path
    }
    else {
        [string] $resolvedCommand.Name
    }
    $commandPath = [System.IO.Path]::GetFullPath($commandPath)

    if ([System.IO.Path]::GetExtension($commandPath) -ieq '.ps1') {
        $powerShellPath = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
            $powerShellPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
                Select-Object -First 1).Source
        }
        return [pscustomobject]@{
            commandPath = $commandPath
            filePath = $powerShellPath
            arguments = @('-NoProfile', '-File', $commandPath)
        }
    }

    return [pscustomobject]@{
        commandPath = $commandPath
        filePath = $commandPath
        arguments = @()
    }
}

function Invoke-CodexAppServerMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,

        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 15,

        [string] $Command = 'codex'
    )

    $launch = Resolve-CodexCliLaunch -Command $Command
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $launch.filePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $launch.arguments) {
        $startInfo.ArgumentList.Add([string] $argument)
    }
    $startInfo.ArgumentList.Add('app-server')
    $startInfo.ArgumentList.Add('--listen')
    $startInfo.ArgumentList.Add('stdio://')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw 'codex app-server could not be started'
        }
        $started = $true
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        $initialize = [ordered]@{
            method = 'initialize'
            id = 1
            params = [ordered]@{
                clientInfo = [ordered]@{
                    name = 'ai_cli_environment'
                    title = 'AI CLI Environment'
                    version = '1.0.0'
                }
            }
        }
        $process.StandardInput.WriteLine(($initialize | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Flush()
        $null = Read-CodexAppServerResponse -Process $process -Id 1 -Deadline $deadline

        $process.StandardInput.WriteLine('{' + '"method":"initialized"' + '}')
        $request = [ordered]@{ method = $Method; id = 2 }
        $process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress))
        $process.StandardInput.Flush()

        return Read-CodexAppServerResponse -Process $process -Id 2 -Deadline $deadline
    }
    finally {
        if ($started) {
            try {
                $process.StandardInput.Close()
            }
            catch {
            }
            if (-not $process.HasExited) {
                try {
                    $process.Kill($true)
                }
                catch {
                    try { $process.Kill() } catch { }
                }
            }
        }
        $process.Dispose()
    }
}

function Invoke-CodexUsageSnapshot {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 15,

        [scriptblock] $AppServerRunner
    )

    if ($null -eq $AppServerRunner) {
        $AppServerRunner = {
            param($Method, $TimeoutSeconds)
            Invoke-CodexAppServerMethod -Method $Method -TimeoutSeconds $TimeoutSeconds
        }
    }

    try {
        $result = & $AppServerRunner 'account/rateLimits/read' $TimeoutSeconds
        return ConvertFrom-CodexRateLimitsResult -Result $result
    }
    catch {
        $unknown = New-CodexUnknownUsage -Source 'codex-app-server' -Reason 'usage_query_failed'
        return [pscustomobject]@{
            provider = 'codex'
            source = 'codex-app-server'
            queriedAt = (Get-Date).ToString('o')
            resources = [pscustomobject]@{
                codexMain = $unknown
                codexSpark = New-CodexUnknownUsage -Source 'codex-app-server' -Reason 'usage_query_failed'
            }
            rateLimitResetCredits = $null
        }
    }
}

function ConvertFrom-CodexWhamWindow {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Window,

        [string] $FallbackScope
    )

    if ($null -eq $Window) {
        return $null
    }
    $usedPercent = ConvertTo-CodexPercent -Value (Get-CodexPropertyValue -InputObject $Window -Name 'used_percent')
    if ($null -eq $usedPercent) {
        return $null
    }
    $durationSeconds = Get-CodexPropertyValue -InputObject $Window -Name 'limit_window_seconds'
    $durationMinutes = if ($null -eq $durationSeconds) { $null } else { [double] $durationSeconds / 60 }
    return [pscustomobject]@{
        scope = Get-CodexWindowScope -DurationMinutes $durationMinutes -Fallback $FallbackScope
        usedPercent = $usedPercent
        remainingPercent = [Math]::Round(100 - $usedPercent, 4)
        windowDurationMinutes = $durationMinutes
        resetsAt = Get-CodexPropertyValue -InputObject $Window -Name 'reset_at'
        resetsAfterSeconds = Get-CodexPropertyValue -InputObject $Window -Name 'reset_after_seconds'
    }
}

function ConvertFrom-CodexUsageResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark')]
        [string] $ResourceName,

        [AllowNull()]
        [object] $Response
    )

    $source = 'chatgpt-wham-usage-private'
    $rateLimit = Get-CodexPropertyValue -InputObject $Response -Name 'rate_limit'
    if ($ResourceName -eq 'codexSpark') {
        $rateLimit = $null
        $additional = Get-CodexPropertyValue -InputObject $Response -Name 'additional_rate_limits'
        foreach ($item in @($additional)) {
            $identity = "$(Get-CodexPropertyValue -InputObject $item -Name 'limit_name') $(Get-CodexPropertyValue -InputObject $item -Name 'display_name')"
            if ($identity -match '(?i)spark') {
                $nested = Get-CodexPropertyValue -InputObject $item -Name 'rate_limit'
                $rateLimit = if ($null -ne $nested) { $nested } else { $item }
                break
            }
        }
        if ($null -eq $rateLimit) {
            return New-CodexUnknownUsage -Source $source -Reason 'usage_meter_unavailable'
        }
    }
    elseif ($null -eq $rateLimit) {
        return New-CodexUnknownUsage -Source $source -Reason 'usage_response_invalid'
    }

    $details = [System.Collections.Generic.List[object]]::new()
    $primary = ConvertFrom-CodexWhamWindow `
        -Window (Get-CodexPropertyValue -InputObject $rateLimit -Name 'primary_window') `
        -FallbackScope 'primary'
    if ($null -ne $primary) { $details.Add($primary) }
    $secondary = ConvertFrom-CodexWhamWindow `
        -Window (Get-CodexPropertyValue -InputObject $rateLimit -Name 'secondary_window') `
        -FallbackScope 'secondary'
    if ($null -ne $secondary) { $details.Add($secondary) }
    if ($details.Count -eq 0) {
        return New-CodexUnknownUsage -Source $source -Reason 'usage_response_invalid'
    }

    $usedPercent = [double] (($details | Measure-Object -Property usedPercent -Maximum).Maximum)
    return [pscustomobject]@{
        known = $true
        usedPercent = $usedPercent
        remainingPercent = [Math]::Round(100 - $usedPercent, 4)
        scope = 'most-consumed-rate-limit'
        details = $details.ToArray()
        source = $source
        reason = $null
        rateLimitReachedType = $null
        individualLimit = $null
        spendControlReached = $null
    }
}

function Invoke-CodexUsageProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark')]
        [string] $ResourceName,

        [string] $AuthPath,

        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 15,

        [scriptblock] $RequestRunner
    )

    $source = 'chatgpt-wham-usage-private'
    if ([string]::IsNullOrWhiteSpace($AuthPath)) {
        $codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
        }
        $AuthPath = Join-Path $codexHome 'auth.json'
    }
    if (-not (Test-Path -LiteralPath $AuthPath -PathType Leaf)) {
        return New-CodexUnknownUsage -Source $source -Reason 'authentication_state_unavailable'
    }

    try {
        $auth = Get-Content -LiteralPath $AuthPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $tokens = Get-CodexPropertyValue -InputObject $auth -Name 'tokens'
        $accessToken = Get-CodexPropertyValue -InputObject $tokens -Name 'access_token'
        $accountId = Get-CodexPropertyValue -InputObject $tokens -Name 'account_id'
        if ([string]::IsNullOrWhiteSpace([string] $accessToken)) {
            return New-CodexUnknownUsage -Source $source -Reason 'authentication_state_unavailable'
        }

        $headers = @{
            Authorization = "Bearer $accessToken"
            'OpenAI-Beta' = 'codex-1'
            originator = 'Codex Desktop'
        }
        if (-not [string]::IsNullOrWhiteSpace([string] $accountId)) {
            $headers['ChatGPT-Account-ID'] = [string] $accountId
        }
        if ($null -eq $RequestRunner) {
            $RequestRunner = {
                param($Uri, $Headers, $TimeoutSeconds)
                Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSeconds
            }
        }

        $response = & $RequestRunner 'https://chatgpt.com/backend-api/wham/usage' $headers $TimeoutSeconds
        return ConvertFrom-CodexUsageResponse -ResourceName $ResourceName -Response $response
    }
    catch {
        return New-CodexUnknownUsage -Source $source -Reason 'usage_query_failed'
    }
}
