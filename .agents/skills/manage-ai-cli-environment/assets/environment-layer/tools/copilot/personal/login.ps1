#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
)

$copilotRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Split-Path -Parent $copilotRoot
. (Join-Path $toolsRoot 'common\import.ps1')

$definition = Get-UserControlledLoginDefinition `
    -ResourceName 'copilotPersonal' `
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
