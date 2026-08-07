Set-StrictMode -Version Latest

function Classify-ProbeFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $ProcessResult
    )

    if ($ProcessResult.commandNotFound) {
        return [pscustomobject]@{ reason = 'command_not_found'; retryable = $true }
    }

    if ($null -ne $ProcessResult.PSObject.Properties['startError'] -and
        $ProcessResult.startError -eq 'permission_denied') {
        return [pscustomobject]@{ reason = 'permission_denied'; retryable = $false }
    }

    if ($ProcessResult.timedOut) {
        return [pscustomobject]@{ reason = 'timeout'; retryable = $true }
    }

    $message = "$($ProcessResult.stderr)`n$($ProcessResult.stdout)"
    if ($message -match '(?i)not logged in|please sign in|sign-in required|authentication required|unauthori[sz]ed|invalid credential|\b401\b') {
        return [pscustomobject]@{ reason = 'authentication_required'; retryable = $true }
    }
    if ($message -match '(?i)model.{0,30}(not available|unavailable|not found|unsupported)|unknown model') {
        return [pscustomobject]@{ reason = 'model_unavailable'; retryable = $false }
    }
    if ($message -match '(?i)permission denied|access is denied|access denied|operation not permitted|\b403\b|forbidden') {
        return [pscustomobject]@{ reason = 'permission_denied'; retryable = $false }
    }
    if ($message -match '(?i)usage.{0,20}(unsupported|not supported|unavailable)') {
        return [pscustomobject]@{ reason = 'usage_unsupported'; retryable = $false }
    }
    if ($message -match '(?i)network|connection|dns|tls|certificate|temporar(?:y|ily)|timed? out|econn|enet') {
        return [pscustomobject]@{ reason = 'network_error'; retryable = $true }
    }
    if ($ProcessResult.started -and $ProcessResult.exitCode -ne 0) {
        return [pscustomobject]@{ reason = 'provider_error'; retryable = $false }
    }

    return [pscustomobject]@{ reason = 'unknown_error'; retryable = $false }
}

function Invoke-PrimaryProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Adapter,

        [hashtable] $Environment = @{},

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 30,

        [scriptblock] $ProcessRunner
    )

    if ($null -eq $ProcessRunner) {
        $ProcessRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            Invoke-CapturedProcess -Command $Command -Arguments $Arguments -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        }
    }

    $probe = if ($Adapter.primaryProbe.mode -eq 'execution') {
        $Adapter.diagnosticProbe
    }
    else {
        $Adapter.primaryProbe
    }

    return & $ProcessRunner $probe.command ([string[]] $probe.arguments) $Environment $TimeoutSeconds
}

