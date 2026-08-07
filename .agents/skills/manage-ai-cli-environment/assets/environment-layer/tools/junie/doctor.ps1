#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int] $TimeoutSeconds = 15
)

$toolsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolsRoot 'common\import.ps1')

Get-JunieDoctorState -TimeoutSeconds $TimeoutSeconds |
    ConvertTo-Json -Depth 12
