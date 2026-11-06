Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CanonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:SkillsCatalogContractModule = $null
$script:ExpectedPlatformRuntimeRootModule = 'platform-runtime.psm1'
$script:ExpectedPlatformRuntimeFunctionsToExport = @(
    'Assert-PlatformRuntimeInventory',
    'Get-PlatformCapabilities',
    'Open-PlatformDirectory',
    'Open-PlatformFile',
    'Assert-PlatformFileIdentity',
    'Enter-PlatformLock',
    'Publish-PlatformFile',
    'Remove-PlatformOwnedFile',
    'Get-PlatformPermissions',
    'Set-PlatformPermissions',
    'Start-PlatformOwnedProcess',
    'Stop-PlatformOwnedProcess',
    'Resolve-PlatformPowerShell',
    'Resolve-PlatformPhysicalPath',
    'Initialize-PlatformAuthorityPester',
    'Assert-PlatformAuthorityPester',
    'New-PlatformPrivateRoot',
    'Invoke-PlatformPreparationCommand',
    'Initialize-PlatformPester',
    'Set-PlatformProcessEnvironment'
)
$script:ExpectedPlatformRuntimeEmptyExports = @('CmdletsToExport','VariablesToExport','AliasesToExport')
$script:AiInstructionsRefusalCodes = @(
    'capability-unavailable','platform-mismatch','downgrade-refused','mixed-generation','unsupported-version',
    'closure-invalid','interrupted-install','projection-runtime-unavailable','runtime-baseline-unavailable'
)

if ($null -eq ('SyuanTsai.AiInstructions.AiInstructionsRefusalException' -as [type])) {
    Add-Type -TypeDefinition @'
namespace SyuanTsai.AiInstructions {
    public sealed class AiInstructionsRefusalException : System.InvalidOperationException {
        public string Code { get; private set; }
        public AiInstructionsRefusalException(string code, string message) : base(message) { Code = code; }
        public AiInstructionsRefusalException(string code, string message, System.Exception inner) : base(message, inner) { Code = code; }
    }
}
'@
}

function Get-AiInstructionsRefusalCodes { return [string[]]@($script:AiInstructionsRefusalCodes) }

function New-AiInstructionsRefusalException {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][System.Exception] $InnerException = $null
    )
    if ($Code -cnotin $script:AiInstructionsRefusalCodes) { throw [ArgumentException]::new("Unknown AI instructions refusal code '$Code'.",'Code') }
    $formattedMessage = "$Message [ai-instructions-refusal-code=$Code]"
    if ($null -eq $InnerException) { return [SyuanTsai.AiInstructions.AiInstructionsRefusalException]::new($Code,$formattedMessage) }
    return [SyuanTsai.AiInstructions.AiInstructionsRefusalException]::new($Code,$formattedMessage,$InnerException)
}

function Get-AiInstructionsRefusalCode {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $ErrorRecordOrException)
    $candidate = $ErrorRecordOrException
    if ($candidate -is [Management.Automation.ErrorRecord]) { $candidate = $candidate.Exception }
    while ($candidate -is [Exception]) {
        if ($candidate -is [SyuanTsai.AiInstructions.AiInstructionsRefusalException] -and
            [string]$candidate.Code -cin $script:AiInstructionsRefusalCodes) { return [string]$candidate.Code }
        $candidate = $candidate.InnerException
    }
    $text = [string]$ErrorRecordOrException
    $matches = [regex]::Matches($text,'\[ai-instructions-refusal-code=([^\]\r\n]*)\]')
    if ($matches.Count -gt 0) {
        $match = $matches[$matches.Count - 1]
        if ($match.Groups[1].Value -cin $script:AiInstructionsRefusalCodes) { return $match.Groups[1].Value }
    }
    return $null
}

function Get-AiInstructionsSkillsCatalogContractModule {
    if ($null -ne $script:SkillsCatalogContractModule) { return $script:SkillsCatalogContractModule }

    $modulePath = Join-Path $PSScriptRoot 'skills-catalog-contract.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Runtime bundle v3 Catalog validation requires module 'skills-catalog-contract.psm1' beside the runtime contract."
    }
    try {
        $script:SkillsCatalogContractModule = Import-Module $modulePath -PassThru -Scope Local -ErrorAction Stop
    }
    catch {
        throw "Runtime bundle v3 Catalog validation could not import module 'skills-catalog-contract.psm1'."
    }
    return $script:SkillsCatalogContractModule
}

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

function Resolve-AiInstructionsCatalogSkillId {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][hashtable] $SkillsById,
        [Parameter(Mandatory = $true)][hashtable] $AliasesById
    )

    if ($SkillsById.ContainsKey($SkillId)) {
        $skill = $SkillsById[$SkillId]
        if ([string]$skill.lifecycle.status -ceq 'removed' -and
            (Test-AiInstructionsObjectHasProperty -Object $skill.lifecycle -Name 'replacementId') -and
            -not [string]::IsNullOrWhiteSpace([string]$skill.lifecycle.replacementId)) {
            return [string]$skill.lifecycle.replacementId
        }
        return $SkillId
    }
    if ($AliasesById.ContainsKey($SkillId)) { return [string]$AliasesById[$SkillId] }
    throw "AI instruction sync configuration references unknown Skill '$SkillId'."
}

function Get-AiInstructionsNormalizedExplicitIncludes {
    param(
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Profiles,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $IncludeSkills
    )

    if (-not (Test-AiInstructionsObjectHasProperty -Object $Catalog -Name 'profiles') -or
        -not (Test-AiInstructionsObjectHasProperty -Object $Catalog -Name 'skills')) {
        throw 'Skills Catalog normalization requires profiles and skills.'
    }

    $profilesById = @{}
    foreach ($profile in @($Catalog.profiles)) { $profilesById[[string]$profile.id] = $profile }
    $skillsById = @{}
    $aliasesById = @{}
    foreach ($skill in @($Catalog.skills)) {
        $skillId = [string]$skill.id
        $skillsById[$skillId] = $skill
        if ([string]$skill.lifecycle.status -ceq 'removed') { continue }
        foreach ($aliasValue in @($skill.lifecycle.aliases)) {
            $alias = [string]$aliasValue
            if ($aliasesById.ContainsKey($alias) -and [string]$aliasesById[$alias] -cne $skillId) {
                throw "Ambiguous Skills Catalog alias '$alias'."
            }
            $aliasesById[$alias] = $skillId
        }
    }

    $requestedProfiles = @($Profiles)
    if ($requestedProfiles.Count -eq 0) {
        $requestedProfiles = @($Catalog.profiles | Where-Object { $_.default -eq $true } | Select-Object -ExpandProperty id)
    }
    $profileSelected = @{}
    $profileExcluded = @{}
    foreach ($profileIdValue in $requestedProfiles) {
        $profileId = [string]$profileIdValue
        if (-not $profilesById.ContainsKey($profileId)) {
            throw "AI instruction sync configuration references unknown profile '$profileId'."
        }
        $profile = $profilesById[$profileId]
        foreach ($skillIdValue in @($profile.includes)) {
            $skillId = Resolve-AiInstructionsCatalogSkillId -SkillId ([string]$skillIdValue) -SkillsById $skillsById -AliasesById $aliasesById
            $profileSelected[$skillId] = $true
        }
        foreach ($skillIdValue in @($profile.excludes)) {
            $skillId = Resolve-AiInstructionsCatalogSkillId -SkillId ([string]$skillIdValue) -SkillsById $skillsById -AliasesById $aliasesById
            $profileExcluded[$skillId] = $true
        }
    }
    foreach ($skillId in @($profileExcluded.Keys)) { $profileSelected.Remove($skillId) }

    return @(
        foreach ($configuredIdValue in @($IncludeSkills)) {
            $configuredId = [string]$configuredIdValue
            $skillId = Resolve-AiInstructionsCatalogSkillId -SkillId $configuredId -SkillsById $skillsById -AliasesById $aliasesById
            if (-not $profileSelected.ContainsKey($skillId)) { $configuredId }
        }
    )
}

function ConvertTo-AiInstructionsSyncConfigurationV4 {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $ExistingConfiguration,
        [Parameter(Mandatory = $true)][string] $CatalogRepository,
        [Parameter(Mandatory = $true)][string] $CatalogRef,
        [string[]] $AdditionalExcludedRepositoryUrls = @(),
        [string[]] $AdditionalExcludedRepositoryPaths = @(),
        [AllowNull()][object] $Catalog,
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
        if ($schemaVersion -eq 5) {
            throw 'AI Instructions sync configuration schema version 5 requires a projection-aware installer.'
        }
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
    if ($null -ne $Catalog) {
        $includeSkills = @(Get-AiInstructionsNormalizedExplicitIncludes -Catalog $Catalog -Profiles $profiles -IncludeSkills $includeSkills)
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

function ConvertTo-AiInstructionsSyncConfigurationV5 {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $ExistingConfiguration,
        [Parameter(Mandatory = $true)][string] $CatalogRepository,
        [Parameter(Mandatory = $true)][string] $CatalogRef,
        [string[]] $AdditionalExcludedRepositoryUrls = @(),
        [string[]] $AdditionalExcludedRepositoryPaths = @(),
        [AllowNull()][object] $Catalog,
        [string] $CanonicalRepository = $script:CanonicalRepository
    )

    if ($null -ne $ExistingConfiguration -and
        (Test-AiInstructionsObjectHasProperty -Object $ExistingConfiguration -Name 'schemaVersion') -and
        ($ExistingConfiguration.schemaVersion -is [int] -or $ExistingConfiguration.schemaVersion -is [long]) -and
        [int64]$ExistingConfiguration.schemaVersion -eq 5) {
        Assert-AiInstructionsSyncConfigurationV5 -Configuration $ExistingConfiguration -CanonicalRepository $CanonicalRepository | Out-Null
        return $ExistingConfiguration
    }

    $v4 = ConvertTo-AiInstructionsSyncConfigurationV4 @PSBoundParameters
    $v5 = [pscustomobject][ordered]@{
        schemaVersion = 5
        excludedRepositoryUrls = @($v4.excludedRepositoryUrls)
        excludedRepositoryPaths = @($v4.excludedRepositoryPaths)
        catalog = $v4.catalog
        updates = $v4.updates
        projections = [pscustomobject][ordered]@{ user=@('user-agents','user-claude'); project=@() }
    }
    Assert-AiInstructionsSyncConfigurationV5 -Configuration $v5 -CanonicalRepository $CanonicalRepository | Out-Null
    return $v5
}

function Assert-AiInstructionsSyncConfigurationV4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Configuration,
        [string] $CanonicalRepository = $script:CanonicalRepository,
        [switch] $AllowCanonicalRepositoryAlias
    )

    if ((Test-AiInstructionsObjectHasProperty -Object $Configuration -Name 'schemaVersion') -and
        ($Configuration.schemaVersion -is [int] -or $Configuration.schemaVersion -is [long]) -and
        [int64]$Configuration.schemaVersion -eq 5) {
        throw 'AI Instructions sync configuration schema version 5 requires a projection-aware installer.'
    }
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

function Assert-AiInstructionsProjectionIdArray {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string[]] $Allowed,
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $RequireUserAgents
    )
    if ($Value -isnot [System.Array]) { throw "$Context must be an array." }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) { throw "$Context must contain only non-empty strings." }
        if ([string]$item -cnotin $Allowed) { throw "$Context contains unknown or wrong-scope projection '$item'." }
        if (-not $seen.Add([string]$item)) { throw "$Context contains duplicate projection '$item'." }
    }
    if ($RequireUserAgents -and -not $seen.Contains('user-agents')) { throw "$Context must include 'user-agents'." }
}

function Assert-AiInstructionsSyncConfigurationV5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Configuration,
        [string] $CanonicalRepository = $script:CanonicalRepository,
        [switch] $AllowCanonicalRepositoryAlias
    )
    if (-not (Test-AiInstructionsObjectHasProperty -Object $Configuration -Name 'schemaVersion') -or
        ($Configuration.schemaVersion -isnot [int] -and $Configuration.schemaVersion -isnot [long]) -or
        [int64]$Configuration.schemaVersion -ne 5) { throw 'AI instruction sync configuration must use schemaVersion 5.' }
    foreach ($propertyName in @($Configuration.PSObject.Properties.Name)) {
        if ($propertyName -cnotin @('schemaVersion','excludedRepositoryUrls','excludedRepositoryPaths','catalog','updates','projections')) {
            throw "AI instruction sync configuration contains unsupported property '$propertyName'."
        }
    }
    foreach ($name in @('excludedRepositoryUrls','excludedRepositoryPaths','catalog','updates','projections')) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Configuration -Name $name)) { throw "AI instruction sync configuration is missing '$name'." }
    }
    $v4 = [pscustomobject][ordered]@{
        schemaVersion=4
        excludedRepositoryUrls=$Configuration.excludedRepositoryUrls
        excludedRepositoryPaths=$Configuration.excludedRepositoryPaths
        catalog=$Configuration.catalog
        updates=$Configuration.updates
    }
    Assert-AiInstructionsSyncConfigurationV4 -Configuration $v4 -CanonicalRepository $CanonicalRepository -AllowCanonicalRepositoryAlias:$AllowCanonicalRepositoryAlias | Out-Null
    foreach ($propertyName in @($Configuration.projections.PSObject.Properties.Name)) {
        if ($propertyName -cnotin @('user','project')) { throw "AI instruction sync configuration projections contains unsupported property '$propertyName'." }
    }
    foreach ($name in @('user','project')) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Configuration.projections -Name $name)) { throw "AI instruction sync configuration projections is missing '$name'." }
    }
    # P6a owns the projection root map. This reader only enforces its fixed scope IDs,
    # avoiding an import cycle from the runtime contract into the Catalog contract.
    Assert-AiInstructionsProjectionIdArray -Value $Configuration.projections.user -Allowed @('user-agents','user-claude','user-copilot') -Context 'AI instruction sync configuration projections.user' -RequireUserAgents
    Assert-AiInstructionsProjectionIdArray -Value $Configuration.projections.project -Allowed @('project-agents','project-claude','project-github') -Context 'AI instruction sync configuration projections.project'
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

function Get-AiInstructionsCanonicalTextSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes([System.IO.Path]::GetFullPath($Path))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw 'Platform runtime files must be UTF-8 without BOM.'
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $canonicalBytes = $utf8.GetBytes($utf8.GetString($bytes).Replace("`r`n","`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($canonicalBytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Resolve-AiInstructionsRuntimeFilePath {
    param(
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $root = Get-AiInstructionsFullDirectoryPath -Path $RuntimeRoot
    Assert-AiInstructionsMutationPath -Path $root -ExpectedType Directory -Context 'AI instructions runtime root' | Out-Null
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Contains('\') -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|/)\.\.?(/|$)' -or
        $RelativePath -match '[\x00-\x1f:]') {
        throw "$Context contains an unsafe runtime-relative path '$RelativePath'."
    }

    $current = $root
    $segments = @($RelativePath.Split('/'))
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        if (-not (Test-Path -LiteralPath $current)) { throw "$Context file is missing: $RelativePath" }
        $item = Get-Item -Force -LiteralPath $current
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context must not traverse a reparse point: $RelativePath"
        }
        $isFinal = $index -eq ($segments.Count - 1)
        if (($isFinal -and $item.PSIsContainer) -or (-not $isFinal -and -not $item.PSIsContainer)) {
            throw "$Context must resolve to a regular file: $RelativePath"
        }
    }
    return [System.IO.Path]::GetFullPath($current)
}

function Get-AiInstructionsDataValue {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-AiInstructionsPlatformRuntimeRelativePath {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ManifestDirectory,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Value
    if ($Value -isnot [string]) { $pathValue = Get-AiInstructionsDataValue -Object $Value -Name 'ModuleName' }
    if ($pathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$pathValue)) {
        throw "$Context must identify a non-empty relative path."
    }
    $relativePath = ([string]$pathValue).Replace('\','/')
    if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.?(/|$)' -or $relativePath -match '[\x00-\x1f:]') {
        throw "$Context contains an unsafe relative path '$relativePath'."
    }
    if ([string]::IsNullOrWhiteSpace($ManifestDirectory)) { return $relativePath }
    return "$ManifestDirectory/$relativePath"
}

function Get-AiInstructionsPlatformRuntimeClosurePaths {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][string] $ManifestPath
    )
    $separatorIndex = $ManifestPath.LastIndexOf('/')
    $manifestDirectory = if ($separatorIndex -lt 0) { '' } else { $ManifestPath.Substring(0,$separatorIndex) }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($field in @('FileList','RootModule','NestedModules','RequiredModules')) {
        $value = Get-AiInstructionsDataValue -Object $Manifest -Name $field
        if ($null -eq $value -or ($field -in @('NestedModules','RequiredModules') -and @($value).Count -eq 0)) { continue }
        foreach ($item in @($value)) {
            $relativePath = ConvertTo-AiInstructionsPlatformRuntimeRelativePath -Value $item -ManifestDirectory $manifestDirectory -Context "Platform runtime manifest $field"
            [void]$paths.Add($relativePath)
        }
    }
    $privateData = Get-AiInstructionsDataValue -Object $Manifest -Name 'PrivateData'
    $platformRuntime = Get-AiInstructionsDataValue -Object $privateData -Name 'PlatformRuntime'
    $manifestInventory = Get-AiInstructionsDataValue -Object $platformRuntime -Name 'Inventory'
    foreach ($entry in @($manifestInventory)) {
        $entryPath = Get-AiInstructionsDataValue -Object $entry -Name 'Path'
        $relativePath = ConvertTo-AiInstructionsPlatformRuntimeRelativePath -Value $entryPath -ManifestDirectory $manifestDirectory -Context 'Platform runtime manifest inventory'
        [void]$paths.Add($relativePath)
    }
    return @($paths)
}

function Assert-AiInstructionsPlatformRuntimeManifestLoadFields {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    # This runtime deliberately uses only RootModule and FileList.  Any other
    # manifest import hook could load code or metadata outside the authenticated
    # closure, so it must remain absent or explicitly empty.
    foreach ($field in @('ModuleToProcess','NestedModules','RequiredModules','ScriptsToProcess','RequiredAssemblies','TypesToProcess','FormatsToProcess')) {
        $value = Get-AiInstructionsDataValue -Object $Manifest -Name $field
        if ($null -eq $value) { continue }
        if ($value -is [string] -and $value.Length -eq 0) { continue }
        if ($value -isnot [string] -and @($value).Count -eq 0) { continue }
        throw "Platform runtime manifest loading field '$field' must be absent or empty."
    }
}

function Assert-AiInstructionsPlatformRuntimeManifestApi {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    $rootModule = Get-AiInstructionsDataValue -Object $Manifest -Name 'RootModule'
    if ($rootModule -isnot [string] -or [string]$rootModule -cne $script:ExpectedPlatformRuntimeRootModule) {
        throw "Platform runtime manifest RootModule must be '$($script:ExpectedPlatformRuntimeRootModule)'."
    }

    $actualFunctions = @(Get-AiInstructionsDataValue -Object $Manifest -Name 'FunctionsToExport')
    $actualFunctionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($functionName in $actualFunctions) {
        if ($functionName -isnot [string] -or -not $actualFunctionSet.Add([string]$functionName)) {
            throw 'Platform runtime manifest FunctionsToExport must exactly match the expected API.'
        }
    }
    $expectedFunctionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($functionName in $script:ExpectedPlatformRuntimeFunctionsToExport) { [void]$expectedFunctionSet.Add($functionName) }
    if ($actualFunctionSet.Count -ne $expectedFunctionSet.Count -or -not $actualFunctionSet.SetEquals($expectedFunctionSet)) {
        throw 'Platform runtime manifest FunctionsToExport must exactly match the expected API.'
    }

    foreach ($field in $script:ExpectedPlatformRuntimeEmptyExports) {
        $value = Get-AiInstructionsDataValue -Object $Manifest -Name $field
        if ($null -ne $value -and @($value).Count -ne 0) {
            throw "Platform runtime manifest $field must be empty."
        }
    }
}

