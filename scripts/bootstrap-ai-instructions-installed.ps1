[CmdletBinding()]
param(
    [string] $TargetRoot,
    [string] $UserHome = [Environment]::GetFolderPath('UserProfile'),
    [switch] $WhatIf,
    [switch] $SkipUpdateCheck,
    [switch] $ValidateOnly,
    [switch] $RecoverInterruptedInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-InstalledAiInstructionsFailureDisposition {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][System.Exception] $Exception,
        [ValidateSet('operational','integrity')][string] $FallbackClassification = 'operational'
    )

    if ($Message -match '\[classification=([^;\]]+);[^\]]*retryable=(true|false)\]') {
        return [pscustomobject]@{
            classification = [string]$Matches[1]
            retryable = [bool]([string]$Matches[2] -ceq 'true')
        }
    }
    $currentException = $Exception
    while ($null -ne $currentException) {
        if ($currentException -is [System.UnauthorizedAccessException] -or
            $currentException -is [System.Security.SecurityException]) {
            return [pscustomobject]@{ classification='sandbox'; retryable=$true }
        }
        $currentException = $currentException.InnerException
    }
    $classification = if ($Message -match '(?i)access(?: to the path.*?)? is denied|permission denied|unauthorizedaccess|operation not permitted') { 'sandbox' }
        elseif ($Message -match '(?i)incompatible|capability evidence') { 'compatibility' }
        elseif ($Message -match '(?i)hash|sha-?256|inventory|bundle|archive|tamper|drift|mismatch|immutable pin') { 'integrity' }
        elseif ($Message -match '(?i)configuration|schemaVersion|unknown (?:profile|Skill)|update policy|unsupported property') { 'configuration' }
        else { $FallbackClassification }
    return [pscustomobject]@{ classification=$classification; retryable=[bool]($classification -ceq 'sandbox') }
}

trap {
    $message = [string]$_.Exception.Message
    if ($message -match 'AI instructions bootstrap stopped \[classification=') { throw $_.Exception }
    $disposition = Get-InstalledAiInstructionsFailureDisposition -Message $message -Exception $_.Exception
    $retryable = ([string]$disposition.retryable).ToLowerInvariant()
    $remediation = switch ([string]$disposition.classification) {
        'sandbox' { 'Request sandbox approval and retry this bootstrap once; do not retry it again in the same task.' }
        'concurrency' { 'Wait for the active installer to finish, then start a later bootstrap run; do not loop this bootstrap.' }
        'compatibility' { 'Keep the verified runtime; repair the central selection or Catalog without fabricating capability evidence or changing the consumer repository.' }
        'configuration' { 'Keep the verified runtime; normalize or repair the personal configuration through the central installer before a later run.' }
        'integrity' { 'Keep fail-closed state; recover or reinstall the verified AI-Instructions runtime before a later run.' }
        default { 'Inspect the reported operation and use a separate operator-approved recovery; do not loop this bootstrap.' }
    }
    throw [System.InvalidOperationException]::new(
        "$message`nAI instructions bootstrap disposition [classification=$($disposition.classification); retryable=$retryable]. Remediation: $remediation",
        $_.Exception
    )
}

$codexHome = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $PSScriptRoot 'ai-instructions-runtime'
$configurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
$catalogPath = Join-Path $runtimeRoot 'catalog\skills-catalog.json'
$lockPath = Join-Path $runtimeRoot 'catalog\skills-catalog-lock.json'
$bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
$contractPath = Join-Path $runtimeRoot 'ai-instructions-runtime-contract.psm1'
$launcherReferencePath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-installed.ps1'
$updaterPath = Join-Path $runtimeRoot 'update-ai-instructions.ps1'
$environmentUpdaterPath = Join-Path $runtimeRoot 'update-agent-environment.ps1'
$bootstrapPath = Join-Path $runtimeRoot 'bootstrap-ai-instructions-multisource.ps1'
$platformRuntimeManifestPath = Join-Path $runtimeRoot 'platform-runtime.psd1'
$installTransactionModulePath = Join-Path $runtimeRoot 'ai-instructions-install-transaction.psm1'
$stableLauncherPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$stableUpdaterPath = Join-Path $PSScriptRoot 'update-ai-instructions.ps1'
$stableEnvironmentUpdaterPath = Join-Path $PSScriptRoot 'update-agent-environment.ps1'
$stableCleanupPath = Join-Path $PSScriptRoot 'cleanup-ai-instructions-pollution.ps1'
$canonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function Assert-InstalledMutationRuntimeBaseline {
    if ($PSVersionTable.PSEdition -cne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7 -or [Environment]::Version.Major -lt 8) {
        throw [System.InvalidOperationException]::new(
            "Interrupted-install recovery requires pwsh 7 on .NET 8 or newer; rerun this command with pwsh 7.`nAI instructions bootstrap stopped [classification=compatibility; retryable=false].`n[ai-instructions-refusal-code=runtime-baseline-unavailable]"
        )
    }
}

