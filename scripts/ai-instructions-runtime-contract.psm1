Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CanonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function Test-AiInstructionsObjectHasProperty {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-AiInstructionsStringValue {
    param([AllowNull()][object] $Value,[Parameter(Mandatory = $true)][string] $Context,[switch] $AllowNull)

    if ($AllowNull -and $null -eq $Value) { return }
    if ($Value -isnot [string]) { throw "$Context must be a string." }
}

function Get-AiInstructionsFullDirectoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $RejectFileSystemRoot,
        [string] $Context = 'Directory path'
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $isFileSystemRoot = -not [string]::IsNullOrWhiteSpace($rootPath) -and
        $fullPath.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase)
    if ($RejectFileSystemRoot -and $isFileSystemRoot) { throw "$Context must not be a filesystem root: $fullPath" }
    if ($isFileSystemRoot) { return $rootPath }
    return $fullPath.TrimEnd([char[]]@('\','/'))
}

function Assert-AiInstructionsSafeChildDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Parent,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $LeafPrefix
    )

    $parentPath = Get-AiInstructionsFullDirectoryPath -Path $Parent
    $childPath = Get-AiInstructionsFullDirectoryPath -Path $Path
    $childParent = Get-AiInstructionsFullDirectoryPath -Path (Split-Path -Parent $childPath)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $childParent.Equals($parentPath,$comparison)) { throw "Transaction cleanup path must be an immediate child of '$parentPath': $childPath" }
    $leaf = Split-Path -Leaf $childPath
    if (-not $leaf.StartsWith($LeafPrefix,[System.StringComparison]::Ordinal)) { throw "Transaction cleanup path does not use expected prefix '$LeafPrefix': $childPath" }
    if (-not (Test-Path -LiteralPath $childPath -PathType Container)) { throw "Transaction cleanup path is not a directory: $childPath" }
    $item = Get-Item -Force -LiteralPath $childPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Transaction cleanup path must not be a reparse point: $childPath" }
    return $childPath
}

function Assert-AiInstructionsMutationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('File','Directory')][string] $ExpectedType,
        [string] $Context = 'AI instructions mutation path'
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) { return $fullPath }
    $item = Get-Item -Force -LiteralPath $fullPath
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $hasExpectedType = if ($ExpectedType -ceq 'Directory') { $item.PSIsContainer } else { -not $item.PSIsContainer }
    if ($isReparsePoint -or -not $hasExpectedType) {
        throw "$Context '$fullPath' must be a non-reparse $($ExpectedType.ToLowerInvariant())."
    }
    return $fullPath
}

function Get-AiInstructionsStringArray {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string[]] $Names)

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Object -Name $name)) { continue }
        $value = $Object.PSObject.Properties[$name].Value
        if ($value -isnot [System.Array]) { throw "AI instruction sync configuration $name must be an array." }
        foreach ($item in @($value)) {
            if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) {
                throw "AI instruction sync configuration $name must contain only non-empty strings."
            }
            $values.Add(([string]$item).Trim())
        }
    }
    return @($values | Sort-Object -Unique)
}

function Assert-AiInstructionsStableIdArray {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object] $Value,[Parameter(Mandatory = $true)][string] $Context)

    if ($Value -isnot [System.Array]) { throw "$Context must be an array." }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]$item -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "$Context item must be a lowercase stable ID."
        }
        if (-not $seen.Add([string]$item)) { throw "$Context contains duplicate ID '$item'." }
    }
}

function Get-AiInstructionsGitHubRepositoryIdentity {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $value = $Repository.Trim()
    if ($value -match '^(?:https|ssh|git)://(?:[^@/]+@)?github\.com/(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?/?$') {
        return "github.com/$($Matches.Owner)/$($Matches.Repository)".ToLowerInvariant()
    }
    if ($value -match '^(?:[^@/]+@)?github\.com:(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?$') {
        return "github.com/$($Matches.Owner)/$($Matches.Repository)".ToLowerInvariant()
    }
    throw "AI-Instructions repository must be a GitHub repository URL: $Repository"
}

