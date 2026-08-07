Set-StrictMode -Version Latest

function Read-GlobalAiResourceGuardConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot
    )

    $configPath = Join-Path $GlobalRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'configuration_missing'
    }

    try {
        $configuration = Get-Content -Raw -LiteralPath $configPath -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'configuration_invalid'
    }

    if ($configuration.schemaVersion -ne 1 -or
        $configuration.unknownUsagePolicy -notin @('allow', 'warn', 'deny') -or
        [int] $configuration.stateMaxAgeSeconds -le 0 -or
        $null -eq $configuration.resources) {
        throw 'configuration_invalid'
    }

    foreach ($resourceName in $script:GlobalAiResourceNames) {
        $property = $configuration.resources.PSObject.Properties[$resourceName]
        if ($null -eq $property) {
            throw 'configuration_invalid'
        }
        $resource = $property.Value
        if ($resource.enabled -isnot [bool]) {
            throw 'configuration_invalid'
        }
        $hardLimit = [double] $resource.hardLimitPercent
        if ($hardLimit -lt 0 -or $hardLimit -gt 100) {
            throw 'configuration_invalid'
        }
        if ($null -ne $resource.PSObject.Properties['unknownUsagePolicy'] -and
            $resource.unknownUsagePolicy -notin @('allow', 'warn', 'deny')) {
            throw 'configuration_invalid'
        }
        if ($null -ne $resource.PSObject.Properties['stateMaxAgeSeconds'] -and
            [int] $resource.stateMaxAgeSeconds -le 0) {
            throw 'configuration_invalid'
        }
    }

    return $configuration
}

function Get-GlobalAiResourcePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Configuration,

        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName
    )

    $resource = $Configuration.resources.PSObject.Properties[$ResourceName].Value
    return [pscustomobject]@{
        enabled = [bool] $resource.enabled
        hardLimitPercent = [double] $resource.hardLimitPercent
        unknownUsagePolicy = if ($null -ne $resource.PSObject.Properties['unknownUsagePolicy']) {
            [string] $resource.unknownUsagePolicy
        }
        else {
            [string] $Configuration.unknownUsagePolicy
        }
        stateMaxAgeSeconds = if ($null -ne $resource.PSObject.Properties['stateMaxAgeSeconds']) {
            [int] $resource.stateMaxAgeSeconds
        }
        else {
            [int] $Configuration.stateMaxAgeSeconds
        }
    }
}
