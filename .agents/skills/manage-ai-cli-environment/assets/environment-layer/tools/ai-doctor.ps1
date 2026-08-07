#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $Repair
)

. (Join-Path $PSScriptRoot 'common\import.ps1')

$configPath = Join-Path $RepositoryRoot '.ai\config.json'
$configuration = Read-AiEnvironmentConfig -Path $configPath
$results = [ordered]@{}

foreach ($resourceName in $script:AiResourceNames) {
    $resourceConfig = Get-ResourceConfig -Configuration $configuration -ResourceName $resourceName
    $adapter = Get-ProviderAdapter -ResourceName $resourceName
    $command = Get-Command $adapter.executable -ErrorAction SilentlyContinue | Select-Object -First 1
    $installed = $null -ne $command
    $version = $null

    if ($installed) {
        $environment = Get-ResourceEnvironment -ResourceName $resourceName
        $versionResult = Invoke-CapturedProcess `
            -Command $adapter.diagnosticProbe.command `
            -Arguments ([string[]] $adapter.diagnosticProbe.arguments) `
            -Environment $environment `
            -TimeoutSeconds 30
        if ($versionResult.exitCode -eq 0) {
            $version = (($versionResult.stdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        }
    }

    $state = Invoke-ResourceAvailability `
        -ResourceName $resourceName `
        -Configuration $configuration `
        -Repair:$Repair

    $results[$resourceName] = [pscustomobject]@{
        enabled = [bool] $resourceConfig.enabled
        installed = $installed
        version = $version
        cliReady = $state.cliReady
        authenticationReady = $state.authenticationReady
        usageKnown = $state.usageKnown
        usedPercent = $state.usedPercent
        hardLimitPercent = $state.hardLimitPercent
        usageAcquisitionMode = $state.usageAcquisitionMode
        usageMachineReadable = $state.usage.machineReadable
        usage = $state.usage
        available = $state.available
        reason = $state.reason
        warning = $state.warning
        model = if ($null -ne $state.PSObject.Properties['model']) { $state.model } else { $null }
        modelAvailable = if ($null -ne $state.PSObject.Properties['modelAvailable']) { $state.modelAvailable } else { $null }
        consumptionMode = if ($null -ne $state.PSObject.Properties['consumptionMode']) { $state.consumptionMode } else { $null }
        consumptionModeVerified = if ($null -ne $state.PSObject.Properties['consumptionModeVerified']) { $state.consumptionModeVerified } else { $null }
    }
}

[pscustomobject]@{
    updatedAt = (Get-Date).ToString('o')
    powershell = $PSVersionTable.PSVersion.ToString()
    operatingSystem = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    resources = [pscustomobject] $results
} | ConvertTo-Json -Depth 12