function Assert-AiInstructionsCanonicalRepository {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [string] $CanonicalRepository = $script:CanonicalRepository
    )

    $actual = Get-AiInstructionsGitHubRepositoryIdentity -Repository $Repository
    $expected = Get-AiInstructionsGitHubRepositoryIdentity -Repository $CanonicalRepository
    if ($actual -cne $expected) {
        throw "AI-Instructions runtime accepts only the canonical repository '$CanonicalRepository'; actual: '$Repository'."
    }
}

function Get-AiInstructionsNormalizedExcludedPaths {
    param([AllowEmptyCollection()][string[]] $Paths = @())

    $normalizedPaths = @(
        foreach ($path in @($Paths)) {
            $normalized = ([string]$path).Trim().Replace('\','/').Trim('/')
            if ([string]::IsNullOrWhiteSpace($normalized) -or [System.IO.Path]::IsPathRooted([string]$path) -or $normalized -match '^[A-Za-z]:') {
                throw "AI instruction excludedRepositoryPaths contains an invalid repository-relative path '$path'."
            }
            foreach ($part in @($normalized -split '/')) {
                if ([string]::IsNullOrWhiteSpace($part) -or $part -in @('.','..')) {
                    throw "AI instruction excludedRepositoryPaths contains an invalid repository-relative path '$path'."
                }
            }
            $normalized
        }
    )
    return @($normalizedPaths | Sort-Object -Unique)
}

function ConvertTo-AiInstructionsSyncConfigurationV4 {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $ExistingConfiguration,
        [Parameter(Mandatory = $true)][string] $CatalogRepository,
        [Parameter(Mandatory = $true)][string] $CatalogRef,
        [string[]] $AdditionalExcludedRepositoryUrls = @(),
        [string[]] $AdditionalExcludedRepositoryPaths = @(),
        [string] $CanonicalRepository = $script:CanonicalRepository
    )

    Assert-AiInstructionsCanonicalRepository -Repository $CatalogRepository -CanonicalRepository $CanonicalRepository
    $CatalogRepository = $CanonicalRepository
    if ($CatalogRef -cnotmatch '^[0-9a-f]{40}$') {
        throw 'AI instruction sync configuration catalog.ref must be a full lowercase 40-character commit SHA.'
    }

    $schemaVersion = $null
    if ($null -ne $ExistingConfiguration) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $ExistingConfiguration -Name 'schemaVersion')) {
            throw 'AI instruction sync configuration is missing schemaVersion.'
        }
        if ($ExistingConfiguration.schemaVersion -isnot [int] -and $ExistingConfiguration.schemaVersion -isnot [long]) {
            throw 'AI instruction sync configuration schemaVersion must be an integer.'
        }
        $schemaVersion = [int]$ExistingConfiguration.schemaVersion
        if ($schemaVersion -notin @(1,2,3,4)) {
            throw "Unsupported AI instruction sync configuration schemaVersion '$schemaVersion'."
        }
    }

    $excludedRepositoryUrls = @(
        @(Get-AiInstructionsStringArray -Object $ExistingConfiguration -Names @('excludedRepositoryUrls','excludedRepositories')) +
        @($AdditionalExcludedRepositoryUrls | ForEach-Object { ([string]$_).Trim() }) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )
    $excludedRepositoryPaths = Get-AiInstructionsNormalizedExcludedPaths -Paths @(
        @(Get-AiInstructionsStringArray -Object $ExistingConfiguration -Names @('excludedRepositoryPaths','excludedPaths')) +
        @($AdditionalExcludedRepositoryPaths)
    )

    $profiles = @('core')
    $includeSkills = @()
    $excludeSkills = @()
    if ($schemaVersion -in @(3,4)) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $ExistingConfiguration -Name 'catalog')) {
            throw "AI instruction sync configuration schemaVersion $schemaVersion is missing catalog."
        }
        $existingCatalog = $ExistingConfiguration.catalog
        foreach ($name in @('repository','ref','profiles','includeSkills','excludeSkills')) {
            if (-not (Test-AiInstructionsObjectHasProperty -Object $existingCatalog -Name $name)) {
                throw "AI instruction sync configuration catalog is missing '$name'."
            }
        }
        Assert-AiInstructionsStringValue -Value $existingCatalog.repository -Context 'AI instruction sync configuration catalog.repository'
        Assert-AiInstructionsStringValue -Value $existingCatalog.ref -Context 'AI instruction sync configuration catalog.ref'
        Assert-AiInstructionsCanonicalRepository -Repository ([string]$existingCatalog.repository) -CanonicalRepository $CanonicalRepository
        if ([string]$existingCatalog.ref -cnotmatch '^[0-9a-f]{40}$') {
            throw 'AI instruction sync configuration catalog.ref must be a full lowercase 40-character commit SHA.'
        }
        Assert-AiInstructionsStableIdArray -Value $existingCatalog.profiles -Context 'AI instruction sync configuration catalog.profiles'
        Assert-AiInstructionsStableIdArray -Value $existingCatalog.includeSkills -Context 'AI instruction sync configuration catalog.includeSkills'
        Assert-AiInstructionsStableIdArray -Value $existingCatalog.excludeSkills -Context 'AI instruction sync configuration catalog.excludeSkills'
        foreach ($skillId in @($existingCatalog.includeSkills)) {
            if (@($existingCatalog.excludeSkills) -ccontains [string]$skillId) {
                throw "AI instruction sync configuration includes and excludes the same Skill '$skillId'."
            }
        }
        $profiles = @($existingCatalog.profiles)
        $includeSkills = @($existingCatalog.includeSkills)
        $excludeSkills = @($existingCatalog.excludeSkills)
    }

    $updateMode = 'notify-only'
    $updateChannel = 'protected-branch'
    $updateRef = 'main'
    $minimumInterval = 1440
    if ($schemaVersion -eq 4) {
        Assert-AiInstructionsSyncConfigurationV4 -Configuration $ExistingConfiguration -CanonicalRepository $CanonicalRepository -AllowCanonicalRepositoryAlias | Out-Null
        if (-not (Test-AiInstructionsObjectHasProperty -Object $ExistingConfiguration -Name 'updates')) {
            throw 'AI instruction sync configuration schemaVersion 4 is missing updates.'
        }
        $existingUpdates = $ExistingConfiguration.updates
        foreach ($name in @('mode','channel','ref','minimumCheckIntervalMinutes')) {
            if (-not (Test-AiInstructionsObjectHasProperty -Object $existingUpdates -Name $name)) {
                throw "AI instruction sync configuration updates is missing '$name'."
            }
        }
        $updateMode = [string]$existingUpdates.mode
        $updateChannel = [string]$existingUpdates.channel
        $updateRef = [string]$existingUpdates.ref
        $minimumInterval = [int]$existingUpdates.minimumCheckIntervalMinutes
    }

    $configuration = [pscustomobject][ordered]@{
        schemaVersion = 4
        excludedRepositoryUrls = @($excludedRepositoryUrls)
        excludedRepositoryPaths = @($excludedRepositoryPaths)
        catalog = [pscustomobject][ordered]@{
            repository = $CatalogRepository
            ref = $CatalogRef
            profiles = @($profiles)
            includeSkills = @($includeSkills)
            excludeSkills = @($excludeSkills)
        }
        updates = [pscustomobject][ordered]@{
            mode = $updateMode
            channel = $updateChannel
            ref = $updateRef
            minimumCheckIntervalMinutes = $minimumInterval
        }
    }
    Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration -CanonicalRepository $CanonicalRepository | Out-Null
    return $configuration
}

