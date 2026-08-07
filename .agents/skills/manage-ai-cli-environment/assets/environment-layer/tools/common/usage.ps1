Set-StrictMode -Version Latest

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
