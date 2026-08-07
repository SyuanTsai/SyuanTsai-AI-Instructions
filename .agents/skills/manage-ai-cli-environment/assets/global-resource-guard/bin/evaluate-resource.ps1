#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
    [string] $ResourceName,

    [string] $GlobalRoot = (Split-Path -Parent $PSScriptRoot)
)

. (Join-Path $PSScriptRoot '..\lib\import.ps1')

Resolve-GlobalResourceAvailability -ResourceName $ResourceName -GlobalRoot $GlobalRoot |
    ConvertTo-Json -Depth 12