function Get-LauncherInstallTransactionResidueKind {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $EntryKind,
        [AllowNull()][object] $JournalEntryKind,
        [AllowNull()][object] $PreviousJournalEntryKind
    )
    if ($Name -cnotmatch '^[0-9a-f]{32}$' -or $EntryKind -cne 'directory') { return 'invalid-name' }
    if ($null -eq $JournalEntryKind -and $null -eq $PreviousJournalEntryKind) { return 'orphan-without-journal' }
    return 'journal-present'
}

function Get-LauncherEntryKind {
    param([Parameter(Mandatory = $true)][string] $LiteralPath)
    $parentPath = Split-Path -Parent $LiteralPath
    $leaf = Split-Path -Leaf $LiteralPath
    $item = @(Get-ChildItem -Force -LiteralPath $parentPath | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1)
    if ($item.Count -eq 0) { return $null }
    $item = $item[0]
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return 'reparse' }
    if ($item.PSIsContainer) { return 'directory' }
    return 'file'
}

function Get-LauncherInterruptedInstallResidue {
    $residue = New-Object System.Collections.Generic.List[string]
    $transactionRoot = Join-Path $codexHome '.ai-instructions-txn'
    $transactionRootKind = Get-LauncherEntryKind -LiteralPath $transactionRoot
    if ($null -ne $transactionRootKind) {
        $rootKind = $transactionRootKind
        if ($rootKind -cne 'directory') { $residue.Add("$transactionRoot [$rootKind]") }
        else {
            foreach ($entry in @(Get-ChildItem -Force -LiteralPath $transactionRoot)) {
                $entryKind = Get-LauncherEntryKind -LiteralPath $entry.FullName
                $journalKind = if ($entryKind -ceq 'directory') { Get-LauncherEntryKind -LiteralPath (Join-Path $entry.FullName 'journal.json') } else { $null }
                $previousKind = if ($entryKind -ceq 'directory') { Get-LauncherEntryKind -LiteralPath (Join-Path $entry.FullName 'journal.prev') } else { $null }
                $classification = Get-LauncherInstallTransactionResidueKind -Name $entry.Name -EntryKind $entryKind -JournalEntryKind $journalKind -PreviousJournalEntryKind $previousKind
                $residue.Add("$($entry.FullName) [$classification; entry=$entryKind; journal=$journalKind; previous=$previousKind]")
            }
        }
    }
    foreach ($entry in @(Get-ChildItem -Force -LiteralPath $codexHome | Where-Object { $_.Name -like '.ai-instructions-install-*' -or $_.Name -like '.ai-instructions-backup-*' })) {
        $residue.Add("$($entry.FullName) [legacy]")
    }
    return $residue.ToArray()
}

function Assert-NoLauncherInterruptedInstallResidue {
    $residue = @(Get-LauncherInterruptedInstallResidue)
    if ($residue.Count -eq 0) { return }
    throw [System.InvalidOperationException]::new(
        "Interrupted AI instructions installation residue was found: $($residue -join '; '). Rerun the installer with pwsh 7 to complete recovery.`nAI instructions bootstrap stopped [classification=integrity; retryable=false].`n[ai-instructions-refusal-code=interrupted-install]"
    )
}

