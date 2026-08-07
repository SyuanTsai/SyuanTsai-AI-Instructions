Set-StrictMode -Version Latest

function Get-UsagePropertyValue {
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

function ConvertTo-UsageSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [psobject] $Usage,

        [Parameter(Mandatory = $true)]
        [ValidateSet('official_api', 'provider_api', 'csv_import', 'interactive', 'unsupported')]
        [string] $AcquisitionMode
    )

    $usedPercent = Get-UsagePropertyValue -InputObject $Usage -Name 'usedPercent'
    $remainingPercent = Get-UsagePropertyValue -InputObject $Usage -Name 'remainingPercent'
    $usedQuantity = Get-UsagePropertyValue -InputObject $Usage -Name 'usedQuantity'
    $limitQuantity = Get-UsagePropertyValue -InputObject $Usage -Name 'limitQuantity'
    $remainingQuantity = Get-UsagePropertyValue -InputObject $Usage -Name 'remainingQuantity'
    if ($null -eq $remainingQuantity) {
        $remainingQuantity = Get-UsagePropertyValue -InputObject $Usage -Name 'remainingAmount'
    }
    $knownValue = Get-UsagePropertyValue -InputObject $Usage -Name 'known'
    $known = if ($null -ne $knownValue) { [bool] $knownValue } else { $null -ne $usedPercent }
    $usageAmountKnownValue = Get-UsagePropertyValue -InputObject $Usage -Name 'usageAmountKnown'
    $usageAmountKnown = if ($null -ne $usageAmountKnownValue) {
        [bool] $usageAmountKnownValue
    }
    else {
        $null -ne $usedQuantity
    }
    $limitAmountKnownValue = Get-UsagePropertyValue -InputObject $Usage -Name 'limitAmountKnown'
    $limitAmountKnown = if ($null -ne $limitAmountKnownValue) {
        [bool] $limitAmountKnownValue
    }
    else {
        $null -ne $limitQuantity
    }
    $remainingAmountKnownValue = Get-UsagePropertyValue -InputObject $Usage -Name 'remainingAmountKnown'
    $remainingAmountKnown = if ($null -ne $remainingAmountKnownValue) {
        [bool] $remainingAmountKnownValue
    }
    else {
        $null -ne $remainingQuantity
    }

    $actions = @(Get-UsagePropertyValue -InputObject $Usage -Name 'actions')
    $humanReviewAction = Get-UsagePropertyValue -InputObject $Usage -Name 'humanReviewAction'
    if ($actions.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string] $humanReviewAction)) {
        $actions = @([pscustomobject]@{
            type = 'human_review'
            command = [string] $humanReviewAction
        })
    }

    $details = @(Get-UsagePropertyValue -InputObject $Usage -Name 'details')
    return [pscustomobject]@{
        provider = $ResourceName
        source = [string] (Get-UsagePropertyValue -InputObject $Usage -Name 'source')
        acquisitionMode = $AcquisitionMode
        machineReadable = $AcquisitionMode -in @('official_api', 'provider_api', 'csv_import')
        queriedAt = if ($null -ne (Get-UsagePropertyValue -InputObject $Usage -Name 'queriedAt')) {
            [string] (Get-UsagePropertyValue -InputObject $Usage -Name 'queriedAt')
        }
        else {
            (Get-Date).ToString('o')
        }
        known = $known
        usageAmountKnown = $usageAmountKnown
        limitAmountKnown = $limitAmountKnown
        remainingAmountKnown = $remainingAmountKnown
        usedPercent = $usedPercent
        remainingPercent = $remainingPercent
        usedQuantity = $usedQuantity
        limitQuantity = $limitQuantity
        remainingQuantity = $remainingQuantity
        sessionAmount = Get-UsagePropertyValue -InputObject $Usage -Name 'sessionAmount'
        remainingAmount = Get-UsagePropertyValue -InputObject $Usage -Name 'remainingAmount'
        unitType = Get-UsagePropertyValue -InputObject $Usage -Name 'unitType'
        scope = Get-UsagePropertyValue -InputObject $Usage -Name 'scope'
        unlimited = Get-UsagePropertyValue -InputObject $Usage -Name 'unlimited'
        details = $details
        reason = Get-UsagePropertyValue -InputObject $Usage -Name 'reason'
        humanReviewAction = $humanReviewAction
        actions = $actions
    }
}

function New-UnknownUsageSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [ValidateSet('official_api', 'provider_api', 'csv_import', 'interactive', 'unsupported')]
        [string] $AcquisitionMode,

        [Parameter(Mandatory = $true)]
        [string] $Reason,

        [object[]] $Actions = @()
    )

    return ConvertTo-UsageSnapshot `
        -ResourceName $ResourceName `
        -AcquisitionMode $AcquisitionMode `
        -Usage ([pscustomobject]@{
            source = $Source
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
            details = @()
            reason = $Reason
            actions = $Actions
        })
}
