Set-StrictMode -Version Latest

function New-GlobalResourceEvaluationResult {
    param(
        [string] $ResourceName,
        [bool] $Available,
        [AllowNull()] $Reason,
        [AllowNull()] $Warning,
        [bool] $UsageKnown,
        [AllowNull()] $UsedPercent,
        [AllowNull()] $HardLimitPercent,
        [AllowNull()] $StateUpdatedAt,
        [AllowNull()] $StateAgeSeconds
    )

    return [pscustomobject]@{
        resource = $ResourceName
        available = $Available
        reason = $Reason
        warning = $Warning
        usageKnown = $UsageKnown
        usedPercent = $UsedPercent
        hardLimitPercent = $HardLimitPercent
        stateUpdatedAt = $StateUpdatedAt
        stateAgeSeconds = $StateAgeSeconds
    }
}

function Resolve-GlobalResourceAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [string] $GlobalRoot,

        [datetime] $Now = (Get-Date)
    )

    $resolvedRoot = Resolve-GlobalAiResourceGuardRoot -GlobalRoot $GlobalRoot
    try {
        $configuration = Read-GlobalAiResourceGuardConfiguration -GlobalRoot $resolvedRoot
    }
    catch {
        $reason = if ($_.Exception.Message -eq 'configuration_missing') {
            'configuration_missing'
        }
        else {
            'configuration_invalid'
        }
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason $reason -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $null `
            -StateUpdatedAt $null -StateAgeSeconds $null
    }

    $policy = Get-GlobalAiResourcePolicy -Configuration $configuration -ResourceName $ResourceName
    if (-not $policy.enabled) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_disabled' -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $null -StateAgeSeconds $null
    }

    try {
        $state = Read-GlobalResourceState -ResourceName $ResourceName -GlobalRoot $resolvedRoot
    }
    catch {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_state_invalid' -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $null -StateAgeSeconds $null
    }
    if ($null -eq $state) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_state_missing' -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $null -StateAgeSeconds $null
    }

    $updatedAt = [datetime]::MinValue
    try {
        $stateValid = $state.schemaVersion -eq 1 -and
            $state.resource -eq $ResourceName -and
            $null -ne $state.readiness -and
            $state.readiness.known -is [bool] -and
            $state.readiness.available -is [bool] -and
            $null -ne $state.usage -and
            $state.usage.known -is [bool] -and
            [datetime]::TryParse([string] $state.updatedAt, [ref] $updatedAt)
    }
    catch {
        $stateValid = $false
    }
    if (-not $stateValid) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_state_invalid' -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $null -StateAgeSeconds $null
    }

    $stateAgeSeconds = [Math]::Max(0, [Math]::Round(($Now.ToUniversalTime() - $updatedAt.ToUniversalTime()).TotalSeconds, 3))
    if ($stateAgeSeconds -gt $policy.stateMaxAgeSeconds) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_state_stale' -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
    }

    if (-not [bool] $state.readiness.known) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_readiness_unknown' -Warning $null `
            -UsageKnown ([bool] $state.usage.known) -UsedPercent $state.usage.usedPercent `
            -HardLimitPercent $policy.hardLimitPercent -StateUpdatedAt $state.updatedAt `
            -StateAgeSeconds $stateAgeSeconds
    }
    if (-not [bool] $state.readiness.available) {
        $readinessReason = if ([string]::IsNullOrWhiteSpace([string] $state.readiness.reason)) {
            'resource_not_ready'
        }
        else {
            [string] $state.readiness.reason
        }
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason $readinessReason -Warning $null `
            -UsageKnown ([bool] $state.usage.known) -UsedPercent $state.usage.usedPercent `
            -HardLimitPercent $policy.hardLimitPercent -StateUpdatedAt $state.updatedAt `
            -StateAgeSeconds $stateAgeSeconds
    }

    $usageKnown = [bool] $state.usage.known
    $usedPercent = $state.usage.usedPercent
    if ($usageKnown -and $null -eq $usedPercent) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_state_invalid' -Warning $null `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
    }
    if ($usageKnown) {
        try {
            if ($usedPercent -is [string]) {
                throw 'Known usage percentage must be numeric.'
            }
            $usedPercent = [double] $usedPercent
        }
        catch {
            return New-GlobalResourceEvaluationResult `
                -ResourceName $ResourceName -Available $false -Reason 'resource_state_invalid' -Warning $null `
                -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
                -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
        }
        if ([double]::IsNaN($usedPercent) -or [double]::IsInfinity($usedPercent) -or
            $usedPercent -lt 0 -or $usedPercent -gt 100) {
            return New-GlobalResourceEvaluationResult `
                -ResourceName $ResourceName -Available $false -Reason 'resource_state_invalid' -Warning $null `
                -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
                -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
        }
    }
    if ($usageKnown -and $usedPercent -ge $policy.hardLimitPercent) {
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName -Available $false -Reason 'resource_hard_limit_reached' -Warning $null `
            -UsageKnown $true -UsedPercent $usedPercent -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
    }
    if (-not $usageKnown) {
        $reason = if ($policy.unknownUsagePolicy -eq 'deny') { 'usage_unknown' } else { $null }
        $warning = if ($policy.unknownUsagePolicy -eq 'warn') { 'usage_unknown' } else { $null }
        return New-GlobalResourceEvaluationResult `
            -ResourceName $ResourceName `
            -Available ($policy.unknownUsagePolicy -ne 'deny') `
            -Reason $reason `
            -Warning $warning `
            -UsageKnown $false -UsedPercent $null -HardLimitPercent $policy.hardLimitPercent `
            -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
    }

    return New-GlobalResourceEvaluationResult `
        -ResourceName $ResourceName -Available $true -Reason $null -Warning $null `
        -UsageKnown $true -UsedPercent $usedPercent -HardLimitPercent $policy.hardLimitPercent `
        -StateUpdatedAt $state.updatedAt -StateAgeSeconds $stateAgeSeconds
}