function Assert-AiInstructionsPlatformRuntimeManifestInventory {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][string] $BundleApiVersion
    )

    Assert-AiInstructionsPlatformRuntimeManifestLoadFields -Manifest $Manifest
    Assert-AiInstructionsPlatformRuntimeManifestApi -Manifest $Manifest
    $privateData = Get-AiInstructionsDataValue -Object $Manifest -Name 'PrivateData'
    $platformRuntime = Get-AiInstructionsDataValue -Object $privateData -Name 'PlatformRuntime'
    $manifestApiVersion = Get-AiInstructionsDataValue -Object $platformRuntime -Name 'ApiVersion'
    $hashMode = Get-AiInstructionsDataValue -Object $platformRuntime -Name 'HashMode'
    $inventory = Get-AiInstructionsDataValue -Object $platformRuntime -Name 'Inventory'
    if ($manifestApiVersion -isnot [string] -or [string]$manifestApiVersion -cne $BundleApiVersion) {
        throw 'Platform runtime manifest ApiVersion does not match runtime bundle platformRuntime.apiVersion.'
    }
    if ($hashMode -isnot [string] -or [string]$hashMode -cne 'sha256-utf8-lf' -or $null -eq $inventory) {
        throw 'Platform runtime manifest has no bound sha256-utf8-lf inventory.'
    }

    $declaredPaths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($inventory)) {
        $relativePath = ([string](Get-AiInstructionsDataValue -Object $entry -Name 'Path')).Replace('\','/')
        $expectedHash = Get-AiInstructionsDataValue -Object $entry -Name 'Sha256'
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            @($relativePath.Split('/') | Where-Object { $_ -ceq '..' }).Count -gt 0 -or
            $expectedHash -isnot [string] -or [string]$expectedHash -cnotmatch '^[a-f0-9]{64}$') {
            throw 'Platform runtime manifest inventory contains an invalid entry.'
        }
        $declaredPaths.Add($relativePath)
    }

    $expectedFileList = @('platform-runtime.psd1') + @($declaredPaths.ToArray())
    $manifestFileList = @(
        @(Get-AiInstructionsDataValue -Object $Manifest -Name 'FileList') | ForEach-Object {
            ([string]$_).Replace('\','/')
        }
    )
    $expectedFileListText = (@($expectedFileList | Sort-Object) -join "`n")
    $manifestFileListText = (@($manifestFileList | Sort-Object) -join "`n")
    if ($expectedFileListText -cne $manifestFileListText -or
        @($expectedFileList | Select-Object -Unique).Count -ne $expectedFileList.Count) {
        throw 'Platform runtime manifest FileList differs from its bound inventory.'
    }

    $platformRoot = Join-Path (Get-AiInstructionsFullDirectoryPath -Path $RuntimeRoot) 'platform'
    if (-not (Test-Path -LiteralPath $platformRoot -PathType Container)) {
        throw 'Platform runtime implementation directory is missing.'
    }
    $actualPlatformPaths = @(
        Get-ChildItem -LiteralPath $platformRoot -File -Recurse | ForEach-Object {
            ('platform/' + $_.FullName.Substring($platformRoot.Length).TrimStart('\','/')).Replace('\','/')
        }
    )
    $declaredPlatformPaths = @($declaredPaths | Where-Object { $_.StartsWith('platform/',[StringComparison]::Ordinal) })
    if ((@($actualPlatformPaths | Sort-Object) -join "`n") -cne (@($declaredPlatformPaths | Sort-Object) -join "`n")) {
        throw 'Platform runtime implementation directory contains missing or extra files.'
    }

    foreach ($entry in @($inventory)) {
        $relativePath = ([string](Get-AiInstructionsDataValue -Object $entry -Name 'Path')).Replace('\','/')
        $fullPath = Resolve-AiInstructionsRuntimeFilePath -RuntimeRoot $RuntimeRoot -RelativePath $relativePath -Context 'Platform runtime manifest inventory'
        $actualHash = Get-AiInstructionsCanonicalTextSha256 -Path $fullPath
        if ($actualHash -cne [string](Get-AiInstructionsDataValue -Object $entry -Name 'Sha256')) {
            throw "Platform runtime manifest inventory hash mismatch: $relativePath"
        }
    }
}

function Get-AiInstructionsProjectionContractSha256 {
    param([Parameter(Mandatory = $true)][object] $Projections)
    if ($Projections -isnot [System.Array]) { throw 'Installed Skills Catalog v3 projections must be an array.' }
    $allowed = @{
        'user-agents'=@('user','.agents/skills'); 'user-claude'=@('user','.claude/skills'); 'user-copilot'=@('user','.copilot/skills')
        'project-agents'=@('project','.agents/skills'); 'project-claude'=@('project','.claude/skills'); 'project-github'=@('project','.github/skills')
    }
    $byId = @{}
    foreach ($projection in @($Projections)) {
        foreach ($name in @('id','scope','root')) {
            if (-not (Test-AiInstructionsObjectHasProperty -Object $projection -Name $name) -or $projection.$name -isnot [string]) {
                throw "Installed Skills Catalog v3 projection is missing string '$name'."
            }
        }
        $id = [string]$projection.id
        if (-not $allowed.ContainsKey($id)) { throw "Installed Skills Catalog v3 contains unknown projection '$id'." }
        if ($byId.ContainsKey($id)) { throw "Installed Skills Catalog v3 contains duplicate projection '$id'." }
        if ([string]$projection.scope -cne [string]$allowed[$id][0] -or [string]$projection.root -cne [string]$allowed[$id][1]) {
            throw "Installed Skills Catalog v3 projection '$id' has an invalid scope or root."
        }
        $byId[$id] = $projection
    }
    if (-not $byId.ContainsKey('user-agents')) { throw "Installed Skills Catalog v3 projections must include 'user-agents'." }
    [string[]]$ids = @($byId.Keys)
    [System.Array]::Sort($ids,[System.StringComparer]::Ordinal)
    $canonical = [string]::Concat(@($ids | ForEach-Object { $projection=$byId[$_]; "$($_)`t$([string]$projection.scope)`t$([string]$projection.root)`n" }))
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-AiInstructionsRuntimeJsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $path = Resolve-AiInstructionsRuntimeFilePath -RuntimeRoot $RuntimeRoot -RelativePath $RelativePath -Context $Context
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { throw "$Context must be UTF-8 without BOM." }
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try { return ($utf8.GetString($bytes) | ConvertFrom-Json) }
    catch { throw "$Context is not valid strict UTF-8 JSON." }
}

function Get-AiInstructionsPlatformRuntimeSourceFingerprint {
    param([Parameter(Mandatory = $true)][string] $RuntimeRoot)
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $stream = New-Object System.IO.MemoryStream
    try {
        foreach ($relativePath in @('platform/PlatformNative.cs','platform/UnixNative.cs','platform/WindowsNative.cs','platform/OwnedProcess.cs','platform/UnixProcess.cs','platform/WindowsProcess.cs')) {
            $fullPath = Resolve-AiInstructionsRuntimeFilePath -RuntimeRoot $RuntimeRoot -RelativePath $relativePath -Context 'Platform runtime source'
            [byte[]]$bytes = [System.IO.File]::ReadAllBytes($fullPath)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { throw 'Platform runtime files must be UTF-8 without BOM.' }
            [byte[]]$canonicalBytes = $utf8.GetBytes($utf8.GetString($bytes).Replace("`r`n","`n"))
            [byte[]]$prefixBytes = $utf8.GetBytes($relativePath + "`n" + $canonicalBytes.Length.ToString([System.Globalization.CultureInfo]::InvariantCulture) + "`n")
            $stream.Write($prefixBytes,0,$prefixBytes.Length)
            $stream.Write($canonicalBytes,0,$canonicalBytes.Length)
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))).Replace('-','').ToLowerInvariant() }
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

function Get-AiInstructionsRuntimeInventorySha256V3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Inventory)

    $paths = New-Object System.Collections.Generic.List[string]
    $hashesByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($Inventory)) {
        $path = [string]$entry.path
        $hash = [string]$entry.sha256
        if ($path -match '[\x00-\x1f\x7f]') { throw "Runtime inventory path contains a control character: $path" }
        if ([string]::IsNullOrWhiteSpace($path) -or $path.Contains('\') -or $path.StartsWith('/') -or $path -match '(^|/)\.\.(/|$)') { throw "Unsafe runtime inventory path: $path" }
        if ($hash -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid runtime inventory hash for '$path'." }
        if ($hashesByPath.ContainsKey($path)) { throw "Duplicate runtime inventory path '$path'." }
        $hashesByPath.Add($path,$hash)
        $paths.Add($path)
    }
    $sortedPaths = [string[]]$paths.ToArray()
    [Array]::Sort($sortedPaths,[StringComparer]::Ordinal)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($path in $sortedPaths) { $lines.Add("$path`t$($hashesByPath[$path])`n") }
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

    if ((Test-AiInstructionsObjectHasProperty -Object $Bundle -Name 'schemaVersion') -and
        ($Bundle.schemaVersion -is [int] -or $Bundle.schemaVersion -is [long]) -and
        [int64]$Bundle.schemaVersion -eq 3) {
        throw 'Runtime bundle schema version 3 requires a projection-aware installer.'
    }
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

# requiredCapabilities is a bundle-declared requirement; this validator checks syntax and known names only.
# Projection-aware installers and launchers must verify it on the target host before enabling the runtime.
function Assert-AiInstructionsRuntimeBundleV3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Bundle,
        [Parameter(Mandatory = $true)][object] $Configuration,
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [string] $CanonicalRepository = $script:CanonicalRepository
    )
    $allowed = @('schemaVersion','repository','commit','acquisition','archiveSha256','inventorySha256','inventory','platform','platformRuntime','requiredCapabilities','projectionContractSha256')
    foreach ($name in $allowed) { if (-not (Test-AiInstructionsObjectHasProperty -Object $Bundle -Name $name)) { throw "Runtime bundle is missing '$name'." } }
    foreach ($name in @($Bundle.PSObject.Properties.Name)) { if ($name -cnotin $allowed) { throw "Runtime bundle contains unsupported property '$name'." } }
    if (($Bundle.schemaVersion -isnot [int] -and $Bundle.schemaVersion -isnot [long]) -or [int64]$Bundle.schemaVersion -ne 3) { throw 'Runtime bundle must use integer schemaVersion 3.' }
    if (-not (Test-AiInstructionsObjectHasProperty -Object $Configuration -Name 'schemaVersion') -or
        ($Configuration.schemaVersion -isnot [int] -and $Configuration.schemaVersion -isnot [long])) {
        throw 'Runtime bundle configuration schemaVersion is invalid.'
    }
    if ([int64]$Configuration.schemaVersion -eq 4) {
        Assert-AiInstructionsSyncConfigurationV4 -Configuration $Configuration -CanonicalRepository $CanonicalRepository | Out-Null
        $v4Configuration = $Configuration
    }
    elseif ([int64]$Configuration.schemaVersion -eq 5) {
        Assert-AiInstructionsSyncConfigurationV5 -Configuration $Configuration -CanonicalRepository $CanonicalRepository | Out-Null
        $v4Configuration = [pscustomobject][ordered]@{
            schemaVersion=4; excludedRepositoryUrls=$Configuration.excludedRepositoryUrls; excludedRepositoryPaths=$Configuration.excludedRepositoryPaths
            catalog=$Configuration.catalog; updates=$Configuration.updates
        }
    }
    else { throw 'Runtime bundle requires sync configuration schemaVersion 4 or 5.' }

    # Validate v3-only shapes before the inventory digest so each malformed field fails on its own boundary.
    foreach ($shape in @(@($Bundle.platform,@('os','architecture'),'Runtime bundle platform'),@($Bundle.platformRuntime,@('apiVersion','manifestSha256','sourceFingerprint'),'Runtime bundle platformRuntime'))) {
        foreach ($name in @($shape[1])) { if (-not (Test-AiInstructionsObjectHasProperty -Object $shape[0] -Name $name)) { throw "$($shape[2]) is missing '$name'." } }
        foreach ($name in @($shape[0].PSObject.Properties.Name)) { if ($name -cnotin @($shape[1])) { throw "$($shape[2]) contains unsupported property '$name'." } }
    }
    if ($Bundle.platform.os -isnot [string] -or [string]$Bundle.platform.os -cnotin @('windows','linux','macos')) { throw 'Runtime bundle platform.os is invalid.' }
    if ($Bundle.platform.architecture -isnot [string] -or [string]$Bundle.platform.architecture -cnotin @('x64','arm64')) { throw 'Runtime bundle platform.architecture is invalid.' }
    Assert-AiInstructionsStringValue -Value $Bundle.platformRuntime.apiVersion -Context 'Runtime bundle platformRuntime.apiVersion'
    if ([string]$Bundle.platformRuntime.apiVersion -cnotmatch '^[0-9]+\.[0-9]+$') { throw 'Runtime bundle platformRuntime.apiVersion is invalid.' }
    if ([string]$Bundle.platformRuntime.apiVersion -cne '1.0') { throw "Unsupported runtime bundle platformRuntime.apiVersion '$($Bundle.platformRuntime.apiVersion)'." }
    foreach ($name in @('manifestSha256','sourceFingerprint')) {
        Assert-AiInstructionsStringValue -Value $Bundle.platformRuntime.$name -Context "Runtime bundle platformRuntime.$name"
        if ([string]$Bundle.platformRuntime.$name -cnotmatch '^[0-9a-f]{64}$') { throw "Runtime bundle platformRuntime.$name is invalid." }
    }
    Assert-AiInstructionsStringValue -Value $Bundle.projectionContractSha256 -Context 'Runtime bundle projectionContractSha256'
    if ([string]$Bundle.projectionContractSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Runtime bundle projectionContractSha256 is invalid.' }
    if ($Bundle.requiredCapabilities -isnot [System.Array] -or @($Bundle.requiredCapabilities).Count -lt 1) { throw 'Runtime bundle requiredCapabilities must be a non-empty array.' }
    $capabilities = @('directory-lease','file-lease','file-identity','lock','publication','owned-file-removal','permissions','process-isolation','owned-process','process-cleanup','powershell-resolution','pester-initialization','powershell-runtime','pester-module','process-environment')
    $seenCapabilities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($capability in @($Bundle.requiredCapabilities)) {
        if ($capability -isnot [string] -or [string]$capability -cnotin $capabilities) { throw "Runtime bundle contains unknown required capability '$capability'." }
        if (-not $seenCapabilities.Add([string]$capability)) { throw "Runtime bundle contains duplicate required capability '$capability'." }
    }
    Assert-AiInstructionsStringValue -Value $Bundle.repository -Context 'Runtime bundle repository'
    Assert-AiInstructionsStringValue -Value $Bundle.commit -Context 'Runtime bundle commit'
    Assert-AiInstructionsStringValue -Value $Bundle.acquisition -Context 'Runtime bundle acquisition'
    Assert-AiInstructionsStringValue -Value $Bundle.archiveSha256 -Context 'Runtime bundle archiveSha256' -AllowNull
    Assert-AiInstructionsStringValue -Value $Bundle.inventorySha256 -Context 'Runtime bundle inventorySha256'
    Assert-AiInstructionsCanonicalRepository -Repository ([string]$Bundle.repository) -CanonicalRepository $CanonicalRepository
    if ([string]$Bundle.repository -cne $CanonicalRepository) { throw "Runtime bundle repository must use the canonical repository '$CanonicalRepository'." }
    if ([string]$Bundle.commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Runtime bundle commit must be a full lowercase 40-character commit SHA.' }
    if ([string]$Bundle.repository -cne [string]$v4Configuration.catalog.repository -or [string]$Bundle.commit -cne [string]$v4Configuration.catalog.ref) {
        throw 'Installed AI instruction runtime bundle does not match the configured immutable Catalog bundle pin.'
    }
    if ([string]$Bundle.acquisition -cnotin @('git-checkout','github-codeload')) { throw "Unsupported runtime bundle acquisition '$($Bundle.acquisition)'." }
    if ([string]$Bundle.acquisition -ceq 'github-codeload' -and [string]$Bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Runtime bundle archiveSha256 is required for github-codeload acquisition.'
    }
    if ($null -ne $Bundle.archiveSha256 -and [string]$Bundle.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Runtime bundle archiveSha256 is invalid.' }
    if ($Bundle.inventory -isnot [System.Array]) { throw 'Runtime bundle inventory must be an array.' }
    $inventoryByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($Bundle.inventory)) {
        if ($null -eq $entry.PSObject.Properties['path'] -or $null -eq $entry.PSObject.Properties['sha256']) { throw 'Runtime bundle inventory entry is missing path or sha256.' }
        foreach ($propertyName in @($entry.PSObject.Properties.Name)) {
            if ($propertyName -cnotin @('path','sha256')) { throw "Runtime bundle inventory entry contains unsupported property '$propertyName'." }
        }
        Assert-AiInstructionsStringValue -Value $entry.path -Context 'Runtime bundle inventory path'
        Assert-AiInstructionsStringValue -Value $entry.sha256 -Context "Runtime bundle inventory hash for '$($entry.path)'"
        if ($inventoryByPath.ContainsKey([string]$entry.path)) { throw "Duplicate runtime inventory path '$($entry.path)'." }
        $inventoryByPath.Add([string]$entry.path,$entry)
    }
    $declaredDigest = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $Bundle.inventory
    if ($declaredDigest -cne [string]$Bundle.inventorySha256) { throw 'Runtime bundle inventory digest does not match inventorySha256.' }
    $actualInventory = @(Get-AiInstructionsRuntimeInventory -RuntimeRoot $RuntimeRoot)
    $actualDigest = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $actualInventory
    if ($actualDigest -cne [string]$Bundle.inventorySha256 -or $actualInventory.Count -ne $Bundle.inventory.Count) {
        throw 'Installed AI instruction runtime inventory does not match the verified bundle.'
    }
    foreach ($actualEntry in $actualInventory) {
        $actualPath = [string]$actualEntry.path
        if (-not $inventoryByPath.ContainsKey($actualPath) -or [string]$inventoryByPath[$actualPath].sha256 -cne [string]$actualEntry.sha256) {
            throw "Installed AI instruction runtime inventory mismatch at '$actualPath'."
        }
    }
    $manifestPaths = @($inventoryByPath.Keys | Where-Object { [string]$_ -ceq 'platform-runtime.psd1' -or [string]$_ -clike '*/platform-runtime.psd1' })
    if ($manifestPaths.Count -ne 1 -or [string]$manifestPaths[0] -cne 'platform-runtime.psd1') {
        throw "Runtime bundle inventory must include exactly one 'platform-runtime.psd1' at the runtime root."
    }
    $manifestRelativePath = 'platform-runtime.psd1'
    $manifestFullPath = Resolve-AiInstructionsRuntimeFilePath -RuntimeRoot $RuntimeRoot -RelativePath $manifestRelativePath -Context 'Platform runtime manifest'
    $actualManifestSha256 = Get-AiInstructionsCanonicalTextSha256 -Path $manifestFullPath
    if ($actualManifestSha256 -cne [string]$Bundle.platformRuntime.manifestSha256) { throw 'Runtime bundle platformRuntime.manifestSha256 does not match the installed platform runtime manifest.' }
    try { $manifest = Import-PowerShellDataFile -LiteralPath $manifestFullPath }
    catch { throw 'Installed platform runtime manifest is not a valid PowerShell data file.' }
    Assert-AiInstructionsPlatformRuntimeManifestInventory `
        -Manifest $manifest `
        -RuntimeRoot $RuntimeRoot `
        -BundleApiVersion ([string]$Bundle.platformRuntime.apiVersion)
    foreach ($closurePath in @(Get-AiInstructionsPlatformRuntimeClosurePaths -Manifest $manifest -ManifestPath $manifestRelativePath)) {
        if (-not $inventoryByPath.ContainsKey($closurePath)) { throw "Runtime bundle inventory is missing platform runtime closure file '$closurePath'." }
        $closureFullPath = Resolve-AiInstructionsRuntimeFilePath -RuntimeRoot $RuntimeRoot -RelativePath $closurePath -Context 'Platform runtime closure'
        $actualClosureSha256 = Get-AiInstructionsFileSha256 -Path $closureFullPath
        if ($actualClosureSha256 -cne [string]$inventoryByPath[$closurePath].sha256) {
            throw "Runtime bundle inventory hash does not match platform runtime closure file '$closurePath'."
        }
    }
    $catalogPaths = @($inventoryByPath.Keys | Where-Object { [string]$_ -ceq 'catalog/skills-catalog.json' -or [string]$_ -clike '*/catalog/skills-catalog.json' })
    if ($catalogPaths.Count -ne 1 -or [string]$catalogPaths[0] -cne 'catalog/skills-catalog.json') {
        throw "Runtime bundle inventory must include exactly one 'catalog/skills-catalog.json' at the fixed Catalog path."
    }
    $catalogRelativePath = 'catalog/skills-catalog.json'
    $catalog = Read-AiInstructionsRuntimeJsonFile -RuntimeRoot $RuntimeRoot -RelativePath $catalogRelativePath -Context 'Installed Skills Catalog'
    if (-not (Test-AiInstructionsObjectHasProperty -Object $catalog -Name 'schemaVersion') -or
        ($catalog.schemaVersion -isnot [int] -and $catalog.schemaVersion -isnot [long]) -or [int64]$catalog.schemaVersion -ne 3) {
        throw 'Installed Skills Catalog must use schemaVersion 3.'
    }
    $catalogPath = Resolve-AiInstructionsRuntimeFilePath -RuntimeRoot $RuntimeRoot -RelativePath $catalogRelativePath -Context 'Installed Skills Catalog'
    $skillsCatalogContractModule = Get-AiInstructionsSkillsCatalogContractModule
    $catalog = & $skillsCatalogContractModule.ExportedCommands['Test-SkillsCatalogDocument'] -CatalogPath $catalogPath
    if ([int64]$Configuration.schemaVersion -eq 5) {
        $installedProjectionIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($projection in @($catalog.projections)) { [void]$installedProjectionIds.Add([string]$projection.id) }
        foreach ($scope in @('user','project')) {
            foreach ($projectionId in @($Configuration.projections.$scope)) {
                if (-not $installedProjectionIds.Contains([string]$projectionId)) {
                    throw "Runtime bundle projection '$projectionId' is not declared by the installed catalog."
                }
            }
        }
    }
    $actualProjectionContractSha256 = Get-AiInstructionsProjectionContractSha256 -Projections $catalog.projections
    if ($actualProjectionContractSha256 -cne [string]$Bundle.projectionContractSha256) {
        throw 'Runtime bundle projectionContractSha256 does not match the installed Skills Catalog projections.'
    }
    $actualSourceFingerprint = Get-AiInstructionsPlatformRuntimeSourceFingerprint -RuntimeRoot $RuntimeRoot
    if ($actualSourceFingerprint -cne [string]$Bundle.platformRuntime.sourceFingerprint) { throw 'Runtime bundle platformRuntime.sourceFingerprint does not match the installed platform runtime source.' }
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

function Assert-AiInstructionsInstallJournalExactProperties {
    param(
        [AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string[]] $Names,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $Object -is [System.Array] -or $Object -is [string] -or $Object -is [ValueType]) {
        throw "$Context must be an object."
    }
    foreach ($name in $Names) {
        if (-not (Test-AiInstructionsObjectHasProperty -Object $Object -Name $name)) { throw "$Context is missing '$name'." }
    }
    foreach ($propertyName in @($Object.PSObject.Properties.Name)) {
        if ($propertyName -cnotin $Names) { throw "$Context contains unsupported property '$propertyName'." }
    }
}

function Assert-AiInstructionsInstallJournalInteger {
    param([AllowNull()][object] $Value,[Parameter(Mandatory = $true)][string] $Context,[long] $Minimum = 0)
    $numericTypeCodes = @(
        [TypeCode]::SByte,[TypeCode]::Byte,[TypeCode]::Int16,[TypeCode]::UInt16,
        [TypeCode]::Int32,[TypeCode]::UInt32,[TypeCode]::Int64,[TypeCode]::UInt64,
        [TypeCode]::Single,[TypeCode]::Double,[TypeCode]::Decimal
    )
    $typeCode = if ($null -eq $Value) { [TypeCode]::Empty } else { [Type]::GetTypeCode($Value.GetType()) }
    $valid = $typeCode -in $numericTypeCodes
    if ($valid -and $typeCode -in @([TypeCode]::Double,[TypeCode]::Single)) {
        $doubleValue = [double]$Value
        $valid = -not [double]::IsNaN($doubleValue) -and -not [double]::IsInfinity($doubleValue) -and
            [Math]::Floor($doubleValue) -eq $doubleValue -and
            $doubleValue -ge -9.2233720368547758E18 -and $doubleValue -lt 9.2233720368547758E18 -and
            $doubleValue -ge [double]$Minimum
    }
    elseif ($valid -and $typeCode -eq [TypeCode]::Decimal) {
        $valid = [decimal]::Truncate([decimal]$Value) -eq [decimal]$Value -and
            [decimal]$Value -ge [decimal][int64]::MinValue -and [decimal]$Value -le [decimal][int64]::MaxValue -and
            [decimal]$Value -ge [decimal]$Minimum
    }
    elseif ($valid) {
        try { $decimalValue = [decimal]$Value }
        catch { $valid = $false }
        if ($valid) {
            $valid = $decimalValue -ge [decimal][int64]::MinValue -and $decimalValue -le [decimal][int64]::MaxValue -and
                $decimalValue -ge [decimal]$Minimum
        }
    }
    if (-not $valid) {
        throw "$Context must be an integer greater than or equal to $Minimum."
    }
}

function Assert-AiInstructionsInstallJournalLeaf {
    param([AllowNull()][object] $Value,[Parameter(Mandatory = $true)][string] $Context,[switch] $AllowNull,[switch] $PortableName)
    if ($AllowNull -and $null -eq $Value) { return }
    if ($Value -isnot [string]) {
        throw "$Context must be a safe single filename."
    }
    Get-AiInstructionsInstallJournalUnicodeScalarLength -Value ([string]$Value) -Context $Context | Out-Null
    if ([string]$Value -in @('.','..') -or [string]::IsNullOrWhiteSpace([string]$Value) -or
        [string]$Value -match '[/\\\x00-\x1f\x7f]') {
        throw "$Context must be a safe single filename."
    }
    if ($PortableName -and ([string]$Value -match '[:*?"<>|]' -or
            [string]$Value -match '\.$' -or [char]::IsWhiteSpace(([string]$Value)[([string]$Value).Length - 1]))) {
        throw "$Context must be a portable single filename."
    }
    if ($PortableName) {
        if (Test-AiInstructionsInstallJournalWindowsReservedDeviceName -Value ([string]$Value)) {
            throw "$Context must not use a Windows reserved device name."
        }
    }
}

function Get-AiInstructionsInstallJournalUnicodeScalarLength {
    param([Parameter(Mandatory = $true)][string] $Value,[Parameter(Mandatory = $true)][string] $Context)
    [int64]$scalarLength = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $unit = $Value[$index]
        if ([char]::IsHighSurrogate($unit)) {
            if ($index + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw "$Context contains an invalid unpaired Unicode surrogate."
            }
            $index++
        }
        elseif ([char]::IsLowSurrogate($unit)) {
            throw "$Context contains an invalid unpaired Unicode surrogate."
        }
        $scalarLength++
    }
    return $scalarLength
}

function Test-AiInstructionsInstallJournalWindowsReservedDeviceName {
    param([Parameter(Mandatory = $true)][string] $Value)
    $baseName = $Value.Split('.')[0].ToUpperInvariant()
    $superscriptOne = [char]0x00B9
    $superscriptTwo = [char]0x00B2
    $superscriptThree = [char]0x00B3
    if ($baseName -in @('CON','PRN','AUX','NUL','CONIN$','CONOUT$')) { return $true }
    return $baseName -match "^(COM|LPT)[0-9$superscriptOne$superscriptTwo$superscriptThree]$"
}

function Get-AiInstructionsInstallJournalPortableNameKey {
    param([Parameter(Mandatory = $true)][string] $Value)
    return $Value.Normalize([Text.NormalizationForm]::FormC).ToUpperInvariant()
}

function Assert-AiInstructionsInstallJournalIdentity {
    param([AllowNull()][object] $Identity,[Parameter(Mandatory = $true)][string] $Context,[Parameter(Mandatory = $true)][string] $ExpectedKind,[switch] $AllowNull)
    if ($null -eq $Identity) {
        if ($AllowNull) { return }
        throw "$Context must not be null."
    }
    Assert-AiInstructionsInstallJournalExactProperties -Object $Identity -Names @('kind','device','fileId') -Context $Context
    if ($Identity.kind -isnot [string] -or [string]$Identity.kind -cnotin @('windows-file-id','unix-device-inode')) { throw "$Context.kind is invalid." }
    if ([string]$Identity.kind -cne $ExpectedKind) { throw "$Context.kind must be $ExpectedKind for the journal platform." }
    foreach ($name in @('device','fileId')) {
        $value = $Identity.PSObject.Properties[$name].Value
        $scalarLength = if ($value -is [string]) { Get-AiInstructionsInstallJournalUnicodeScalarLength -Value ([string]$value) -Context "$Context.$name" } else { -1 }
        if ($value -isnot [string] -or [string]::IsNullOrEmpty([string]$value) -or $scalarLength -gt 64 -or [string]$value -cnotmatch '^[0-9A-Fa-fx:-]+$') { throw "$Context.$name is invalid." }
    }
}

function Assert-AiInstructionsInstallJournalFileState {
    param([AllowNull()][object] $State,[Parameter(Mandatory = $true)][string] $Context)
    Assert-AiInstructionsInstallJournalExactProperties -Object $State -Names @('exists','sha256','length','identity') -Context $Context
    if ($State.exists -isnot [bool]) { throw "$Context.exists must be a boolean." }
    if ($State.exists) {
        if ($State.sha256 -isnot [string] -or [string]$State.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "$Context.sha256 must be a lowercase SHA-256 hash when exists is true." }
        Assert-AiInstructionsInstallJournalInteger -Value $State.length -Context "$Context.length" -Minimum 0
    }
    elseif ($null -ne $State.sha256 -or $null -ne $State.length -or $null -ne $State.identity) {
        throw "$Context.sha256, $Context.length, and $Context.identity must be null when exists is false."
    }
}

function Assert-AiInstructionsInstallJournalDirectoryState {
    param([AllowNull()][object] $State,[Parameter(Mandatory = $true)][string] $Context)
    Assert-AiInstructionsInstallJournalExactProperties -Object $State -Names @('exists','identity','inventorySha256','entryCount') -Context $Context
    if ($State.exists -isnot [bool]) { throw "$Context.exists must be a boolean." }
    if ($State.exists) {
        if ($State.inventorySha256 -isnot [string] -or [string]$State.inventorySha256 -cnotmatch '^[0-9a-f]{64}$') { throw "$Context.inventorySha256 must be a lowercase SHA-256 hash when exists is true." }
        Assert-AiInstructionsInstallJournalInteger -Value $State.entryCount -Context "$Context.entryCount" -Minimum 0
    }
    elseif ($null -ne $State.identity -or $null -ne $State.inventorySha256 -or $null -ne $State.entryCount) {
        throw "$Context.identity, $Context.inventorySha256, and $Context.entryCount must be null when exists is false."
    }
}

function Get-AiInstructionsInstallJournalDirectoryState {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Inventory,[AllowNull()][object] $Identity)
    return [pscustomobject][ordered]@{
        exists = $true
        identity = $Identity
        inventorySha256 = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $Inventory
        entryCount = @($Inventory).Count
    }
}

function Get-AiInstructionsInstallJournalStoreLeaves {
    return [pscustomobject][ordered]@{ directory='.ai-instructions-txn'; journal='journal.json'; stage='journal.stage'; previous='journal.prev' }
}

function Assert-AiInstructionsInstallJournalV1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Journal)

    $topProperties = @('schemaVersion','kind','transactionId','createdAtUtc','owner','platform','lock','generation','phase','operations')
    Assert-AiInstructionsInstallJournalExactProperties -Object $Journal -Names $topProperties -Context 'AI instructions install journal'
    Assert-AiInstructionsInstallJournalInteger -Value $Journal.schemaVersion -Context 'AI instructions install journal schemaVersion' -Minimum 1
    if ([decimal]$Journal.schemaVersion -ne 1) {
        throw "Unsupported AI instructions install journal schema version '$($Journal.schemaVersion)'."
    }
    if ($Journal.kind -isnot [string] -or [string]$Journal.kind -cne 'ai-instructions-install-transaction') { throw 'AI instructions install journal kind is invalid.' }
    if ($Journal.transactionId -isnot [string] -or [string]$Journal.transactionId -cnotmatch '^[0-9a-f]{32}$') { throw 'AI instructions install journal transactionId must be 32 lowercase hexadecimal characters.' }
    if ($Journal.createdAtUtc -isnot [string] -or [string]$Journal.createdAtUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$') {
        throw 'AI instructions install journal createdAtUtc must be an ISO 8601 UTC string ending in Z.'
    }
    try { ConvertTo-AiInstructionsUtcDateTime -Value $Journal.createdAtUtc -Context 'AI instructions install journal createdAtUtc' | Out-Null }
    catch { throw 'AI instructions install journal createdAtUtc must be an ISO 8601 UTC string ending in Z.' }

    Assert-AiInstructionsInstallJournalExactProperties -Object $Journal.owner -Names @('component','processId','processStartIdentity') -Context 'AI instructions install journal owner'
    if ($Journal.owner.component -isnot [string] -or [string]$Journal.owner.component -cnotin @('installer','updater','launcher-recovery')) { throw 'AI instructions install journal owner.component is invalid.' }
    Assert-AiInstructionsInstallJournalInteger -Value $Journal.owner.processId -Context 'AI instructions install journal owner.processId' -Minimum 1
    $processStartIdentityScalarLength = if ($Journal.owner.processStartIdentity -is [string]) {
        Get-AiInstructionsInstallJournalUnicodeScalarLength -Value ([string]$Journal.owner.processStartIdentity) -Context 'AI instructions install journal owner.processStartIdentity'
    } else { -1 }
    if ($Journal.owner.processStartIdentity -isnot [string] -or [string]::IsNullOrEmpty([string]$Journal.owner.processStartIdentity) -or
        $processStartIdentityScalarLength -gt 128 -or [string]$Journal.owner.processStartIdentity -match '[\x00-\x1f\x7f]') {
        throw 'AI instructions install journal owner.processStartIdentity is invalid.'
    }

    Assert-AiInstructionsInstallJournalExactProperties -Object $Journal.platform -Names @('os','architecture') -Context 'AI instructions install journal platform'
    if ($Journal.platform.os -isnot [string] -or [string]$Journal.platform.os -cnotin @('windows','linux','macos')) { throw 'AI instructions install journal platform.os is invalid.' }
    if ($Journal.platform.architecture -isnot [string] -or [string]$Journal.platform.architecture -cnotin @('x64','arm64')) { throw 'AI instructions install journal platform.architecture is invalid.' }

    Assert-AiInstructionsInstallJournalExactProperties -Object $Journal.lock -Names @('primitive','leaf') -Context 'AI instructions install journal lock'
    if ($Journal.lock.primitive -isnot [string] -or [string]$Journal.lock.primitive -cnotin @('windows-fileshare','flock')) { throw 'AI instructions install journal lock.primitive is invalid.' }
    $expectedLockPrimitive = if ([string]$Journal.platform.os -ceq 'windows') { 'windows-fileshare' } else { 'flock' }
    if ([string]$Journal.lock.primitive -cne $expectedLockPrimitive) { throw "AI instructions install journal lock.primitive must be $expectedLockPrimitive for the journal platform." }
    Assert-AiInstructionsInstallJournalLeaf -Value $Journal.lock.leaf -Context 'AI instructions install journal lock.leaf' -PortableName
    $lockLeafKey = Get-AiInstructionsInstallJournalPortableNameKey -Value ([string]$Journal.lock.leaf)
    if ($lockLeafKey -ceq '.AI-INSTRUCTIONS-TXN') {
        throw 'AI instructions install journal lock.leaf must not use the reserved .ai-instructions-txn name.'
    }

    Assert-AiInstructionsInstallJournalExactProperties -Object $Journal.generation -Names @('previousBundleSha256','candidateBundleSha256') -Context 'AI instructions install journal generation'
    if ($null -ne $Journal.generation.previousBundleSha256 -and
        ($Journal.generation.previousBundleSha256 -isnot [string] -or [string]$Journal.generation.previousBundleSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'AI instructions install journal generation.previousBundleSha256 is invalid.'
    }
    if ($Journal.generation.candidateBundleSha256 -isnot [string] -or [string]$Journal.generation.candidateBundleSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'AI instructions install journal generation.candidateBundleSha256 is invalid.'
    }
    if ($Journal.phase -isnot [string] -or [string]$Journal.phase -cnotin @('prepared','applying','applied','rolling-back','rolled-back','committed')) { throw 'AI instructions install journal phase is invalid.' }
    if ($Journal.operations -isnot [System.Array] -or @($Journal.operations).Count -lt 1) { throw 'AI instructions install journal operations must be a non-empty array.' }

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $leaves = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $validatedOperationPaths = New-Object System.Collections.Generic.List[object]
    $expectedIdentityKind = if ([string]$Journal.platform.os -ceq 'windows') { 'windows-file-id' } else { 'unix-device-inode' }
    $expectedSequence = 1
    foreach ($operation in @($Journal.operations)) {
        $context = "AI instructions install journal operation sequence $expectedSequence"
        Assert-AiInstructionsInstallJournalExactProperties -Object $operation -Names @('sequence','kind','method','targetRelativePath','stageLeaf','backupLeaf','quarantineLeaf','original','backupIdentity','applied','permissions','state') -Context $context
        Assert-AiInstructionsInstallJournalInteger -Value $operation.sequence -Context "$context.sequence" -Minimum 1
        if ([int64]$operation.sequence -ne $expectedSequence) { throw "$context.sequence must be $expectedSequence for a continuous sequence." }
        $sequence = [int64]$operation.sequence
        $context = "AI instructions install journal operation sequence $sequence"
        if ($operation.kind -isnot [string] -or [string]$operation.kind -cnotin @('write-file','create-file','remove-file','swap-directory','create-directory')) { throw "$context.kind is invalid." }
        if ($operation.method -isnot [string] -or [string]$operation.method -cnotin @('stage-rename','tombstone-rename')) { throw "$context.method is invalid." }
        if ($operation.state -isnot [string] -or [string]$operation.state -cnotin @('pending','staged','applied','rolled-back')) { throw "$context.state is invalid." }
        if ([string]$operation.kind -ceq 'remove-file' -and [string]$operation.method -cne 'tombstone-rename') { throw "$context.method must be tombstone-rename for remove-file." }
        if ([string]$operation.kind -cne 'remove-file' -and [string]$operation.method -cne 'stage-rename') { throw "$context.method must be stage-rename for $($operation.kind)." }
        $targetPathEndsWithInvalidCharacter = $false
        if ($operation.targetRelativePath -is [string] -and -not [string]::IsNullOrEmpty([string]$operation.targetRelativePath)) {
            foreach ($targetSegment in ([string]$operation.targetRelativePath).Split('/')) {
                if ($targetSegment.Length -gt 0 -and ($targetSegment -match '\.$' -or [char]::IsWhiteSpace($targetSegment[$targetSegment.Length - 1]))) {
                    $targetPathEndsWithInvalidCharacter = $true
                    break
                }
            }
        }
        $targetPathScalarLength = if ($operation.targetRelativePath -is [string]) {
            Get-AiInstructionsInstallJournalUnicodeScalarLength -Value ([string]$operation.targetRelativePath) -Context "$context.targetRelativePath"
        } else { -1 }
        if ($operation.targetRelativePath -isnot [string] -or [string]::IsNullOrEmpty([string]$operation.targetRelativePath) -or
            $targetPathScalarLength -gt 512 -or [string]$operation.targetRelativePath -match '[\\\x00-\x1f\x7f:*?"<>|]' -or
            [string]$operation.targetRelativePath -match '^/' -or [string]$operation.targetRelativePath -match '/$' -or [string]$operation.targetRelativePath -match '^[A-Za-z]:' -or
            [string]$operation.targetRelativePath -match '(^|/)(?:\.|\.\.)(?:/|$)' -or $targetPathEndsWithInvalidCharacter -or
            [string]$operation.targetRelativePath -match '//') {
            throw "$context.targetRelativePath is not a safe transaction-relative path."
        }
        foreach ($segment in ([string]$operation.targetRelativePath).Split('/')) {
            if ([string]::IsNullOrWhiteSpace($segment)) {
                throw "$context.targetRelativePath contains an empty or whitespace-only segment."
            }
            if (Test-AiInstructionsInstallJournalWindowsReservedDeviceName -Value $segment) {
                throw "$context.targetRelativePath contains a Windows reserved device name."
            }
        }
        $firstTargetSegment = ([string]$operation.targetRelativePath).Split('/')[0]
        if ((Get-AiInstructionsInstallJournalPortableNameKey -Value $firstTargetSegment) -ceq '.AI-INSTRUCTIONS-TXN') {
            throw "$context.targetRelativePath must not use the reserved .ai-instructions-txn first segment."
        }
        $pathKey = Get-AiInstructionsInstallJournalPortableNameKey -Value ([string]$operation.targetRelativePath)
        $pathSegments = @(([string]$operation.targetRelativePath).Split('/') | ForEach-Object { Get-AiInstructionsInstallJournalPortableNameKey -Value $_ })
        if ($pathSegments.Count -eq 1 -and $pathKey -ceq $lockLeafKey) {
            throw "$context.targetRelativePath conflicts with lock.leaf after Unicode NFC and invariant case normalization."
        }
        if (-not $paths.Add($pathKey)) { throw "$context.targetRelativePath duplicates another target path after Unicode NFC and invariant case normalization." }
        foreach ($otherPath in $validatedOperationPaths) {
            $prefixLength = [Math]::Min($pathSegments.Count,[int]$otherPath.segments.Count)
            $hasCommonPrefix = $true
            for ($segmentIndex = 0; $segmentIndex -lt $prefixLength; $segmentIndex++) {
                if ([string]$pathSegments[$segmentIndex] -cne [string]$otherPath.segments[$segmentIndex]) {
                    $hasCommonPrefix = $false
                    break
                }
            }
            if ($hasCommonPrefix) {
                throw "$context.targetRelativePath conflicts with operation sequence $($otherPath.sequence) because operation targets cannot have an ancestor or descendant relationship."
            }
        }
        $validatedOperationPaths.Add([pscustomobject][ordered]@{ sequence=$sequence; kind=[string]$operation.kind; segments=$pathSegments }) | Out-Null
        Assert-AiInstructionsInstallJournalLeaf -Value $operation.stageLeaf -Context "$context.stageLeaf" -AllowNull -PortableName
        if ([string]$operation.method -ceq 'stage-rename' -and $null -eq $operation.stageLeaf) {
            throw "$context.stageLeaf must not be null when method is stage-rename."
        }
        if ([string]$operation.method -ceq 'tombstone-rename' -and $null -ne $operation.stageLeaf) {
            throw "$context.stageLeaf must be null when method is tombstone-rename."
        }
        if ([string]$operation.method -ceq 'tombstone-rename' -and [string]$operation.state -ceq 'staged') {
            throw "$context.method tombstone-rename does not allow state staged."
        }
        Assert-AiInstructionsInstallJournalLeaf -Value $operation.backupLeaf -Context "$context.backupLeaf" -AllowNull -PortableName
        if ([string]$operation.kind -in @('create-file','create-directory') -and $null -ne $operation.backupLeaf) {
            throw "$context.backupLeaf must be null for $($operation.kind)."
        }
        Assert-AiInstructionsInstallJournalLeaf -Value $operation.quarantineLeaf -Context "$context.quarantineLeaf" -AllowNull -PortableName
        if ([string]$operation.kind -in @('swap-directory','create-directory')) {
            if ($null -eq $operation.quarantineLeaf) { throw "$context.quarantineLeaf must not be null for $($operation.kind)." }
        }
        elseif ($null -ne $operation.quarantineLeaf) { throw "$context.quarantineLeaf must be null for file operations." }
        foreach ($leaf in @($operation.stageLeaf,$operation.backupLeaf,$operation.quarantineLeaf)) {
            if ($null -ne $leaf) {
                $leafKey = Get-AiInstructionsInstallJournalPortableNameKey -Value ([string]$leaf)
                if ($leafKey -ceq 'JOURNAL' -or $leafKey.StartsWith('JOURNAL.',[StringComparison]::Ordinal)) { throw "$context transaction leaves must not use the reserved journal store namespace." }
                if (-not $leaves.Add($leafKey)) { throw "$context stageLeaf and backupLeaf and quarantineLeaf values must be unique after Unicode NFC and invariant case normalization." }
            }
        }
        $isDirectoryOperation = [string]$operation.kind -in @('swap-directory','create-directory')
        if ($isDirectoryOperation) {
            Assert-AiInstructionsInstallJournalDirectoryState -State $operation.original -Context "$context.original"
            Assert-AiInstructionsInstallJournalDirectoryState -State $operation.applied -Context "$context.applied"
        }
        else {
            Assert-AiInstructionsInstallJournalFileState -State $operation.original -Context "$context.original"
            Assert-AiInstructionsInstallJournalFileState -State $operation.applied -Context "$context.applied"
        }

        switch ([string]$operation.kind) {
            'create-file' { if ($operation.original.exists -or -not $operation.applied.exists) { throw "$context kind create-file requires original.exists=false and applied.exists=true." } }
            'create-directory' { if ($operation.original.exists -or -not $operation.applied.exists) { throw "$context kind create-directory requires original.exists=false and applied.exists=true." } }
            'remove-file' { if (-not $operation.original.exists -or $operation.applied.exists) { throw "$context kind remove-file requires original.exists=true and applied.exists=false." } }
            default { if (-not $operation.original.exists -or -not $operation.applied.exists) { throw "$context kind $($operation.kind) requires original.exists=true and applied.exists=true." } }
        }
        if ($operation.original.exists -and $null -eq $operation.backupLeaf) { throw "$context.backupLeaf must not be null when original.exists is true." }
        Assert-AiInstructionsInstallJournalIdentity -Identity $operation.original.identity -Context "$context.original.identity" -ExpectedKind $expectedIdentityKind -AllowNull:(-not [bool]$operation.original.exists)
        if (-not $operation.original.exists -and $null -ne $operation.original.identity) { throw "$context.original.identity must be null when exists is false." }
        Assert-AiInstructionsInstallJournalIdentity -Identity $operation.backupIdentity -Context "$context.backupIdentity" -ExpectedKind $expectedIdentityKind -AllowNull:(-not [bool]$operation.original.exists)
        if (-not $operation.original.exists -and $null -ne $operation.backupIdentity) { throw "$context.backupIdentity must be null when original.exists is false." }
        if ($operation.original.exists -and
            -not (Test-AiInstructionsInstallJournalIdentityMatch -Observed $operation.backupIdentity -Expected $operation.original.identity)) {
            throw "$context.backupIdentity must equal original.identity because rename preserves identity."
        }
        if ([string]$operation.kind -eq 'create-directory' -and $null -ne $operation.permissions) { throw "$context.permissions must be null for create-directory." }
        if ($operation.original.exists -and $null -eq $operation.permissions) { throw "$context.permissions must not be null when original.exists is true." }
        if ($null -ne $operation.permissions) {
            if ($operation.permissions.kind -isnot [string]) { throw "$context.permissions.kind is invalid." }
            if ([string]$operation.permissions.kind -ceq 'windows-sddl') {
                Assert-AiInstructionsInstallJournalExactProperties -Object $operation.permissions -Names @('kind','sddl','readOnly') -Context "$context.permissions"
                $sddlScalarLength = if ($operation.permissions.sddl -is [string]) {
                    Get-AiInstructionsInstallJournalUnicodeScalarLength -Value ([string]$operation.permissions.sddl) -Context "$context.permissions.sddl"
                } else { -1 }
                if ($operation.permissions.sddl -isnot [string] -or [string]::IsNullOrEmpty([string]$operation.permissions.sddl) -or
                    $sddlScalarLength -gt 4096 -or [string]$operation.permissions.sddl -match '[\x00-\x1f\x7f]' -or
                    [string]$operation.permissions.sddl -notmatch '^D:' -or [string]$operation.permissions.sddl -match '[OGS]:') {
                    throw "$context.permissions.sddl must contain only a DACL SDDL policy."
                }
                if ($operation.permissions.readOnly -isnot [bool]) { throw "$context.permissions.readOnly must be a boolean." }
            }
            elseif ([string]$operation.permissions.kind -ceq 'unix-mode') {
                Assert-AiInstructionsInstallJournalExactProperties -Object $operation.permissions -Names @('kind','mode','uid','gid') -Context "$context.permissions"
                if ($operation.permissions.mode -isnot [string] -or [string]$operation.permissions.mode -cnotmatch '^[0-7]{3,4}$') { throw "$context.permissions.mode is invalid." }
                Assert-AiInstructionsInstallJournalInteger -Value $operation.permissions.uid -Context "$context.permissions.uid" -Minimum 0
                Assert-AiInstructionsInstallJournalInteger -Value $operation.permissions.gid -Context "$context.permissions.gid" -Minimum 0
            }
            else { throw "$context.permissions.kind is invalid." }
            $expectedPermissionsKind = if ([string]$Journal.platform.os -ceq 'windows') { 'windows-sddl' } else { 'unix-mode' }
            if ([string]$operation.permissions.kind -cne $expectedPermissionsKind) { throw "$context.permissions.kind must be $expectedPermissionsKind for the journal platform." }
        }
        $appliedIdentityMayBeNull = -not [bool]$operation.applied.exists
        Assert-AiInstructionsInstallJournalIdentity -Identity $operation.applied.identity -Context "$context.applied.identity" -ExpectedKind $expectedIdentityKind -AllowNull:$appliedIdentityMayBeNull
        if (-not $operation.applied.exists -and $null -ne $operation.applied.identity) { throw "$context.applied.identity must be null when exists is false." }
        if ([string]$Journal.phase -ceq 'prepared' -and [string]$operation.state -cnotin @('pending','staged')) { throw "$context.state is inconsistent with phase prepared." }
        if ([string]$Journal.phase -in @('applied','committed') -and [string]$operation.state -cne 'applied') { throw "$context.state is inconsistent with phase $($Journal.phase)." }
        if ([string]$Journal.phase -ceq 'rolled-back' -and [string]$operation.state -cnotin @('pending','staged','rolled-back')) { throw "$context.state is inconsistent with phase rolled-back." }
        $expectedSequence++
    }
    return $Journal
}

function Assert-AiInstructionsInstallJournalUnambiguousJson {
    param([Parameter(Mandatory = $true)][string] $Json)
    $tokenRegex = New-Object Text.RegularExpressions.Regex('\G\s*(?:"(?:\\.|[^"\\])*"|[{}\[\],:]|[^{}\[\],:\s]+)',[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromSeconds(2))
    $stack = New-Object System.Collections.ArrayList
    [void]$stack.Add([pscustomobject]@{ kind='root'; mode='value'; seen=$null })
    $position = 0
    try {
        while ($position -lt $Json.Length) {
            $match = $tokenRegex.Match($Json,$position)
            if (-not $match.Success -or $match.Index -ne $position) {
                if ([string]::IsNullOrWhiteSpace($Json.Substring($position))) { break }
                throw 'AI instructions install journal JSON token is invalid.'
            }
            $token = $match.Value.TrimStart()
            $position += $match.Length
            if ($token.StartsWith('"',[StringComparison]::Ordinal)) {
                Assert-AiInstructionsInstallJournalJsonStringUnicode -Token $token
            }
            $frame = $stack[$stack.Count - 1]
            if ($token -ceq '}' -or $token -ceq ']') {
                if ($frame.kind -ceq 'root' -or ($token -ceq '}' -and $frame.kind -cne 'object') -or ($token -ceq ']' -and $frame.kind -cne 'array') -or
                    $frame.mode -notin @('keyOrEnd','valueOrEnd','commaOrEnd')) { throw 'AI instructions install journal JSON structure is invalid.' }
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            if ($token -ceq ',') {
                if ($frame.mode -cne 'commaOrEnd') { throw 'AI instructions install journal JSON comma is invalid.' }
                $frame.mode = if ($frame.kind -ceq 'object') { 'key' } else { 'value' }
                continue
            }
            if ($token -ceq ':') {
                if ($frame.kind -cne 'object' -or $frame.mode -cne 'colon') { throw 'AI instructions install journal JSON colon is invalid.' }
                $frame.mode = 'value'
                continue
            }
            if ($frame.kind -ceq 'object' -and $frame.mode -in @('key','keyOrEnd')) {
                if (-not $token.StartsWith('"',[StringComparison]::Ordinal)) { throw 'AI instructions install journal JSON key is invalid.' }
                try { $key = [string](ConvertFrom-Json -InputObject ('{"key":' + $token + '}') -ErrorAction Stop).key }
                catch { throw 'AI instructions install journal JSON key is invalid.' }
                if (-not $frame.seen.Add($key)) { throw "AI instructions install journal JSON contains duplicate key '$key'." }
                $frame.mode = 'colon'
                continue
            }
            if ($frame.mode -cne 'value' -and $frame.mode -cne 'valueOrEnd') { throw 'AI instructions install journal JSON value is invalid.' }
            $frame.mode = if ($frame.kind -ceq 'root') { 'done' } else { 'commaOrEnd' }
            if ($token -ceq '{') { [void]$stack.Add([pscustomobject]@{ kind='object'; mode='keyOrEnd'; seen=(New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)) }) }
            elseif ($token -ceq '[') { [void]$stack.Add([pscustomobject]@{ kind='array'; mode='valueOrEnd'; seen=$null }) }
        }
    }
    catch {
        if ($_.Exception.Message -like 'AI instructions install journal JSON*') { throw }
        throw 'AI instructions install journal JSON token scan failed.'
    }
    if ($stack.Count -ne 1 -or $stack[0].mode -cne 'done') { throw 'AI instructions install journal JSON is incomplete.' }
}

function Assert-AiInstructionsInstallJournalJsonStringUnicode {
    param([Parameter(Mandatory = $true)][string] $Token)
    $end = $Token.Length - 1
    for ($index = 1; $index -lt $end;) {
        $unit = $Token[$index]
        if ($unit -eq '\') {
            if ($index + 1 -ge $end) { return }
            if ($Token[$index + 1] -ne 'u' -or $index + 5 -ge $end) {
                $index += 2
                continue
            }
            $hex = $Token.Substring($index + 2,4)
            if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { return }
            $escapedUnit = [char][Convert]::ToInt32($hex,16)
            if ([char]::IsHighSurrogate($escapedUnit)) {
                $nextEscapeIndex = $index + 6
                if ($nextEscapeIndex + 5 -ge $end -or $Token[$nextEscapeIndex] -ne '\' -or $Token[$nextEscapeIndex + 1] -ne 'u') {
                    throw 'AI instructions install journal JSON string contains an invalid unpaired Unicode surrogate.'
                }
                $lowHex = $Token.Substring($nextEscapeIndex + 2,4)
                if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$' -or -not [char]::IsLowSurrogate([char][Convert]::ToInt32($lowHex,16))) {
                    throw 'AI instructions install journal JSON string contains an invalid unpaired Unicode surrogate.'
                }
                $index += 12
                continue
            }
            if ([char]::IsLowSurrogate($escapedUnit)) {
                throw 'AI instructions install journal JSON string contains an invalid unpaired Unicode surrogate.'
            }
            $index += 6
            continue
        }
        if ([char]::IsHighSurrogate($unit)) {
            if ($index + 1 -ge $end -or -not [char]::IsLowSurrogate($Token[$index + 1])) {
                throw 'AI instructions install journal JSON string contains an invalid unpaired Unicode surrogate.'
            }
            $index += 2
            continue
        }
        if ([char]::IsLowSurrogate($unit)) {
            throw 'AI instructions install journal JSON string contains an invalid unpaired Unicode surrogate.'
        }
        $index++
    }
}

function ConvertFrom-AiInstructionsInstallJournalV1Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)][string] $Json,
        [string] $ExpectedTransactionId
    )
    process {
        Assert-AiInstructionsInstallJournalUnambiguousJson -Json $Json
        $convertParameters = @{ InputObject=$Json; ErrorAction='Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $convertParameters.DateKind = 'String' }
        try { $journal = ConvertFrom-Json @convertParameters }
        catch { throw 'AI instructions install journal JSON is invalid.' }
        if ($null -eq $journal -or $journal -is [System.Array] -or $journal -is [string] -or $journal -is [ValueType]) { throw 'AI instructions install journal JSON root must be an object.' }
        $journal = Assert-AiInstructionsInstallJournalV1 -Journal $journal
        if ($PSBoundParameters.ContainsKey('ExpectedTransactionId') -and [string]$journal.transactionId -cne $ExpectedTransactionId) {
            throw 'AI instructions install journal transactionId does not match the expected transaction directory.'
        }
        Write-Output $journal
    }
}

function Test-AiInstructionsJsonNumber {
    param([Parameter(Mandatory = $true)][object] $Value)
    return [Type]::GetTypeCode($Value.GetType()) -in @(
        [TypeCode]::Byte,[TypeCode]::SByte,[TypeCode]::Int16,[TypeCode]::UInt16,
        [TypeCode]::Int32,[TypeCode]::UInt32,[TypeCode]::Int64,[TypeCode]::UInt64,
        [TypeCode]::Single,[TypeCode]::Double,[TypeCode]::Decimal
    )
}

function Get-AiInstructionsJsonObjectProperties {
    param([Parameter(Mandatory = $true)][object] $Value)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { [pscustomobject]@{ Name=[string]$key; Value=$Value[$key] } }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        [pscustomobject]@{ Name=[string]$property.Name; Value=$property.Value }
    }
}

function Test-AiInstructionsJsonSemanticEqual {
    param([AllowNull()][object] $Left,[AllowNull()][object] $Right)
    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }

    $leftIsNumber = Test-AiInstructionsJsonNumber -Value $Left
    $rightIsNumber = Test-AiInstructionsJsonNumber -Value $Right
    if ($leftIsNumber -or $rightIsNumber) {
        if (-not ($leftIsNumber -and $rightIsNumber)) { return $false }
        try { return [decimal]$Left -eq [decimal]$Right }
        catch { return $false }
    }
    if ($Left -is [string] -or $Right -is [string]) {
        return $Left -is [string] -and $Right -is [string] -and
            [string]::Equals([string]$Left,[string]$Right,[StringComparison]::Ordinal)
    }
    if ($Left -is [bool] -or $Right -is [bool]) {
        return $Left -is [bool] -and $Right -is [bool] -and [bool]$Left -eq [bool]$Right
    }
    $leftIsArray = $Left -is [System.Collections.IList]
    $rightIsArray = $Right -is [System.Collections.IList]
    if ($leftIsArray -or $rightIsArray) {
        if (-not ($leftIsArray -and $rightIsArray) -or $Left.Count -ne $Right.Count) { return $false }
        for ($index = 0; $index -lt $Left.Count; $index++) {
            if (-not (Test-AiInstructionsJsonSemanticEqual -Left $Left[$index] -Right $Right[$index])) { return $false }
        }
        return $true
    }
    $leftIsObject = $Left -is [System.Collections.IDictionary] -or $Left -is [Management.Automation.PSCustomObject]
    $rightIsObject = $Right -is [System.Collections.IDictionary] -or $Right -is [Management.Automation.PSCustomObject]
    if ($leftIsObject -or $rightIsObject) {
        if (-not ($leftIsObject -and $rightIsObject)) { return $false }
        $leftProperties = @(Get-AiInstructionsJsonObjectProperties -Value $Left)
        $rightProperties = @(Get-AiInstructionsJsonObjectProperties -Value $Right)
        if ($leftProperties.Count -ne $rightProperties.Count) { return $false }
        foreach ($leftProperty in $leftProperties) {
            $rightProperty = @($rightProperties | Where-Object { [string]::Equals($_.Name,$leftProperty.Name,[StringComparison]::Ordinal) })
            if ($rightProperty.Count -ne 1 -or -not (Test-AiInstructionsJsonSemanticEqual -Left $leftProperty.Value -Right $rightProperty[0].Value)) { return $false }
        }
        return $true
    }
    return $Left.GetType() -eq $Right.GetType() -and $Left.Equals($Right)
}

function Assert-AiInstructionsInstallJournalStoreTransition {
    param([Parameter(Mandatory = $true)][object] $Previous,[Parameter(Mandatory = $true)][object] $Next)
    Assert-AiInstructionsInstallJournalV1 -Journal $Previous | Out-Null
    Assert-AiInstructionsInstallJournalV1 -Journal $Next | Out-Null
    foreach ($name in @('schemaVersion','kind','transactionId','createdAtUtc','owner','platform','lock','generation')) {
        if (-not (Test-AiInstructionsJsonSemanticEqual -Left $Previous.PSObject.Properties[$name].Value -Right $Next.PSObject.Properties[$name].Value)) {
            throw "AI instructions install journal store transition cannot change $name."
        }
    }
    if (@($Previous.operations).Count -ne @($Next.operations).Count) { throw 'AI instructions install journal store transition cannot change operations count.' }
    for ($index = 0; $index -lt @($Previous.operations).Count; $index++) {
        $previousOperation = [ordered]@{}
        $nextOperation = [ordered]@{}
        foreach ($property in @($Previous.operations[$index].PSObject.Properties)) { if ($property.Name -cne 'state') { $previousOperation[$property.Name] = $property.Value } }
        foreach ($property in @($Next.operations[$index].PSObject.Properties)) { if ($property.Name -cne 'state') { $nextOperation[$property.Name] = $property.Value } }
        if (-not (Test-AiInstructionsJsonSemanticEqual -Left ([pscustomobject]$previousOperation) -Right ([pscustomobject]$nextOperation))) { throw "AI instructions install journal store transition cannot change operation $($index + 1) fields other than state." }
        $fromState = [string]$Previous.operations[$index].state
        $toState = [string]$Next.operations[$index].state
        $allowedState = $fromState -ceq $toState -or
            "$fromState>$toState" -cin @('pending>staged','staged>applied','pending>applied','applied>rolled-back','pending>rolled-back','staged>rolled-back')
        if (-not $allowedState) { throw "AI instructions install journal store transition operation $($index + 1) state transition is invalid." }
    }
    $fromPhase = [string]$Previous.phase
    $toPhase = [string]$Next.phase
    $allowedPhase = $fromPhase -ceq $toPhase -or
        "$fromPhase>$toPhase" -cin @('prepared>applying','applying>applied','applied>committed','prepared>rolling-back','applying>rolling-back','applied>rolling-back','rolling-back>rolled-back')
    if (-not $allowedPhase) { throw 'AI instructions install journal store phase transition is invalid.' }
    return $Next
}

function Get-AiInstructionsInstallTransactionClassification {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $EntryKind,
        [AllowNull()][object] $JournalEntryKind,
        [AllowNull()][object] $JournalJson,
        [AllowNull()][object] $PreviousJournalEntryKind,
        [AllowNull()][object] $PreviousJournalJson
    )
    if ($Name -cnotmatch '^[0-9a-f]{32}$' -or $EntryKind -cne 'directory') {
        return [pscustomobject][ordered]@{ classification='invalid-name'; journalLeaf=$null; journal=$null; reason='invalid transaction directory name or entry kind' }
    }
    $journalExists = $null -ne $JournalEntryKind
    $previousExists = $null -ne $PreviousJournalEntryKind
    if (-not $journalExists -and -not $previousExists) {
        return [pscustomobject][ordered]@{ classification='orphan-without-journal'; journalLeaf=$null; journal=$null; reason='journal is absent' }
    }
    $leaf = if ($journalExists) { 'journal.json' } else { 'journal.prev' }
    $kind = if ($journalExists) { $JournalEntryKind } else { $PreviousJournalEntryKind }
    $json = if ($journalExists) { $JournalJson } else { $PreviousJournalJson }
    if ($kind -isnot [string] -or [string]$kind -cne 'file' -or $json -isnot [string]) {
        return [pscustomobject][ordered]@{ classification='malformed-journal'; journalLeaf=$leaf; journal=$null; reason='journal entry is not a file' }
    }
    try { $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json -ExpectedTransactionId $Name }
    catch { return [pscustomobject][ordered]@{ classification='malformed-journal'; journalLeaf=$leaf; journal=$null; reason='journal validation failed' } }
    if ($journalExists -and $previousExists) {
        if ($PreviousJournalEntryKind -isnot [string] -or [string]$PreviousJournalEntryKind -cne 'file' -or $PreviousJournalJson -isnot [string]) {
            return [pscustomobject][ordered]@{ classification='malformed-journal'; journalLeaf='journal.json'; journal=$null; reason='previous journal entry is not a file' }
        }
        try { $previousJournal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json $PreviousJournalJson -ExpectedTransactionId $Name }
        catch { return [pscustomobject][ordered]@{ classification='malformed-journal'; journalLeaf='journal.json'; journal=$null; reason='previous journal validation failed' } }
        try { Assert-AiInstructionsInstallJournalStoreTransition -Previous $previousJournal -Next $journal | Out-Null }
        catch { return [pscustomobject][ordered]@{ classification='malformed-journal'; journalLeaf='journal.json'; journal=$null; reason='journal transition from previous journal is invalid' } }
    }
    return [pscustomobject][ordered]@{ classification='valid-journal'; journalLeaf=$leaf; journal=$journal; reason=$null }
}

function Get-AiInstructionsInstallTransactionResidueKind {
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

function Get-AiInstructionsInstallTransactionDisposition {
    param(
        [Parameter(Mandatory = $true)][string] $Classification,
        [Parameter(Mandatory = $true)][string] $Component
    )
    if ($Classification -cnotin @('valid-journal','orphan-without-journal','malformed-journal','invalid-name','journal-present')) { throw "Unknown install transaction classification '$Classification'." }
    if ($Component -cnotin @('installer','launcher','updater')) { throw "Unknown install transaction component '$Component'." }
    if ($Component -cne 'installer') { return [pscustomobject][ordered]@{ action='refuse'; refusalCode='interrupted-install' } }
    switch ($Classification) {
        'valid-journal' { return [pscustomobject][ordered]@{ action='recover'; refusalCode=$null } }
        'orphan-without-journal' { return [pscustomobject][ordered]@{ action='purge-orphan'; refusalCode=$null } }
        default { return [pscustomobject][ordered]@{ action='refuse'; refusalCode='interrupted-install' } }
    }
}

function New-AiInstructionsInstallJournalV1 {
    [CmdletBinding()]
    param(
        [string] $TransactionId = [guid]::NewGuid().ToString('N'),
        [string] $CreatedAtUtc = [datetime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture),
        [Parameter(Mandatory = $true)][string] $OwnerComponent,
        [Parameter(Mandatory = $true)][long] $OwnerProcessId,
        [Parameter(Mandatory = $true)][string] $OwnerProcessStartIdentity,
        [Parameter(Mandatory = $true)][string] $PlatformOs,
        [Parameter(Mandatory = $true)][string] $PlatformArchitecture,
        [Parameter(Mandatory = $true)][ValidateSet('windows-fileshare','flock')][string] $LockPrimitive,
        [Parameter(Mandatory = $true)][string] $LockLeaf,
        [AllowNull()][object] $PreviousBundleSha256 = $null,
        [Parameter(Mandatory = $true)][string] $CandidateBundleSha256,
        [Parameter(Mandatory = $true)][string] $Phase,
        [Parameter(Mandatory = $true)][object[]] $Operations
    )
    $journal = [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'ai-instructions-install-transaction'
        transactionId = $TransactionId
        createdAtUtc = $CreatedAtUtc
        owner = [pscustomobject][ordered]@{ component=$OwnerComponent; processId=$OwnerProcessId; processStartIdentity=$OwnerProcessStartIdentity }
        platform = [pscustomobject][ordered]@{ os=$PlatformOs; architecture=$PlatformArchitecture }
        lock = [pscustomobject][ordered]@{ primitive=$LockPrimitive; leaf=$LockLeaf }
        generation = [pscustomobject][ordered]@{ previousBundleSha256=$PreviousBundleSha256; candidateBundleSha256=$CandidateBundleSha256 }
        phase = $Phase
        operations = @($Operations)
    }
    return (Assert-AiInstructionsInstallJournalV1 -Journal $journal)
}

function Test-AiInstructionsInstallJournalIdentityMatch {
    param([Parameter(Mandatory = $true)][object] $Observed,[Parameter(Mandatory = $true)][object] $Expected)
    return [string]$Observed.kind -ceq [string]$Expected.kind -and
        ([string]$Observed.device).ToLowerInvariant() -ceq ([string]$Expected.device).ToLowerInvariant() -and
        ([string]$Observed.fileId).ToLowerInvariant() -ceq ([string]$Expected.fileId).ToLowerInvariant()
}

function Test-AiInstructionsInstallJournalStateMatch {
    param(
        [Parameter(Mandatory = $true)][object] $Observation,
        [Parameter(Mandatory = $true)][object] $State,
        [AllowNull()][object] $AlternativeIdentity = $null
    )
    if ([bool]$Observation.exists -ne [bool]$State.exists) { return $false }
    if (-not [bool]$State.exists) { return $true }
    if ($null -eq $State.identity) { return $false }
    if (Test-AiInstructionsObjectHasProperty -Object $State -Name 'inventorySha256') {
        if ([string]$Observation.inventorySha256 -cne [string]$State.inventorySha256 -or [int64]$Observation.entryCount -ne [int64]$State.entryCount) { return $false }
    }
    elseif ([string]$Observation.sha256 -cne [string]$State.sha256 -or [int64]$Observation.length -ne [int64]$State.length) { return $false }
    if (Test-AiInstructionsInstallJournalIdentityMatch -Observed $Observation.identity -Expected $State.identity) { return $true }
    return $null -ne $AlternativeIdentity -and
        (Test-AiInstructionsInstallJournalIdentityMatch -Observed $Observation.identity -Expected $AlternativeIdentity)
}

function Test-AiInstructionsInstallJournalPermissionsMatch {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Observation,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Permissions
    )
    if ($null -eq $Observation -or $null -eq $Permissions -or $null -eq $Observation.permissions) { return $false }
    if ([string]$Permissions.kind -ceq 'windows-sddl') {
        return [string]$Observation.permissions.sddl -ceq [string]$Permissions.sddl -and
            [bool]$Observation.permissions.readOnly -eq [bool]$Permissions.readOnly
    }
    $observedMode = ([string]$Observation.permissions.mode).TrimStart('0')
    $expectedMode = ([string]$Permissions.mode).TrimStart('0')
    if ([string]::IsNullOrEmpty($observedMode)) { $observedMode = '0' }
    if ([string]::IsNullOrEmpty($expectedMode)) { $expectedMode = '0' }
    return [int]$observedMode -eq [int]$expectedMode -and
        [int64]$Observation.permissions.uid -eq [int64]$Permissions.uid -and
        [int64]$Observation.permissions.gid -eq [int64]$Permissions.gid
}

function Test-AiInstructionsInstallJournalBackupMatch {
    param(
        [AllowNull()][object] $Backup,
        [Parameter(Mandatory = $true)][object] $Original,
        [AllowNull()][object] $BackupIdentity
    )
    if ($null -eq $Backup -or $null -eq $BackupIdentity -or -not [bool]$Backup.exists) { return $false }
    $contentMatches = if (Test-AiInstructionsObjectHasProperty -Object $Original -Name 'inventorySha256') {
        [string]$Backup.inventorySha256 -ceq [string]$Original.inventorySha256 -and [int64]$Backup.entryCount -eq [int64]$Original.entryCount
    }
    else { [string]$Backup.sha256 -ceq [string]$Original.sha256 -and [int64]$Backup.length -eq [int64]$Original.length }
    return $contentMatches -and (Test-AiInstructionsInstallJournalIdentityMatch -Observed $Backup.identity -Expected $BackupIdentity)
}

function Test-AiInstructionsInstallJournalBackupEvidenceValid {
    param(
        [Parameter(Mandatory = $true)][object] $Operation,
        [Parameter(Mandatory = $true)][object] $Observation
    )
    if ([string]$Operation.kind -in @('create-file','create-directory')) { return $null -eq $Observation.backup }
    if ($null -eq $Observation.backup) { return $true }
    return Test-AiInstructionsInstallJournalBackupMatch -Backup $Observation.backup -Original $Operation.original -BackupIdentity $Operation.backupIdentity
}

function Get-AiInstructionsInstallRecoveryDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Journal,[Parameter(Mandatory = $true)][object] $Observations)
    Assert-AiInstructionsInstallJournalV1 -Journal $Journal | Out-Null
    $expectedIdentityKind = if ([string]$Journal.platform.os -ceq 'windows') { 'windows-file-id' } else { 'unix-device-inode' }
    $expectedPermissionsKind = if ([string]$Journal.platform.os -ceq 'windows') { 'windows-sddl' } else { 'unix-mode' }
    if ($null -eq $Observations -or $Observations -is [string] -or $Observations -is [ValueType] -or $Observations -is [System.Array]) { throw 'AI instructions install recovery observations must be keyed by sequence.' }
    $observationProperties = @(if ($Observations -is [System.Collections.IDictionary]) { $Observations.Keys } else { $Observations.PSObject.Properties.Name })
    if ($observationProperties.Count -ne @($Journal.operations).Count) { throw 'AI instructions install recovery observations must correspond one-to-one with journal operations.' }
    $bySequence = @{}
    foreach ($keyValue in $observationProperties) {
        $key = [string]$keyValue
        if ($key -cnotmatch '^[1-9][0-9]*$') { throw "AI instructions install recovery observation key '$key' is not a valid sequence." }
        $sequence = [int64]$key
        if ($bySequence.ContainsKey($sequence)) { throw "AI instructions install recovery observations contain duplicate sequence $sequence." }
        $value = if ($Observations -is [System.Collections.IDictionary]) { $Observations[$keyValue] } else { $Observations.PSObject.Properties[$key].Value }
        $operation = @($Journal.operations | Where-Object { [int64]$_.sequence -eq $sequence })[0]
        if ($null -eq $operation) { throw "AI instructions install recovery observation sequence $sequence is not present in the journal." }
        $isDirectoryOperation = [string]$operation.kind -in @('swap-directory','create-directory')
        $observationNames = if ($isDirectoryOperation) { @('exists','identity','inventorySha256','entryCount','permissions','backup') } else { @('exists','sha256','length','identity','permissions','backup') }
        Assert-AiInstructionsInstallJournalExactProperties -Object $value -Names $observationNames -Context "AI instructions install recovery observation sequence $sequence"
        if ($value.exists -isnot [bool]) { throw "AI instructions install recovery observation sequence $sequence.exists must be a boolean." }
        if ($value.exists) {
            if ($isDirectoryOperation) {
                if ($value.inventorySha256 -isnot [string] -or [string]$value.inventorySha256 -cnotmatch '^[0-9a-f]{64}$') { throw "AI instructions install recovery observation sequence $sequence.inventorySha256 is invalid." }
                Assert-AiInstructionsInstallJournalInteger -Value $value.entryCount -Context "AI instructions install recovery observation sequence $sequence.entryCount" -Minimum 0
            }
            else {
                if ($value.sha256 -isnot [string] -or [string]$value.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "AI instructions install recovery observation sequence $sequence.sha256 is invalid." }
                Assert-AiInstructionsInstallJournalInteger -Value $value.length -Context "AI instructions install recovery observation sequence $sequence.length" -Minimum 0
            }
            Assert-AiInstructionsInstallJournalIdentity -Identity $value.identity -Context "AI instructions install recovery observation sequence $sequence.identity" -ExpectedKind $expectedIdentityKind
            if ($null -eq $value.permissions) { throw "AI instructions install recovery observation sequence $sequence.permissions must not be null when exists is true." }
            if ($value.permissions.kind -isnot [string] -or [string]$value.permissions.kind -cne $expectedPermissionsKind) { throw "AI instructions install recovery observation sequence $sequence.permissions.kind must be $expectedPermissionsKind for the journal platform." }
            if ($expectedPermissionsKind -ceq 'windows-sddl') {
                Assert-AiInstructionsInstallJournalExactProperties -Object $value.permissions -Names @('kind','sddl','readOnly') -Context "AI instructions install recovery observation sequence $sequence.permissions"
                $sddlScalarLength = if ($value.permissions.sddl -is [string]) {
                    Get-AiInstructionsInstallJournalUnicodeScalarLength -Value ([string]$value.permissions.sddl) -Context "AI instructions install recovery observation sequence $sequence.permissions.sddl"
                } else { -1 }
                if ($value.permissions.sddl -isnot [string] -or [string]::IsNullOrEmpty([string]$value.permissions.sddl) -or
                    $sddlScalarLength -gt 4096 -or [string]$value.permissions.sddl -match '[\x00-\x1f\x7f]' -or
                    [string]$value.permissions.sddl -notmatch '^D:' -or [string]$value.permissions.sddl -match '[OGS]:') {
                    throw "AI instructions install recovery observation sequence $sequence.permissions.sddl must contain only a DACL SDDL policy."
                }
                if ($value.permissions.readOnly -isnot [bool]) { throw "AI instructions install recovery observation sequence $sequence.permissions.readOnly must be a boolean." }
            }
            else {
                Assert-AiInstructionsInstallJournalExactProperties -Object $value.permissions -Names @('kind','mode','uid','gid') -Context "AI instructions install recovery observation sequence $sequence.permissions"
                if ($value.permissions.mode -isnot [string] -or [string]$value.permissions.mode -cnotmatch '^[0-7]{3,4}$') { throw "AI instructions install recovery observation sequence $sequence.permissions.mode is invalid." }
                Assert-AiInstructionsInstallJournalInteger -Value $value.permissions.uid -Context "AI instructions install recovery observation sequence $sequence.permissions.uid" -Minimum 0
                Assert-AiInstructionsInstallJournalInteger -Value $value.permissions.gid -Context "AI instructions install recovery observation sequence $sequence.permissions.gid" -Minimum 0
            }
        }
        elseif (($isDirectoryOperation -and ($null -ne $value.inventorySha256 -or $null -ne $value.entryCount)) -or
            (-not $isDirectoryOperation -and ($null -ne $value.sha256 -or $null -ne $value.length)) -or
            $null -ne $value.identity -or $null -ne $value.permissions) { throw "AI instructions install recovery observation sequence $sequence state fields must be null when exists is false." }
        if ($null -ne $value.backup) {
            if ($isDirectoryOperation) { Assert-AiInstructionsInstallJournalDirectoryState -State $value.backup -Context "AI instructions install recovery observation sequence $sequence.backup" }
            else { Assert-AiInstructionsInstallJournalFileState -State $value.backup -Context "AI instructions install recovery observation sequence $sequence.backup" }
            if (-not [bool]$value.backup.exists) { throw "AI instructions install recovery observation sequence $sequence.backup.exists must be true when backup is not null." }
            Assert-AiInstructionsInstallJournalIdentity -Identity $value.backup.identity -Context "AI instructions install recovery observation sequence $sequence.backup.identity" -ExpectedKind $expectedIdentityKind
        }
        $bySequence[$sequence] = $value
    }
    foreach ($operation in @($Journal.operations)) {
        if (-not $bySequence.ContainsKey([int64]$operation.sequence)) { throw "AI instructions install recovery observations are missing sequence $($operation.sequence)." }
    }

    $matchesApplied = @{}
    $matchesOriginal = @{}
    $permissionsMatchOriginal = @{}
    $backupMatchesOriginal = @{}
    $backupEvidenceValid = @{}
    foreach ($operation in @($Journal.operations)) {
        $sequence = [int64]$operation.sequence
        $matchesApplied[$sequence] = Test-AiInstructionsInstallJournalStateMatch -Observation $bySequence[$sequence] -State $operation.applied
        $matchesOriginal[$sequence] = Test-AiInstructionsInstallJournalStateMatch -Observation $bySequence[$sequence] -State $operation.original -AlternativeIdentity $operation.backupIdentity
        $backupMatchesOriginal[$sequence] = Test-AiInstructionsInstallJournalBackupMatch -Backup $bySequence[$sequence].backup -Original $operation.original -BackupIdentity $operation.backupIdentity
        $backupEvidenceValid[$sequence] = Test-AiInstructionsInstallJournalBackupEvidenceValid -Operation $operation -Observation $bySequence[$sequence]
        if ([string]$operation.kind -ceq 'remove-file' -and -not [bool]$bySequence[$sequence].exists) {
            if ([string]$Journal.phase -ceq 'committed') {
                $matchesApplied[$sequence] = ($null -eq $bySequence[$sequence].backup -or $backupMatchesOriginal[$sequence])
            }
            else {
                $matchesApplied[$sequence] = $backupMatchesOriginal[$sequence]
            }
        }
        $permissionsMatchOriginal[$sequence] = $true
        if ([string]$Journal.phase -cne 'committed' -and $matchesOriginal[$sequence] -and [bool]$operation.original.exists -and $null -ne $operation.permissions) {
            $permissionsMatchOriginal[$sequence] = Test-AiInstructionsInstallJournalPermissionsMatch -Observation $bySequence[$sequence] -Permissions $operation.permissions
        }
    }
    $allApplied = @($Journal.operations | Where-Object { -not $matchesApplied[[int64]$_.sequence] }).Count -eq 0
    $allOriginal = @($Journal.operations | Where-Object { -not $matchesOriginal[[int64]$_.sequence] }).Count -eq 0
    $allBackupEvidenceValid = @($Journal.operations | Where-Object { -not $backupEvidenceValid[[int64]$_.sequence] }).Count -eq 0
    if (-not $allBackupEvidenceValid) {
        $reasons = New-Object System.Collections.Generic.List[string]
        foreach ($operation in @($Journal.operations)) {
            $sequence = [int64]$operation.sequence
            if ($backupEvidenceValid[$sequence]) { continue }
            if ([string]$operation.kind -in @('create-file','create-directory')) { $reasons.Add("sequence $sequence backup must be null for $($operation.kind)") }
            elseif ([string]$operation.kind -ceq 'remove-file') { $reasons.Add("sequence $sequence tombstone backup does not match original") }
            else { $reasons.Add("sequence $sequence backup does not match original") }
        }
        return [pscustomobject][ordered]@{ action='refuse'; reasons=$reasons.ToArray(); operations=@($Journal.operations | ForEach-Object { [pscustomobject][ordered]@{ sequence=[int64]$_.sequence; action='keep' } }) }
    }
    if ([string]$Journal.phase -in @('committed','rolled-back')) {
        $allOriginalPermissions = @($Journal.operations | Where-Object { -not $permissionsMatchOriginal[[int64]$_.sequence] }).Count -eq 0
        $matchesTerminal = if ([string]$Journal.phase -ceq 'committed') { $allApplied } else { $allOriginal -and $allOriginalPermissions }
        $terminalAction = if ($matchesTerminal) { 'none' } else { 'refuse' }
        $reasons = New-Object System.Collections.Generic.List[string]
        if (-not $matchesTerminal) { $reasons.Add("phase $($Journal.phase) observations do not match the expected terminal state") }
        if ([string]$Journal.phase -ceq 'rolled-back') {
            foreach ($operation in @($Journal.operations)) {
                $sequence = [int64]$operation.sequence
                if (-not $permissionsMatchOriginal[$sequence]) { $reasons.Add("sequence $sequence permissions do not match original") }
            }
        }
        return [pscustomobject][ordered]@{ action=$terminalAction; reasons=$reasons.ToArray(); operations=@($Journal.operations | ForEach-Object { [pscustomobject][ordered]@{ sequence=[int64]$_.sequence; action='keep' } }) }
    }
    if ([string]$Journal.phase -ceq 'applied' -and $allApplied) {
        return [pscustomobject][ordered]@{ action='commit'; reasons=@(); operations=@($Journal.operations | ForEach-Object { [pscustomobject][ordered]@{ sequence=[int64]$_.sequence; action='keep' } }) }
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    $operationDecisions = New-Object System.Collections.Generic.List[object]
    $mustRefuse = $false
    foreach ($operation in @($Journal.operations)) {
        $sequence = [int64]$operation.sequence
        $action = 'none'
        if ($matchesOriginal[$sequence]) {
            $action = if ($permissionsMatchOriginal[$sequence]) { 'none' } else { 'restore-permissions' }
        }
        elseif ([string]$operation.kind -in @('write-file','swap-directory') -and
            [bool]$operation.original.exists -and -not [bool]$bySequence[$sequence].exists -and
            $backupMatchesOriginal[$sequence]) {
            $action = 'restore-original'
        }
        elseif ($matchesApplied[$sequence]) {
            if ($operation.original.exists) {
                if (-not $backupMatchesOriginal[$sequence]) {
                    $mustRefuse = $true
                    $action = 'keep'
                    $reasons.Add("sequence $sequence cannot restore original because backup is unavailable or does not match original")
                }
                else { $action = 'restore-original' }
            }
            else { $action = 'remove-applied' }
        }
        else {
            $mustRefuse = $true
            $action = 'keep'
            $reasons.Add("sequence $sequence has an external change")
        }
        $operationDecisions.Add([pscustomobject][ordered]@{ sequence=$sequence; action=$action })
    }
    if ($mustRefuse) {
        $safeDecisions = @($Journal.operations | ForEach-Object { [pscustomobject][ordered]@{ sequence=[int64]$_.sequence; action='keep' } })
        return [pscustomobject][ordered]@{ action='refuse'; reasons=$reasons.ToArray(); operations=$safeDecisions }
    }
    return [pscustomobject][ordered]@{ action='roll-back'; reasons=@(); operations=$operationDecisions.ToArray() }
}

function Get-AiInstructionsInstallRecoveryPlan {
    param([Parameter(Mandatory = $true)][object] $Journal,[Parameter(Mandatory = $true)][object] $Decision)
    Assert-AiInstructionsInstallJournalV1 -Journal $Journal | Out-Null
    Assert-AiInstructionsInstallJournalExactProperties -Object $Decision -Names @('action','reasons','operations') -Context 'AI instructions install recovery decision'
    if ($Decision.action -isnot [string] -or [string]$Decision.action -cnotin @('none','commit','roll-back','refuse')) { throw 'AI instructions install recovery decision action is invalid.' }
    if ($Decision.operations -isnot [System.Array] -or @($Decision.operations).Count -ne @($Journal.operations).Count) { throw 'AI instructions install recovery decision operations must correspond one-to-one with the journal.' }
    for ($index = 0; $index -lt @($Journal.operations).Count; $index++) {
        $decisionOperation = $Decision.operations[$index]
        Assert-AiInstructionsInstallJournalExactProperties -Object $decisionOperation -Names @('sequence','action') -Context "AI instructions install recovery decision operation $($index + 1)"
        if ([int64]$decisionOperation.sequence -ne [int64]$Journal.operations[$index].sequence) { throw 'AI instructions install recovery decision operation sequence does not match the journal.' }
        if ($decisionOperation.action -isnot [string] -or [string]$decisionOperation.action -cnotin @('none','restore-original','remove-applied','restore-permissions','keep')) { throw 'AI instructions install recovery decision operation action is invalid.' }
        if ([string]$Decision.action -in @('none','commit','refuse') -and [string]$decisionOperation.action -cne 'keep') { throw "AI instructions install recovery decision $($Decision.action) requires keep operations." }
        if ([string]$Decision.action -ceq 'roll-back' -and [string]$decisionOperation.action -ceq 'keep') { throw 'AI instructions install recovery roll-back decision must not contain keep operations.' }
    }
    $steps = New-Object System.Collections.Generic.List[object]
    switch ([string]$Decision.action) {
        'refuse' { return [pscustomobject][ordered]@{ action='refuse'; mutatesTargets=$false; steps=@() } }
        'none' {
            $steps.Add([pscustomobject][ordered]@{ step='cleanup-transaction'; primitive='Remove-PlatformOwnedDirectoryTree' })
            return [pscustomobject][ordered]@{ action='none'; mutatesTargets=$false; steps=$steps.ToArray() }
        }
        'commit' {
            $steps.Add([pscustomobject][ordered]@{ step='write-phase'; phase='committed' })
            foreach ($operation in @($Journal.operations | Sort-Object sequence)) {
                $directoryOperation = [string]$operation.kind -in @('swap-directory','create-directory')
                foreach ($leafName in @('backupLeaf','stageLeaf','quarantineLeaf')) {
                    $leaf = $operation.PSObject.Properties[$leafName].Value
                    if ($null -eq $leaf) { continue }
                    $primitive = if ($directoryOperation) { 'Remove-PlatformOwnedDirectoryTree' } else { 'Remove-PlatformOwnedFile' }
                    $steps.Add([pscustomobject][ordered]@{ step='cleanup-artifact'; sequence=[int64]$operation.sequence; leaf=[string]$leaf; primitive=$primitive })
                }
            }
            $steps.Add([pscustomobject][ordered]@{ step='cleanup-transaction'; primitive='Remove-PlatformOwnedDirectoryTree' })
            return [pscustomobject][ordered]@{ action='commit'; mutatesTargets=$false; steps=$steps.ToArray() }
        }
        'roll-back' {
            $steps.Add([pscustomobject][ordered]@{ step='write-phase'; phase='rolling-back' })
            for ($index = @($Journal.operations).Count - 1; $index -ge 0; $index--) {
                $operation = $Journal.operations[$index]
                $decisionOperation = $Decision.operations[$index]
                $action = [string]$decisionOperation.action
                if ($action -cne 'none') {
                    $primitive = switch ($action) {
                        'restore-original' { if ([string]$operation.kind -ceq 'swap-directory') { 'Move-PlatformOwnedDirectory' } else { 'Publish-PlatformFile' } }
                        'remove-applied' { if ([string]$operation.kind -ceq 'create-directory') { 'Move-PlatformOwnedDirectory' } else { 'Remove-PlatformOwnedFile' } }
                        'restore-permissions' { 'Set-PlatformPermissions' }
                    }
                    $step = [ordered]@{ step='operation'; sequence=[int64]$operation.sequence; action=$action; kind=[string]$operation.kind; targetRelativePath=[string]$operation.targetRelativePath; primitive=$primitive }
                    if ([string]$operation.kind -ceq 'swap-directory' -and $action -ceq 'restore-original') { $step.quarantineLeaf=$operation.quarantineLeaf; $step.backupLeaf=$operation.backupLeaf }
                    if ([string]$operation.kind -ceq 'create-directory' -and $action -ceq 'remove-applied') { $step.quarantineLeaf=$operation.quarantineLeaf }
                    if ($action -ceq 'restore-permissions') { $step.snapshot=$operation.permissions }
                    $steps.Add([pscustomobject]$step)
                    $steps.Add([pscustomobject][ordered]@{ step='write-operation-state'; sequence=[int64]$operation.sequence; state='rolled-back' })
                }
                elseif ([string]$operation.state -ceq 'applied') {
                    $steps.Add([pscustomobject][ordered]@{ step='write-operation-state'; sequence=[int64]$operation.sequence; state='rolled-back' })
                }
            }
            $steps.Add([pscustomobject][ordered]@{ step='write-phase'; phase='rolled-back' })
            $steps.Add([pscustomobject][ordered]@{ step='cleanup-transaction'; primitive='Remove-PlatformOwnedDirectoryTree' })
            return [pscustomobject][ordered]@{ action='roll-back'; mutatesTargets=$true; steps=$steps.ToArray() }
        }
    }
}

function Test-AiInstructionsReservedJournalPathSegment {
    param([Parameter(Mandatory = $true)][string] $Path)
    foreach ($segment in @($Path -split '[/\\]')) {
        if ([string]::Equals($segment,'.ai-instructions-txn',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-AiInstructionsPhysicalPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $pathToResolve = [System.IO.Path]::GetFullPath($Path)
    $replacementCount = 0
    while ($true) {
        $root = [System.IO.Path]::GetPathRoot($pathToResolve)
        $segments = @($pathToResolve.Substring($root.Length) -split '[/\\]' | Where-Object { $_.Length -gt 0 })
        $current = $root
        $replaced = $false
        for ($index = 0; $index -lt $segments.Count; $index++) {
            $candidate = Join-Path $current $segments[$index]
            $item = $null
            try { $item = Get-Item -Force -LiteralPath $candidate -ErrorAction Stop }
            catch [System.Management.Automation.ItemNotFoundException] { $item = $null }
            if ($null -ne $item) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $linkTarget = $null
                    foreach ($propertyName in @('LinkTarget','Target')) {
                        $property = $item.PSObject.Properties[$propertyName]
                        if ($null -eq $property) { continue }
                        foreach ($value in @($property.Value)) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $linkTarget = [string]$value; break }
                        }
                        if ($null -ne $linkTarget) { break }
                    }
                    if ($null -eq $linkTarget) { throw "Cannot resolve reparse point '$candidate' to a link target." }
                    $replacementCount++
                    if ($replacementCount -gt 40) { throw 'Physical path resolution exceeded 40 link replacements.' }
                    $targetPath = if ([System.IO.Path]::IsPathRooted($linkTarget)) { $linkTarget } else { Join-Path (Split-Path -Parent $candidate) $linkTarget }
                    $pathToResolve = [System.IO.Path]::GetFullPath($targetPath)
                    for ($tailIndex = $index + 1; $tailIndex -lt $segments.Count; $tailIndex++) {
                        $pathToResolve = Join-Path $pathToResolve $segments[$tailIndex]
                    }
                    $pathToResolve = [System.IO.Path]::GetFullPath($pathToResolve)
                    $replaced = $true
                    break
                }
            }
            $current = $candidate
        }
        if (-not $replaced) { return $pathToResolve }
    }
}

function Write-AiInstructionsJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][object] $Document)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (Test-AiInstructionsReservedJournalPathSegment -Path $fullPath) {
        throw 'Write-AiInstructionsJsonFile must not write inside the reserved .ai-instructions-txn journal store.'
    }
    $physicalPath = Get-AiInstructionsPhysicalPath -Path $fullPath
    if (Test-AiInstructionsReservedJournalPathSegment -Path $physicalPath) {
        throw 'Write-AiInstructionsJsonFile must not write inside the reserved .ai-instructions-txn journal store.'
    }
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
    'Assert-AiInstructionsRuntimeBundleV3',
    'Assert-AiInstructionsMutationPath',
    'Assert-AiInstructionsSafeChildDirectory',
    'Assert-AiInstructionsInstallJournalV1',
    'Assert-AiInstructionsSyncConfigurationV4',
    'Assert-AiInstructionsSyncConfigurationV5',
    'Assert-AiInstructionsUpdateReceiptV1',
    'ConvertTo-AiInstructionsUtcDateTime',
    'ConvertFrom-AiInstructionsInstallJournalV1Json',
    'ConvertTo-AiInstructionsSyncConfigurationV4',
    'ConvertTo-AiInstructionsSyncConfigurationV5',
    'Get-AiInstructionsFileSha256',
    'Get-AiInstructionsFullDirectoryPath',
    'Get-AiInstructionsInstallRecoveryDecision',
    'Get-AiInstructionsInstallRecoveryPlan',
    'Get-AiInstructionsInstallJournalDirectoryState',
    'Get-AiInstructionsInstallJournalStoreLeaves',
    'Get-AiInstructionsInstallTransactionClassification',
    'Get-AiInstructionsInstallTransactionResidueKind',
    'Get-AiInstructionsInstallTransactionDisposition',
    'Assert-AiInstructionsInstallJournalStoreTransition',
    'Get-AiInstructionsRefusalCodes',
    'New-AiInstructionsRefusalException',
    'Get-AiInstructionsRefusalCode',
    'Get-AiInstructionsRuntimeInventory',
    'Get-AiInstructionsRuntimeInventorySha256',
    'Get-AiInstructionsRuntimeInventorySha256V3',
    'New-AiInstructionsRuntimeBundleV2',
    'New-AiInstructionsInstallJournalV1',
    'Write-AiInstructionsJsonFile'
)
