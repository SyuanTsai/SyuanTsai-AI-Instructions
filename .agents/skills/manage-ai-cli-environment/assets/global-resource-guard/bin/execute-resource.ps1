#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
    [string] $ResourceName,

    [string] $GlobalRoot = (Split-Path -Parent $PSScriptRoot),

    [string] $WorkingDirectory = (Get-Location).Path,

    [string[]] $ResourceArguments = @()
)

. (Join-Path $PSScriptRoot '..\lib\import.ps1')

$result = Invoke-GlobalResourceExecution `
    -ResourceName $ResourceName `
    -GlobalRoot $GlobalRoot `
    -Arguments $ResourceArguments `
    -WorkingDirectory $WorkingDirectory
$result | ConvertTo-Json -Depth 12
if (-not $result.success) {
    exit 1
}
