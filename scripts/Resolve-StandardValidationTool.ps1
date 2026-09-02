[CmdletBinding()]
param(
    [ValidateSet('skillspector', 'skill-validator', 'skill-tools', 'pester')]
    [string] $ToolName,

    [string] $PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/validation-toolchain.json'),

    [switch] $Install,

    [switch] $ValidatePolicyOnly,

    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

$trustedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}

$trustedRegistries = [ordered]@{
    'skill-tools' = 'https://registry.npmjs.org/'
}

$trustedPythonIndex = 'https://pypi.org/simple'

$trustedGoEnvironment = [ordered]@{
    'GOENV' = 'off'
    'GOPROXY' = 'https://proxy.golang.org'
    'GOSUMDB' = 'sum.golang.org'
    'GOPRIVATE' = ''
    'GONOPROXY' = 'none'
    'GONOSUMDB' = 'none'
    'GOINSECURE' = ''
}

$trustedGoDistribution = [ordered]@{
    'moduleCacheIsolation' = 'temporary-empty'
    'rejectInheritedModuleCache' = $true
}

function Normalize-RegistryUri {
    param([Parameter(Mandatory = $true)][string] $Value)

    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Registry URI cannot be empty.'
    }

    try {
        $uri = [Uri]$trimmed
    }
    catch {
        throw "Invalid registry URI '$Value'."
    }

    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https') {
        throw "Registry URI must use absolute HTTPS: '$Value'."
    }

    return $uri.AbsoluteUri.TrimEnd('/') + '/'
}

