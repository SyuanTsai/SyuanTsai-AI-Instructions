#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $PrivateEndpoint
)

$copilotRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Split-Path -Parent $copilotRoot
. (Join-Path $toolsRoot 'common\import.ps1')

$token = Get-CopilotPersonalToken
try {
    $result = Invoke-CopilotPersonalUsageSnapshot `
        -Token ([string] $token) `
        -PrivateEndpoint:$PrivateEndpoint
    $result | ConvertTo-Json -Depth 12
}
finally {
    $token = $null
}
