#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $Repair,
    [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
    [string] $InteractiveResourceName,

    [string] $JunieCentralConsoleCsvPath,

    [string] $JunieUsedColumn,

    [string] $JunieLimitColumn,

    [string] $JunieRemainingColumn,

    [ValidateRange(1, 16)]
    [int] $ThrottleLimit = 6
)

$configPath = Join-Path $RepositoryRoot '.ai\config.json'
$importPath = Join-Path $PSScriptRoot 'common\import.ps1'
$resourceNames = @('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')
$repairEnabled = [bool] $Repair

if (-not [string]::IsNullOrWhiteSpace($InteractiveResourceName)) {
    . $importPath
    $interactiveResult = Start-UserControlledUsageInspection `
        -ResourceName $InteractiveResourceName `
        -RepositoryRoot $RepositoryRoot `
        -WaitForExit
    $interactiveResult | ConvertTo-Json -Depth 6
    if (-not $interactiveResult.started -or $interactiveResult.exitCode -ne 0) {
        exit 1
    }
    return
}

# Each runspace performs exactly the provider's configured primary probe. A
# provider without a non-consuming status command uses its diagnostic CLI probe
# here and reports authenticationReady/usage as unknown.
$parallelResourceNames = if ([string]::IsNullOrWhiteSpace($JunieCentralConsoleCsvPath)) {
    $resourceNames
}
else {
    @($resourceNames | Where-Object { $_ -ne 'junie' })
}
$states = @($parallelResourceNames | ForEach-Object -Parallel {
    . $using:importPath
    $configuration = Read-AiEnvironmentConfig -Path $using:configPath
    Invoke-ResourceAvailability `
        -ResourceName $_ `
        -Configuration $configuration `
        -Repair:$using:repairEnabled
} -ThrottleLimit $ThrottleLimit)

if (-not [string]::IsNullOrWhiteSpace($JunieCentralConsoleCsvPath)) {
    if ([string]::IsNullOrWhiteSpace($JunieUsedColumn)) {
        throw '-JunieUsedColumn is required with -JunieCentralConsoleCsvPath.'
    }
    . $importPath
    $configuration = Read-AiEnvironmentConfig -Path $configPath
    $usageRunner = {
        param($ResourceName, $TimeoutSeconds)
        Import-JetBrainsCentralConsoleUsage `
            -Path $JunieCentralConsoleCsvPath `
            -UsedColumn $JunieUsedColumn `
            -LimitColumn $JunieLimitColumn `
            -RemainingColumn $JunieRemainingColumn
    }
    $states += Invoke-ResourceAvailability `
        -ResourceName 'junie' `
        -Configuration $configuration `
        -UsageRunner $usageRunner `
        -Repair:$repairEnabled
}

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