function Get-Policy {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Validation toolchain policy not found: $Path"
    }

    $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    if ($null -eq $policy -or $policy.schemaVersion -ne 1) {
        throw 'Unsupported validation toolchain schemaVersion.'
    }
    if ([string]$policy.policy -cne 'latest-stable-per-validation-run') {
        throw "Unsupported validation tool policy '$($policy.policy)'."
    }
    if ([string]$policy.sourceTrust.enforcement -cne 'exact-approved-source') {
        throw "Unsupported validation tool source trust enforcement '$($policy.sourceTrust.enforcement)'."
    }
    if ([string]$policy.sourceTrust.resolver -cne 'scripts/Resolve-StandardValidationTool.ps1') {
        throw "Unexpected validation tool resolver '$($policy.sourceTrust.resolver)'."
    }
    if (-not [bool]$policy.sourceTrust.failClosedOnMismatch) {
        throw 'Validation tool source mismatch must fail closed.'
    }
    if (-not [bool]$policy.resolution.resolveAtRunStart -or -not [bool]$policy.resolution.freezeForRun) {
        throw 'Validation tools must resolve at run start and freeze for the run.'
    }
    if (-not [bool]$policy.resolution.recordResolvedVersion) {
        throw 'Validation tool policy must record resolved versions.'
    }
    if (-not [bool]$policy.resolution.recordResolvedIdentityWhenAvailable) {
        throw 'Validation tool policy must record resolved immutable/package identity when available.'
    }
    if ([bool]$policy.resolution.allowPrerelease) {
        throw 'Prerelease validation tools cannot be the canonical default.'
    }

    foreach ($entry in $trustedSources.GetEnumerator()) {
        $tool = $policy.tools.($entry.Key)
        if ($null -eq $tool) {
            throw "Missing validation tool policy for '$($entry.Key)'."
        }
        if ([string]$tool.source -cne [string]$entry.Value) {
            throw "Untrusted validation tool source for '$($entry.Key)': '$($tool.source)'. Expected '$($entry.Value)'."
        }
        if ([string]$tool.channel -cne 'latest-stable') {
            throw "Validation tool '$($entry.Key)' must use channel 'latest-stable'."
        }
    }

    foreach ($entry in $trustedRegistries.GetEnumerator()) {
        $tool = $policy.tools.($entry.Key)
        $configuredRegistry = Normalize-RegistryUri -Value ([string]$tool.registry)
        $expectedRegistry = Normalize-RegistryUri -Value ([string]$entry.Value)
        if ($configuredRegistry -cne $expectedRegistry) {
            throw "Untrusted package registry for '$($entry.Key)': '$configuredRegistry'. Expected '$expectedRegistry'."
        }
    }

    $skillSpector = $policy.tools.skillspector
    if ([string]$skillSpector.releaseVersionRule -cne 'v-semver-release-only') {
        throw "Unexpected SkillSpector releaseVersionRule '$($skillSpector.releaseVersionRule)'."
    }
    if ((Normalize-RegistryUri -Value ([string]$skillSpector.pythonPackageIndex)) -cne (Normalize-RegistryUri -Value $trustedPythonIndex)) {
        throw "Untrusted SkillSpector Python package index '$($skillSpector.pythonPackageIndex)'. Expected '$trustedPythonIndex'."
    }
    $allowedInherited = @($skillSpector.pythonDistribution.allowedInheritedEnvironment)
    if ([string]$skillSpector.pythonDistribution.configIsolation -cne 'os.devnull' -or
        [string]$skillSpector.pythonDistribution.environmentOverridePolicy -cne 'deny-by-default' -or
        $allowedInherited.Count -ne 1 -or [string]$allowedInherited[0] -cne 'PIP_INDEX_URL' -or
        -not [bool]$skillSpector.pythonDistribution.onlyBinary -or
        -not [bool]$skillSpector.pythonDistribution.disableCache -or
        [string]$skillSpector.pythonDistribution.dependencyAcquisition -cne 'verified-wheelhouse' -or
        [string]$skillSpector.pythonDistribution.installEnvironment -cne 'isolated-venv' -or
        -not [bool]$skillSpector.pythonDistribution.installNoIndex -or
        -not [bool]$skillSpector.pythonDistribution.requireHashes -or
        -not [bool]$skillSpector.pythonDistribution.recordDependencyClosureHashes) {
        throw 'SkillSpector Python dependency distribution policy is incomplete or untrusted.'
    }

    $skillValidator = $policy.tools.'skill-validator'
    if ([string]$skillValidator.stableVersionRule -cne 'release-semver-only') {
        throw "Unexpected skill-validator stableVersionRule '$($skillValidator.stableVersionRule)'."
    }
    if ([string]$skillValidator.proxy -cne 'https://proxy.golang.org') {
        throw "Untrusted Go module proxy '$($skillValidator.proxy)'. Expected 'https://proxy.golang.org'."
    }
    if ([string]$skillValidator.checksumDatabase -cne 'sum.golang.org') {
        throw "Untrusted Go checksum database '$($skillValidator.checksumDatabase)'. Expected 'sum.golang.org'."
    }
    foreach ($entry in $trustedGoEnvironment.GetEnumerator()) {
        $actual = [string]$skillValidator.goEnvironment.($entry.Key)
        if ($actual -cne [string]$entry.Value) {
            throw "Untrusted Go environment policy for '$($entry.Key)': '$actual'. Expected '$($entry.Value)'."
        }
    }
    if ([string]$skillValidator.goDistribution.moduleCacheIsolation -cne [string]$trustedGoDistribution.moduleCacheIsolation -or
        [bool]$skillValidator.goDistribution.rejectInheritedModuleCache -ne [bool]$trustedGoDistribution.rejectInheritedModuleCache) {
        throw 'Go module cache distribution policy is incomplete or untrusted.'
    }

    return $policy
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Required command '$Name' is unavailable."
    }
    return $command
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-GitHubHeaders {
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'SyuanTsai-AI-Instructions-validation-tool-resolver'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }
    return $headers
}

function Test-StableGoModuleVersion {
    param([Parameter(Mandatory = $true)][string] $Version)

    return $Version -match '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'
}

function Normalize-PythonPackageName {
    param([Parameter(Mandatory = $true)][string] $Name)

    return (($Name.Trim().ToLowerInvariant()) -replace '[-_.]+', '-')
}