function Assert-AiInstructionsSyncConfigurationV4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Configuration,
        [string] $CanonicalRepository = $script:CanonicalRepository,
        [switch] $AllowCanonicalRepositoryAlias
    )

    if (-not (Test-AiInstructionsObjectHasProperty -Object $Configuration -Name 'schemaVersion') -or
        ($Configuration.schemaVersion -isnot [int] -and $Configuration.schemaVersion -isnot [long]) -or
        $Configuration.schemaVersion -ne 4) {
        throw 'AI instruction sync configuration must use schemaVersion 4.'
    }
    $allowedTopLevel = @('schemaVersion','excludedRepositoryUrls','excludedRepositoryPaths','catalog','updates')
    foreach ($propertyName in @($Configuration.PSObject.Properties.Name)) {
        if ($propertyName -cnotin $allowedTopLevel) { throw "AI instruction sync configuration contains unsupported property '$propertyName'." }
    }
    foreach ($name in @('excludedRepositoryUrls','excludedRepositoryPaths','catalog','updates')) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Configuration -Name $name)) {
            throw "AI instruction sync configuration is missing '$name'."
        }
    }
    $normalizedExcludedUrls = @(Get-AiInstructionsStringArray -Object $Configuration -Names @('excludedRepositoryUrls'))
    if ($normalizedExcludedUrls.Count -ne @($Configuration.excludedRepositoryUrls).Count) { throw 'AI instruction sync configuration excludedRepositoryUrls contains duplicates.' }
    $strictExcludedPaths = @(Get-AiInstructionsStringArray -Object $Configuration -Names @('excludedRepositoryPaths'))
    $normalizedExcludedPaths = @(Get-AiInstructionsNormalizedExcludedPaths -Paths $strictExcludedPaths)
    if ($normalizedExcludedPaths.Count -ne @($Configuration.excludedRepositoryPaths).Count) { throw 'AI instruction sync configuration excludedRepositoryPaths contains duplicates.' }

    $catalog = $Configuration.catalog
    foreach ($propertyName in @($catalog.PSObject.Properties.Name)) {
        if ($propertyName -cnotin @('repository','ref','profiles','includeSkills','excludeSkills')) { throw "AI instruction sync configuration catalog contains unsupported property '$propertyName'." }
    }
    foreach ($name in @('repository','ref','profiles','includeSkills','excludeSkills')) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $catalog -Name $name)) { throw "AI instruction sync configuration catalog is missing '$name'." }
    }
    Assert-AiInstructionsStringValue -Value $catalog.repository -Context 'AI instruction sync configuration catalog.repository'
    Assert-AiInstructionsStringValue -Value $catalog.ref -Context 'AI instruction sync configuration catalog.ref'
    Assert-AiInstructionsCanonicalRepository -Repository ([string]$catalog.repository) -CanonicalRepository $CanonicalRepository
    if (-not $AllowCanonicalRepositoryAlias -and [string]$catalog.repository -cne $CanonicalRepository) { throw "AI instruction sync configuration catalog.repository must use the canonical repository '$CanonicalRepository'." }
    if ([string]$catalog.ref -cnotmatch '^[0-9a-f]{40}$') { throw 'AI instruction sync configuration catalog.ref must be a full lowercase 40-character commit SHA.' }
    Assert-AiInstructionsStableIdArray -Value $catalog.profiles -Context 'AI instruction sync configuration catalog.profiles'
    Assert-AiInstructionsStableIdArray -Value $catalog.includeSkills -Context 'AI instruction sync configuration catalog.includeSkills'
    Assert-AiInstructionsStableIdArray -Value $catalog.excludeSkills -Context 'AI instruction sync configuration catalog.excludeSkills'
    foreach ($skillId in @($catalog.includeSkills)) {
        if (@($catalog.excludeSkills) -ccontains [string]$skillId) { throw "AI instruction sync configuration includes and excludes the same Skill '$skillId'." }
    }

    $updates = $Configuration.updates
    foreach ($propertyName in @($updates.PSObject.Properties.Name)) {
        if ($propertyName -cnotin @('mode','channel','ref','minimumCheckIntervalMinutes')) { throw "AI instruction sync configuration updates contains unsupported property '$propertyName'." }
    }
    foreach ($name in @('mode','channel','ref','minimumCheckIntervalMinutes')) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $updates -Name $name)) { throw "AI instruction sync configuration updates is missing '$name'." }
    }
    Assert-AiInstructionsStringValue -Value $updates.mode -Context 'AI instruction sync configuration updates.mode'
    Assert-AiInstructionsStringValue -Value $updates.channel -Context 'AI instruction sync configuration updates.channel'
    Assert-AiInstructionsStringValue -Value $updates.ref -Context 'AI instruction sync configuration updates.ref'
    if ([string]$updates.mode -cnotin @('notify-only','auto-install-approved')) { throw "Unsupported AI instruction update mode '$($updates.mode)'." }
    if ([string]$updates.channel -cnotin @('protected-branch','github-release')) { throw "Unsupported AI instruction update channel '$($updates.channel)'." }
    if ([string]$updates.ref -cnotin @('main','latest')) { throw "Unsupported AI instruction update ref '$($updates.ref)'." }
    if (([string]$updates.channel -ceq 'protected-branch' -and [string]$updates.ref -cne 'main') -or
        ([string]$updates.channel -ceq 'github-release' -and [string]$updates.ref -cne 'latest')) {
        throw 'AI instruction update channel/ref combination is invalid.'
    }
    if ($updates.minimumCheckIntervalMinutes -isnot [int] -and $updates.minimumCheckIntervalMinutes -isnot [long]) { throw 'AI instruction update minimumCheckIntervalMinutes must be an integer.' }
    if ([long]$updates.minimumCheckIntervalMinutes -lt 1) { throw 'AI instruction update minimumCheckIntervalMinutes must be at least 1.' }
    if ([long]$updates.minimumCheckIntervalMinutes -gt [int]::MaxValue) { throw "AI instruction update minimumCheckIntervalMinutes must be at most $([int]::MaxValue)." }
    return $Configuration
}

