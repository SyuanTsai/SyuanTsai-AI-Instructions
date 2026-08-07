Set-StrictMode -Version Latest

$script:AiResourceNames = @(
    'codexMain',
    'codexSpark',
    'copilotPersonal',
    'copilotCompany',
    'agy',
    'junie'
)

function Read-AiEnvironmentConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AI CLI configuration was not found: $Path"
    }

    $configuration = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($configuration.schemaVersion -ne 1) {
        throw "Unsupported AI CLI configuration schemaVersion '$($configuration.schemaVersion)'."
    }

    if ($configuration.unknownUsagePolicy -notin @('allow', 'warn', 'deny')) {
        throw "unknownUsagePolicy must be allow, warn, or deny."
    }

    foreach ($resourceName in $script:AiResourceNames) {
        $property = $configuration.resources.PSObject.Properties[$resourceName]
        if ($null -eq $property) {
            throw "Missing resource configuration '$resourceName'."
        }

        $resource = $property.Value
        if ($resource.enabled -isnot [bool]) {
            throw "Resource '$resourceName' must define a boolean enabled value."
        }

        $hardLimit = [double] $resource.hardLimitPercent
        if ($hardLimit -lt 0 -or $hardLimit -gt 100) {
            throw "Resource '$resourceName' hardLimitPercent must be between 0 and 100."
        }
    }

    return $configuration
}

function Get-ResourceConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Configuration,

        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName
    )

    return $Configuration.resources.PSObject.Properties[$ResourceName].Value
}

function Resolve-UsageAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $UsageKnown,

        [AllowNull()]
        [Nullable[double]] $UsedPercent,

        [Parameter(Mandatory = $true)]
        [double] $HardLimitPercent,

        [Parameter(Mandatory = $true)]
        [ValidateSet('allow', 'warn', 'deny')]
        [string] $UnknownUsagePolicy
    )

    if (-not $UsageKnown) {
        return [pscustomobject]@{
            available = $UnknownUsagePolicy -ne 'deny'
            reason = if ($UnknownUsagePolicy -eq 'deny') { 'usage_unknown' } else { $null }
            warning = if ($UnknownUsagePolicy -eq 'warn') { 'usage_unknown' } else { $null }
            usageKnown = $false
            usedPercent = $null
            hardLimitPercent = $HardLimitPercent
        }
    }

    if ($null -eq $UsedPercent) {
        throw 'UsedPercent cannot be null when UsageKnown is true.'
    }

    $limitReached = [double] $UsedPercent -ge $HardLimitPercent
    return [pscustomobject]@{
        available = -not $limitReached
        reason = if ($limitReached) { 'resource_hard_limit_reached' } else { $null }
        warning = $null
        usageKnown = $true
        usedPercent = [double] $UsedPercent
        hardLimitPercent = $HardLimitPercent
    }
}
