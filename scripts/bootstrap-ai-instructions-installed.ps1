[CmdletBinding()]
param(
    [string] $TargetRoot,
    [switch] $SkipUpdateCheck,
    [switch] $ValidateOnly,
    [switch] $RecoverInterruptedInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHome = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $PSScriptRoot 'ai-instructions-runtime'
$configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
$catalogPath = Join-Path $runtimeRoot 'catalog\skills-catalog.json'
$lockPath = Join-Path $runtimeRoot 'catalog\skills-catalog-lock.json'
$bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
$contractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
$launcherReferencePath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-installed.ps1'
$updaterPath = Join-Path $runtimeRoot 'update-ai-instructions.ps1'
$bootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'
$stableLauncherPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$stableUpdaterPath = Join-Path $PSScriptRoot 'update-ai-instructions.ps1'
$stableCleanupPath = Join-Path $PSScriptRoot 'cleanup-ai-instructions-pollution.ps1'
$canonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function Test-TrustedProperty {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-TrustedProperties {
    param([Parameter(Mandatory = $true)][object] $Object,[Parameter(Mandatory = $true)][string[]] $Required,[Parameter(Mandatory = $true)][string] $Context)
    foreach ($name in $Required) {
        if (-not (Test-TrustedProperty -Object $Object -Name $name)) { throw "$Context is missing '$name'." }
    }
    foreach ($name in @($Object.PSObject.Properties.Name)) {
        if ($name -cnotin $Required) { throw "$Context contains unsupported property '$name'." }
    }
}

function Assert-TrustedStringArray {
    param([Parameter(Mandatory = $true)][object] $Value,[Parameter(Mandatory = $true)][string] $Context,[switch] $StableId)
    if ($Value -isnot [System.Array]) { throw "$Context must be an array." }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) { throw "$Context must contain strings." }
        if ($StableId -and [string]$item -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') { throw "$Context must contain lowercase stable IDs." }
        if (-not $seen.Add([string]$item)) { throw "$Context contains duplicate '$item'." }
    }
}

function Get-TrustedFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-TrustedRuntimeInventory {
    param([Parameter(Mandatory = $true)][string] $Root)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $rootItem = Get-Item -Force -LiteralPath $rootPath
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Installed AI instructions runtime root must be a non-reparse directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Sort-Object FullName)
    foreach ($item in $items) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed AI instructions runtime inventory crosses a reparse point: $($item.FullName)"
        }
    }
    return @(
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
            $relativePath = $file.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            if ($relativePath -ceq 'runtime-bundle.json') { continue }
            if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.StartsWith('/') -or $relativePath.Contains('\') -or $relativePath -match '(^|/)\.\.(/|$)') {
                throw "Unsafe installed runtime inventory path: $relativePath"
            }
            [pscustomobject][ordered]@{ path=$relativePath; sha256=(Get-TrustedFileSha256 -Path $file.FullName) }
        }
    )
}

