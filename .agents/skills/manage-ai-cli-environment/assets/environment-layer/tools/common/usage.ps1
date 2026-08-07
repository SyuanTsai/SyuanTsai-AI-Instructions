Set-StrictMode -Version Latest

function Get-UserControlledUsageDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot
    )

    $resolvedRepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $instructions = [System.Collections.Generic.List[string]]::new()
    $instructions.Add('This PowerShell window is yours to control; the agent will not enter commands or choose options for you.')
    $instructions.Add('Usage shown by the provider CLI is for human review only and will not be parsed or written to usage-state.json.')
    $command = $null
    $arguments = @()

    switch ($ResourceName) {
        { $_ -in @('codexMain', 'codexSpark') } {
            $command = 'codex'
            $instructions.Add('Run /usage in Codex to inspect the usage information available to your signed-in account.')
            if ($ResourceName -eq 'codexSpark') {
                $instructions.Add('Codex Main and Spark share authentication; this view does not prove Spark model availability.')
            }
        }
        { $_ -in @('copilotPersonal', 'copilotCompany') } {
            $command = 'copilot'
            $instructions.Add('Review the Plan quota in the Copilot status line. If it is hidden, run /statusline and enable quota.')
            $instructions.Add('The /usage command is session-scoped and is not the monthly Plan quota.')
        }
        'agy' {
            $command = 'agy'
            $arguments = @('models')
            $instructions.Add('The verified Agy CLI does not expose account usage; this command can only verify accessible models.')
        }
        'junie' {
            $command = 'junie'
            $instructions.Add('Run /account to confirm the intended JetBrains identity, then run /usage to inspect available usage information.')
        }
    }

    return [pscustomobject]@{
        resourceName = $ResourceName
        command = $command
        arguments = [string[]] $arguments
        workingDirectory = $resolvedRepositoryRoot
        windowTitle = "$ResourceName CLI usage inspection"
        instructions = $instructions.ToArray()
        confirmationPrompt = 'Press Enter to start the official provider CLI.'
        interactionOwner = 'user'
        machineReadable = $false
        source = 'provider-cli-user-visible'
    }
}

function Start-UserControlledUsageInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [string] $StateRoot,

        [scriptblock] $EnvironmentReader = {
            param($Name, $Target)
            [Environment]::GetEnvironmentVariable($Name, $Target)
        },

        [switch] $WaitForExit,

        [scriptblock] $ProcessStarter
    )

    $definition = Get-UserControlledUsageDefinition `
        -ResourceName $ResourceName `
        -RepositoryRoot $RepositoryRoot
    $environment = Get-ResourceEnvironment `
        -ResourceName $ResourceName `
        -StateRoot $StateRoot `
        -EnvironmentReader $EnvironmentReader
    if ($ResourceName -eq 'copilotPersonal') {
        $authentication = Resolve-CopilotProfileAuthentication `
            -ResourceName $ResourceName `
            -ResourceConfig ([pscustomobject]@{ authenticationMode = 'token' }) `
            -Environment $environment
        if (-not $authentication.ready) {
            return [pscustomobject]@{
                provider = $ResourceName
                started = $false
                processId = $null
                exitCode = $null
                reason = $authentication.reason
                usageKnown = $false
                usedPercent = $null
                source = $definition.source
            }
        }
    }
    $startParameters = @{
        Command = $definition.command
        Arguments = [string[]] $definition.arguments
        Environment = $environment
        WorkingDirectory = $definition.workingDirectory
        WindowTitle = $definition.windowTitle
        Instructions = [string[]] $definition.instructions
        ConfirmationPrompt = $definition.confirmationPrompt
        WaitForExit = [bool] $WaitForExit
    }
    if ($null -ne $ProcessStarter) {
        $startParameters.ProcessStarter = $ProcessStarter
    }

    $processResult = Start-UserControlledPowerShellProcess @startParameters
    return [pscustomobject]@{
        provider = $ResourceName
        started = $processResult.started
        processId = $processResult.processId
        exitCode = $processResult.exitCode
        reason = $processResult.reason
        usageKnown = $false
        usedPercent = $null
        source = $definition.source
    }
}

function Get-ResourceUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Adapter,

        [Parameter(Mandatory = $true)]
        [psobject] $ProbeResult
    )

    # None of the verified provider commands currently returns account quota as
    # machine-readable data. Keep this parser deliberately strict: only a future
    # adapter that explicitly marks structured percentage output may opt in.
    if ($Adapter.usageSource -eq 'structured-used-percent' -and
        -not [string]::IsNullOrWhiteSpace($ProbeResult.stdout)) {
        try {
            $payload = $ProbeResult.stdout | ConvertFrom-Json
            if ($null -ne $payload.usedPercent) {
                return [pscustomobject]@{
                    known = $true
                    usedPercent = [double] $payload.usedPercent
                    source = [string] $Adapter.usageSource
                }
            }
        }
        catch {
            # Malformed provider output is unknown, never zero.
        }
    }

    return [pscustomobject]@{
        known = $false
        usedPercent = $null
        source = [string] $Adapter.usageSource
    }
}
