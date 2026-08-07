#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('codexMain', 'codexSpark')]
    [string] $ResourceName,

    [switch] $PrivateEndpoint,

    [string] $AuthPath,

    [ValidateRange(1, 60)]
    [int] $TimeoutSeconds = 15
)

$toolsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolsRoot 'common\import.ps1')

if ($PrivateEndpoint) {
    if ([string]::IsNullOrWhiteSpace($ResourceName)) {
        throw '-PrivateEndpoint requires -ResourceName codexMain or codexSpark.'
    }
    $providerUsage = Invoke-CodexUsageProbe `
        -ResourceName $ResourceName `
        -AuthPath $AuthPath `
        -TimeoutSeconds $TimeoutSeconds
    $result = ConvertTo-UsageSnapshot `
        -ResourceName $ResourceName `
        -Usage $providerUsage `
        -AcquisitionMode 'provider_api'
}
else {
    $snapshot = Invoke-CodexUsageSnapshot -TimeoutSeconds $TimeoutSeconds
    $normalizedResources = [pscustomobject]@{
        codexMain = ConvertTo-UsageSnapshot `
            -ResourceName 'codexMain' `
            -Usage $snapshot.resources.codexMain `
            -AcquisitionMode 'official_api'
        codexSpark = ConvertTo-UsageSnapshot `
            -ResourceName 'codexSpark' `
            -Usage $snapshot.resources.codexSpark `
            -AcquisitionMode 'official_api'
    }
    $result = if ([string]::IsNullOrWhiteSpace($ResourceName)) {
        [pscustomobject]@{
            provider = $snapshot.provider
            source = $snapshot.source
            queriedAt = $snapshot.queriedAt
            resources = $normalizedResources
            rateLimitResetCredits = $snapshot.rateLimitResetCredits
        }
    }
    else {
        $normalizedResources.$ResourceName
    }
}

$result | ConvertTo-Json -Depth 16
