Set-StrictMode -Version Latest

function Get-GlobalStatePropertyValue {
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-GlobalPersistedUsage {
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceName,
        [AllowNull()] [object] $Usage
    )

    if ($null -eq $Usage) {
        return [pscustomobject]@{
            provider = $ResourceName
            source = 'unavailable'
            acquisitionMode = 'unsupported'
            machineReadable = $false
            queriedAt = (Get-Date).ToString('o')
            known = $false
            usageAmountKnown = $false
            limitAmountKnown = $false
            remainingAmountKnown = $false
            usedPercent = $null
            remainingPercent = $null
            usedQuantity = $null
            limitQuantity = $null
            remainingQuantity = $null
            unitType = $null
            scope = $null
            unlimited = $null
            reason = 'usage_unavailable'
            actions = @()
        }
    }

    return [pscustomobject]@{
        provider = $ResourceName
        source = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'source'
        acquisitionMode = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'acquisitionMode'
        machineReadable = [bool] (Get-GlobalStatePropertyValue -InputObject $Usage -Name 'machineReadable')
        queriedAt = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'queriedAt'
        known = [bool] (Get-GlobalStatePropertyValue -InputObject $Usage -Name 'known')
        usageAmountKnown = [bool] (Get-GlobalStatePropertyValue -InputObject $Usage -Name 'usageAmountKnown')
        limitAmountKnown = [bool] (Get-GlobalStatePropertyValue -InputObject $Usage -Name 'limitAmountKnown')
        remainingAmountKnown = [bool] (Get-GlobalStatePropertyValue -InputObject $Usage -Name 'remainingAmountKnown')
        usedPercent = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'usedPercent'
        remainingPercent = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'remainingPercent'
        usedQuantity = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'usedQuantity'
        limitQuantity = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'limitQuantity'
        remainingQuantity = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'remainingQuantity'
        unitType = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'unitType'
        scope = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'scope'
        unlimited = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'unlimited'
        reason = Get-GlobalStatePropertyValue -InputObject $Usage -Name 'reason'
        actions = @(Get-GlobalStatePropertyValue -InputObject $Usage -Name 'actions')
    }
}

function Get-GlobalProviderReality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot,

        [scriptblock] $UsageRunner
    )

    . Import-GlobalAiProviderTools -GlobalRoot $GlobalRoot
    $configuration = Read-GlobalAiResourceGuardConfiguration -GlobalRoot $GlobalRoot
    $parameters = @{
        ResourceName = $ResourceName
        Configuration = $configuration
        StateRoot = (Join-Path $GlobalRoot 'profiles')
    }
    if ($null -ne $UsageRunner) {
        $parameters.UsageRunner = $UsageRunner
    }
    return Invoke-ResourceAvailability @parameters
}

function Update-GlobalResourceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [string] $GlobalRoot,

        [scriptblock] $UsageRunner,

        [scriptblock] $RealityCollector
    )

    $resolvedRoot = Resolve-GlobalAiResourceGuardRoot -GlobalRoot $GlobalRoot
    if ($null -eq $RealityCollector) {
        $RealityCollector = {
            param($Name, $Root, $ProviderUsageRunner)
            Get-GlobalProviderReality `
                -ResourceName $Name `
                -GlobalRoot $Root `
                -UsageRunner $ProviderUsageRunner
        }
    }
    $reality = & $RealityCollector $ResourceName $resolvedRoot $UsageRunner
    $cliReady = Get-GlobalStatePropertyValue -InputObject $reality -Name 'cliReady'
    $authenticationReady = Get-GlobalStatePropertyValue -InputObject $reality -Name 'authenticationReady'
    $readinessKnown = $null -ne $cliReady -or $null -ne $authenticationReady
    $readinessAvailable = $cliReady -ne $false -and $authenticationReady -ne $false
    $readinessReason = if ($readinessKnown -and -not $readinessAvailable) {
        Get-GlobalStatePropertyValue -InputObject $reality -Name 'reason'
    }
    else {
        $null
    }

    $state = [pscustomobject]@{
        schemaVersion = 1
        resource = $ResourceName
        updatedAt = (Get-Date).ToString('o')
        readiness = [pscustomobject]@{
            known = $readinessKnown
            available = $readinessAvailable
            cliReady = $cliReady
            authenticationReady = $authenticationReady
            reason = $readinessReason
        }
        usage = ConvertTo-GlobalPersistedUsage `
            -ResourceName $ResourceName `
            -Usage (Get-GlobalStatePropertyValue -InputObject $reality -Name 'usage')
    }
    Write-GlobalResourceState -ResourceName $ResourceName -GlobalRoot $resolvedRoot -State $state | Out-Null
    return $state
}
