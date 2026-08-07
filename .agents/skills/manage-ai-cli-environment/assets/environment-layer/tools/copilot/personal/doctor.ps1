#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int] $TimeoutSeconds = 15,

    [switch] $PrivateEndpoint
)

$copilotRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Split-Path -Parent $copilotRoot
. (Join-Path $toolsRoot 'common\import.ps1')

$command = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$token = Get-CopilotPersonalToken
$installed = $null -ne $command
$credentialReady = -not [string]::IsNullOrWhiteSpace([string] $token)
$version = $null

try {
    if ($installed) {
        $versionResult = Invoke-CapturedProcess `
            -Command $command.Source `
            -Arguments @('version') `
            -TimeoutSeconds $TimeoutSeconds
        if ($versionResult.exitCode -eq 0) {
            $version = (($versionResult.stdout -split "`r?`n") |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 1)
        }
    }

    $usage = if ($credentialReady) {
        Invoke-CopilotPersonalUsageSnapshot `
            -Token ([string] $token) `
            -PrivateEndpoint:$PrivateEndpoint
    }
    else {
        New-CopilotPersonalUnknownUsage `
            -Source $(if ($PrivateEndpoint) { 'github-copilot-private' } else { 'github-billing-user' }) `
            -Reason 'authentication_required'
    }

    [pscustomobject]@{
        provider = 'copilotPersonal'
        checkedAt = (Get-Date).ToString('o')
        installed = $installed
        executable = if ($installed) { $command.Source } else { $null }
        version = $version
        credentialReady = $credentialReady
        credentialSource = if ($credentialReady) { 'windows-credential-manager-or-legacy-user-environment' } else { $null }
        usage = $usage
    } | ConvertTo-Json -Depth 14
}
finally {
    $token = $null
}