function Get-AiInstructionsFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-AiInstructionsRuntimeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $RuntimeRoot)

    $root = Get-AiInstructionsFullDirectoryPath -Path $RuntimeRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "AI instructions runtime root does not exist: $root" }
    Assert-AiInstructionsMutationPath -Path $root -ExpectedType Directory -Context 'AI instructions runtime root' | Out-Null
    $entries = New-Object System.Collections.Generic.List[object]
    $runtimeItems = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)
    foreach ($item in $runtimeItems) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "AI instructions runtime inventory must not cross a reparse point: $($item.FullName)"
        }
    }
    foreach ($file in @($runtimeItems | Where-Object { -not $_.PSIsContainer })) {
        $relativePath = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        if ($relativePath -ceq 'runtime-bundle.json') { continue }
        if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.StartsWith('../') -or $relativePath.Contains('\')) {
            throw "Unsafe runtime inventory path: $relativePath"
        }
        $entries.Add([pscustomobject][ordered]@{ path=$relativePath; sha256=(Get-AiInstructionsFileSha256 -Path $file.FullName) })
    }
    return @($entries.ToArray())
}

function Get-AiInstructionsRuntimeInventorySha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Inventory)

    $lines = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($Inventory | Sort-Object path)) {
        $path = [string]$entry.path
        $hash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($path) -or $path.Contains('\') -or $path.StartsWith('/') -or $path -match '(^|/)\.\.(/|$)') { throw "Unsafe runtime inventory path: $path" }
        if ($hash -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid runtime inventory hash for '$path'." }
        if (-not $seen.Add($path)) { throw "Duplicate runtime inventory path '$path'." }
        $lines.Add("$path`t$hash`n")
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($lines -join ''))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-AiInstructionsRuntimeBundleV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Commit,
        [Parameter(Mandatory = $true)][ValidateSet('git-checkout','github-codeload')][string] $Acquisition,
        [AllowNull()][string] $ArchiveSha256,
        [string] $CanonicalRepository = $script:CanonicalRepository
    )

    Assert-AiInstructionsCanonicalRepository -Repository $Repository -CanonicalRepository $CanonicalRepository
    $Repository = $CanonicalRepository
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Runtime bundle commit must be a full lowercase 40-character commit SHA.' }
    if ($Acquisition -ceq 'github-codeload' -and [string]$ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Runtime bundle archiveSha256 is required for github-codeload acquisition.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ArchiveSha256) -and [string]$ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Runtime bundle archiveSha256 must be null or a lowercase SHA-256 value.'
    }
    $inventory = @(Get-AiInstructionsRuntimeInventory -RuntimeRoot $RuntimeRoot)
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        repository = $Repository
        commit = $Commit
        acquisition = $Acquisition
        archiveSha256 = if ([string]::IsNullOrWhiteSpace($ArchiveSha256)) { $null } else { $ArchiveSha256 }
        inventorySha256 = Get-AiInstructionsRuntimeInventorySha256 -Inventory $inventory
        inventory = $inventory
    }
}