function Assert-LauncherRecoveryCapabilities {
    param([Parameter(Mandatory = $true)] $Receipt)
    $required = @('directory-lease','file-lease','file-identity','lock','publication','owned-file-removal','permissions')
    $missing = @($required | Where-Object {
        $name = $_
        @($Receipt.capabilities | Where-Object { [string]$_.name -ceq $name -and [string]$_.status -ceq 'available' }).Count -ne 1
    })
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            ('Required recovery platform capabilities are unavailable: ' + ($missing -join ', ') + '. [ai-instructions-refusal-code=capability-unavailable]')
        )
    }
}

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
    foreach ($entry in @($Inventory)) {
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

    foreach ($requiredPath in @($configurationPath,$catalogPath,$lockPath,$bundlePath,$contractPath,$launcherReferencePath,$updaterPath,$environmentUpdaterPath,$bootstrapPath,$stableUpdaterPath,$stableEnvironmentUpdaterPath,$stableCleanupPath)) {
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

    if (($configuration.schemaVersion -is [int] -or $configuration.schemaVersion -is [long]) -and [int64]$configuration.schemaVersion -eq 5) {
        throw 'AI Instructions sync configuration schema version 5 requires a projection-aware installer.'
    }
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

    if (($bundle.schemaVersion -is [int] -or $bundle.schemaVersion -is [long]) -and [int64]$bundle.schemaVersion -eq 3) {
        throw 'Runtime bundle schema version 3 requires a projection-aware installer.'
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
    $declaredInventory = @($bundle.inventory)
    $declaredDigest = Get-TrustedInventorySha256 -Inventory $declaredInventory
    $actualInventoryUnordered = @(Get-TrustedRuntimeInventory -Root $runtimeRoot)
    $actualByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($actualEntry in $actualInventoryUnordered) {
        if ($actualByPath.ContainsKey([string]$actualEntry.path)) { throw "Installed AI instruction runtime inventory contains duplicate path '$($actualEntry.path)'." }
        $actualByPath.Add([string]$actualEntry.path,$actualEntry)
    }
    $actualInventory = @(
        foreach ($declaredEntry in $declaredInventory) {
            if (-not $actualByPath.ContainsKey([string]$declaredEntry.path)) { throw "Installed AI instruction runtime inventory is missing '$($declaredEntry.path)'." }
            $actualByPath[[string]$declaredEntry.path]
        }
    )
    $actualDigest = Get-TrustedInventorySha256 -Inventory $actualInventory
    if ($declaredDigest -cne [string]$bundle.inventorySha256 -or $actualDigest -cne [string]$bundle.inventorySha256 -or $declaredInventory.Count -ne $actualInventoryUnordered.Count) {
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
    if ((Get-TrustedFileSha256 -Path $stableEnvironmentUpdaterPath) -cne
        (Get-TrustedFileSha256 -Path $environmentUpdaterPath)) {
        throw 'Installed AI instructions stable Agent environment updater does not match the active immutable runtime.'
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

function Assert-VerifiedInstalledRuntime {
    param([switch] $AllowPinMismatch)

    try { return Assert-InstalledRuntime -AllowPinMismatch:$AllowPinMismatch }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'AI instructions bootstrap stopped \[classification=') { throw $_.Exception }
        $disposition = Get-InstalledAiInstructionsFailureDisposition `
            -Message $message `
            -Exception $_.Exception `
            -FallbackClassification 'integrity'
        $retryable = ([string]$disposition.retryable).ToLowerInvariant()
        throw [System.InvalidOperationException]::new(
            "$message`nAI instructions bootstrap stopped [classification=$($disposition.classification); retryable=$retryable].",
            $_.Exception
        )
    }
}

function Repair-InterruptedRuntimePin {
    param(
        [Parameter(Mandatory = $true)][object] $State,
        [Parameter(Mandatory = $true)] $RootLease,
        [Parameter(Mandatory = $true)] $CapabilityReceipt
    )

    if (-not [bool]$State.PinMismatch) { return $false }
    $transactionRootLease = $null
    $transactionLease = $null
    $transactionId = [Guid]::NewGuid().ToString('N')
    $transactionRootPath = Join-Path $codexHome '.ai-instructions-txn'
    $transactionPath = Join-Path $transactionRootPath $transactionId
    $journalDurable = $false
    $currentJournal = $null
    $journalStoreStates = [ordered]@{
        'journal.json'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        'journal.prev'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        'journal.stage'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
    }
    try {
        $transactionRootLease = Open-PlatformDirectory -Root $codexHome -RelativePath '.ai-instructions-txn' -CreatePrivate
        $transactionLease = Open-PlatformDirectory -Root $codexHome -RelativePath ('.ai-instructions-txn/' + $transactionId) -CreatePrivate
        $State.Configuration.catalog.ref = [string]$State.Bundle.commit
        $json = ($State.Configuration | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"
        $desiredBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        $stage = New-AiInstructionsInstallStageFile -TransactionLease $transactionLease -Leaf 'op-01-sync.stage' -Bytes $desiredBytes -PlatformOs ([string]$CapabilityReceipt.os)
        $captured = Get-AiInstructionsInstallFileState -ParentLease $RootLease -Leaf 'ai-instructions-sync.json' -LiteralPath $configurationPath -PlatformOs ([string]$CapabilityReceipt.os) -IncludePermissions
        $original = [pscustomobject][ordered]@{exists=$true;sha256=$captured.sha256;length=$captured.length;identity=$captured.identity}
        $operation = [pscustomobject][ordered]@{
            sequence=1;kind='write-file';method='stage-rename';targetRelativePath='ai-instructions-sync.json'
            stageLeaf='op-01-sync.stage';backupLeaf='op-01-sync.backup';quarantineLeaf=$null
            original=$original;backupIdentity=$captured.identity;applied=$stage;permissions=$captured.permissions;state='pending'
        }
        $bundleSha256 = Get-AiInstructionsFileSha256 -Path $bundlePath
        $processStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $currentJournal = New-AiInstructionsInstallJournalV1 -TransactionId $transactionId -OwnerComponent launcher-recovery `
            -OwnerProcessId $PID -OwnerProcessStartIdentity $processStart -PlatformOs ([string]$CapabilityReceipt.os) `
            -PlatformArchitecture ([string]$CapabilityReceipt.architecture) `
            -LockPrimitive $(if ([string]$CapabilityReceipt.os -ceq 'windows') { 'windows-fileshare' } else { 'flock' }) `
            -LockLeaf 'ai-instructions-install.lock' -PreviousBundleSha256 $bundleSha256 -CandidateBundleSha256 $bundleSha256 `
            -Phase prepared -Operations @($operation)
        $currentJournal = Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $currentJournal -PlatformOs ([string]$CapabilityReceipt.os) -JournalStoreStates $journalStoreStates
        $journalDurable = $true
        $nextJournal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($currentJournal | ConvertTo-Json -Depth 30) -ExpectedTransactionId $transactionId
        $nextJournal.phase = 'applying'
        $currentJournal = Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $nextJournal -PreviousJournal $currentJournal -PlatformOs ([string]$CapabilityReceipt.os) -JournalStoreStates $journalStoreStates
        Invoke-AiInstructionsInstallOperation -Operation $currentJournal.operations[0] -ParentLease $RootLease -TransactionLease $transactionLease | Out-Null
        $nextJournal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($currentJournal | ConvertTo-Json -Depth 30) -ExpectedTransactionId $transactionId
        $nextJournal.operations[0].state = 'applied'
        $currentJournal = Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $nextJournal -PreviousJournal $currentJournal -PlatformOs ([string]$CapabilityReceipt.os) -JournalStoreStates $journalStoreStates
        Assert-VerifiedInstalledRuntime | Out-Null
        $nextJournal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($currentJournal | ConvertTo-Json -Depth 30) -ExpectedTransactionId $transactionId
        $nextJournal.phase = 'applied'
        $currentJournal = Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $nextJournal -PreviousJournal $currentJournal -PlatformOs ([string]$CapabilityReceipt.os) -JournalStoreStates $journalStoreStates
        $observations = Get-AiInstructionsInstallRecoveryObservations -Journal $currentJournal -CodexHome $codexHome -TransactionLease $transactionLease -TransactionPath $transactionPath
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $currentJournal -Observations $observations
        $plan = Get-AiInstructionsInstallRecoveryPlan -Journal $currentJournal -Decision $decision
        if ([string]$plan.action -cne 'commit') { throw "Runtime pin repair did not produce a commit recovery plan: $($decision.action)" }
        Invoke-AiInstructionsInstallRecoveryPlan -Journal $currentJournal -Plan $plan -CodexHome $codexHome -TransactionRootLease $transactionRootLease -TransactionLease $transactionLease -TransactionPath $transactionPath -JournalStoreStates $journalStoreStates | Out-Null
        $transactionLease = $null
        return $true
    }
    catch {
        $repairError = $_
        if ($journalDurable -and $null -ne $transactionLease) {
            try {
                $observations = Get-AiInstructionsInstallRecoveryObservations -Journal $currentJournal -CodexHome $codexHome -TransactionLease $transactionLease -TransactionPath $transactionPath
                $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $currentJournal -Observations $observations
                $plan = Get-AiInstructionsInstallRecoveryPlan -Journal $currentJournal -Decision $decision
                Invoke-AiInstructionsInstallRecoveryPlan -Journal $currentJournal -Plan $plan -CodexHome $codexHome -TransactionRootLease $transactionRootLease -TransactionLease $transactionLease -TransactionPath $transactionPath -JournalStoreStates $journalStoreStates | Out-Null
                $transactionLease = $null
            }
            catch { throw "Runtime pin repair validation failed and journal rollback retained evidence at '$transactionPath'. Validation: $($repairError.Exception.Message) Rollback: $($_.Exception.Message)" }
        }
        throw $repairError
    }
    finally {
        if ($null -ne $transactionLease) { $transactionLease.Dispose() }
        if ($null -ne $transactionRootLease) { $transactionRootLease.Dispose() }
    }
}

function Open-InstalledRuntimeReadLock {
    param([switch] $ForRecovery)
    $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
    if (-not (Test-Path -LiteralPath $installLockPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "AI instructions install lock is missing from the installed runtime.`nAI instructions bootstrap stopped [classification=integrity; retryable=false]."
        )
    }
    $installLockItem = Get-Item -Force -LiteralPath $installLockPath
    if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw [System.InvalidOperationException]::new(
            "AI instructions install lock must be a non-reparse file.`nAI instructions bootstrap stopped [classification=integrity; retryable=false]."
        )
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
        $message = if ($ForRecovery) {
            'Interrupted-install recovery refused to run while another AI instructions installer is active.'
        }
        else { 'AI instructions runtime is being installed; bootstrap stopped before reading a mixed runtime.' }
        throw [System.InvalidOperationException]::new(
            "$message`nAI instructions bootstrap stopped [classification=concurrency; retryable=false].",
            $_.Exception
        )
    }
}

if ($RecoverInterruptedInstall) {
    Assert-InstalledMutationRuntimeBaseline
    Assert-NoLauncherInterruptedInstallResidue
    $trustReadLock = Open-InstalledRuntimeReadLock -ForRecovery
    try {
        $recoveryState = Assert-VerifiedInstalledRuntime -AllowPinMismatch
        try { Import-Module $platformRuntimeManifestPath -Force -ErrorAction Stop }
        catch {
            throw [System.InvalidOperationException]::new(
                "Verified installed platform runtime could not be loaded: $($_.Exception.Message)`nAI instructions bootstrap stopped [classification=integrity; retryable=false].`n[ai-instructions-refusal-code=closure-invalid]",
                $_.Exception
            )
        }
        try { Assert-PlatformRuntimeInventory -Root $runtimeRoot -ManifestPath $platformRuntimeManifestPath | Out-Null }
        catch {
            throw [System.InvalidOperationException]::new(
                "Installed platform runtime inventory verification failed: $($_.Exception.Message)`nAI instructions bootstrap stopped [classification=integrity; retryable=false].`n[ai-instructions-refusal-code=closure-invalid]",
                $_.Exception
            )
        }
        $capabilityReceipt = Get-PlatformCapabilities -Required @()
        Assert-LauncherRecoveryCapabilities -Receipt $capabilityReceipt
    }
    finally { $trustReadLock.Dispose() }

    $installLockPath = Join-Path $codexHome 'ai-instructions-install.lock'
    if (Test-Path -LiteralPath $installLockPath) {
        $installLockItem = Get-Item -Force -LiteralPath $installLockPath
        if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [System.InvalidOperationException]::new(
                "AI instructions install lock must be a non-reparse file.`nAI instructions bootstrap stopped [classification=integrity; retryable=false]."
            )
        }
    }
    $rootLease = Open-PlatformDirectory -Root $codexHome -RootOnly
    $installLockLease = $null
    try {
        try {
            $installLockLease = Enter-PlatformLock -ParentLease $rootLease -Leaf 'ai-instructions-install.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
        }
        catch {
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -isnot [System.TimeoutException]) { throw }
            throw [System.InvalidOperationException]::new(
                "Interrupted-install recovery refused to run while another AI instructions installer is active.`nAI instructions bootstrap stopped [classification=concurrency; retryable=false].",
                $_.Exception
            )
        }
        Assert-NoLauncherInterruptedInstallResidue
        $recoveryState = Assert-VerifiedInstalledRuntime -AllowPinMismatch
        try { Import-Module $platformRuntimeManifestPath -Force -ErrorAction Stop }
        catch { throw [System.InvalidOperationException]::new("Verified installed platform runtime could not be reloaded under the install lock: $($_.Exception.Message) [ai-instructions-refusal-code=closure-invalid]",$_.Exception) }
        try { Assert-PlatformRuntimeInventory -Root $runtimeRoot -ManifestPath $platformRuntimeManifestPath | Out-Null }
        catch { throw [System.InvalidOperationException]::new("Installed platform runtime inventory verification failed under the install lock: $($_.Exception.Message) [ai-instructions-refusal-code=closure-invalid]",$_.Exception) }
        $capabilityReceipt = Get-PlatformCapabilities -Required @()
        Assert-LauncherRecoveryCapabilities -Receipt $capabilityReceipt
        Import-Module $contractPath -Force -ErrorAction Stop
        Import-Module $installTransactionModulePath -Force -ErrorAction Stop
        if (Repair-InterruptedRuntimePin -State $recoveryState -RootLease $rootLease -CapabilityReceipt $capabilityReceipt) {
            Write-Output "Recovered interrupted AI instructions installation by aligning the verified configuration pin to runtime commit $($recoveryState.Bundle.commit)."
        }
        else { Write-Output 'AI instructions runtime pin is already consistent; no interrupted-install repair was required.' }
    }
    finally {
        if ($null -ne $installLockLease) { $installLockLease.Dispose() }
        $rootLease.Dispose()
    }
    return
}

