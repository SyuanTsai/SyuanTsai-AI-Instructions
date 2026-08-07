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

    Write-Host "Authentication is required for $ResourceName. Complete the official browser, OAuth, or device flow."
    return Invoke-InteractiveProcess -Command $Adapter.login.command -Arguments ([string[]] $Adapter.login.arguments) -Environment $Environment
}
