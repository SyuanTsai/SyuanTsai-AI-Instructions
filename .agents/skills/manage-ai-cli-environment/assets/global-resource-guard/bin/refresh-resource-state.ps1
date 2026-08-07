#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
    [string] $ResourceName,

    [string] $GlobalRoot = (Split-Path -Parent $PSScriptRoot),

    [string] $JunieCentralConsoleCsvPath,

    [string] $JunieUsedColumn,

    [string] $JunieLimitColumn,

    [string] $JunieRemainingColumn
)

. (Join-Path $PSScriptRoot '..\lib\import.ps1')

$usageRunner = $null
if (-not [string]::IsNullOrWhiteSpace($JunieCentralConsoleCsvPath)) {
    if ($ResourceName -ne 'junie') {
        throw 'JetBrains Central Console CSV can only be supplied for the junie resource.'
    }
    if ([string]::IsNullOrWhiteSpace($JunieUsedColumn)) {
        throw '-JunieUsedColumn is required with -JunieCentralConsoleCsvPath.'
    }
    . Import-GlobalAiProviderTools -GlobalRoot $GlobalRoot
    $usageRunner = {
        param($Name, $TimeoutSeconds)
        Import-JetBrainsCentralConsoleUsage `
            -Path $JunieCentralConsoleCsvPath `
            -UsedColumn $JunieUsedColumn `
            -LimitColumn $JunieLimitColumn `
            -RemainingColumn $JunieRemainingColumn
    }
}

Update-GlobalResourceState `
    -ResourceName $ResourceName `
    -GlobalRoot $GlobalRoot `
    -UsageRunner $usageRunner |
    ConvertTo-Json -Depth 12