function Assert-AiInstructionsRuntimeBundleV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Bundle,
        [Parameter(Mandatory = $true)][object] $Configuration,
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [string] $CanonicalRepository = $script:CanonicalRepository
    )

    Assert-AiInstructionsSyncConfigurationV4 -Configuration $Configuration -CanonicalRepository $CanonicalRepository | Out-Null
    foreach ($name in @('schemaVersion','repository','commit','acquisition','archiveSha256','inventorySha256','inventory')) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Bundle -Name $name)) { throw "Runtime bundle is missing '$name'." }
    }
    foreach ($propertyName in @($Bundle.PSObject.Properties.Name)) {
        if ($propertyName -cnotin @('schemaVersion','repository','commit','acquisition','archiveSha256','inventorySha256','inventory')) { throw "Runtime bundle contains unsupported property '$propertyName'." }
    }
    if (($Bundle.schemaVersion -isnot [int] -and $Bundle.schemaVersion -isnot [long]) -or $Bundle.schemaVersion -ne 2) { throw 'Runtime bundle must use integer schemaVersion 2.' }
    Assert-AiInstructionsStringValue -Value $Bundle.repository -Context 'Runtime bundle repository'
    Assert-AiInstructionsStringValue -Value $Bundle.commit -Context 'Runtime bundle commit'
    Assert-AiInstructionsStringValue -Value $Bundle.acquisition -Context 'Runtime bundle acquisition'
    Assert-AiInstructionsStringValue -Value $Bundle.archiveSha256 -Context 'Runtime bundle archiveSha256' -AllowNull
    Assert-AiInstructionsStringValue -Value $Bundle.inventorySha256 -Context 'Runtime bundle inventorySha256'
    Assert-AiInstructionsCanonicalRepository -Repository ([string]$Bundle.repository) -CanonicalRepository $CanonicalRepository
    if ([string]$Bundle.repository -cne $CanonicalRepository) { throw "Runtime bundle repository must use the canonical repository '$CanonicalRepository'." }
    if ([string]$Bundle.commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Runtime bundle commit must be a full lowercase 40-character commit SHA.' }
    if ([string]$Bundle.repository -cne [string]$Configuration.catalog.repository -or [string]$Bundle.commit -cne [string]$Configuration.catalog.ref) {
        throw 'Installed AI instruction runtime bundle does not match the configured immutable Catalog bundle pin.'
    }
    if ([string]$Bundle.acquisition -cnotin @('git-checkout','github-codeload')) { throw "Unsupported runtime bundle acquisition '$($Bundle.acquisition)'." }
    if ([string]$Bundle.acquisition -ceq 'github-codeload' -and [string]$Bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Runtime bundle archiveSha256 is required for github-codeload acquisition.'
    }
    if ($null -ne $Bundle.archiveSha256 -and [string]$Bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Runtime bundle archiveSha256 is invalid.'
    }
    if ($Bundle.inventory -isnot [System.Array]) { throw 'Runtime bundle inventory must be an array.' }
    foreach ($entry in @($Bundle.inventory)) {
        if ($null -eq $entry.PSObject.Properties['path'] -or $null -eq $entry.PSObject.Properties['sha256']) { throw 'Runtime bundle inventory entry is missing path or sha256.' }
        foreach ($propertyName in @($entry.PSObject.Properties.Name)) {
            if ($propertyName -cnotin @('path','sha256')) { throw "Runtime bundle inventory entry contains unsupported property '$propertyName'." }
        }
        Assert-AiInstructionsStringValue -Value $entry.path -Context 'Runtime bundle inventory path'
        Assert-AiInstructionsStringValue -Value $entry.sha256 -Context "Runtime bundle inventory hash for '$($entry.path)'"
    }
    $declaredInventory = @($Bundle.inventory | Sort-Object path)
    $declaredDigest = Get-AiInstructionsRuntimeInventorySha256 -Inventory $declaredInventory
    if ($declaredDigest -cne [string]$Bundle.inventorySha256) { throw 'Runtime bundle inventory digest does not match inventorySha256.' }
    $actualInventory = @(Get-AiInstructionsRuntimeInventory -RuntimeRoot $RuntimeRoot | Sort-Object path)
    $actualDigest = Get-AiInstructionsRuntimeInventorySha256 -Inventory $actualInventory
    if ($actualDigest -cne [string]$Bundle.inventorySha256 -or $actualInventory.Count -ne $declaredInventory.Count) {
        throw 'Installed AI instruction runtime inventory does not match the verified bundle.'
    }
    for ($index = 0; $index -lt $declaredInventory.Count; $index++) {
        if ([string]$declaredInventory[$index].path -cne [string]$actualInventory[$index].path -or
            [string]$declaredInventory[$index].sha256 -cne [string]$actualInventory[$index].sha256) {
            throw "Installed AI instruction runtime inventory mismatch at '$($declaredInventory[$index].path)'."
        }
    }
    return $Bundle
}

function ConvertTo-AiInstructionsUtcDateTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -is [datetime]) {
        if (([datetime]$Value).Kind -eq [DateTimeKind]::Unspecified) {
            throw "$Context must include an explicit UTC or numeric offset."
        }
        return ([datetime]$Value).ToUniversalTime()
    }

    $parsedValue = [datetimeoffset]::MinValue
    if ($Value -isnot [string] -or
            [string]$Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$' -or
            -not [datetimeoffset]::TryParse(
                [string]$Value,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsedValue
            )) {
        throw "$Context must be an ISO 8601 date-time."
    }

    return $parsedValue.UtcDateTime
}

function Assert-AiInstructionsUpdateReceiptV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Receipt)

    $allowedProperties = @(
        'schemaVersion','checkedAtUtc','mode','channel','ref','currentCommit',
        'candidateCommit','outcome','archiveSha256','message'
    )
    foreach ($name in $allowedProperties) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Receipt -Name $name)) {
            throw "AI instructions update receipt is missing '$name'."
        }
    }
    foreach ($propertyName in @($Receipt.PSObject.Properties.Name)) {
        if ($propertyName -cnotin $allowedProperties) { throw "AI instructions update receipt contains unsupported property '$propertyName'." }
    }
    if (($Receipt.schemaVersion -isnot [int] -and $Receipt.schemaVersion -isnot [long]) -or $Receipt.schemaVersion -ne 1) { throw 'AI instructions update receipt must use integer schemaVersion 1.' }

    ConvertTo-AiInstructionsUtcDateTime -Value $Receipt.checkedAtUtc -Context 'AI instructions update receipt checkedAtUtc' | Out-Null
    Assert-AiInstructionsStringValue -Value $Receipt.mode -Context 'AI instructions update receipt mode'
    Assert-AiInstructionsStringValue -Value $Receipt.channel -Context 'AI instructions update receipt channel'
    Assert-AiInstructionsStringValue -Value $Receipt.ref -Context 'AI instructions update receipt ref'
    Assert-AiInstructionsStringValue -Value $Receipt.currentCommit -Context 'AI instructions update receipt currentCommit'
    Assert-AiInstructionsStringValue -Value $Receipt.candidateCommit -Context 'AI instructions update receipt candidateCommit' -AllowNull
    Assert-AiInstructionsStringValue -Value $Receipt.outcome -Context 'AI instructions update receipt outcome'
    Assert-AiInstructionsStringValue -Value $Receipt.archiveSha256 -Context 'AI instructions update receipt archiveSha256' -AllowNull
    if ([string]$Receipt.mode -cnotin @('notify-only','auto-install-approved')) { throw "Unsupported AI instructions update receipt mode '$($Receipt.mode)'." }
    if ([string]$Receipt.channel -cnotin @('protected-branch','github-release')) { throw "Unsupported AI instructions update receipt channel '$($Receipt.channel)'." }
    if (([string]$Receipt.channel -ceq 'protected-branch' -and [string]$Receipt.ref -cne 'main') -or
        ([string]$Receipt.channel -ceq 'github-release' -and [string]$Receipt.ref -cne 'latest')) {
        throw 'AI instructions update receipt channel/ref combination is invalid.'
    }
    if ([string]$Receipt.currentCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'AI instructions update receipt currentCommit is invalid.' }
    if ($null -ne $Receipt.candidateCommit -and [string]$Receipt.candidateCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'AI instructions update receipt candidateCommit is invalid.'
    }
    $outcome = [string]$Receipt.outcome
    if ($outcome -cnotin @('current','available','installed','offline','stale','drift','failed')) {
        throw "Unsupported AI instructions update receipt outcome '$outcome'."
    }
    if ($null -ne $Receipt.archiveSha256 -and [string]$Receipt.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'AI instructions update receipt archiveSha256 is invalid.'
    }
    if ($Receipt.message -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Receipt.message)) {
        throw 'AI instructions update receipt message must be a non-empty string.'
    }
    if ($outcome -ceq 'current' -and $null -ne $Receipt.candidateCommit) {
        throw 'AI instructions current receipt candidateCommit must be null because currentCommit already identifies the resolved version.'
    }
    if ($outcome -in @('available','installed','stale','drift') -and $null -eq $Receipt.candidateCommit) {
        throw "AI instructions $outcome receipt requires candidateCommit."
    }
    if ($outcome -in @('installed','drift') -and $null -eq $Receipt.archiveSha256) {
        throw "AI instructions $outcome receipt requires archiveSha256."
    }
    return $Receipt
}

