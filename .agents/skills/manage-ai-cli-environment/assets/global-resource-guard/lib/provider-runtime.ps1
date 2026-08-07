Set-StrictMode -Version Latest

function Import-GlobalAiProviderTools {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot
    )

    if ($null -ne (Get-Command Get-ProviderAdapter -ErrorAction SilentlyContinue)) {
        return
    }
    $providerImport = Join-Path $GlobalRoot 'provider-tools\common\import.ps1'
    if (-not (Test-Path -LiteralPath $providerImport -PathType Leaf)) {
        throw 'provider_tools_missing'
    }
    . $providerImport
}

function Get-GlobalResourceRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot
    )

    . Import-GlobalAiProviderTools -GlobalRoot $GlobalRoot
    $configuration = Read-GlobalAiResourceGuardConfiguration -GlobalRoot $GlobalRoot
    $resourceConfig = $configuration.resources.PSObject.Properties[$ResourceName].Value
    $adapter = Get-ProviderAdapter -ResourceName $ResourceName
    $environment = Get-ResourceEnvironment `
        -ResourceName $ResourceName `
        -StateRoot (Join-Path $GlobalRoot 'profiles')

    if ($ResourceName -in @('copilotPersonal', 'copilotCompany')) {
        $authentication = Resolve-CopilotProfileAuthentication `
            -ResourceName $ResourceName `
            -ResourceConfig $resourceConfig `
            -Environment $environment
        if (-not $authentication.ready) {
            return [pscustomobject]@{
                ready = $false
                reason = $authentication.reason
                command = $adapter.executable
                argumentsPrefix = @()
                environment = @{}
            }
        }
    }

    if ($ResourceName -eq 'junie') {
        $junieEnvironment = Get-JunieCredentialEnvironment
        $authentication = Resolve-JunieHeadlessAuthentication -Environment $junieEnvironment
        if (-not $authentication.ready) {
            return [pscustomobject]@{
                ready = $false
                reason = $authentication.reason
                command = $adapter.executable
                argumentsPrefix = @('--task')
                environment = @{}
            }
        }
    }

    $argumentsPrefix = if ($ResourceName -eq 'codexSpark') {
        @('-m', $adapter.model)
    }
    elseif ($ResourceName -eq 'junie') {
        @('--task')
    }
    else {
        @()
    }

    return [pscustomobject]@{
        ready = $true
        reason = $null
        command = $adapter.executable
        argumentsPrefix = [string[]] $argumentsPrefix
        environment = $environment
    }
}