function Invoke-ResourceAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [psobject] $Configuration,

        [string] $StateRoot,

        [scriptblock] $ProcessRunner,

        [scriptblock] $Installer,

        [scriptblock] $LoginRunner,

        [switch] $Repair
    )

    $resourceConfig = Get-ResourceConfig -Configuration $Configuration -ResourceName $ResourceName
    $hardLimitPercent = [double] $resourceConfig.hardLimitPercent
    if (-not $resourceConfig.enabled) {
        return [pscustomobject]@{
            provider = $ResourceName
            available = $false
            reason = 'resource_disabled'
            warning = $null
            cliReady = $null
            authenticationReady = $null
            usageKnown = $false
            usedPercent = $null
            hardLimitPercent = $hardLimitPercent
            bootstrapAction = $null
            authenticationAction = $null
        }
    }

    $adapter = Get-ProviderAdapter -ResourceName $ResourceName
    $environment = Get-ResourceEnvironment -ResourceName $ResourceName -StateRoot $StateRoot
    $timeoutSeconds = if ($null -ne $Configuration.PSObject.Properties['probeTimeoutSeconds']) {
        [int] $Configuration.probeTimeoutSeconds
    }
    else {
        30
    }

    $bootstrapAction = $null
    $authenticationAction = $null
    $probeResult = Invoke-PrimaryProbe -Adapter $adapter -Environment $environment -TimeoutSeconds $timeoutSeconds -ProcessRunner $ProcessRunner
    if ($probeResult.exitCode -ne 0 -or -not $probeResult.started) {
        $failure = Classify-ProbeFailure -ProcessResult $probeResult

        if ($Repair -and $failure.reason -eq 'command_not_found') {
            if ($null -eq $Installer) {
                $Installer = { param($Name, $Definition) Install-ResourceCli -ResourceName $Name -Adapter $Definition }
            }
            $installed = & $Installer $ResourceName $adapter
            $bootstrapAction = if ($installed) { 'installed' } else { 'failed' }
            if ($installed) {
                $probeResult = Invoke-PrimaryProbe -Adapter $adapter -Environment $environment -TimeoutSeconds $timeoutSeconds -ProcessRunner $ProcessRunner
            }
        }
        elseif ($Repair -and $failure.reason -eq 'authentication_required') {
            if ($null -eq $LoginRunner) {
                $LoginRunner = { param($Name, $Definition, $Variables) Invoke-ResourceLogin -ResourceName $Name -Adapter $Definition -Environment $Variables }
            }
            $authenticated = & $LoginRunner $ResourceName $adapter $environment
            $authenticationAction = if ($authenticated) { 'completed' } else { 'failed' }
            if ($authenticated) {
                $probeResult = Invoke-PrimaryProbe -Adapter $adapter -Environment $environment -TimeoutSeconds $timeoutSeconds -ProcessRunner $ProcessRunner
            }
        }
    }

    if ($probeResult.exitCode -ne 0 -or -not $probeResult.started) {
        $failure = if ($authenticationAction -eq 'failed') {
            [pscustomobject]@{ reason = 'authentication_failed'; retryable = $false }
        }
        else {
            Classify-ProbeFailure -ProcessResult $probeResult
        }
        return [pscustomobject]@{
            provider = $ResourceName
            available = $false
            reason = $failure.reason
            warning = $null
            cliReady = $failure.reason -ne 'command_not_found'
            authenticationReady = if ($failure.reason -in @('authentication_required', 'authentication_failed')) { $false } else { $null }
            usageKnown = $false
            usedPercent = $null
            hardLimitPercent = $hardLimitPercent
            bootstrapAction = $bootstrapAction
            authenticationAction = $authenticationAction
            durationMs = $probeResult.durationMs
        }
    }

    $usage = Get-ResourceUsage -Adapter $adapter -ProbeResult $probeResult
    $policy = Resolve-UsageAvailability `
        -UsageKnown $usage.known `
        -UsedPercent $usage.usedPercent `
        -HardLimitPercent $hardLimitPercent `
        -UnknownUsagePolicy $Configuration.unknownUsagePolicy

    $state = [ordered]@{
        provider = $ResourceName
        available = $policy.available
        reason = $policy.reason
        warning = $policy.warning
        cliReady = $true
        authenticationReady = if ($adapter.primaryProbe.mode -eq 'status') { $true } else { $null }
        usageKnown = $policy.usageKnown
        usedPercent = $policy.usedPercent
        hardLimitPercent = $policy.hardLimitPercent
        usageSource = $usage.source
        bootstrapAction = $bootstrapAction
        authenticationAction = $authenticationAction
        durationMs = $probeResult.durationMs
    }

    if ($ResourceName -eq 'codexSpark') {
        $state.modelAvailable = $null
        $state.model = $adapter.model
    }
    if ($ResourceName -eq 'junie') {
        $ambient = @{}
        foreach ($name in @('JUNIE_API_KEY', 'JUNIE_ANTHROPIC_API_KEY', 'JUNIE_OPENAI_API_KEY', 'JUNIE_GOOGLE_API_KEY', 'JUNIE_GROK_API_KEY', 'JUNIE_OPENROUTER_API_KEY')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $ambient[$name] = $value
            }
        }
        $consumption = Get-JunieConsumptionMode -Environment $ambient
        $state.consumptionMode = $consumption.consumptionMode
        $state.consumptionModeVerified = $consumption.consumptionModeVerified
    }

    return [pscustomobject] $state
}
