#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [Parameter(Mandatory = $true)]
    [string] $UsedColumn,

    [string] $LimitColumn,

    [string] $RemainingColumn,

    [string] $UnitType = 'AI Credits',

    [string] $Scope = 'monthly'
)

. (Join-Path $PSScriptRoot '..\common\import.ps1')

Import-JetBrainsCentralConsoleUsage @PSBoundParameters |
    ConvertTo-Json -Depth 12