function Get-PythonWheelMetadata {
    param([Parameter(Mandatory = $true)][string] $WheelPath)

    if (-not (Test-Path -LiteralPath $WheelPath -PathType Leaf)) {
        throw "Python wheel not found: $WheelPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($WheelPath)
    try {
        $metadataEntries = @($archive.Entries | Where-Object { $_.FullName -match '[^/]+\.dist-info/METADATA$' })
        if ($metadataEntries.Count -ne 1) {
            throw "Expected exactly one dist-info/METADATA entry in '$WheelPath'; found $($metadataEntries.Count)."
        }

        $stream = $metadataEntries[0].Open()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        try {
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }

        $nameMatch = [regex]::Match($text, '(?m)^Name:\s*(.+?)\s*$')
        $versionMatch = [regex]::Match($text, '(?m)^Version:\s*(.+?)\s*$')
        if (-not $nameMatch.Success -or -not $versionMatch.Success) {
            throw "Wheel METADATA in '$WheelPath' does not contain Name and Version."
        }

        return [ordered]@{
            name = $nameMatch.Groups[1].Value.Trim()
            version = $versionMatch.Groups[1].Value.Trim()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-SkillSpectorWheelIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $ReleaseVersion,
        [Parameter(Mandatory = $true)][string] $WheelFileName,
        [Parameter(Mandatory = $true)][string] $MetadataName,
        [Parameter(Mandatory = $true)][string] $MetadataVersion
    )

    $expectedWheelName = "skillspector-$ReleaseVersion-py3-none-any.whl"
    if ($WheelFileName -cne $expectedWheelName) {
        throw "SkillSpector release/wheel version mismatch. Expected '$expectedWheelName', got '$WheelFileName'."
    }
    if ((Normalize-PythonPackageName -Name $MetadataName) -cne 'skillspector') {
        throw "SkillSpector wheel METADATA Name mismatch. Expected 'skillspector', got '$MetadataName'."
    }
    if ($MetadataVersion -cne $ReleaseVersion) {
        throw "SkillSpector wheel METADATA Version mismatch. Expected '$ReleaseVersion', got '$MetadataVersion'."
    }
}

function Get-ProcessPipEnvironmentNames {
    return @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^PIP_' } |
        Sort-Object -Unique)
}

function Assert-NoConflictingPipEnvironment {
    param([Parameter(Mandatory = $true)][string] $ApprovedIndex)

    $expectedIndex = Normalize-RegistryUri -Value $ApprovedIndex
    foreach ($name in Get-ProcessPipEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrWhiteSpace($actual)) {
            continue
        }
        if ($name -ceq 'PIP_INDEX_URL') {
            $actualIndex = Normalize-RegistryUri -Value $actual
            if ($actualIndex -cne $expectedIndex) {
                throw "Untrusted pip environment override for 'PIP_INDEX_URL': '$actualIndex'. Expected '$expectedIndex'."
            }
            continue
        }
        throw "Untrusted pip environment override for '$name': '$actual'."
    }
}

function Invoke-WithApprovedPipEnvironment {
    param(
        [Parameter(Mandatory = $true)][string] $ApprovedIndex,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingPipEnvironment -ApprovedIndex $ApprovedIndex

    $names = @((Get-ProcessPipEnvironmentNames) + @('PIP_INDEX_URL', 'PIP_CONFIG_FILE') | Sort-Object -Unique)
    $previous = [ordered]@{}
    $nullDevice = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'NUL' } else { '/dev/null' }
    $normalizedIndex = Normalize-RegistryUri -Value $ApprovedIndex

    try {
        foreach ($name in $names) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $normalizedIndex, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('PIP_CONFIG_FILE', $nullDevice, [EnvironmentVariableTarget]::Process)

        return & $Action
    }
    finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
        }
    }
}

