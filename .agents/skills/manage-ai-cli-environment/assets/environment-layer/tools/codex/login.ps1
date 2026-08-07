#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$toolsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolsRoot 'common\import.ps1')

$definition = Get-UserControlledLoginDefinition `
    -ResourceName 'codexMain' `
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
