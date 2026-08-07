#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int] $TimeoutSeconds = 15
)

$toolsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolsRoot 'common\import.ps1')
. (Join-Path $PSScriptRoot 'usage.ps1')

$launch = try { Resolve-CodexCliLaunch -Command 'codex' } catch { $null }
$installed = $null -ne $launch
$version = $null
$authenticationReady = $false
$authenticationReason = if ($installed) { 'authentication_unknown' } else { 'command_not_found' }

if ($installed) {
    $versionResult = Invoke-CapturedProcess `
        -Command $launch.filePath `
        -Arguments (@($launch.arguments) + @('--version')) `
        -TimeoutSeconds $TimeoutSeconds
    if ($versionResult.exitCode -eq 0) {
        $version = (($versionResult.stdout -split "`r?`n") |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1)
    }

    $loginResult = Invoke-CapturedProcess `
        -Command $launch.filePath `
        -Arguments (@($launch.arguments) + @('login', 'status')) `
        -TimeoutSeconds $TimeoutSeconds
    $authenticationReady = $loginResult.exitCode -eq 0
    $authenticationReason = if ($authenticationReady) { $null } else { 'authentication_required' }
}

$usage = if ($installed -and $authenticationReady) {
    Invoke-CodexUsageSnapshot -TimeoutSeconds $TimeoutSeconds
}
else {
    $unknownReason = if (-not $installed) { 'command_not_found' } else { 'authentication_required' }
    [pscustomobject]@{
        provider = 'codex'
        source = 'codex-app-server'
        queriedAt = (Get-Date).ToString('o')
        resources = [pscustomobject]@{
            codexMain = New-CodexUnknownUsage -Source 'codex-app-server' -Reason $unknownReason
            codexSpark = New-CodexUnknownUsage -Source 'codex-app-server' -Reason $unknownReason
        }
        rateLimitResetCredits = $null
    }
}

[pscustomobject]@{
    provider = 'codex'
    checkedAt = (Get-Date).ToString('o')
    installed = $installed
    executable = if ($installed) { $launch.commandPath } else { $null }
    version = $version
    authenticationReady = $authenticationReady
    authenticationReason = $authenticationReason
    usage = $usage
} | ConvertTo-Json -Depth 16
