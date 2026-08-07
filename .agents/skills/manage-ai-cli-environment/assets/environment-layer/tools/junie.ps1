#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $NoRepair,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ResourceArguments = @()
)

$repositoryRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'ai-resource.ps1') -ResourceName junie -RepositoryRoot $repositoryRoot -NoRepair:$NoRepair @ResourceArguments
exit $LASTEXITCODE
