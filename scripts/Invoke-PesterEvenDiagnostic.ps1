[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ps51', 'ps7')]
    [string]$Runtime,

    [Parameter(Mandatory = $true)]
    [ValidateSet('3.4.0', '4.10.1')]
    [string]$PesterVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet(0, 4)]
    [int]$PartitionIndex,

    [Parameter(Mandatory = $true)]
    [ValidateSet(182, 40)]
    [int]$ExpectedTotalCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (($Runtime -eq 'ps51' -and $PSVersionTable.PSVersion.Major -ne 5) -or
    ($Runtime -eq 'ps7' -and $PSVersionTable.PSVersion.Major -ne 7)) {
    throw "Diagnostic runtime $Runtime does not match the PowerShell host."
}
if (($PartitionIndex -eq 0 -and $ExpectedTotalCount -ne 182) -or
    ($PartitionIndex -eq 4 -and $ExpectedTotalCount -ne 40)) {
    throw 'Diagnostic partition and expected count disagree.'
}

Remove-Module Pester -Force -ErrorAction SilentlyContinue
$version = [version]$PesterVersion
$pester = Get-Module Pester -ListAvailable |
    Where-Object { $_.Version -eq $version } | Select-Object -First 1
if ($null -eq $pester) {
    Install-Module Pester -RequiredVersion $version -Scope CurrentUser -Force -SkipPublisherCheck
    $pester = Get-Module Pester -ListAvailable |
        Where-Object { $_.Version -eq $version } | Select-Object -First 1
}
if ($null -eq $pester) { throw "Pester $version is unavailable." }

$parameters = @{
    PesterModulePath = [string]$pester.Path
    PesterVersion = $PesterVersion
    ExpectedTotalCount = $ExpectedTotalCount
    ExpectedSkippedCount = 0
    ShardPartitionCount = 8
    ShardPartitionIndex = $PartitionIndex
    ExpectedFullShardCount = 32
    OuterTimeoutSeconds = 2400
    TestRoot = './tests'
    EvidenceRoot = $env:RUNNER_TEMP
}
Write-Host "DIAGNOSTIC_PARTITION_START runtime=$Runtime index=$PartitionIndex utc=$([DateTime]::UtcNow.ToString('o'))"
try {
    # The existing executor emits per-shard start and terminal summaries.
    # Its create-only process and result JSON files are retained on normal failure.
    & ./scripts/Invoke-PesterShardProcess.ps1 @parameters
    Write-Host "DIAGNOSTIC_PARTITION_END runtime=$Runtime index=$PartitionIndex utc=$([DateTime]::UtcNow.ToString('o'))"
}
finally {
    Write-Host "DIAGNOSTIC_PARTITION_EXIT runtime=$Runtime index=$PartitionIndex utc=$([DateTime]::UtcNow.ToString('o'))"
}
