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

. (Join-Path $PSScriptRoot 'usage.ps1')

if ($PrivateEndpoint) {
    if ([string]::IsNullOrWhiteSpace($ResourceName)) {
        throw '-PrivateEndpoint requires -ResourceName codexMain or codexSpark.'
    }
    $result = Invoke-CodexUsageProbe `
        -ResourceName $ResourceName `
        -AuthPath $AuthPath `
        -TimeoutSeconds $TimeoutSeconds
}
else {
    $snapshot = Invoke-CodexUsageSnapshot -TimeoutSeconds $TimeoutSeconds
    $result = if ([string]::IsNullOrWhiteSpace($ResourceName)) {
        $snapshot
    }
    else {
        $snapshot.resources.$ResourceName
    }
}

$result | ConvertTo-Json -Depth 16
