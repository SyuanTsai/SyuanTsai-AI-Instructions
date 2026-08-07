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

        [scriptblock] $UsageRunner,

        [switch] $Repair
    )

    $resourceConfig = Get-ResourceConfig -Configuration $Configuration -ResourceName $ResourceName
    $hardLimitPercent = [double] $resourceConfig.hardLimitPercent
    $adapter = Get-ProviderAdapter -ResourceName $ResourceName
    if (-not $resourceConfig.enabled) {
        $usage = New-UnknownUsageSnapshot `
            -ResourceName $ResourceName `
            -Source $adapter.usageAcquisition.source `
            -AcquisitionMode $adapter.usageAcquisition.mode `
            -Reason 'resource_disabled'
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
            usageSource = $usage.source
            usageAcquisitionMode = $usage.acquisitionMode
            usage = $usage
            bootstrapAction = $null
            authenticationAction = $null
        }
    }

    $environment = Get-ResourceEnvironment -ResourceName $ResourceName -StateRoot $StateRoot
    if ($ResourceName -in @('copilotPersonal', 'copilotCompany')) {
        $profileAuthentication = Resolve-CopilotProfileAuthentication `
            -ResourceName $ResourceName `
            -ResourceConfig $resourceConfig `
            -Environment $environment
        if (-not $profileAuthentication.ready) {
            $usage = New-UnknownUsageSnapshot `
                -ResourceName $ResourceName `
                -Source $adapter.usageAcquisition.source `
                -AcquisitionMode $adapter.usageAcquisition.mode `
                -Reason $profileAuthentication.reason
            return [pscustomobject]@{
                provider = $ResourceName
                available = $false
                reason = $profileAuthentication.reason
                warning = $null
                cliReady = $null
                authenticationReady = $false
                authenticationSource = $profileAuthentication.source
                usageKnown = $false
                usedPercent = $null
                hardLimitPercent = $hardLimitPercent
                usageSource = $usage.source
                usageAcquisitionMode = $usage.acquisitionMode
                usage = $usage
                bootstrapAction = $null
                authenticationAction = 'profile_token_required'
            }
        }
    }
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
        $usage = if ($null -ne $UsageRunner) {
            $independentUsage = & $UsageRunner $ResourceName $timeoutSeconds
            $mode = if ($independentUsage.PSObject.Properties['acquisitionMode']) {
                [string] $independentUsage.acquisitionMode
            }
            else {
                [string] $adapter.usageAcquisition.mode
            }
            ConvertTo-UsageSnapshot `
                -ResourceName $ResourceName `
                -Usage $independentUsage `
                -AcquisitionMode $mode
        }
        else {
            New-UnknownUsageSnapshot `
                -ResourceName $ResourceName `
                -Source $adapter.usageAcquisition.source `
                -AcquisitionMode $adapter.usageAcquisition.mode `
                -Reason $failure.reason
        }
        return [pscustomobject]@{
            provider = $ResourceName
            available = $false
            reason = $failure.reason
            warning = $null
            cliReady = $failure.reason -ne 'command_not_found'
            authenticationReady = if ($failure.reason -in @('authentication_required', 'authentication_failed')) { $false } else { $null }
            usageKnown = $usage.known
            usedPercent = $usage.usedPercent
            hardLimitPercent = $hardLimitPercent
            usageSource = $usage.source
            usageAcquisitionMode = $usage.acquisitionMode
            usage = $usage
            bootstrapAction = $bootstrapAction
            authenticationAction = $authenticationAction
            durationMs = $probeResult.durationMs
        }
    }

    $providerUsage = if ($null -ne $UsageRunner) {
        & $UsageRunner $ResourceName $timeoutSeconds
    }
    elseif ($adapter.usageAcquisition.mode -eq 'official_api' -and $adapter.usageSource -eq 'codex-app-server') {
        if ($null -eq $ProcessRunner) {
            (Invoke-CodexUsageSnapshot -TimeoutSeconds $timeoutSeconds).resources.$ResourceName
        }
        else {
            New-CodexUnknownUsage -Source 'codex-app-server' -Reason 'usage_not_probed_in_test_transport'
        }
    }
    elseif ($ResourceName -eq 'copilotPersonal' -and
        $null -eq $ProcessRunner -and
        $environment.ContainsKey('COPILOT_GITHUB_TOKEN')) {
        Invoke-CopilotPersonalUsageSnapshot -Token ([string] $environment.COPILOT_GITHUB_TOKEN)
    }
    elseif ($ResourceName -eq 'junie') {
        New-JunieUsageSnapshot
    }
    else {
        Get-ResourceUsage -Adapter $adapter -ProbeResult $probeResult
    }
    $usage = ConvertTo-UsageSnapshot `
        -ResourceName $ResourceName `
        -Usage $providerUsage `
        -AcquisitionMode $adapter.usageAcquisition.mode
    if ($providerUsage.PSObject.Properties['acquisitionMode']) {
        $usage = ConvertTo-UsageSnapshot `
            -ResourceName $ResourceName `
            -Usage $providerUsage `
            -AcquisitionMode ([string] $providerUsage.acquisitionMode)
    }
    $policy = Resolve-UsageSnapshotAvailability `
        -UsageSnapshot $usage `
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
        usageAcquisitionMode = $usage.acquisitionMode
        usage = $usage
        bootstrapAction = $bootstrapAction
        authenticationAction = $authenticationAction
        durationMs = $probeResult.durationMs
    }

    if ($ResourceName -eq 'codexSpark') {
        $state.modelAvailable = $null
        $state.model = $adapter.model
    }
    if ($ResourceName -eq 'junie') {
        $consumption = Get-JunieConsumptionMode -Environment (Get-JunieCredentialEnvironment)
        $state.consumptionMode = $consumption.consumptionMode
        $state.consumptionModeVerified = $consumption.consumptionModeVerified
    }

    return [pscustomobject] $state
}