function New-PythonWheelhouseLock {
    param(
        [Parameter(Mandatory = $true)][string] $WheelhousePath,
        [Parameter(Mandatory = $true)][string] $LockPath
    )

    $files = @(Get-ChildItem -LiteralPath $WheelhousePath -File | Sort-Object Name)
    if ($files.Count -eq 0) {
        throw 'Python wheelhouse is empty.'
    }

    $seen = @{}
    $entries = @()
    foreach ($file in $files) {
        if ($file.Extension -cne '.whl') {
            throw "Non-wheel artifact found in verified wheelhouse: '$($file.Name)'."
        }
        $metadata = Get-PythonWheelMetadata -WheelPath $file.FullName
        $normalizedName = Normalize-PythonPackageName -Name ([string]$metadata.name)
        if ($seen.ContainsKey($normalizedName)) {
            throw "Duplicate Python distribution '$normalizedName' in wheelhouse."
        }
        $seen[$normalizedName] = $true
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $entries += [pscustomobject][ordered]@{
            name = [string]$metadata.name
            normalizedName = $normalizedName
            version = [string]$metadata.version
            file = $file.Name
            sha256 = $hash
        }
    }

    $entries = @($entries | Sort-Object normalizedName)
    $lockLines = @($entries | ForEach-Object { "$($_.name)==$($_.version) --hash=sha256:$($_.sha256)" })
    [IO.File]::WriteAllText($LockPath, (($lockLines -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))

    $canonical = ($entries | ForEach-Object { "$($_.normalizedName)`t$($_.version)`t$($_.file)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $closureHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    return [ordered]@{
        lockPath = $LockPath
        closureSha256 = $closureHash
        entries = $entries
    }
}

function Assert-ApprovedNpmRegistry {
    param([Parameter(Mandatory = $true)][string] $ExpectedRegistry)

    $expected = Normalize-RegistryUri -Value $ExpectedRegistry

    if (-not [string]::IsNullOrWhiteSpace($env:NPM_CONFIG_REGISTRY)) {
        $environmentRegistry = Normalize-RegistryUri -Value $env:NPM_CONFIG_REGISTRY
        if ($environmentRegistry -cne $expected) {
            throw "Untrusted npm registry from NPM_CONFIG_REGISTRY: '$environmentRegistry'. Expected '$expected'."
        }
    }

    [void](Assert-Command -Name 'npm')
    $configuredRegistry = (Invoke-CheckedCommand -Command 'npm' -Arguments @('config', 'get', 'registry')) -join ''
    $configured = Normalize-RegistryUri -Value $configuredRegistry
    if ($configured -cne $expected) {
        throw "Untrusted npm registry from npm configuration: '$configured'. Expected '$expected'."
    }

    return $expected
}

function Assert-NoConflictingGoEnvironment {
    param([Parameter(Mandatory = $true)] $ExpectedEnvironment)

    foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
        $actual = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
            continue
        }
        if ([string]$actual -cne [string]$entry.Value) {
            throw "Untrusted Go environment override for '$($entry.Key)': '$actual'. Expected '$($entry.Value)'."
        }
    }
}

