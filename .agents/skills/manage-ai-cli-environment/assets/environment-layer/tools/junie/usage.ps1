Set-StrictMode -Version Latest

function New-JunieUsageSnapshot {
    [CmdletBinding()]
    param(
        [string] $Reason = 'interactive_usage_only'
    )

    $usage = [pscustomobject]@{
        provider = 'junie'
        source = 'junie-interactive-usage'
        queriedAt = (Get-Date).ToString('o')
        known = $false
        usageAmountKnown = $false
        limitAmountKnown = $false
        remainingAmountKnown = $false
        usedPercent = $null
        remainingPercent = $null
        usedQuantity = $null
        limitQuantity = $null
        sessionAmount = $null
        remainingAmount = $null
        unitType = $null
        scope = $null
        unlimited = $null
        details = @()
        reason = $Reason
        humanReviewAction = 'tools/ai-usage.ps1 -InteractiveResourceName junie'
        actions = @([pscustomobject]@{
            type = 'human_review'
            command = 'tools/ai-usage.ps1 -InteractiveResourceName junie'
        })
    }
    return ConvertTo-UsageSnapshot `
        -ResourceName 'junie' `
        -Usage $usage `
        -AcquisitionMode 'interactive'
}

function Get-JunieDoctorState {
    [CmdletBinding()]
    param(
        [hashtable] $CredentialEnvironment,

        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 15,

        [scriptblock] $CommandResolver = {
            Get-Command junie -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
        },

        [scriptblock] $VersionRunner = {
            param($Command, $Timeout)
            Invoke-CapturedProcess `
                -Command $Command `
                -Arguments @('--version') `
                -TimeoutSeconds $Timeout
        }
    )

    if ($null -eq $CredentialEnvironment) {
        $CredentialEnvironment = Get-JunieCredentialEnvironment
    }

    $command = & $CommandResolver
    $installed = $null -ne $command
    $commandPath = if ($installed -and $null -ne $command.PSObject.Properties['Source']) {
        [string] $command.Source
    }
    else {
        $null
    }
    $version = $null
    $versionReason = $null
    if ($installed -and -not [string]::IsNullOrWhiteSpace($commandPath)) {
        try {
            $versionResult = & $VersionRunner $commandPath $TimeoutSeconds
            if ($versionResult.exitCode -eq 0) {
                $version = (($versionResult.stdout -split "`r?`n") |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -First 1)
            }
            else {
                $versionReason = 'version_probe_failed'
            }
        }
        catch {
            $versionReason = 'version_probe_failed'
        }
    }

    $consumption = Get-JunieConsumptionMode -Environment $CredentialEnvironment
    $headlessAuthentication = Resolve-JunieHeadlessAuthentication -Environment $CredentialEnvironment

    return [pscustomobject]@{
        provider = 'junie'
        checkedAt = (Get-Date).ToString('o')
        installed = $installed
        executable = $commandPath
        version = $version
        installationReason = if ($installed) { $null } else { 'command_not_found' }
        versionReason = $versionReason
        interactiveCredentialReady = $null
        interactiveAuthenticationReason = 'interactive_verification_required'
        headlessCredentialReady = [bool] $headlessAuthentication.ready
        headlessAuthenticationReason = $headlessAuthentication.reason
        authenticationAction = if ($headlessAuthentication.ready) {
            'interactive_login_optional'
        }
        else {
            'interactive_login_or_configure_headless_key'
        }
        consumptionMode = $consumption.consumptionMode
        consumptionModeVerified = [bool] $consumption.consumptionModeVerified
        usage = New-JunieUsageSnapshot
    }
}
