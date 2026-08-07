Set-StrictMode -Version Latest

function Install-ResourceCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [psobject] $Adapter
    )

    # This diagnostic runs only after a command-not-found primary probe.
    if ($null -ne (Get-Command $Adapter.executable -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $true
    }

    return Invoke-InteractiveProcess -Command $Adapter.install.command -Arguments ([string[]] $Adapter.install.arguments)
}