function Invoke-WithApprovedGoEnvironment {
    param(
        [Parameter(Mandatory = $true)] $ExpectedEnvironment,
        [Parameter(Mandatory = $true)] $DistributionPolicy,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingGoEnvironment -ExpectedEnvironment $ExpectedEnvironment
    $inheritedModuleCache = [Environment]::GetEnvironmentVariable('GOMODCACHE', [EnvironmentVariableTarget]::Process)
    if ([bool]$DistributionPolicy.rejectInheritedModuleCache -and -not [string]::IsNullOrEmpty($inheritedModuleCache)) {
        throw "Untrusted Go environment override for 'GOMODCACHE': '$inheritedModuleCache'. Expected an unset value."
    }
    if ([string]$DistributionPolicy.moduleCacheIsolation -cne 'temporary-empty') {
        throw "Unsupported Go module cache isolation '$($DistributionPolicy.moduleCacheIsolation)'."
    }

    $previous = [ordered]@{}
    $moduleCachePath = Join-Path ([IO.Path]::GetTempPath()) ("standard-go-module-cache-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
            $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
        }
        $previous.GOMODCACHE = $inheritedModuleCache
        [void](New-Item -ItemType Directory -Path $moduleCachePath)
        [Environment]::SetEnvironmentVariable('GOMODCACHE', $moduleCachePath, [EnvironmentVariableTarget]::Process)

        $processGoEnv = [Environment]::GetEnvironmentVariable('GOENV', [EnvironmentVariableTarget]::Process)
        if ([string]$processGoEnv -cne 'off') {
            throw "Canonical Go process environment requires GOENV=off. Actual='$processGoEnv'."
        }

        [void](Assert-Command -Name 'go')
        $effectiveNames = @('GOPROXY', 'GOSUMDB', 'GOPRIVATE', 'GONOPROXY', 'GONOSUMDB', 'GOINSECURE', 'GOMODCACHE')
        $effectiveJson = (Invoke-CheckedCommand -Command 'go' -Arguments (@('env', '-json') + $effectiveNames)) -join "`n"
        $effective = $effectiveJson | ConvertFrom-Json
        foreach ($name in @('GOPROXY', 'GOSUMDB', 'GOPRIVATE', 'GONOPROXY', 'GONOSUMDB', 'GOINSECURE')) {
            $actual = [string]$effective.$name
            $expected = [string]$ExpectedEnvironment[$name]
            if ($actual -cne $expected) {
                throw "Go did not apply approved environment for '$name': '$actual'. Expected '$expected'."
            }
        }
        $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        $effectiveModuleCache = [IO.Path]::GetFullPath([string]$effective.GOMODCACHE)
        $expectedModuleCache = [IO.Path]::GetFullPath($moduleCachePath)
        if (-not [string]::Equals($effectiveModuleCache, $expectedModuleCache, $pathComparison)) {
            throw "Go did not apply the isolated module cache '$expectedModuleCache'. Actual='$effectiveModuleCache'."
        }
        if (@(Get-ChildItem -LiteralPath $moduleCachePath -Force).Count -ne 0) {
            throw "The isolated Go module cache was not empty before module resolution: '$moduleCachePath'."
        }

        return & $Action
    }
    finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
        }
        if (Test-Path -LiteralPath $moduleCachePath) {
            Remove-Item -LiteralPath $moduleCachePath -Recurse -Force -ErrorAction Stop
        }
    }
}

function Resolve-Pester {
    param([bool] $ShouldInstall)

    $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop
    $expectedRepository = 'https://www.powershellgallery.com/api/v2'
    $actualRepository = ([string]$repository.SourceLocation).TrimEnd('/')
    if ($actualRepository -cne $expectedRepository) {
        throw "Untrusted PSGallery endpoint '$actualRepository'. Expected '$expectedRepository'."
    }

    $package = Find-Module -Name Pester -Repository PSGallery -ErrorAction Stop
    $version = [string]$package.Version
    if ([string]::IsNullOrWhiteSpace($version) -or $version.Contains('-')) {
        throw "Could not resolve a stable Pester version. Resolved='$version'."
    }

    if ($ShouldInstall) {
        Install-Module Pester -Repository PSGallery -RequiredVersion $version -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = "PowerShellGallery:Pester@$version"
        identityKind = 'package-coordinate'
    }
}

