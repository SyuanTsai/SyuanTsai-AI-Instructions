#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
    [string] $ResourceName,

    [Parameter(Mandatory = $true)]
    [string] $RepositoryRoot,

    [switch] $NoRepair,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ResourceArguments = @()
)

. (Join-Path $PSScriptRoot 'common\import.ps1')

$result = Invoke-GuardedResourceCommand `
    -ResourceName $ResourceName `
    -RepositoryRoot $RepositoryRoot `
    -Arguments $ResourceArguments `
    -NoRepair:$NoRepair

$result | ConvertTo-Json -Depth 10
if (-not $result.success) {
    exit 1
}
