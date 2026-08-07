Set-StrictMode -Version Latest

function New-CopilotPersonalUnknownUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    return [pscustomobject]@{
        provider = 'copilotPersonal'
        source = $Source
        queriedAt = (Get-Date).ToString('o')
        known = $false
        usageAmountKnown = $false
        usedPercent = $null
        remainingPercent = $null
        usedQuantity = $null
        limitQuantity = $null
        unitType = $null
        scope = $null
        unlimited = $null
        details = @()
        reason = $Reason
    }
}

function ConvertFrom-CopilotPersonalBillingUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Response
    )

    if ($null -eq $Response.PSObject.Properties['usageItems']) {
        throw 'copilot billing response schema is unsupported'
    }

    $details = [System.Collections.Generic.List[object]]::new()
    $usedQuantity = [double] 0
    foreach ($item in @($Response.usageItems)) {
        if ($null -eq $item) {
            continue
        }
        $grossQuantity = if ($null -ne $item.PSObject.Properties['grossQuantity']) {
            [double] $item.grossQuantity
        }
        else {
            [double] 0
        }
        $usedQuantity += $grossQuantity
        $details.Add([pscustomobject]@{
            product = if ($null -ne $item.PSObject.Properties['product']) { [string] $item.product } else { $null }
            sku = if ($null -ne $item.PSObject.Properties['sku']) { [string] $item.sku } else { $null }
            model = if ($null -ne $item.PSObject.Properties['model']) { [string] $item.model } else { $null }
            unitType = if ($null -ne $item.PSObject.Properties['unitType']) { [string] $item.unitType } else { $null }
            grossQuantity = $grossQuantity
            netQuantity = if ($null -ne $item.PSObject.Properties['netQuantity']) { [double] $item.netQuantity } else { $null }
        })
    }

    return [pscustomobject]@{
        provider = 'copilotPersonal'
        source = 'github-billing-user'
        queriedAt = (Get-Date).ToString('o')
        known = $false
        usageAmountKnown = $true
        usedPercent = $null
        remainingPercent = $null
        usedQuantity = $usedQuantity
        limitQuantity = $null
        unitType = 'requests'
        scope = 'monthly'
        unlimited = $false
        details = $details.ToArray()
        reason = 'limit_unavailable'
    }
}

function ConvertFrom-CopilotPersonalPrivateQuota {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Response
    )

    $snapshotsProperty = @('quota_snapshots', 'quotaSnapshots') |
        Where-Object { $null -ne $Response.PSObject.Properties[$_] } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($snapshotsProperty)) {
        throw 'copilot private quota response schema is unsupported'
    }
    $snapshots = $Response.PSObject.Properties[$snapshotsProperty].Value
    $meterName = @('premium_interactions', 'premium_requests', 'ai_credits') |
        Where-Object { $null -ne $snapshots.PSObject.Properties[$_] } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($meterName)) {
        throw 'copilot private quota meter is unavailable'
    }
    $meter = $snapshots.PSObject.Properties[$meterName].Value
    $unlimited = $null -ne $meter.PSObject.Properties['unlimited'] -and [bool] $meter.unlimited

    if ($unlimited) {
        return [pscustomobject]@{
            provider = 'copilotPersonal'
            source = 'github-copilot-private'
            queriedAt = (Get-Date).ToString('o')
            known = $true
            usageAmountKnown = $false
            usedPercent = [double] 0
            remainingPercent = [double] 100
            usedQuantity = $null
            limitQuantity = $null
            unitType = $meterName
            scope = 'unlimited'
            unlimited = $true
            details = @([pscustomobject]@{ meter = $meterName; unlimited = $true })
            reason = $null
        }
    }

    if ($null -eq $meter.PSObject.Properties['entitlement'] -or
        $null -eq $meter.PSObject.Properties['remaining']) {
        throw 'copilot private quota quantities are unavailable'
    }
    $limitQuantity = [double] $meter.entitlement
    $remainingQuantity = [double] $meter.remaining
    $usedQuantity = [Math]::Max(0, $limitQuantity - $remainingQuantity)
    $remainingPercent = if ($null -ne $meter.PSObject.Properties['percent_remaining']) {
        [double] $meter.percent_remaining
    }
    elseif ($limitQuantity -gt 0) {
        ($remainingQuantity / $limitQuantity) * 100
    }
    else {
        throw 'copilot private quota denominator is invalid'
    }
    $remainingPercent = [Math]::Max(0, [Math]::Min(100, $remainingPercent))
    $usedPercent = 100 - $remainingPercent

    return [pscustomobject]@{
        provider = 'copilotPersonal'
        source = 'github-copilot-private'
        queriedAt = (Get-Date).ToString('o')
        known = $true
        usageAmountKnown = $true
        usedPercent = $usedPercent
        remainingPercent = $remainingPercent
        usedQuantity = $usedQuantity
        limitQuantity = $limitQuantity
        unitType = $meterName
        scope = 'monthly'
        unlimited = $false
        details = @([pscustomobject]@{
            meter = $meterName
            usedQuantity = $usedQuantity
            remainingQuantity = $remainingQuantity
            limitQuantity = $limitQuantity
        })
        reason = $null
    }
}

function Invoke-CopilotPersonalOfficialBillingRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Token
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Token"
        'User-Agent' = 'ai-cli-environment'
        'X-GitHub-Api-Version' = '2026-03-10'
    }
    $user = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/user' -Headers $headers
    if ($null -eq $user.PSObject.Properties['login'] -or [string]::IsNullOrWhiteSpace([string] $user.login)) {
        throw 'github user response schema is unsupported'
    }
    $username = [Uri]::EscapeDataString([string] $user.login)
    $now = Get-Date
    $uri = "https://api.github.com/users/$username/settings/billing/premium_request/usage?year=$($now.Year)&month=$($now.Month)"
    return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
}

function Invoke-CopilotPersonalPrivateQuotaRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Token
    )

    $headers = @{
        Accept = 'application/json'
        Authorization = "Bearer $Token"
        'User-Agent' = 'ai-cli-environment'
    }
    return Invoke-RestMethod `
        -Method Get `
        -Uri 'https://api.github.com/copilot_internal/user' `
        -Headers $headers
}

function Get-CopilotUsageFailureReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $statusCode = $null
    if ($null -ne $ErrorRecord.Exception.PSObject.Properties['Response'] -and
        $null -ne $ErrorRecord.Exception.Response -and
        $null -ne $ErrorRecord.Exception.Response.PSObject.Properties['StatusCode']) {
        $statusCode = [int] $ErrorRecord.Exception.Response.StatusCode
    }
    switch ($statusCode) {
        401 { return 'authentication_required' }
        403 { return 'billing_permission_required' }
        404 { return 'usage_endpoint_unavailable' }
        default { return 'usage_query_failed' }
    }
}

function Invoke-CopilotPersonalUsageSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Token,

        [switch] $PrivateEndpoint,

        [scriptblock] $OfficialRunner,

        [scriptblock] $PrivateRunner
    )

    $source = if ($PrivateEndpoint) { 'github-copilot-private' } else { 'github-billing-user' }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return New-CopilotPersonalUnknownUsage -Source $source -Reason 'authentication_required'
    }
    if ($null -eq $OfficialRunner) {
        $OfficialRunner = { param($Credential) Invoke-CopilotPersonalOfficialBillingRequest -Token $Credential }
    }
    if ($null -eq $PrivateRunner) {
        $PrivateRunner = { param($Credential) Invoke-CopilotPersonalPrivateQuotaRequest -Token $Credential }
    }

    try {
        if ($PrivateEndpoint) {
            $response = & $PrivateRunner $Token
            return ConvertFrom-CopilotPersonalPrivateQuota -Response $response
        }
        $response = & $OfficialRunner $Token
        return ConvertFrom-CopilotPersonalBillingUsage -Response $response
    }
    catch {
        return New-CopilotPersonalUnknownUsage `
            -Source $source `
            -Reason (Get-CopilotUsageFailureReason -ErrorRecord $_)
    }
}