function Write-AiInstructionsJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][object] $Document)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $json = ($Document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"
    $temporaryPath = Join-Path $parent ('.' + (Split-Path -Leaf $fullPath) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $parent ('.' + (Split-Path -Leaf $fullPath) + '.backup-' + [Guid]::NewGuid().ToString('N'))
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        $stream = [System.IO.File]::Open($temporaryPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        try {
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { [System.IO.File]::Replace($temporaryPath,$fullPath,$backupPath) }
        else { [System.IO.File]::Move($temporaryPath,$fullPath) }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function @(
    'Assert-AiInstructionsCanonicalRepository',
    'Assert-AiInstructionsRuntimeBundleV2',
    'Assert-AiInstructionsMutationPath',
    'Assert-AiInstructionsSafeChildDirectory',
    'Assert-AiInstructionsSyncConfigurationV4',
    'Assert-AiInstructionsUpdateReceiptV1',
    'ConvertTo-AiInstructionsUtcDateTime',
    'ConvertTo-AiInstructionsSyncConfigurationV4',
    'Get-AiInstructionsFileSha256',
    'Get-AiInstructionsFullDirectoryPath',
    'Get-AiInstructionsRuntimeInventory',
    'Get-AiInstructionsRuntimeInventorySha256',
    'New-AiInstructionsRuntimeBundleV2',
    'Write-AiInstructionsJsonFile'
)
