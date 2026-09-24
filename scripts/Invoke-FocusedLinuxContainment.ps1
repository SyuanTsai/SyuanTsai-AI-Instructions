[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$resolverPath = Join-Path $PSScriptRoot 'Resolve-StandardValidationTool.ps1'
$testPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/standard-semantic-bridge.Tests.ps1'
$receiptRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [string]$env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}
if (-not (Test-Path -LiteralPath $receiptRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $receiptRoot -Force)
}
$receiptPath = Join-Path $receiptRoot ("focused-pester-{0}.json" -f [guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
    throw "The central Pester resolver is missing: $resolverPath"
}
if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw "The focused Linux containment test file is missing: $testPath"
}

Remove-Module Pester -Force -ErrorAction SilentlyContinue
& $resolverPath -ToolName pester -Install -OutputPath $receiptPath | Out-Null
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw 'The central Pester resolver did not write its receipt.'
}

$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if ($receipt.toolName -isnot [string] -or [string]$receipt.toolName -cne 'pester' -or
    $receipt.source -isnot [string] -or [string]$receipt.source -cne 'PowerShellGallery:Pester' -or
    $receipt.channel -isnot [string] -or [string]$receipt.channel -cne 'latest-stable' -or
    $receipt.resolvedVersion -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$receipt.resolvedVersion) -or
    $receipt.installRoot -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$receipt.installRoot) -or
    $receipt.modulePath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$receipt.modulePath)) {
    throw 'The central Pester receipt is incomplete or has an unapproved tool identity.'
}

try { $resolvedPesterVersion = [version]$receipt.resolvedVersion }
catch { throw "The central Pester receipt has an invalid version: $($receipt.resolvedVersion)" }
if ($resolvedPesterVersion.Major -ne 6) {
    throw "The focused Linux containment gate requires the central resolver's Pester 6 channel; resolved $resolvedPesterVersion."
}

$installRoot = [IO.Path]::GetFullPath([string]$receipt.installRoot)
$modulePath = [IO.Path]::GetFullPath([string]$receipt.modulePath)
$installRootPrefix = $installRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $modulePath.StartsWith($installRootPrefix, [StringComparison]::Ordinal) -or
    -not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw 'The Pester module path is missing or escapes the resolver-owned install root.'
}

Import-Module -Name $modulePath -Force -ErrorAction Stop
$loadedPester = Get-Module Pester | Where-Object {
    [string]$_.Version -ceq [string]$resolvedPesterVersion -and
    [IO.Path]::GetFullPath([string]$_.ModuleBase).StartsWith($installRootPrefix, [StringComparison]::Ordinal)
} | Select-Object -First 1
if ($null -eq $loadedPester) {
    throw "The Pester module loaded from the resolver receipt does not match version $resolvedPesterVersion."
}
$invokePester = Get-Command Invoke-Pester -Module Pester -CommandType Function, Cmdlet -ErrorAction Stop | Select-Object -First 1
if ($null -eq $invokePester -or [string]$invokePester.Module.Version -cne [string]$resolvedPesterVersion) {
    throw 'The resolver-owned Pester module did not provide the expected Invoke-Pester command.'
}

$result = Invoke-Pester -Path $testPath -TagFilter 'LinuxContainment' -PassThru
if ($null -eq $result) {
    throw 'Pester did not return a result object for the Linux containment tag.'
}

$requiredCounts = @('TotalCount', 'PassedCount', 'FailedCount', 'SkippedCount', 'InconclusiveCount', 'NotRunCount')
$counts = [ordered]@{}
foreach ($countName in $requiredCounts) {
    $countProperty = $result.PSObject.Properties[$countName]
    if ($null -eq $countProperty -or
        ($countProperty.Value -isnot [int] -and $countProperty.Value -isnot [long] -and $countProperty.Value -isnot [int32] -and $countProperty.Value -isnot [int64])) {
        throw "Pester did not return an integer $countName value for the Linux containment tag."
    }
    $counts[$countName] = [int64]$countProperty.Value
    if ([int64]$counts[$countName] -lt 0) {
        throw "Pester returned a negative $countName value for the Linux containment tag."
    }
}

$pendingCount = 0L
$pendingCountProperty = $result.PSObject.Properties['PendingCount']
if ($null -ne $pendingCountProperty) {
    if ($pendingCountProperty.Value -isnot [int] -and $pendingCountProperty.Value -isnot [long]) {
        throw 'Pester returned a non-integer PendingCount value for the Linux containment tag.'
    }
    $pendingCount = [int64]$pendingCountProperty.Value
}
$testsProperty = $result.PSObject.Properties['Tests']
if ($null -ne $testsProperty) {
    $pendingTests = @($testsProperty.Value | Where-Object { [string]$_.Result -ceq 'Pending' })
    if ($pendingTests.Count -gt $pendingCount) { $pendingCount = [int64]$pendingTests.Count }
}
if ($pendingCount -lt 0) {
    throw 'Pester returned a negative PendingCount value for the Linux containment tag.'
}
$counts['PendingCount'] = $pendingCount

$selectedCount = [int64]$counts.PassedCount + [int64]$counts.FailedCount + [int64]$counts.SkippedCount +
    [int64]$counts.PendingCount + [int64]$counts.InconclusiveCount
$selectedCountFromDiscovery = [int64]$counts.TotalCount - [int64]$counts.NotRunCount
if ($selectedCountFromDiscovery -lt 0 -or $selectedCountFromDiscovery -ne $selectedCount) {
    throw "Pester's selected-test count does not reconcile with its result statuses: discovered=$($counts.TotalCount), notrun=$($counts.NotRunCount), statuses=$selectedCount."
}
if ($null -ne $result.PSObject.Properties['Result'] -and [string]$result.Result -cne 'Passed') {
    throw "Pester reported overall result '$($result.Result)' for the Linux containment tag."
}
Write-Host "UnixCallbackContainment - Pester $resolvedPesterVersion Selected: $selectedCount Total: $($counts.TotalCount) NotRun: $($counts.NotRunCount) Passed: $($counts.PassedCount) Failed: $($counts.FailedCount) Skipped: $($counts.SkippedCount) Pending: $($counts.PendingCount) Inconclusive: $($counts.InconclusiveCount)"
Write-Host "Pester resolver receipt: $receiptPath"

if ([int64]$selectedCountFromDiscovery -ne 5 -or
    [int64]$selectedCount -ne 5 -or
    [int64]$counts.PassedCount -ne 5 -or
    [int64]$counts.FailedCount -ne 0 -or
    [int64]$counts.SkippedCount -ne 0 -or
    [int64]$counts.PendingCount -ne 0 -or
    [int64]$counts.InconclusiveCount -ne 0) {
    throw 'Linux callback containment did not produce exactly five passing selected tests.'
}

foreach ($diagnosticName in @('FailedBlocksCount', 'FailedContainersCount')) {
    $diagnosticProperty = $result.PSObject.Properties[$diagnosticName]
    if ($null -ne $diagnosticProperty -and [int64]$diagnosticProperty.Value -ne 0) {
        throw "Pester reported $diagnosticName=$($diagnosticProperty.Value) for the Linux containment tag."
    }
}