function Resolve-SkillTools {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)][string] $Registry
    )

    $approvedRegistry = Assert-ApprovedNpmRegistry -ExpectedRegistry $Registry
    $registryArgument = "--registry=$approvedRegistry"

    $versionJson = (Invoke-CheckedCommand -Command 'npm' -Arguments @('view', 'skill-tools', 'version', '--json', $registryArgument)) -join "`n"
    $version = [string]($versionJson | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace($version) -or $version.Contains('-')) {
        throw "Could not resolve a stable skill-tools version. Resolved='$version'."
    }

    $integrityJson = (Invoke-CheckedCommand -Command 'npm' -Arguments @('view', "skill-tools@$version", 'dist.integrity', '--json', $registryArgument)) -join "`n"
    $integrity = [string]($integrityJson | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace($integrity)) {
        throw 'npm did not return package integrity for skill-tools.'
    }

    if ($ShouldInstall) {
        [void](Invoke-CheckedCommand -Command 'npm' -Arguments @('install', '--global', '--no-audit', '--no-fund', $registryArgument, "skill-tools@$version"))
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = "npm:skill-tools@$version#$integrity#registry=$approvedRegistry"
        identityKind = 'registry-integrity'
    }
}

function Resolve-SkillValidator {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)] $ToolPolicy
    )

    $modulePath = 'github.com/agent-ecosystem/skill-validator'
    $commandPath = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    $expectedEnvironment = [ordered]@{}
    foreach ($entry in $trustedGoEnvironment.GetEnumerator()) {
        $expectedEnvironment[$entry.Key] = [string]$ToolPolicy.goEnvironment.($entry.Key)
    }

    return Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -DistributionPolicy $ToolPolicy.goDistribution -Action {
        $metadataJson = (Invoke-CheckedCommand -Command 'go' -Arguments @('list', '-m', '-json', "$modulePath@latest")) -join "`n"
        $metadata = $metadataJson | ConvertFrom-Json
        $version = [string]$metadata.Version
        if (-not (Test-StableGoModuleVersion -Version $version)) {
            throw "Go did not resolve a stable release version for skill-validator. Resolved='$version'."
        }

        if ($ShouldInstall) {
            [void](Invoke-CheckedCommand -Command 'go' -Arguments @('install', "$commandPath@$version"))
        }

        return [ordered]@{
            resolvedVersion = $version
            resolvedIdentity = "go:$modulePath@$version#proxy=$($ToolPolicy.proxy)#sumdb=$($ToolPolicy.checksumDatabase)#moduleCache=$($ToolPolicy.goDistribution.moduleCacheIsolation)"
            identityKind = 'go-module-version-with-trusted-distribution'
            moduleCacheIsolation = [string]$ToolPolicy.goDistribution.moduleCacheIsolation
        }
    }
}