$runtimeReadLock = Open-InstalledRuntimeReadLock
try {
    Assert-NoLauncherInterruptedInstallResidue
    Assert-VerifiedInstalledRuntime | Out-Null
}
finally { $runtimeReadLock.Dispose() }
if ($ValidateOnly) { return }
if (-not $SkipUpdateCheck -and -not $WhatIf) {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Console]::Error.WriteLine('AI instructions automatic update check was skipped because it requires pwsh 7; read-only fan-out will continue.')
    }
    else {
        $engineName = 'pwsh.exe'
        $enginePath = Join-Path $PSHOME $engineName
        if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { $enginePath = $engineName }
        $updateOutput = & $enginePath -NoProfile -ExecutionPolicy Bypass -File $stableUpdaterPath -CodexHome $codexHome 2>&1
        if ($LASTEXITCODE -ne 0) { throw "AI instructions update check failed: $($updateOutput -join [Environment]::NewLine)" }
        foreach ($line in @($updateOutput)) { Write-Output $line }
    }
}

$runtimeReadLock = Open-InstalledRuntimeReadLock
try {
    Assert-NoLauncherInterruptedInstallResidue
    Assert-VerifiedInstalledRuntime | Out-Null
    $arguments = @{
        CatalogPath = $catalogPath
        LockPath = $lockPath
        ConfigurationPath = $configurationPath
        UserHome = $UserHome
        WhatIf = $WhatIf
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) { $arguments.TargetRoot = $TargetRoot }
    & $bootstrapPath @arguments
}
finally { $runtimeReadLock.Dispose() }
