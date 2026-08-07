Set-StrictMode -Version Latest

function New-GuardFailureResult {
    param(
        [string] $ResourceName,
        [string] $Reason,
        [bool] $UsageKnown,
        [AllowNull()] $UsedPercent,
        [double] $HardLimitPercent,
        [AllowNull()] $Warning,
        [AllowNull()]
        [string] $BootstrapAction = $null,
        [AllowNull()]
        [string] $AuthenticationAction = $null
    )

    return [pscustomobject]@{
        provider = $ResourceName
        success = $false
        available = $false
        reason = $Reason
        warning = $Warning
        usage = [pscustomobject]@{
            known = $UsageKnown
            usedPercent = $UsedPercent
            hardLimitPercent = $HardLimitPercent
        }
        result = $null
        bootstrapAction = $BootstrapAction
        authenticationAction = $AuthenticationAction
    }
}

function Invoke-GuardedResourceCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [string[]] $Arguments = @(),

        [string] $StateRoot,

        [scriptblock] $ProcessRunner,

        [switch] $NoRepair
    )

    $configPath = Join-Path $RepositoryRoot '.ai\config.json'
    $configuration = Read-AiEnvironmentConfig -Path $configPath
    $resourceConfig = Get-ResourceConfig -Configuration $configuration -ResourceName $ResourceName
    $hardLimit = [double] $resourceConfig.hardLimitPercent

    if (-not $resourceConfig.enabled) {
        $disabled = New-GuardFailureResult -ResourceName $ResourceName -Reason 'resource_disabled' -UsageKnown $false -UsedPercent $null -HardLimitPercent $hardLimit -Warning $null
        Write-AiEnvironmentLog -RepositoryRoot $RepositoryRoot -Entry $disabled
        return $disabled
    }

    $adapter = Get-ProviderAdapter -ResourceName $ResourceName
    $environment = Get-ResourceEnvironment -ResourceName $ResourceName -StateRoot $StateRoot
    $availability = $null
    $bootstrapAction = $null
    $authenticationAction = $null

    if ($adapter.primaryProbe.mode -eq 'status') {
        $availability = Invoke-ResourceAvailability `
            -ResourceName $ResourceName `
            -Configuration $configuration `
            -StateRoot $StateRoot `
            -ProcessRunner $ProcessRunner `
            -Repair:(-not $NoRepair)

        if (-not $availability.available) {
            $blocked = New-GuardFailureResult `
                -ResourceName $ResourceName `
                -Reason $availability.reason `
                -UsageKnown $availability.usageKnown `
                -UsedPercent $availability.usedPercent `
            -HardLimitPercent $hardLimit `
                -Warning $availability.warning `
                -BootstrapAction $availability.bootstrapAction `
                -AuthenticationAction $availability.authenticationAction
            Write-AiEnvironmentLog -RepositoryRoot $RepositoryRoot -Entry $blocked
            return $blocked
        }
        $bootstrapAction = $availability.bootstrapAction
        $authenticationAction = $availability.authenticationAction
    }
    else {
        # Copilot and Junie do not expose a non-consuming, machine-readable auth
        # and quota status command. Their requested task is the optimistic probe.
        $policy = Resolve-UsageAvailability `
            -UsageKnown $false `
            -UsedPercent $null `
            -HardLimitPercent $hardLimit `
            -UnknownUsagePolicy $configuration.unknownUsagePolicy
        if (-not $policy.available) {
            $blocked = New-GuardFailureResult -ResourceName $ResourceName -Reason $policy.reason -UsageKnown $false -UsedPercent $null -HardLimitPercent $hardLimit -Warning $policy.warning
            Write-AiEnvironmentLog -RepositoryRoot $RepositoryRoot -Entry $blocked
            return $blocked
        }
        $availability = [pscustomobject]@{
            available = $true
            usageKnown = $false
            usedPercent = $null
            warning = $policy.warning
        }
    }

    if ($null -eq $ProcessRunner) {
        $ProcessRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            Invoke-CapturedProcess -Command $Command -Arguments $Arguments -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        }
    }

    $taskArguments = @($Arguments)
    if ($ResourceName -eq 'codexSpark') {
        $taskArguments = @('-m', $adapter.model) + $taskArguments
    }

    $timeout = if ($null -ne $configuration.PSObject.Properties['commandTimeoutSeconds'] -and
        [int] $configuration.commandTimeoutSeconds -gt 0) {
        [int] $configuration.commandTimeoutSeconds
    }
    else {
        86400
    }

    $execution = & $ProcessRunner $adapter.executable ([string[]] $taskArguments) $environment $timeout
    if ($execution.exitCode -ne 0 -or -not $execution.started) {
        $failure = Classify-ProbeFailure -ProcessResult $execution
        if (-not $NoRepair -and $failure.reason -eq 'command_not_found') {
            if (Install-ResourceCli -ResourceName $ResourceName -Adapter $adapter) {
                $bootstrapAction = 'installed'
                $execution = & $ProcessRunner $adapter.executable ([string[]] $taskArguments) $environment $timeout
            }
            else {
                $bootstrapAction = 'failed'
            }
        }
        elseif (-not $NoRepair -and $failure.reason -eq 'authentication_required') {
            if (Invoke-ResourceLogin -ResourceName $ResourceName -Adapter $adapter -Environment $environment) {
                $authenticationAction = 'completed'
                $execution = & $ProcessRunner $adapter.executable ([string[]] $taskArguments) $environment $timeout
            }
            else {
                $authenticationAction = 'failed'
            }
        }
    }

    if ($execution.exitCode -ne 0 -or -not $execution.started) {
        $failure = if ($authenticationAction -eq 'failed') {
            [pscustomobject]@{ reason = 'authentication_failed'; retryable = $false }
        }
        else {
            Classify-ProbeFailure -ProcessResult $execution
        }
        $failed = New-GuardFailureResult `
            -ResourceName $ResourceName `
            -Reason $failure.reason `
            -UsageKnown $availability.usageKnown `
            -UsedPercent $availability.usedPercent `
            -HardLimitPercent $hardLimit `
            -Warning $availability.warning `
            -BootstrapAction $bootstrapAction `
            -AuthenticationAction $authenticationAction
        $failed | Add-Member -NotePropertyName durationMs -NotePropertyValue $execution.durationMs
        Write-AiEnvironmentLog -RepositoryRoot $RepositoryRoot -Entry $failed
        return $failed
    }

    $success = [ordered]@{
        provider = $ResourceName
        success = $true
        available = $true
        reason = $null
        warning = $availability.warning
        usage = [pscustomobject]@{
            known = $availability.usageKnown
            usedPercent = $availability.usedPercent
            hardLimitPercent = $hardLimit
        }
        result = $execution.stdout
        durationMs = $execution.durationMs
    }
    if ($ResourceName -eq 'codexSpark') {
        $success.modelAvailable = $true
        $success.model = $adapter.model
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
        $success.consumptionMode = $consumption.consumptionMode
        $success.consumptionModeVerified = $consumption.consumptionModeVerified
    }

    $result = [pscustomobject] $success
    $logEntry = [pscustomobject]@{
        provider = $ResourceName
        probeResult = 'success'
        usageKnown = $availability.usageKnown
        usedPercent = $availability.usedPercent
        hardLimitPercent = $hardLimit
        bootstrapAction = $bootstrapAction
        authenticationAction = $authenticationAction
        executionResult = 'success'
        reason = $null
        durationMs = $execution.durationMs
    }
    Write-AiEnvironmentLog -RepositoryRoot $RepositoryRoot -Entry $logEntry
    return $result
}
