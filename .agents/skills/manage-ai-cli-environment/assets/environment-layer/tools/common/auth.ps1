Set-StrictMode -Version Latest

function Get-UserControlledLoginDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot
    )

    $resolvedRepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $adapter = Get-ProviderAdapter -ResourceName $ResourceName
    $toolsRoot = Split-Path -Parent $PSScriptRoot
    $instructions = [System.Collections.Generic.List[string]]::new()
    $instructions.Add('This PowerShell window is yours to control; the agent will not press keys or choose options for you.')
    $instructions.Add('There is no need to preselect a browser. If an official sign-in page opens, choose its browser context, profile, and account yourself.')

    $command = [string] $adapter.login.command
    $arguments = [string[]] $adapter.login.arguments
    $confirmationPrompt = 'Prepare the browser and profile you intend to use, then press Enter to start the official provider flow.'
    switch ($ResourceName) {
        'codexMain' {
            $instructions.Add('Complete the official Codex login and close this window when the CLI returns.')
        }
        'codexSpark' {
            $instructions.Add('Codex Main and Spark share Codex authentication; complete the official login, then verify Spark with a real Spark task.')
        }
        'copilotPersonal' {
            $command = Join-Path $toolsRoot 'copilot-personal-token.ps1'
            $arguments = @($resolvedRepositoryRoot)
            $confirmationPrompt = $null
            $instructions.Add('Enter the dedicated Personal token only in the secure prompt in this window; it remains isolated from Company stored authentication.')
        }
        'copilotCompany' {
            $arguments = @('login', '--device-code')
            $confirmationPrompt = 'Press Enter to generate a device code. Then open the displayed URL in any browser/profile you choose.'
            $instructions.Add('Complete the official Company account login with the device URL and confirm the intended GitHub identity yourself.')
        }
        'agy' {
            $instructions.Add('Complete the official Google account flow and make all account choices yourself.')
        }
        'junie' {
            $instructions.Add('Choose the JetBrains account, model, settings import, and repository trust options yourself, then verify with /account and a minimal task.')
        }
    }

    return [pscustomobject]@{
        resourceName = $ResourceName
        command = $command
        arguments = $arguments
        workingDirectory = $resolvedRepositoryRoot
        windowTitle = "$ResourceName interactive setup"
        instructions = $instructions.ToArray()
        confirmationPrompt = $confirmationPrompt
        interactionOwner = 'user'
        preselectBrowser = $false
    }
}

function Invoke-ResourceLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [psobject] $Adapter,

        [hashtable] $Environment = @{}
    )

    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $definition = Get-UserControlledLoginDefinition -ResourceName $ResourceName -RepositoryRoot $repositoryRoot
    Write-Host "Authentication is required for $ResourceName. A user-controlled PowerShell window will open; complete every choice there."
    $result = Start-UserControlledPowerShellProcess `
        -Command $definition.command `
        -Arguments ([string[]] $definition.arguments) `
        -WorkingDirectory $definition.workingDirectory `
        -WindowTitle $definition.windowTitle `
        -Instructions ([string[]] $definition.instructions) `
        -ConfirmationPrompt $definition.confirmationPrompt `
        -WaitForExit

    return $result.started -and $result.exitCode -eq 0
}