function Resolve-SkillSpector {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)] $ToolPolicy
    )

    [void](Assert-Command -Name 'python')
    $headers = Get-GitHubHeaders
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/NVIDIA/SkillSpector/releases/latest' -Headers $headers -Method Get
    if ($null -eq $release -or [bool]$release.draft -or [bool]$release.prerelease) {
        throw 'GitHub did not return a stable SkillSpector release.'
    }

    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$') {
        throw "SkillSpector stable release tag '$tag' does not match v-semver-release-only policy."
    }
    $version = [string]$Matches.version

    $tagRef = Invoke-RestMethod -Uri ("https://api.github.com/repos/NVIDIA/SkillSpector/git/ref/tags/{0}" -f $tag) -Headers $headers -Method Get
    $commitSha = [string]$tagRef.object.sha
    $objectType = [string]$tagRef.object.type
    if ($objectType -eq 'tag') {
        $tagObject = Invoke-RestMethod -Uri ("https://api.github.com/repos/NVIDIA/SkillSpector/git/tags/{0}" -f $commitSha) -Headers $headers -Method Get
        $commitSha = [string]$tagObject.object.sha
        $objectType = [string]$tagObject.object.type
    }
    if ($objectType -cne 'commit' -or $commitSha -notmatch '^[0-9a-f]{40}$') {
        throw "SkillSpector tag '$tag' did not resolve to a full commit SHA."
    }

    $wheelAssets = @($release.assets | Where-Object { [string]$_.name -match '^skillspector-.+-py3-none-any\.whl$' })
    if ($wheelAssets.Count -ne 1) {
        throw "Expected exactly one SkillSpector universal wheel asset; found $($wheelAssets.Count)."
    }
    $wheel = $wheelAssets[0]
    $expectedWheelName = "skillspector-$version-py3-none-any.whl"
    if ([string]$wheel.name -cne $expectedWheelName) {
        throw "SkillSpector release tag/wheel filename mismatch. Tag '$tag' requires '$expectedWheelName', got '$($wheel.name)'."
    }

    $digest = [string]$wheel.digest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'SkillSpector release wheel does not expose a SHA-256 digest.'
    }

    $approvedIndex = Normalize-RegistryUri -Value ([string]$ToolPolicy.pythonPackageIndex)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("skillspector-{0}-{1}" -f $version, [guid]::NewGuid().ToString('N'))
    $wheelhouse = Join-Path $tempRoot 'wheelhouse'
    [void](New-Item -ItemType Directory -Path $wheelhouse -Force)

    $closure = $null
    $installEnvironment = $null
    try {
        $wheelPath = Join-Path $tempRoot ([string]$wheel.name)
        Invoke-WebRequest -Uri ([string]$wheel.browser_download_url) -Headers $headers -OutFile $wheelPath -UseBasicParsing
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheelPath).Hash.ToLowerInvariant()
        $expectedHash = $digest.Substring('sha256:'.Length)
        if ($actualHash -cne $expectedHash) {
            throw "SkillSpector wheel hash mismatch. Expected '$expectedHash', got '$actualHash'."
        }

        $wheelMetadata = Get-PythonWheelMetadata -WheelPath $wheelPath
        Assert-SkillSpectorWheelIdentity -ReleaseVersion $version -WheelFileName ([string]$wheel.name) -MetadataName ([string]$wheelMetadata.name) -MetadataVersion ([string]$wheelMetadata.version)

        if ($ShouldInstall) {
            $venvPath = Join-Path $tempRoot 'venv'
            [void](Invoke-CheckedCommand -Command 'python' -Arguments @('-m', 'venv', $venvPath))
            $venvPython = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                Join-Path $venvPath 'Scripts\python.exe'
            }
            else {
                Join-Path $venvPath 'bin/python'
            }
            if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
                throw "SkillSpector isolated virtual environment Python was not created: $venvPython"
            }
            $installEnvironment = 'isolated-venv'

            $closure = Invoke-WithApprovedPipEnvironment -ApprovedIndex $approvedIndex -Action {
                $indexArgument = "--index-url=$approvedIndex"
                [void](Invoke-CheckedCommand -Command $venvPython -Arguments @(
                    '-m', 'pip', 'download', '--disable-pip-version-check', '--no-cache-dir',
                    '--only-binary=:all:', '--dest', $wheelhouse, $indexArgument, $wheelPath
                ))

                $wheelhouseRoot = Join-Path $wheelhouse ([string]$wheel.name)
                if (-not (Test-Path -LiteralPath $wheelhouseRoot -PathType Leaf)) {
                    Copy-Item -LiteralPath $wheelPath -Destination $wheelhouseRoot -Force
                }
                $wheelhouseRootHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheelhouseRoot).Hash.ToLowerInvariant()
                if ($wheelhouseRootHash -cne $expectedHash) {
                    throw "SkillSpector root wheel changed during dependency acquisition. Expected '$expectedHash', got '$wheelhouseRootHash'."
                }

                $lockPath = Join-Path $tempRoot 'skillspector-dependency-lock.txt'
                $manifest = New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath
                $rootEntry = @($manifest.entries | Where-Object { $_.normalizedName -eq 'skillspector' })
                if ($rootEntry.Count -ne 1 -or [string]$rootEntry[0].version -cne $version -or [string]$rootEntry[0].sha256 -cne $expectedHash) {
                    throw 'SkillSpector root wheel is not correctly bound into the dependency closure.'
                }

                [void](Invoke-CheckedCommand -Command $venvPython -Arguments @(
                    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir',
                    '--no-index', "--find-links=$wheelhouse", '--require-hashes', '--no-deps', '--force-reinstall',
                    '-r', $lockPath
                ))

                $installedVersion = ((Invoke-CheckedCommand -Command $venvPython -Arguments @(
                    '-c', "import importlib.metadata as m; print(m.version('skillspector'))"
                )) -join '').Trim()
                if ($installedVersion -cne $version) {
                    throw "Installed SkillSpector version mismatch. Expected '$version', got '$installedVersion'."
                }

                return $manifest
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $identity = "github:NVIDIA/SkillSpector@$tag#commit=$commitSha#asset=$digest#metadata=skillspector@$version"
    if ($null -ne $closure) {
        $identity += "#pythonIndex=$approvedIndex#installEnvironment=$installEnvironment#dependencyClosureSha256=$($closure.closureSha256)"
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = $identity
        identityKind = 'release-commit-asset-metadata-and-dependency-closure'
        pythonPackageIndex = $approvedIndex
        installEnvironment = $installEnvironment
        dependencyClosureSha256 = if ($null -eq $closure) { $null } else { [string]$closure.closureSha256 }
        dependencyClosure = if ($null -eq $closure) { @() } else { @($closure.entries) }
    }
}

