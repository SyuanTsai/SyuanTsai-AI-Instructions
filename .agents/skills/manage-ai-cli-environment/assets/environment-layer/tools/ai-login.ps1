#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
    [string] $ResourceName,

    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

. (Join-Path $PSScriptRoot 'common\import.ps1')

$definition = Get-UserControlledLoginDefinition `
    -ResourceName $ResourceName `
    -RepositoryRoot $RepositoryRoot
$result = Start-UserControlledPowerShellProcess `
    -Command $definition.command `
    -Arguments ([string[]] $definition.arguments) `
    -WorkingDirectory $definition.workingDirectory `
    -WindowTitle $definition.windowTitle `
    -Instructions ([string[]] $definition.instructions) `
    -ConfirmationPrompt $definition.confirmationPrompt `
    -WaitForExit

$result | ConvertTo-Json -Compress
if (-not $result.started -or $result.exitCode -ne 0) {
    exit 1
}
