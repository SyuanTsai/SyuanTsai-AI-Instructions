Set-StrictMode -Version Latest

function Invoke-ResourceLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [psobject] $Adapter,

        [hashtable] $Environment = @{}
    )

    if ($ResourceName -eq 'junie') {
        Write-Host 'Authentication is required for Junie. Leave Continue with JetBrains account selected in the terminal, activate the intended Chrome profile, and confirm the terminal choice only after that profile is ready. Select the intended JetBrains identity yourself and verify it in /account. JUNIE_API_KEY and BYOK are headless alternatives.'
    }
    else {
        Write-Host "Authentication is required for $ResourceName. Complete the official browser, OAuth, or device flow."
    }
    return Invoke-InteractiveProcess -Command $Adapter.login.command -Arguments ([string[]] $Adapter.login.arguments) -Environment $Environment
}