$policy = Get-Policy -Path $PolicyPath

if ($ValidatePolicyOnly) {
    $result = [ordered]@{
        schemaVersion = 1
        policy = [string]$policy.policy
        sourceTrust = [ordered]@{
            enforcement = [string]$policy.sourceTrust.enforcement
            resolver = [string]$policy.sourceTrust.resolver
            failClosedOnMismatch = [bool]$policy.sourceTrust.failClosedOnMismatch
        }
        trustedSources = $trustedSources
        trustedRegistries = $trustedRegistries
        trustedPythonIndex = $trustedPythonIndex
        trustedGoEnvironment = $trustedGoEnvironment
        trustedGoDistribution = $trustedGoDistribution
        recordResolvedIdentityWhenAvailable = [bool]$policy.resolution.recordResolvedIdentityWhenAvailable
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        throw 'ToolName is required unless -ValidatePolicyOnly is specified.'
    }

    $resolved = switch ($ToolName) {
        'pester' { Resolve-Pester -ShouldInstall ([bool]$Install) }
        'skill-tools' { Resolve-SkillTools -ShouldInstall ([bool]$Install) -Registry ([string]$policy.tools.'skill-tools'.registry) }
        'skill-validator' { Resolve-SkillValidator -ShouldInstall ([bool]$Install) -ToolPolicy $policy.tools.'skill-validator' }
        'skillspector' { Resolve-SkillSpector -ShouldInstall ([bool]$Install) -ToolPolicy $policy.tools.skillspector }
    }

    $toolPolicy = $policy.tools.$ToolName
    $result = [ordered]@{
        schemaVersion = 1
        toolName = $ToolName
        source = [string]$toolPolicy.source
        channel = [string]$toolPolicy.channel
        resolvedVersion = [string]$resolved.resolvedVersion
        resolvedIdentity = [string]$resolved.resolvedIdentity
        identityKind = [string]$resolved.identityKind
        frozenForRun = [bool]$policy.resolution.freezeForRun
    }
    if ($ToolName -eq 'skill-tools') {
        $result.registry = [string]$toolPolicy.registry
    }
    if ($ToolName -eq 'skill-validator') {
        $result.proxy = [string]$toolPolicy.proxy
        $result.checksumDatabase = [string]$toolPolicy.checksumDatabase
        $result.moduleCacheIsolation = [string]$resolved.moduleCacheIsolation
    }
    if ($ToolName -eq 'skillspector') {
        $result.pythonPackageIndex = [string]$resolved.pythonPackageIndex
        $result.installEnvironment = $resolved.installEnvironment
        $result.dependencyClosureSha256 = $resolved.dependencyClosureSha256
        $result.dependencyClosure = $resolved.dependencyClosure
    }
}

$json = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $directory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

$json