function Get-TrustedInventorySha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Inventory)
    $lines = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($Inventory | Sort-Object path)) {
        Assert-TrustedProperties -Object $entry -Required @('path','sha256') -Context 'Runtime bundle inventory entry'
        if ($entry.path -isnot [string] -or [string]$entry.path -eq '' -or [string]$entry.path -match '(^|/)\.\.(/|$)' -or
            [string]$entry.path -match '^/' -or [string]$entry.path -match '\\' -or [string]$entry.sha256 -isnot [string] -or
            [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Runtime bundle inventory contains an unsafe path or invalid hash.'
        }
        if (-not $seen.Add([string]$entry.path)) { throw "Runtime bundle inventory contains duplicate path '$($entry.path)'." }
        $lines.Add("$($entry.path)`t$($entry.sha256)`n")
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($lines -join ''))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-InstalledRuntime {
    param([switch] $AllowPinMismatch)

    foreach ($requiredPath in @($configurationPath,$catalogPath,$lockPath,$bundlePath,$contractPath,$launcherReferencePath,$updaterPath,$bootstrapPath,$stableUpdaterPath,$stableCleanupPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Installed AI instruction runtime is incomplete: $requiredPath" }
    }
    $configurationItem = Get-Item -Force -LiteralPath $configurationPath
    if ($configurationItem.PSIsContainer -or ($configurationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Installed AI instruction configuration must be a non-reparse file.'
    }
    try {
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
    }
    catch { throw "Installed AI instruction runtime identity is invalid: $($_.Exception.Message)" }

    Assert-TrustedProperties -Object $configuration -Required @('schemaVersion','excludedRepositoryUrls','excludedRepositoryPaths','catalog','updates') -Context 'AI instruction sync configuration'
    if (($configuration.schemaVersion -isnot [int] -and $configuration.schemaVersion -isnot [long]) -or $configuration.schemaVersion -ne 4) { throw 'AI instruction sync configuration must use integer schemaVersion 4.' }
    Assert-TrustedStringArray -Value $configuration.excludedRepositoryUrls -Context 'AI instruction excludedRepositoryUrls'
    Assert-TrustedStringArray -Value $configuration.excludedRepositoryPaths -Context 'AI instruction excludedRepositoryPaths'
    $normalizedExcludedUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($url in @($configuration.excludedRepositoryUrls)) {
        if (-not $normalizedExcludedUrls.Add(([string]$url).Trim())) { throw 'AI instruction excludedRepositoryUrls contains duplicates.' }
    }
    $normalizedExcludedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($configuration.excludedRepositoryPaths)) {
        $normalizedPath = ([string]$path).Trim().Replace('\','/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [System.IO.Path]::IsPathRooted([string]$path) -or $normalizedPath -match '^[A-Za-z]:' -or
            @($normalizedPath.Split('/') | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.','..') }).Count -gt 0 -or
            -not $normalizedExcludedPaths.Add($normalizedPath)) {
            throw 'AI instruction excludedRepositoryPaths contains an unsafe or duplicate path.'
        }
    }
    Assert-TrustedProperties -Object $configuration.catalog -Required @('repository','ref','profiles','includeSkills','excludeSkills') -Context 'AI instruction sync configuration catalog'
    if ($configuration.catalog.repository -isnot [string] -or [string]$configuration.catalog.repository -cne $canonicalRepository -or
        $configuration.catalog.ref -isnot [string] -or [string]$configuration.catalog.ref -cnotmatch '^[0-9a-f]{40}$') {
        throw 'AI instruction sync configuration canonical identity is invalid.'
    }
    foreach ($name in @('profiles','includeSkills','excludeSkills')) { Assert-TrustedStringArray -Value $configuration.catalog.$name -Context "AI instruction catalog $name" -StableId }
    foreach ($skillId in @($configuration.catalog.includeSkills)) {
        if (@($configuration.catalog.excludeSkills) -ccontains [string]$skillId) { throw "AI instruction configuration includes and excludes Skill '$skillId'." }
    }
    Assert-TrustedProperties -Object $configuration.updates -Required @('mode','channel','ref','minimumCheckIntervalMinutes') -Context 'AI instruction sync configuration updates'
    if ($configuration.updates.mode -isnot [string] -or [string]$configuration.updates.mode -cnotin @('notify-only','auto-install-approved') -or
        $configuration.updates.channel -isnot [string] -or [string]$configuration.updates.channel -cnotin @('protected-branch','github-release') -or
        $configuration.updates.ref -isnot [string] -or
        (([string]$configuration.updates.channel -ceq 'protected-branch' -and [string]$configuration.updates.ref -cne 'main') -or
         ([string]$configuration.updates.channel -ceq 'github-release' -and [string]$configuration.updates.ref -cne 'latest')) -or
        (($configuration.updates.minimumCheckIntervalMinutes -isnot [int] -and $configuration.updates.minimumCheckIntervalMinutes -isnot [long]) -or
         [long]$configuration.updates.minimumCheckIntervalMinutes -lt 1 -or
         [long]$configuration.updates.minimumCheckIntervalMinutes -gt [int]::MaxValue)) {
        throw 'AI instruction sync configuration update policy is invalid.'
    }

    Assert-TrustedProperties -Object $bundle -Required @('schemaVersion','repository','commit','acquisition','archiveSha256','inventorySha256','inventory') -Context 'Runtime bundle'
    if (($bundle.schemaVersion -isnot [int] -and $bundle.schemaVersion -isnot [long]) -or $bundle.schemaVersion -ne 2 -or
        $bundle.repository -isnot [string] -or [string]$bundle.repository -cne $canonicalRepository -or
        $bundle.commit -isnot [string] -or [string]$bundle.commit -cnotmatch '^[0-9a-f]{40}$' -or
        $bundle.acquisition -isnot [string] -or [string]$bundle.acquisition -cnotin @('git-checkout','github-codeload') -or
        $bundle.inventorySha256 -isnot [string] -or [string]$bundle.inventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $bundle.inventory -isnot [System.Array]) {
        throw 'Installed AI instruction runtime bundle identity is invalid.'
    }
    $pinMismatch = [string]$bundle.commit -cne [string]$configuration.catalog.ref
    if (($null -ne $bundle.archiveSha256 -and ($bundle.archiveSha256 -isnot [string] -or [string]$bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$')) -or
        ([string]$bundle.acquisition -ceq 'github-codeload' -and [string]$bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Installed AI instruction runtime bundle archive identity is invalid.'
    }
    $declaredInventory = @($bundle.inventory | Sort-Object path)
    $declaredDigest = Get-TrustedInventorySha256 -Inventory $declaredInventory
    $actualInventory = @(Get-TrustedRuntimeInventory -Root $runtimeRoot | Sort-Object path)
    $actualDigest = Get-TrustedInventorySha256 -Inventory $actualInventory
    if ($declaredDigest -cne [string]$bundle.inventorySha256 -or $actualDigest -cne [string]$bundle.inventorySha256 -or $declaredInventory.Count -ne $actualInventory.Count) {
        throw 'Installed AI instruction runtime inventory does not match the verified bundle.'
    }
    for ($index=0; $index -lt $declaredInventory.Count; $index++) {
        if ([string]$declaredInventory[$index].path -cne [string]$actualInventory[$index].path -or [string]$declaredInventory[$index].sha256 -cne [string]$actualInventory[$index].sha256) {
            throw "Installed AI instruction runtime inventory mismatch at '$($declaredInventory[$index].path)'."
        }
    }
    if ((Get-TrustedFileSha256 -Path $stableLauncherPath) -cne
        (Get-TrustedFileSha256 -Path $launcherReferencePath)) {
        throw 'Installed AI instructions stable launcher does not match the active immutable runtime.'
    }
    if ((Get-TrustedFileSha256 -Path $stableUpdaterPath) -cne
        (Get-TrustedFileSha256 -Path $updaterPath)) {
        throw 'Installed AI instructions stable updater does not match the active immutable runtime.'
    }
    if ((Get-TrustedFileSha256 -Path $stableCleanupPath) -cne
        (Get-TrustedFileSha256 -Path (Join-Path $runtimeRoot 'cleanup-ai-instructions-pollution.ps1'))) {
        throw 'Installed AI instructions stable cleanup command does not match the active immutable runtime.'
    }
    if ($pinMismatch -and -not $AllowPinMismatch) {
        throw 'Installed AI instruction runtime bundle does not match the configured immutable Catalog bundle pin.'
    }
    return [pscustomobject][ordered]@{
        Configuration = $configuration
        Bundle = $bundle
        PinMismatch = $pinMismatch
    }
}

function Repair-InterruptedRuntimePin {
    param([Parameter(Mandatory = $true)][object] $State)

    if (-not [bool]$State.PinMismatch) { return $false }
    $configurationDirectory = Split-Path -Parent $configurationPath
    $configurationName = Split-Path -Leaf $configurationPath
    $recoveryId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $configurationDirectory ('.' + $configurationName + '.recovery-' + $recoveryId)
    $backupPath = Join-Path $configurationDirectory ('.' + $configurationName + '.backup-' + $recoveryId)
    $failedPath = Join-Path $configurationDirectory ('.' + $configurationName + '.failed-' + $recoveryId)
    try {
        $State.Configuration.catalog.ref = [string]$State.Bundle.commit
        $json = ($State.Configuration | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"
        [System.IO.File]::WriteAllText($temporaryPath,$json,(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Replace($temporaryPath,$configurationPath,$backupPath)
        try { Assert-InstalledRuntime | Out-Null }
        catch {
            $validationError = $_
            try { [System.IO.File]::Replace($backupPath,$configurationPath,$failedPath) }
            catch { throw "Interrupted-install recovery validation failed and configuration rollback also failed. Validation: $($validationError.Exception.Message) Rollback: $($_.Exception.Message)" }
            throw $validationError
        }
    }
    finally {
        foreach ($cleanupPath in @($temporaryPath,$backupPath,$failedPath)) {
            if (Test-Path -LiteralPath $cleanupPath) { Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue }
        }
    }
    return $true
}

function Open-InstalledRuntimeReadLock {
    $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
    if (-not (Test-Path -LiteralPath $installLockPath -PathType Leaf)) {
        throw 'AI instructions install lock is missing from the installed runtime.'
    }
    $installLockItem = Get-Item -Force -LiteralPath $installLockPath
    if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'AI instructions install lock must be a non-reparse file.'
    }
    try {
        return [System.IO.File]::Open(
            $installLockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
    }
    catch [System.IO.IOException] {
        throw 'AI instructions runtime is being installed; bootstrap stopped before reading a mixed runtime.'
    }
}

if ($RecoverInterruptedInstall) {
    $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
    if (Test-Path -LiteralPath $installLockPath) {
        $installLockItem = Get-Item -Force -LiteralPath $installLockPath
        if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'AI instructions install lock must be a non-reparse file.'
        }
    }
    $installLockStream = $null
    try {
        try {
            $installLockStream = [System.IO.File]::Open(
                $installLockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            throw 'Interrupted-install recovery refused to run while another AI instructions installer is active.'
        }
        $recoveryState = Assert-InstalledRuntime -AllowPinMismatch
        if (Repair-InterruptedRuntimePin -State $recoveryState) {
            Write-Output "Recovered interrupted AI instructions installation by aligning the verified configuration pin to runtime commit $($recoveryState.Bundle.commit)."
        }
        else { Write-Output 'AI instructions runtime pin is already consistent; no interrupted-install repair was required.' }
    }
    finally { if ($null -ne $installLockStream) { $installLockStream.Dispose() } }
    return
}

$runtimeReadLock = Open-InstalledRuntimeReadLock
try { Assert-InstalledRuntime | Out-Null }
finally { $runtimeReadLock.Dispose() }
if ($ValidateOnly) { return }
if (-not $SkipUpdateCheck) {
    $engineName = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $enginePath = Join-Path $PSHOME $engineName
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { $enginePath = $engineName }
    $updateOutput = & $enginePath -NoProfile -ExecutionPolicy Bypass -File $stableUpdaterPath -CodexHome $codexHome 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AI instructions update check failed: $($updateOutput -join [Environment]::NewLine)" }
    foreach ($line in @($updateOutput)) { Write-Output $line }
}

$runtimeReadLock = Open-InstalledRuntimeReadLock
try {
    Assert-InstalledRuntime | Out-Null
    $arguments = @{
        CatalogPath = $catalogPath
        LockPath = $lockPath
        ConfigurationPath = $configurationPath
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) { $arguments.TargetRoot = $TargetRoot }
    & $bootstrapPath @arguments
}
finally { $runtimeReadLock.Dispose() }
