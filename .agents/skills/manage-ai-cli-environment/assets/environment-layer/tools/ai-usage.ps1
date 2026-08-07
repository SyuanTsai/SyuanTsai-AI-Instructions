#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $Repair,
    [ValidateRange(1, 16)]
    [int] $ThrottleLimit = 6
)

$configPath = Join-Path $RepositoryRoot '.ai\config.json'
$importPath = Join-Path $PSScriptRoot 'common\import.ps1'
$resourceNames = @('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')
$repairEnabled = [bool] $Repair

# Each runspace performs exactly the provider's configured primary probe. A
# provider without a non-consuming status command uses its diagnostic CLI probe
# here and reports authenticationReady/usage as unknown.
$states = $resourceNames | ForEach-Object -Parallel {
    . $using:importPath
    $configuration = Read-AiEnvironmentConfig -Path $using:configPath
    Invoke-ResourceAvailability `
        -ResourceName $_ `
        -Configuration $configuration `
        -Repair:$using:repairEnabled
} -ThrottleLimit $ThrottleLimit

$resources = [ordered]@{}
foreach ($state in $states) {
    $resources[$state.provider] = $state
}

$snapshot = [pscustomobject]@{
    updatedAt = (Get-Date).ToString('o')
    resources = [pscustomobject] $resources
}

$statePath = Join-Path $RepositoryRoot '.ai\usage-state.json'
$snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
$snapshot | ConvertTo-Json -Depth 12
