#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'CsvImport')]
    [string] $CentralConsoleCsvPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'CsvImport')]
    [string] $UsedColumn,

    [Parameter(ParameterSetName = 'CsvImport')]
    [string] $LimitColumn,

    [Parameter(ParameterSetName = 'CsvImport')]
    [string] $RemainingColumn,

    [Parameter(ParameterSetName = 'CsvImport')]
    [string] $UnitType = 'AI Credits',

    [Parameter(ParameterSetName = 'CsvImport')]
    [string] $Scope = 'monthly'
)

$toolsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolsRoot 'common\import.ps1')

$usage = if ($PSCmdlet.ParameterSetName -eq 'CsvImport') {
    Import-JetBrainsCentralConsoleUsage `
        -Path $CentralConsoleCsvPath `
        -UsedColumn $UsedColumn `
        -LimitColumn $LimitColumn `
        -RemainingColumn $RemainingColumn `
        -UnitType $UnitType `
        -Scope $Scope
}
else {
    New-JunieUsageSnapshot
}

$usage | ConvertTo-Json -Depth 12
