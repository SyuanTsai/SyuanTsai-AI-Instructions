[CmdletBinding()]
param(
    [ValidateSet('skillspector', 'skill-validator', 'skill-tools', 'pester')]
    [string] $ToolName,

    [string] $PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/validation-toolchain.json'),

    [switch] $Install,

    [switch] $ValidatePolicyOnly,

    [string] $InstallRoot,

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
$trustedPowerShellRepository = 'https://www.powershellgallery.com/api/v2'
$trustedGoRuntimeVersion = '1.26.8'

$trustedGoEnvironment = [ordered]@{
    'GOENV' = 'off'
    'GOPROXY' = 'https://proxy.golang.org'
    'GOSUMDB' = 'sum.golang.org'
    'GOPRIVATE' = ''
    'GONOPROXY' = 'none'
    'GONOSUMDB' = 'none'
    'GOINSECURE' = ''
    'GOFLAGS' = ''
    'GOTOOLCHAIN' = 'local'
    'GOWORK' = 'off'
    'CGO_ENABLED' = '0'
}

$trustedGoDistribution = [ordered]@{
    'moduleCacheIsolation' = 'temporary-empty'
    'buildCacheIsolation' = 'temporary-empty'
    'temporaryDirectoryIsolation' = 'temporary-empty'
    'binaryInstallIsolation' = 'run-owned'
    'rejectInheritedModuleCache' = $true
    'rejectInheritedBuildCache' = $true
    'rejectDangerousEnvironment' = $true
    'recordBinaryHash' = $true
}

$deniedGoEnvironmentNames = @(
    'GOROOT', 'GOTOOLDIR', 'GOPATH', 'GO111MODULE',
    'GOOS', 'GOARCH', 'GOAMD64', 'GO386', 'GOARM', 'GOARM64',
    'GOMIPS', 'GOMIPS64', 'GOPPC64', 'GORISCV64', 'GOWASM',
    'GOCACHEPROG', 'GOAUTH', 'GOVCS', 'GOEXPERIMENT', 'GODEBUG',
    'GO_EXTLINK_ENABLED', 'GCCGO',
    'CC', 'CXX', 'FC', 'AR', 'PKG_CONFIG',
    'CGO_CFLAGS', 'CGO_CPPFLAGS', 'CGO_CXXFLAGS', 'CGO_FFLAGS', 'CGO_LDFLAGS',
    'CGO_CFLAGS_ALLOW', 'CGO_CFLAGS_DISALLOW',
    'CGO_CPPFLAGS_ALLOW', 'CGO_CPPFLAGS_DISALLOW',
    'CGO_CXXFLAGS_ALLOW', 'CGO_CXXFLAGS_DISALLOW',
    'CGO_FFLAGS_ALLOW', 'CGO_FFLAGS_DISALLOW',
    'CGO_LDFLAGS_ALLOW', 'CGO_LDFLAGS_DISALLOW'
)

# Python isolated mode ignores PYTHON* startup configuration, but rejecting the
# variables that can redirect imports or execute startup code makes the trust
# boundary explicit. Do not match every case-insensitive "python*" name here:
# setup-python intentionally publishes benign runner metadata such as
# pythonLocation, Python_ROOT_DIR, and Python3_ROOT_DIR.
$dangerousPythonEnvironmentNames = @(
    'PYTHONPATH', 'PYTHONHOME', 'PYTHONUSERBASE', 'PYTHONEXECUTABLE',
    'PYTHONSTARTUP', 'PYTHONINSPECT', 'PYTHONBREAKPOINT',
    'PYTHONNOUSERSITE', 'PYTHONSAFEPATH', 'PYTHONPLATLIBDIR',
    '_PYTHON_SYSCONFIGDATA_NAME', '__PYVENV_LAUNCHER__',
    'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR'
)

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject) {
        throw "JSON object '$Context' is missing."
    }

    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "JSON object '$Context' has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-JsonBoolean {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][bool] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [bool] -or $Value -ne $Expected) {
        throw "JSON property '$Context' must be the boolean '$($Expected.ToString().ToLowerInvariant())'."
    }
}

function Assert-JsonString {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]$Value -cne $Expected) {
        throw "JSON property '$Context' must be the exact string '$Expected'."
    }
}

function Assert-JsonIntegerOne {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $isInteger = $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    if (-not $isInteger -or [Convert]::ToInt64($Value) -ne 1) {
        throw "JSON property '$Context' must be the integer 1."
    }
}

function Assert-JsonSingleStringArray {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [array]) {
        throw "JSON property '$Context' must be an array."
    }
    $items = @($Value)
    if ($items.Count -ne 1 -or $items[0] -isnot [string] -or [string]$items[0] -cne $Expected) {
        throw "JSON property '$Context' must contain only '$Expected'."
    }
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
    Assert-ExactPropertySet -Value $policy -Expected @(
        'schemaVersion', 'policy', 'sourceTrust', 'resolution', 'tools', 'compatibilityLane'
    ) -Context '$'
    Assert-JsonIntegerOne -Value $policy.schemaVersion -Context '$.schemaVersion'
    Assert-JsonString -Value $policy.policy -Expected 'latest-stable-per-validation-run' -Context '$.policy'

    Assert-ExactPropertySet -Value $policy.sourceTrust -Expected @(
        'enforcement', 'resolver', 'failClosedOnMismatch'
    ) -Context '$.sourceTrust'
    Assert-JsonString -Value $policy.sourceTrust.enforcement -Expected 'exact-approved-source' -Context '$.sourceTrust.enforcement'
    Assert-JsonString -Value $policy.sourceTrust.resolver -Expected 'scripts/Resolve-StandardValidationTool.ps1' -Context '$.sourceTrust.resolver'
    Assert-JsonBoolean -Value $policy.sourceTrust.failClosedOnMismatch -Expected $true -Context '$.sourceTrust.failClosedOnMismatch'

    Assert-ExactPropertySet -Value $policy.resolution -Expected @(
        'resolveAtRunStart', 'freezeForRun', 'recordResolvedVersion',
        'recordResolvedIdentityWhenAvailable', 'allowPrerelease'
    ) -Context '$.resolution'
    Assert-JsonBoolean -Value $policy.resolution.resolveAtRunStart -Expected $true -Context '$.resolution.resolveAtRunStart'
    Assert-JsonBoolean -Value $policy.resolution.freezeForRun -Expected $true -Context '$.resolution.freezeForRun'
    Assert-JsonBoolean -Value $policy.resolution.recordResolvedVersion -Expected $true -Context '$.resolution.recordResolvedVersion'
    Assert-JsonBoolean -Value $policy.resolution.recordResolvedIdentityWhenAvailable -Expected $true -Context '$.resolution.recordResolvedIdentityWhenAvailable'
    Assert-JsonBoolean -Value $policy.resolution.allowPrerelease -Expected $false -Context '$.resolution.allowPrerelease'

    Assert-ExactPropertySet -Value $policy.tools -Expected @(
        'skillspector', 'skill-validator', 'skill-tools', 'pester'
    ) -Context '$.tools'

    foreach ($entry in $trustedSources.GetEnumerator()) {
        $tool = $policy.tools.($entry.Key)
        if ($tool.source -isnot [string] -or [string]$tool.source -cne [string]$entry.Value) {
            throw "Untrusted validation tool source for '$($entry.Key)': '$($tool.source)'. Expected '$($entry.Value)'."
        }
        if ($tool.channel -isnot [string] -or [string]$tool.channel -cne 'latest-stable') {
            throw "Validation tool '$($entry.Key)' must use string channel 'latest-stable'."
        }
    }

    foreach ($entry in $trustedRegistries.GetEnumerator()) {
        $tool = $policy.tools.($entry.Key)
        if ($tool.registry -isnot [string]) {
            throw "Validation tool registry for '$($entry.Key)' must be a string."
        }
        $configuredRegistry = Normalize-RegistryUri -Value ([string]$tool.registry)
        $expectedRegistry = Normalize-RegistryUri -Value ([string]$entry.Value)
        if ($configuredRegistry -cne $expectedRegistry) {
            throw "Untrusted package registry for '$($entry.Key)': '$configuredRegistry'. Expected '$expectedRegistry'."
        }
    }

    $skillSpector = $policy.tools.skillspector
    Assert-ExactPropertySet -Value $skillSpector -Expected @(
        'source', 'channel', 'releaseVersionRule', 'pythonPackageIndex', 'pythonDistribution'
    ) -Context '$.tools.skillspector'
    Assert-JsonString -Value $skillSpector.releaseVersionRule -Expected 'v-semver-release-only' -Context '$.tools.skillspector.releaseVersionRule'
    if ($skillSpector.pythonPackageIndex -isnot [string]) {
        throw 'SkillSpector pythonPackageIndex must be a string.'
    }
    if ((Normalize-RegistryUri -Value ([string]$skillSpector.pythonPackageIndex)) -cne (Normalize-RegistryUri -Value $trustedPythonIndex)) {
        throw "Untrusted SkillSpector Python package index '$($skillSpector.pythonPackageIndex)'. Expected '$trustedPythonIndex'."
    }
    Assert-ExactPropertySet -Value $skillSpector.pythonDistribution -Expected @(
        'configIsolation', 'environmentOverridePolicy', 'allowedInheritedEnvironment',
        'rejectInheritedPythonEnvironment', 'onlyBinary', 'allowDirectReferences',
        'allowPipOnlineDependencyTraversal', 'allowYanked', 'disableCache',
        'candidateDiscovery', 'requiresPythonPolicy', 'dependencyAcquisition', 'dependencyResolver',
        'installEnvironment', 'interpreterIsolation', 'credentialIsolation',
        'installedMetadataVerification', 'verifyOfflineResolution',
        'installNoIndex', 'requireHashes',
        'recordDependencyClosureHashes'
    ) -Context '$.tools.skillspector.pythonDistribution'
    Assert-JsonString -Value $skillSpector.pythonDistribution.configIsolation -Expected 'os.devnull' -Context '$.tools.skillspector.pythonDistribution.configIsolation'
    Assert-JsonString -Value $skillSpector.pythonDistribution.environmentOverridePolicy -Expected 'deny-by-default' -Context '$.tools.skillspector.pythonDistribution.environmentOverridePolicy'
    Assert-JsonSingleStringArray -Value $skillSpector.pythonDistribution.allowedInheritedEnvironment -Expected 'PIP_INDEX_URL' -Context '$.tools.skillspector.pythonDistribution.allowedInheritedEnvironment'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.rejectInheritedPythonEnvironment -Expected $true -Context '$.tools.skillspector.pythonDistribution.rejectInheritedPythonEnvironment'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.onlyBinary -Expected $true -Context '$.tools.skillspector.pythonDistribution.onlyBinary'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.allowDirectReferences -Expected $false -Context '$.tools.skillspector.pythonDistribution.allowDirectReferences'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.allowPipOnlineDependencyTraversal -Expected $false -Context '$.tools.skillspector.pythonDistribution.allowPipOnlineDependencyTraversal'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.allowYanked -Expected $false -Context '$.tools.skillspector.pythonDistribution.allowYanked'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.disableCache -Expected $true -Context '$.tools.skillspector.pythonDistribution.disableCache'
    Assert-JsonString -Value $skillSpector.pythonDistribution.candidateDiscovery -Expected 'approved-simple-json-lazy' -Context '$.tools.skillspector.pythonDistribution.candidateDiscovery'
    Assert-JsonString -Value $skillSpector.pythonDistribution.requiresPythonPolicy -Expected 'simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' -Context '$.tools.skillspector.pythonDistribution.requiresPythonPolicy'
    Assert-JsonString -Value $skillSpector.pythonDistribution.dependencyAcquisition -Expected 'verified-wheelhouse' -Context '$.tools.skillspector.pythonDistribution.dependencyAcquisition'
    Assert-JsonString -Value $skillSpector.pythonDistribution.dependencyResolver -Expected 'pip-offline-backtracking' -Context '$.tools.skillspector.pythonDistribution.dependencyResolver'
    Assert-JsonString -Value $skillSpector.pythonDistribution.installEnvironment -Expected 'isolated-venv' -Context '$.tools.skillspector.pythonDistribution.installEnvironment'
    Assert-JsonString -Value $skillSpector.pythonDistribution.interpreterIsolation -Expected 'python-isolated-mode' -Context '$.tools.skillspector.pythonDistribution.interpreterIsolation'
    Assert-JsonString -Value $skillSpector.pythonDistribution.credentialIsolation -Expected 'github-token-cleared-before-python' -Context '$.tools.skillspector.pythonDistribution.credentialIsolation'
    Assert-JsonString -Value $skillSpector.pythonDistribution.installedMetadataVerification -Expected 'static-dist-info-metadata' -Context '$.tools.skillspector.pythonDistribution.installedMetadataVerification'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.verifyOfflineResolution -Expected $true -Context '$.tools.skillspector.pythonDistribution.verifyOfflineResolution'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.installNoIndex -Expected $true -Context '$.tools.skillspector.pythonDistribution.installNoIndex'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.requireHashes -Expected $true -Context '$.tools.skillspector.pythonDistribution.requireHashes'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.recordDependencyClosureHashes -Expected $true -Context '$.tools.skillspector.pythonDistribution.recordDependencyClosureHashes'

    $skillValidator = $policy.tools.'skill-validator'
    Assert-ExactPropertySet -Value $skillValidator -Expected @(
        'source', 'channel', 'stableVersionRule', 'proxy', 'checksumDatabase', 'goRuntimeVersion', 'goEnvironment', 'goDistribution'
    ) -Context '$.tools.skill-validator'
    Assert-JsonString -Value $skillValidator.stableVersionRule -Expected 'release-semver-only' -Context '$.tools.skill-validator.stableVersionRule'
    Assert-JsonString -Value $skillValidator.goRuntimeVersion -Expected $trustedGoRuntimeVersion -Context '$.tools.skill-validator.goRuntimeVersion'
    if ($skillValidator.proxy -isnot [string] -or $skillValidator.checksumDatabase -isnot [string]) {
        throw 'skill-validator proxy and checksumDatabase must be strings.'
    }
    if ([string]$skillValidator.proxy -cne 'https://proxy.golang.org') {
        throw "Untrusted Go module proxy '$($skillValidator.proxy)'. Expected 'https://proxy.golang.org'."
    }
    if ([string]$skillValidator.checksumDatabase -cne 'sum.golang.org') {
        throw "Untrusted Go checksum database '$($skillValidator.checksumDatabase)'. Expected 'sum.golang.org'."
    }
    foreach ($entry in $trustedGoEnvironment.GetEnumerator()) {
        $raw = $skillValidator.goEnvironment.($entry.Key)
        if ($raw -isnot [string]) {
            throw "Go environment policy '$($entry.Key)' must be a string."
        }
        $actual = [string]$raw
        if ($actual -cne [string]$entry.Value) {
            throw "Untrusted Go environment policy for '$($entry.Key)': '$actual'. Expected '$($entry.Value)'."
        }
    }
    Assert-ExactPropertySet -Value $skillValidator.goEnvironment -Expected @($trustedGoEnvironment.Keys) -Context '$.tools.skill-validator.goEnvironment'
    Assert-ExactPropertySet -Value $skillValidator.goDistribution -Expected @($trustedGoDistribution.Keys) -Context '$.tools.skill-validator.goDistribution'
    foreach ($entry in $trustedGoDistribution.GetEnumerator()) {
        if ($entry.Value -is [bool]) {
            Assert-JsonBoolean -Value $skillValidator.goDistribution.($entry.Key) -Expected ([bool]$entry.Value) -Context "$.tools.skill-validator.goDistribution.$($entry.Key)"
        }
        else {
            Assert-JsonString -Value $skillValidator.goDistribution.($entry.Key) -Expected ([string]$entry.Value) -Context "$.tools.skill-validator.goDistribution.$($entry.Key)"
        }
    }

    $skillTools = $policy.tools.'skill-tools'
    Assert-ExactPropertySet -Value $skillTools -Expected @(
        'source', 'registry', 'channel', 'npmDistribution'
    ) -Context '$.tools.skill-tools'
    Assert-ExactPropertySet -Value $skillTools.npmDistribution -Expected @(
        'configIsolation', 'environmentOverridePolicy', 'allowedInheritedEnvironment',
        'dependencyAcquisition', 'installEnvironment', 'ignoreScripts',
        'recordDependencyClosureIntegrity'
    ) -Context '$.tools.skill-tools.npmDistribution'
    Assert-JsonString -Value $skillTools.npmDistribution.configIsolation -Expected 'empty-config-and-workdir' -Context '$.tools.skill-tools.npmDistribution.configIsolation'
    Assert-JsonString -Value $skillTools.npmDistribution.environmentOverridePolicy -Expected 'deny-by-default' -Context '$.tools.skill-tools.npmDistribution.environmentOverridePolicy'
    Assert-JsonSingleStringArray -Value $skillTools.npmDistribution.allowedInheritedEnvironment -Expected 'NPM_CONFIG_REGISTRY' -Context '$.tools.skill-tools.npmDistribution.allowedInheritedEnvironment'
    Assert-JsonString -Value $skillTools.npmDistribution.dependencyAcquisition -Expected 'package-lock' -Context '$.tools.skill-tools.npmDistribution.dependencyAcquisition'
    Assert-JsonString -Value $skillTools.npmDistribution.installEnvironment -Expected 'isolated-prefix' -Context '$.tools.skill-tools.npmDistribution.installEnvironment'
    Assert-JsonBoolean -Value $skillTools.npmDistribution.ignoreScripts -Expected $true -Context '$.tools.skill-tools.npmDistribution.ignoreScripts'
    Assert-JsonBoolean -Value $skillTools.npmDistribution.recordDependencyClosureIntegrity -Expected $true -Context '$.tools.skill-tools.npmDistribution.recordDependencyClosureIntegrity'

    $pester = $policy.tools.pester
    Assert-ExactPropertySet -Value $pester -Expected @('source', 'channel', 'repository') -Context '$.tools.pester'
    Assert-JsonString -Value $pester.repository -Expected $trustedPowerShellRepository -Context '$.tools.pester.repository'

    Assert-ExactPropertySet -Value $policy.compatibilityLane -Expected @(
        'mayPinOlderVersion', 'requiresExplicitPurpose', 'mayBeCanonicalReleaseGate'
    ) -Context '$.compatibilityLane'
    Assert-JsonBoolean -Value $policy.compatibilityLane.mayPinOlderVersion -Expected $true -Context '$.compatibilityLane.mayPinOlderVersion'
    Assert-JsonBoolean -Value $policy.compatibilityLane.requiresExplicitPurpose -Expected $true -Context '$.compatibilityLane.requiresExplicitPurpose'
    Assert-JsonBoolean -Value $policy.compatibilityLane.mayBeCanonicalReleaseGate -Expected $false -Context '$.compatibilityLane.mayBeCanonicalReleaseGate'

    return $policy
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string] $Name)

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Required native command '$Name' is unavailable."
    }
    $path = if ($null -ne $command.PSObject.Properties['Path']) { [string]$command.Path } else { [string]$command.Source }
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
        throw "Required native command '$Name' did not resolve to an absolute application path."
    }
    $resolvedPath = [IO.Path]::GetFullPath($path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Required native command '$Name' does not exist at '$resolvedPath'."
    }
    return $resolvedPath
}

function Assert-NpmCommand {
    $name = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'npm.cmd' } else { 'npm' }
    return Assert-Command -Name $name
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $commandPath = if ([IO.Path]::IsPathRooted($Command)) {
        $resolved = [IO.Path]::GetFullPath($Command)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Required native command does not exist at '$resolved'."
        }
        $resolved
    }
    else {
        Assert-Command -Name $Command
    }

    $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ("standard-command-stderr-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            # Windows PowerShell 5.1 promotes native stderr to NativeCommandError when
            # the caller uses Stop. The native exit code remains authoritative here.
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = $null
            $output = & $commandPath @Arguments 2> $stderrPath
            $exitCode = $global:LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $stderr = @(
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ }
            }
        )
        if ($null -eq $exitCode) {
            throw "$commandPath could not be started: $($stderr -join [Environment]::NewLine)"
        }
        if ($exitCode -ne 0) {
            throw "$commandPath $($Arguments -join ' ') failed: $($stderr -join [Environment]::NewLine)"
        }
        if ($stderr.Count -gt 0) {
            Write-Verbose ($stderr -join [Environment]::NewLine)
        }
        return @($output | ForEach-Object { [string]$_ })
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-RunOwnedInstallDirectory {
    param(
        [string] $Root,
        [Parameter(Mandatory = $true)][string] $ToolName
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $base = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
            $env:RUNNER_TEMP
        }
        else {
            [IO.Path]::GetTempPath()
        }
        $Root = Join-Path $base 'standard-validation-tools'
    }
    $fullRoot = [IO.Path]::GetFullPath($Root)
    [void](New-Item -ItemType Directory -Path $fullRoot -Force)
    $toolRoot = Join-Path $fullRoot ("{0}-{1}" -f $ToolName, [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $toolRoot)
    return [IO.Path]::GetFullPath($toolRoot)
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for hashing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-DirectoryClosureIdentity {
    param([Parameter(Mandatory = $true)][string] $Path)

    $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $entries = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $relative = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
        $entries += [pscustomobject][ordered]@{
            path = $relative
            sha256 = Get-FileSha256 -Path $file.FullName
        }
    }
    if ($entries.Count -eq 0) {
        throw "Installed tool directory is empty: $root"
    }
    $canonical = ($entries | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $closureHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    return [ordered]@{
        sha256 = $closureHash
        entries = $entries
    }
}

function Get-DependencyClosureEntriesArray {
    param([AllowNull()] $Closure)

    if ($null -eq $Closure) {
        return ,([object[]]@())
    }
    return ,([object[]]@($Closure.entries))
}

function Get-OrdinalUniqueStrings {
    param([object[]] $Values)

    $result = @()
    foreach ($value in @($Values)) {
        $item = [string]$value
        if ($result -cnotcontains $item) {
            $result += $item
        }
    }
    return $result
}

function Add-ProcessPathValue {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Value
    )

    $separator = [IO.Path]::PathSeparator
    $current = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    $updated = if ([string]::IsNullOrWhiteSpace($current)) { $Value } else { "$Value$separator$current" }
    [Environment]::SetEnvironmentVariable($Name, $updated, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        [IO.File]::AppendAllText($env:GITHUB_ENV, "$Name=$updated$([Environment]::NewLine)", (New-Object Text.UTF8Encoding($false)))
    }
}

function Invoke-IsolatedPythonCommand {
    param(
        [Parameter(Mandatory = $true)][string] $PythonCommand,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    return Invoke-CheckedCommand -Command $PythonCommand -Arguments (@('-I') + $Arguments)
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

function Get-ApprovedSkillSpectorAssetUri {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Tag,
        [Parameter(Mandatory = $true)][string] $FileName
    )

    try {
        $uri = [Uri]$Value
    }
    catch {
        throw "Invalid SkillSpector release asset URI '$Value'."
    }
    $expectedPath = "/NVIDIA/SkillSpector/releases/download/$Tag/$FileName"
    if (-not $uri.IsAbsoluteUri -or
        $uri.Scheme -cne 'https' -or
        $uri.Host -cne 'github.com' -or
        -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        $uri.AbsolutePath -cne $expectedPath) {
        throw "Untrusted SkillSpector release asset URI '$Value'. Expected 'https://github.com$expectedPath'."
    }
    return $uri.AbsoluteUri
}

function Test-StableGoModuleVersion {
    param([Parameter(Mandatory = $true)][string] $Version)

    return $Version -match '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'
}

function Test-StableNpmPackageVersion {
    param([Parameter(Mandatory = $true)][string] $Version)

    return $Version -cmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\+[0-9A-Za-z.-]+)?$'
}

function Normalize-PythonPackageName {
    param([Parameter(Mandatory = $true)][string] $Name)

    return (($Name.Trim().ToLowerInvariant()) -replace '[-_.]+', '-')
}

function ConvertFrom-PythonMetadataText {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $normalizedText = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $headerBoundary = $normalizedText.IndexOf("`n`n", [StringComparison]::Ordinal)
    $headerText = if ($headerBoundary -ge 0) { $normalizedText.Substring(0, $headerBoundary) } else { $normalizedText }
    $unfoldedHeaders = [regex]::Replace($headerText, "\n[ `t]+", ' ')
    $nameMatches = @([regex]::Matches($unfoldedHeaders, '(?im)^Name:[ \t]*([^\n]+?)[ \t]*$'))
    $versionMatches = @([regex]::Matches($unfoldedHeaders, '(?im)^Version:[ \t]*([^\n]+?)[ \t]*$'))
    if ($nameMatches.Count -ne 1 -or $versionMatches.Count -ne 1) {
        throw "$Context must contain exactly one Name field and one Version field in its metadata header section. Found Name=$($nameMatches.Count), Version=$($versionMatches.Count)."
    }

    $name = $nameMatches[0].Groups[1].Value.Trim()
    $version = $versionMatches[0].Groups[1].Value.Trim()
    $normalizedName = Normalize-PythonPackageName -Name $name
    if ($normalizedName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "$Context contains an unsafe Python distribution Name '$name'."
    }
    if ($version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+!-]*$') {
        throw "$Context contains an unsafe Python distribution Version '$version'."
    }

    $requiresDist = @([regex]::Matches($unfoldedHeaders, '(?im)^Requires-Dist:[ \t]*([^\r\n]+?)[ \t]*\r?$') | ForEach-Object {
        $_.Groups[1].Value.Trim()
    })

    return [ordered]@{
        name = $name
        normalizedName = $normalizedName
        version = $version
        requiresDist = $requiresDist
    }
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

        return ConvertFrom-PythonMetadataText -Text $text -Context "Wheel METADATA in '$WheelPath'"
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PythonConsoleEntryPoint {
    param(
        [Parameter(Mandatory = $true)][string] $EntryPointsPath,
        [Parameter(Mandatory = $true)][string] $CommandName
    )

    if (-not (Test-Path -LiteralPath $EntryPointsPath -PathType Leaf)) {
        throw "Installed Python entry_points.txt is missing: '$EntryPointsPath'."
    }
    $item = Get-Item -LiteralPath $EntryPointsPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installed Python entry_points.txt is a reparse point: '$EntryPointsPath'."
    }

    $section = ''
    $entryPointMatches = @()
    $text = ([IO.File]::ReadAllText($item.FullName)).Replace("`r`n", "`n").Replace("`r", "`n")
    foreach ($rawLine in @($text.Split("`n"))) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }
        if ($line -match '^\[(?<section>[A-Za-z0-9_.-]+)\]$') {
            $section = [string]$Matches.section
            continue
        }
        if ($section -cne 'console_scripts') {
            continue
        }
        if ($line -notmatch '^(?<name>[A-Za-z0-9_.-]+)\s*=\s*(?<value>\S(?:.*\S)?)$') {
            throw "Installed Python console_scripts contains a malformed entry: '$line'."
        }
        if ([string]$Matches.name -ceq $CommandName) {
            $entryPointMatches += [string]$Matches.value
        }
    }
    if ($entryPointMatches.Count -ne 1) {
        throw "Expected exactly one installed Python console entry point '$CommandName'; found $($entryPointMatches.Count)."
    }
    $value = [string]$entryPointMatches[0]
    if ($value.Length -gt 512 -or
        $value -cnotmatch '^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_.]*$') {
        throw "Installed Python console entry point '$CommandName' has an unsafe target."
    }
    return $value
}

function Get-InstalledPythonDistributionMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $VirtualEnvironmentPath,
        [Parameter(Mandatory = $true)][string] $DistributionName
    )

    $resolvedVenv = [IO.Path]::GetFullPath($VirtualEnvironmentPath)
    $sitePackages = @()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $candidate = Join-Path $resolvedVenv 'Lib\site-packages'
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $sitePackages += $candidate
        }
    }
    else {
        $libRoot = Join-Path $resolvedVenv 'lib'
        if (Test-Path -LiteralPath $libRoot -PathType Container) {
            foreach ($pythonDirectory in @(Get-ChildItem -LiteralPath $libRoot -Directory)) {
                if ($pythonDirectory.Name -notmatch '^python(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
                    continue
                }
                $candidate = Join-Path $pythonDirectory.FullName 'site-packages'
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $sitePackages += $candidate
                }
            }
        }
    }
    if ($sitePackages.Count -ne 1) {
        throw "Expected exactly one virtual-environment site-packages directory; found $($sitePackages.Count)."
    }
    $sitePackagesItem = Get-Item -LiteralPath $sitePackages[0] -Force
    if (($sitePackagesItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Virtual-environment site-packages is a reparse point: '$($sitePackagesItem.FullName)'."
    }

    $targetName = Normalize-PythonPackageName -Name $DistributionName
    $matches = @()
    foreach ($distInfo in @(Get-ChildItem -LiteralPath $sitePackages[0] -Directory -Filter '*.dist-info')) {
        if (($distInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed Python metadata directory is a reparse point: '$($distInfo.FullName)'."
        }
        $metadataPath = Join-Path $distInfo.FullName 'METADATA'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            continue
        }
        $metadataItem = Get-Item -LiteralPath $metadataPath -Force
        if (($metadataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed Python METADATA is a reparse point: '$metadataPath'."
        }
        $metadataText = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath
        $metadata = ConvertFrom-PythonMetadataText -Text $metadataText -Context "Installed Python METADATA '$metadataPath'"
        if ([string]$metadata.normalizedName -ceq $targetName) {
            $entryPointsPath = Join-Path $distInfo.FullName 'entry_points.txt'
            $consoleEntryPoint = Get-PythonConsoleEntryPoint -EntryPointsPath $entryPointsPath -CommandName $targetName
            $matches += [pscustomobject][ordered]@{
                name = [string]$metadata.name
                normalizedName = [string]$metadata.normalizedName
                version = [string]$metadata.version
                metadataPath = $metadataPath
                entryPointsPath = $entryPointsPath
                consoleEntryPoint = $consoleEntryPoint
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one installed Python distribution '$targetName'; found $($matches.Count)."
    }
    return $matches[0]
}

function Assert-NoPythonDirectReferences {
    param(
        [Parameter(Mandatory = $true)] $Metadata,
        [Parameter(Mandatory = $true)][string] $WheelFileName
    )

    foreach ($requirement in @($Metadata.requiresDist)) {
        if ([string]$requirement -match '@|(?:https?|file|git\+https?|git\+ssh|ssh)\s*:') {
            throw "Python direct dependency reference is not allowed in '$WheelFileName': '$requirement'."
        }
    }
}

function Resolve-PythonWheelClosureFromApprovedIndex {
    param(
        [Parameter(Mandatory = $true)][string] $PythonCommand,
        [Parameter(Mandatory = $true)][string] $HelperPath,
        [Parameter(Mandatory = $true)][string] $ApprovedIndex,
        [Parameter(Mandatory = $true)][string] $RootWheelPath,
        [Parameter(Mandatory = $true)][string] $RootWheelSha256,
        [Parameter(Mandatory = $true)][string] $CandidatePath,
        [Parameter(Mandatory = $true)][string] $WheelhousePath,
        [Parameter(Mandatory = $true)][string] $WorkPath
    )

    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
        throw "Python wheel closure helper not found: $HelperPath"
    }
    [void](New-Item -ItemType Directory -Path $WorkPath -Force)
    $planPath = Join-Path $WorkPath 'offline-backtracking-plan.json'
    $inventoryPath = Join-Path $WorkPath 'candidate-inventory.json'
    $resultPath = Join-Path $WorkPath 'closure-result.json'

    [void](Invoke-IsolatedPythonCommand -PythonCommand $PythonCommand -Arguments @(
        $HelperPath, 'resolve',
        '--index-url', $ApprovedIndex,
        '--root-wheel', $RootWheelPath,
        '--root-sha256', $RootWheelSha256,
        '--candidate-dir', $CandidatePath,
        '--selected-dir', $WheelhousePath,
        '--plan', $planPath,
        '--inventory', $inventoryPath,
        '--result', $resultPath
    ))
    foreach ($path in @($planPath, $inventoryPath, $resultPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Python wheel closure helper did not produce required evidence: $path"
        }
    }

    try {
        $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath | ConvertFrom-Json
        $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $inventoryPath | ConvertFrom-Json
        $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    }
    catch {
        throw "Python wheel closure helper result is invalid JSON: $($_.Exception.Message)"
    }
    try {
        $verificationOutput = @(Invoke-IsolatedPythonCommand -PythonCommand $PythonCommand -Arguments @(
            $HelperPath, 'verify',
            '--candidate-dir', $CandidatePath,
            '--selected-dir', $WheelhousePath,
            '--plan', $planPath,
            '--inventory', $inventoryPath,
            '--result', $resultPath
        ))
        $verification = ($verificationOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Python wheel closure cross-file evidence verification failed: $($_.Exception.Message)"
    }
    if (($result.schemaVersion -isnot [int] -and $result.schemaVersion -isnot [long]) -or
        [int64]$result.schemaVersion -ne 1) {
        throw 'Python wheel closure helper returned an unsupported schemaVersion.'
    }
    foreach ($name in @('candidateInventorySha256', 'selectionPlanSha256', 'rawSelectionPlanSha256', 'selectedClosureSha256')) {
        $value = $result.$name
        if ($value -isnot [string] -or [string]$value -cnotmatch '^[0-9a-f]{64}$') {
            throw "Python wheel closure helper returned an invalid $name."
        }
        if ($verification.$name -isnot [string] -or [string]$verification.$name -cne [string]$value) {
            throw "Python wheel closure helper cross-file verification disagrees on $name."
        }
    }
    if (($verification.schemaVersion -isnot [int] -and $verification.schemaVersion -isnot [long]) -or
        [int64]$verification.schemaVersion -ne 1 -or
        $verification.verified -isnot [bool] -or
        -not [bool]$verification.verified) {
        throw 'Python wheel closure helper did not verify its cross-file evidence.'
    }
    foreach ($name in @('resolutionRounds', 'candidateCount')) {
        $value = $result.$name
        if (($value -isnot [int] -and $value -isnot [long]) -or [int64]$value -le 0) {
            throw "Python wheel closure helper returned an invalid $name."
        }
    }
    if ($result.pipVersion -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$result.pipVersion) -or
        [string]$result.pipVersion -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._+!-]{0,63}$') {
        throw 'Python wheel closure helper did not record a safe pip resolver version.'
    }
    $selectedEntries = @($result.selectedEntries)
    if ($result.selectedEntries -isnot [array] -or $selectedEntries.Count -le 0) {
        throw 'Python wheel closure helper returned no selected wheel entries.'
    }
    if (($inventory.schemaVersion -isnot [int] -and $inventory.schemaVersion -isnot [long]) -or
        [int64]$inventory.schemaVersion -ne 1 -or
        $inventory.index -isnot [string] -or
        [string]$inventory.index -cne $ApprovedIndex.TrimEnd('/') -or
        $inventory.pipVersion -isnot [string] -or
        [string]$inventory.pipVersion -cne [string]$result.pipVersion -or
        $inventory.yankedAllowed -isnot [bool] -or
        [bool]$inventory.yankedAllowed -or
        $inventory.inventorySha256 -isnot [string] -or
        [string]$inventory.inventorySha256 -cne [string]$result.candidateInventorySha256 -or
        $inventory.entries -isnot [array] -or
        @($inventory.entries).Count -ne [int64]$result.candidateCount) {
        throw 'Python wheel closure candidate inventory is inconsistent with the helper result.'
    }
    $candidateRoot = [IO.Path]::GetFullPath($CandidatePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else { [StringComparison]::Ordinal }
    foreach ($entry in @($inventory.entries)) {
        if ($entry.file -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entry.file) -or
            [IO.Path]::GetFileName([string]$entry.file) -cne [string]$entry.file -or
            $entry.sha256 -isnot [string] -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Python wheel closure candidate inventory contains an invalid file identity.'
        }
        $candidateFile = [IO.Path]::GetFullPath((Join-Path $CandidatePath ([string]$entry.file)))
        if (-not $candidateFile.StartsWith($candidateRoot, $pathComparison) -or
            -not (Test-Path -LiteralPath $candidateFile -PathType Leaf) -or
            (Get-FileSha256 -Path $candidateFile) -cne [string]$entry.sha256) {
            throw "Python wheel closure candidate evidence changed or escaped its pool: $candidateFile"
        }
    }
    $rawPlanHash = Get-FileSha256 -Path $planPath
    if ($rawPlanHash -cne [string]$result.rawSelectionPlanSha256 -or
        $plan.install -isnot [array] -or
        @($plan.install).Count -ne $selectedEntries.Count) {
        throw 'Python wheel closure selection plan is inconsistent with the helper result.'
    }

    return [ordered]@{
        planPath = $planPath
        inventoryPath = $inventoryPath
        resultPath = $resultPath
        pipVersion = [string]$result.pipVersion
        resolutionRounds = [int64]$result.resolutionRounds
        candidateCount = [int64]$result.candidateCount
        candidateInventorySha256 = [string]$result.candidateInventorySha256
        selectionPlanSha256 = [string]$result.selectionPlanSha256
        rawSelectionPlanSha256 = [string]$result.rawSelectionPlanSha256
        selectedClosureSha256 = [string]$result.selectedClosureSha256
        selectedEntries = $selectedEntries
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
        Sort-Object)
}

function Get-ProcessPythonEnvironmentNames {
    return @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $dangerousPythonEnvironmentNames -icontains $_ } |
        Sort-Object)
}

function Assert-NoConflictingPythonEnvironment {
    foreach ($name in Get-ProcessPythonEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Python environment override for '$name': '$actual'."
        }
    }
}

function Assert-NoConflictingPipEnvironment {
    param([Parameter(Mandatory = $true)][string] $ApprovedIndex)

    $expectedIndex = Normalize-RegistryUri -Value $ApprovedIndex
    foreach ($name in Get-ProcessPipEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
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
    Assert-NoConflictingPythonEnvironment

    $names = @(Get-OrdinalUniqueStrings -Values @(
        (Get-ProcessPipEnvironmentNames) +
        (Get-ProcessPythonEnvironmentNames) +
        @('PIP_INDEX_URL', 'PIP_CONFIG_FILE')
    ))
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

    $files = @(Get-ChildItem -LiteralPath $WheelhousePath -File)
    if ($files.Count -eq 0) {
        throw 'Python wheelhouse is empty.'
    }

    $entryMap = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($file in $files) {
        if ($file.Extension -cne '.whl') {
            throw "Non-wheel artifact found in verified wheelhouse: '$($file.Name)'."
        }
        $metadata = Get-PythonWheelMetadata -WheelPath $file.FullName
        Assert-NoPythonDirectReferences -Metadata $metadata -WheelFileName $file.Name
        $normalizedName = [string]$metadata.normalizedName
        if ($entryMap.ContainsKey($normalizedName)) {
            throw "Duplicate Python distribution '$normalizedName' in wheelhouse."
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $entryMap.Add($normalizedName, [pscustomobject][ordered]@{
            name = [string]$metadata.name
            normalizedName = $normalizedName
            version = [string]$metadata.version
            file = $file.Name
            sha256 = $hash
        })
    }

    $entries = @($entryMap.Values)
    $lockLines = @($entries | ForEach-Object { "$($_.normalizedName)==$($_.version) --hash=sha256:$($_.sha256)" })
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

function Get-ProcessNpmEnvironmentNames {
    $knownNames = @(
        'NPM_CONFIG_REGISTRY', 'NPM_CONFIG_USERCONFIG', 'NPM_CONFIG_GLOBALCONFIG',
        'NPM_CONFIG_CACHE', 'NPM_CONFIG_DRY_RUN', 'NPM_CONFIG_OFFLINE',
        'NPM_CONFIG_PREFER_OFFLINE', 'NPM_CONFIG_AUDIT', 'NPM_CONFIG_FUND',
        'NPM_CONFIG_UPDATE_NOTIFIER', 'NPM_CONFIG_IGNORE_SCRIPTS',
        'NPM_CONFIG_PACKAGE_LOCK', 'NPM_CONFIG_OMIT_LOCKFILE_REGISTRY_RESOLVED',
        'NPM_CONFIG_BIN_LINKS', 'NPM_CONFIG_WORKSPACES', 'NPM_CONFIG_GLOBAL'
    )
    $presentNames = @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^NPM_CONFIG_' } |
        Sort-Object)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $presentNames = @($presentNames | ForEach-Object {
            $presentName = [string]$_
            $canonicalName = @($knownNames | Where-Object {
                [string]::Equals([string]$_, $presentName, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($canonicalName.Count -eq 1) { [string]$canonicalName[0] } else { $presentName }
        })
    }
    return @(Get-OrdinalUniqueStrings -Values @($presentNames + $knownNames))
}

function Get-ProcessNodeEnvironmentNames {
    return @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object {
            $_ -match '^NODE_' -or
            $_ -ieq 'SSL_CERT_FILE' -or
            $_ -ieq 'SSL_CERT_DIR'
        } |
        Sort-Object)
}

function Assert-NoConflictingNpmEnvironment {
    param([Parameter(Mandatory = $true)][string] $ExpectedRegistry)

    $expected = Normalize-RegistryUri -Value $ExpectedRegistry
    foreach ($name in Get-ProcessNpmEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
            continue
        }
        if ($name -ieq 'NPM_CONFIG_REGISTRY') {
            $actualRegistry = Normalize-RegistryUri -Value $actual
            if ($actualRegistry -cne $expected) {
                throw "Untrusted npm registry from '$name': '$actualRegistry'. Expected '$expected'."
            }
            continue
        }
        throw "Untrusted npm environment override for '$name': '$actual'."
    }

    foreach ($name in @(Get-OrdinalUniqueStrings -Values @((Get-ProcessNodeEnvironmentNames) + @(
        'NODE_OPTIONS', 'NODE_PATH', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS',
        'SSL_CERT_FILE', 'SSL_CERT_DIR'
    )))) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Node environment override for '$name': '$actual'."
        }
    }
}

function Assert-ApprovedNpmRegistry {
    param(
        [Parameter(Mandatory = $true)][string] $NpmCommand,
        [Parameter(Mandatory = $true)][string] $ExpectedRegistry
    )

    $expected = Normalize-RegistryUri -Value $ExpectedRegistry
    $configuredRegistry = (Invoke-CheckedCommand -Command $NpmCommand -Arguments @('config', 'get', 'registry')) -join ''
    $configured = Normalize-RegistryUri -Value $configuredRegistry
    if ($configured -cne $expected) {
        throw "Untrusted npm registry from npm configuration: '$configured'. Expected '$expected'."
    }

    $configJson = (Invoke-CheckedCommand -Command $NpmCommand -Arguments @('config', 'list', '--json')) -join "`n"
    $config = $configJson | ConvertFrom-Json
    Assert-ApprovedNpmConfigurationObject -Configuration $config -ExpectedRegistry $ExpectedRegistry
    return $expected
}

function Assert-ApprovedNpmConfigurationObject {
    param(
        [Parameter(Mandatory = $true)] $Configuration,
        [Parameter(Mandatory = $true)][string] $ExpectedRegistry
    )

    $registryProperty = $Configuration.PSObject.Properties['registry']
    if ($null -eq $registryProperty -or $registryProperty.Value -isnot [string]) {
        throw 'npm configuration did not expose a string default registry.'
    }
    $expected = Normalize-RegistryUri -Value $ExpectedRegistry
    $configured = Normalize-RegistryUri -Value ([string]$registryProperty.Value)
    if ($configured -cne $expected) {
        throw "Untrusted npm registry from npm configuration object: '$configured'. Expected '$expected'."
    }
    $scopedRegistries = @($Configuration.PSObject.Properties | Where-Object { [string]$_.Name -match ':registry$' })
    if ($scopedRegistries.Count -gt 0) {
        throw "Untrusted scoped npm registry configuration remains active: '$($scopedRegistries.Name -join ',')'."
    }
}

function Invoke-WithApprovedNpmEnvironment {
    param(
        [Parameter(Mandatory = $true)][string] $NpmCommand,
        [Parameter(Mandatory = $true)][string] $ApprovedRegistry,
        [Parameter(Mandatory = $true)][string] $WorkPath,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingNpmEnvironment -ExpectedRegistry $ApprovedRegistry
    [void](New-Item -ItemType Directory -Path $WorkPath -Force)
    $cachePath = Join-Path $WorkPath 'npm-cache'
    [void](New-Item -ItemType Directory -Path $cachePath -Force)
    $normalizedRegistry = Normalize-RegistryUri -Value $ApprovedRegistry
    $userConfig = Join-Path $WorkPath 'user.npmrc'
    $globalConfig = Join-Path $WorkPath 'global.npmrc'
    $projectConfig = Join-Path $WorkPath '.npmrc'
    [IO.File]::WriteAllText($userConfig, '', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($globalConfig, '', (New-Object Text.UTF8Encoding($false)))
    $controlledNpmrc = @(
        "registry=$normalizedRegistry",
        'dry-run=false',
        'ignore-scripts=true',
        'package-lock=true',
        'omit-lockfile-registry-resolved=false',
        'audit=false',
        'fund=false'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($projectConfig, $controlledNpmrc + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $workManifest = [ordered]@{
        name = 'standard-validation-npm-work'
        version = '1.0.0'
        private = $true
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $WorkPath 'package.json'), $workManifest + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    $names = @(Get-OrdinalUniqueStrings -Values @((Get-ProcessNpmEnvironmentNames) + (Get-ProcessNodeEnvironmentNames) + @(
        'NPM_CONFIG_REGISTRY', 'NPM_CONFIG_USERCONFIG', 'NPM_CONFIG_GLOBALCONFIG',
        'NPM_CONFIG_CACHE', 'NPM_CONFIG_DRY_RUN', 'NPM_CONFIG_OFFLINE',
        'NPM_CONFIG_PREFER_OFFLINE', 'NPM_CONFIG_AUDIT', 'NPM_CONFIG_FUND',
        'NPM_CONFIG_UPDATE_NOTIFIER', 'NPM_CONFIG_IGNORE_SCRIPTS',
        'NPM_CONFIG_PACKAGE_LOCK', 'NPM_CONFIG_OMIT_LOCKFILE_REGISTRY_RESOLVED',
        'NPM_CONFIG_BIN_LINKS', 'NPM_CONFIG_WORKSPACES', 'NPM_CONFIG_GLOBAL',
        'NODE_OPTIONS', 'NODE_PATH', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS',
        'SSL_CERT_FILE', 'SSL_CERT_DIR'
    )))
    $previous = @()
    $previousLocation = Get-Location
    try {
        foreach ($name in $names) {
            $previous += [pscustomobject]@{
                name = $name
                value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            }
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', $normalizedRegistry, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG', $userConfig, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_GLOBALCONFIG', $globalConfig, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_CACHE', $cachePath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_DRY_RUN', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_OFFLINE', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_PREFER_OFFLINE', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_AUDIT', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_FUND', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_UPDATE_NOTIFIER', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_IGNORE_SCRIPTS', 'true', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_PACKAGE_LOCK', 'true', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_OMIT_LOCKFILE_REGISTRY_RESOLVED', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_BIN_LINKS', 'true', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_WORKSPACES', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_GLOBAL', 'false', [EnvironmentVariableTarget]::Process)
        Set-Location -LiteralPath $WorkPath

        $approved = Assert-ApprovedNpmRegistry -NpmCommand $NpmCommand -ExpectedRegistry $ApprovedRegistry
        return & $Action $approved
    }
    finally {
        Set-Location -LiteralPath $previousLocation.Path
        $currentNames = @(Get-OrdinalUniqueStrings -Values @(
            (Get-ProcessNpmEnvironmentNames) + (Get-ProcessNodeEnvironmentNames) + $names
        ))
        foreach ($name in $currentNames) {
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        foreach ($entry in $previous) {
            [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
        }
    }
}

function New-NpmJsonNode {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Object','Array','String','Integer','Number','Boolean','Null')][string] $TokenType,
        [AllowNull()] $Value,
        [AllowNull()] $Properties,
        [AllowNull()] $Items
    )

    $node = [ordered]@{ TokenType = $TokenType }
    if ($TokenType -ceq 'Object') { $node['Properties'] = $Properties }
    elseif ($TokenType -ceq 'Array') { $node['Items'] = @($Items) }
    else { $node['Value'] = $Value }
    return [pscustomobject]$node
}

function Skip-NpmJsonWhitespace {
    param([Parameter(Mandatory = $true)] $State)

    while ($State.Index -lt $State.Text.Length) {
        $code = [int][char]$State.Text[$State.Index]
        if ($code -notin @(0x20, 0x09, 0x0A, 0x0D)) { break }
        $State.Index++
    }
}

function Add-NpmJsonSemanticToken {
    param([Parameter(Mandatory = $true)] $State)

    $State.TokenCount++
    if ($State.TokenCount -gt $State.MaxTokens) {
        throw "npm package-lock JSON exceeds the maximum semantic token count of $($State.MaxTokens)."
    }
}

function Read-NpmJsonString {
    param([Parameter(Mandatory = $true)] $State)

    if ($State.Index -ge $State.Text.Length -or [int][char]$State.Text[$State.Index] -ne 0x22) {
        throw "npm package-lock JSON expected a string at offset $($State.Index)."
    }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    while ($State.Index -lt $State.Text.Length) {
        $code = [int][char]$State.Text[$State.Index]
        $State.Index++
        if ($code -eq 0x22) {
            return $builder.ToString()
        }
        if ($code -lt 0x20) {
            throw "npm package-lock JSON string contains an unescaped control character at offset $($State.Index - 1)."
        }
        if ($code -ne 0x5C) {
            if ($code -ge 0xD800 -and $code -le 0xDBFF) {
                if ($State.Index -ge $State.Text.Length) {
                    throw 'npm package-lock JSON string contains an unpaired raw high surrogate.'
                }
                $lowCode = [int][char]$State.Text[$State.Index]
                if ($lowCode -lt 0xDC00 -or $lowCode -gt 0xDFFF) {
                    throw 'npm package-lock JSON string contains an unpaired raw high surrogate.'
                }
                [void]$builder.Append([char]$code)
                [void]$builder.Append([char]$lowCode)
                $State.Index++
                continue
            }
            if ($code -ge 0xDC00 -and $code -le 0xDFFF) {
                throw 'npm package-lock JSON string contains an unpaired raw low surrogate.'
            }
            [void]$builder.Append([char]$code)
            continue
        }
        if ($State.Index -ge $State.Text.Length) {
            throw 'npm package-lock JSON string ends with an incomplete escape.'
        }
        $escape = [int][char]$State.Text[$State.Index]
        $State.Index++
        if ($escape -eq 0x22) { [void]$builder.Append([char]0x22); continue }
        if ($escape -eq 0x5C) { [void]$builder.Append([char]0x5C); continue }
        if ($escape -eq 0x2F) { [void]$builder.Append([char]0x2F); continue }
        if ($escape -eq 0x62) { [void]$builder.Append([char]0x08); continue }
        if ($escape -eq 0x66) { [void]$builder.Append([char]0x0C); continue }
        if ($escape -eq 0x6E) { [void]$builder.Append([char]0x0A); continue }
        if ($escape -eq 0x72) { [void]$builder.Append([char]0x0D); continue }
        if ($escape -eq 0x74) { [void]$builder.Append([char]0x09); continue }
        if ($escape -ne 0x75 -or ($State.Index + 4) -gt $State.Text.Length) {
            throw "npm package-lock JSON string contains an invalid escape at offset $($State.Index - 1)."
        }
        $hex = $State.Text.Substring($State.Index, 4)
        if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') {
            throw "npm package-lock JSON string contains an invalid Unicode escape at offset $($State.Index)."
        }
        $unit = [Convert]::ToInt32($hex, 16)
        $State.Index += 4
        if ($unit -ge 0xD800 -and $unit -le 0xDBFF) {
            if (($State.Index + 6) -gt $State.Text.Length -or
                [int][char]$State.Text[$State.Index] -ne 0x5C -or
                [int][char]$State.Text[$State.Index + 1] -ne 0x75) {
                throw 'npm package-lock JSON string contains an unpaired high surrogate.'
            }
            $lowHex = $State.Text.Substring($State.Index + 2, 4)
            if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$') {
                throw 'npm package-lock JSON string contains an invalid low-surrogate escape.'
            }
            $lowUnit = [Convert]::ToInt32($lowHex, 16)
            if ($lowUnit -lt 0xDC00 -or $lowUnit -gt 0xDFFF) {
                throw 'npm package-lock JSON string contains an unpaired high surrogate.'
            }
            $State.Index += 6
            $scalar = 0x10000 + (($unit - 0xD800) * 0x400) + ($lowUnit - 0xDC00)
            [void]$builder.Append([char]::ConvertFromUtf32($scalar))
            continue
        }
        if ($unit -ge 0xDC00 -and $unit -le 0xDFFF) {
            throw 'npm package-lock JSON string contains an unpaired low surrogate.'
        }
        [void]$builder.Append([char]$unit)
    }
    throw 'npm package-lock JSON string is unterminated.'
}

function Read-NpmJsonNumber {
    param([Parameter(Mandatory = $true)] $State)

    $start = $State.Index
    if ([int][char]$State.Text[$State.Index] -eq 0x2D) {
        $State.Index++
        if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON number is incomplete.' }
    }
    $first = [int][char]$State.Text[$State.Index]
    if ($first -eq 0x30) {
        $State.Index++
        if ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -ge 0x30 -and $next -le 0x39) {
                throw "npm package-lock JSON number has a leading zero at offset $start."
            }
        }
    }
    elseif ($first -ge 0x31 -and $first -le 0x39) {
        while ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -lt 0x30 -or $next -gt 0x39) { break }
            $State.Index++
        }
    }
    else {
        throw "npm package-lock JSON number is invalid at offset $start."
    }

    $isInteger = $true
    if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x2E) {
        $isInteger = $false
        $State.Index++
        $fractionStart = $State.Index
        while ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -lt 0x30 -or $next -gt 0x39) { break }
            $State.Index++
        }
        if ($State.Index -eq $fractionStart) { throw 'npm package-lock JSON fraction is missing digits.' }
    }
    if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -in @(0x45, 0x65)) {
        $isInteger = $false
        $State.Index++
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -in @(0x2B, 0x2D)) {
            $State.Index++
        }
        $exponentStart = $State.Index
        while ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -lt 0x30 -or $next -gt 0x39) { break }
            $State.Index++
        }
        if ($State.Index -eq $exponentStart) { throw 'npm package-lock JSON exponent is missing digits.' }
    }
    $raw = $State.Text.Substring($start, $State.Index - $start)
    return New-NpmJsonNode -TokenType $(if ($isInteger) { 'Integer' } else { 'Number' }) -Value $raw
}

function Read-NpmJsonValue {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)][int] $Depth
    )

    if ($Depth -gt 128) { throw 'npm package-lock JSON exceeds the maximum nesting depth.' }
    Add-NpmJsonSemanticToken -State $State
    Skip-NpmJsonWhitespace -State $State
    if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON ends before a value.' }
    $code = [int][char]$State.Text[$State.Index]

    if ($code -eq 0x7B) {
        $State.Index++
        $properties = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        Skip-NpmJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x7D) {
            $State.Index++
            return New-NpmJsonNode -TokenType Object -Properties $properties
        }
        while ($true) {
            $nameOffset = $State.Index
            Add-NpmJsonSemanticToken -State $State
            $name = Read-NpmJsonString -State $State
            if ($properties.ContainsKey($name)) {
                throw "npm package-lock JSON contains a duplicate object key at offset $nameOffset."
            }
            Skip-NpmJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length -or [int][char]$State.Text[$State.Index] -ne 0x3A) {
                throw "npm package-lock JSON expected ':' after the object key at offset $nameOffset."
            }
            $State.Index++
            $value = Read-NpmJsonValue -State $State -Depth ($Depth + 1)
            $properties.Add($name, $value)
            Skip-NpmJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON object is unterminated.' }
            $delimiter = [int][char]$State.Text[$State.Index]
            $State.Index++
            if ($delimiter -eq 0x7D) { break }
            if ($delimiter -ne 0x2C) { throw 'npm package-lock JSON object expected a comma or closing brace.' }
            Skip-NpmJsonWhitespace -State $State
        }
        return New-NpmJsonNode -TokenType Object -Properties $properties
    }

    if ($code -eq 0x5B) {
        $State.Index++
        $items = New-Object 'System.Collections.Generic.List[object]'
        Skip-NpmJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x5D) {
            $State.Index++
            return New-NpmJsonNode -TokenType Array -Items @()
        }
        while ($true) {
            [void]$items.Add((Read-NpmJsonValue -State $State -Depth ($Depth + 1)))
            Skip-NpmJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON array is unterminated.' }
            $delimiter = [int][char]$State.Text[$State.Index]
            $State.Index++
            if ($delimiter -eq 0x5D) { break }
            if ($delimiter -ne 0x2C) { throw 'npm package-lock JSON array expected a comma or closing bracket.' }
            Skip-NpmJsonWhitespace -State $State
        }
        return New-NpmJsonNode -TokenType Array -Items ([object[]]$items.ToArray())
    }

    if ($code -eq 0x22) {
        return New-NpmJsonNode -TokenType String -Value (Read-NpmJsonString -State $State)
    }
    if ($code -eq 0x74 -and ($State.Index + 4) -le $State.Text.Length -and
        $State.Text.Substring($State.Index, 4) -ceq 'true') {
        $State.Index += 4
        return New-NpmJsonNode -TokenType Boolean -Value $true
    }
    if ($code -eq 0x66 -and ($State.Index + 5) -le $State.Text.Length -and
        $State.Text.Substring($State.Index, 5) -ceq 'false') {
        $State.Index += 5
        return New-NpmJsonNode -TokenType Boolean -Value $false
    }
    if ($code -eq 0x6E -and ($State.Index + 4) -le $State.Text.Length -and
        $State.Text.Substring($State.Index, 4) -ceq 'null') {
        $State.Index += 4
        return New-NpmJsonNode -TokenType Null -Value $null
    }
    if ($code -eq 0x2D -or ($code -ge 0x30 -and $code -le 0x39)) {
        return Read-NpmJsonNumber -State $State
    }
    throw "npm package-lock JSON contains an unexpected token at offset $($State.Index)."
}

function ConvertFrom-NpmJsonStrict {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [ValidateRange(1, 50000)][int] $MaxTokens = 50000
    )

    $state = [pscustomobject]@{ Text = $Text; Index = 0; TokenCount = 0; MaxTokens = $MaxTokens }
    $value = Read-NpmJsonValue -State $state -Depth 0
    Skip-NpmJsonWhitespace -State $state
    if ($state.Index -ne $state.Text.Length) {
        throw "npm package-lock JSON contains trailing content at offset $($state.Index)."
    }
    return $value
}

function Get-NpmJsonTokenType {
    param($Token)

    if ($null -eq $Token) { return $null }
    return [string]$Token.TokenType
}

function Get-NpmJsonObjectProperty {
    param(
        [Parameter(Mandatory = $true)] $Token,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Name
    )

    if ((Get-NpmJsonTokenType -Token $Token) -cne 'Object') { return $null }
    $value = $null
    if ($Token.Properties.TryGetValue($Name, [ref]$value)) { return $value }
    return $null
}

function Get-NpmJsonObjectProperties {
    param([Parameter(Mandatory = $true)] $Token)

    if ((Get-NpmJsonTokenType -Token $Token) -cne 'Object') { return @() }
    return @($Token.Properties.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value }
    })
}

function Get-NpmJsonScalarValue {
    param([Parameter(Mandatory = $true)] $Token)

    if ((Get-NpmJsonTokenType -Token $Token) -in @('Object','Array')) {
        throw 'npm package-lock JSON value is not scalar.'
    }
    return $Token.Value
}

function Get-CanonicalNpmBinTarget {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context is not a safe relative package path: expected a non-empty string."
    }
    foreach ($character in ([string]$Value).ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "$Context is not a safe relative package path: control characters are forbidden."
        }
    }
    if (([string]$Value).Contains(':')) {
        throw "$Context is not a safe relative package path: colons are forbidden."
    }

    $normalized = ([string]$Value).Replace([char]'\', [char]'/')
    if ($normalized.StartsWith('/')) {
        throw "$Context is not a safe relative package path: absolute paths are forbidden."
    }

    $segments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($segment in @($normalized.Split([char[]]@([char]'/'), [System.StringSplitOptions]::None))) {
        if ($segment -ceq '.') {
            continue
        }
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '..') {
            throw "$Context is not a safe relative package path: empty and parent segments are forbidden."
        }
        [void]$segments.Add($segment)
    }
    if ($segments.Count -eq 0) {
        throw "$Context is not a safe relative package path: no package file is identified."
    }
    return [string]::Join('/', [string[]]$segments.ToArray())
}

function Get-NpmLockIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $LockPath,
        [Parameter(Mandatory = $true)][string] $ApprovedRegistry,
        [Parameter(Mandatory = $true)][string] $ExpectedRootIntegrity,
        [Parameter(Mandatory = $true)][string] $ExpectedVersion
    )

    try {
        $lockStream = [System.IO.File]::Open(
            [System.IO.Path]::GetFullPath($LockPath),
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $lockLength = $lockStream.Length
            if ($lockLength -gt 32MB) {
                throw 'npm package-lock exceeds the 32 MiB validation limit.'
            }
            $lockBytes = [System.Array]::CreateInstance([byte], [int]$lockLength)
            $lockOffset = 0
            while ($lockOffset -lt $lockBytes.Length) {
                $readCount = $lockStream.Read($lockBytes, $lockOffset, $lockBytes.Length - $lockOffset)
                if ($readCount -le 0) {
                    throw 'npm package-lock changed or ended while its validation snapshot was read.'
                }
                $lockOffset += $readCount
            }
            if ($lockStream.ReadByte() -ne -1 -or $lockStream.Length -ne $lockLength) {
                throw 'npm package-lock changed while its validation snapshot was read.'
            }
        }
        finally {
            $lockStream.Dispose()
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $lockText = $utf8.GetString($lockBytes)
        $lock = ConvertFrom-NpmJsonStrict -Text $lockText
    }
    catch {
        throw "npm package-lock is not valid JSON: $($_.Exception.Message)"
    }
    $integerType = 'Integer'
    $objectType = 'Object'
    $stringType = 'String'
    $booleanType = 'Boolean'
    $lockfileVersionToken = Get-NpmJsonObjectProperty -Token $lock -Name 'lockfileVersion'
    $packages = Get-NpmJsonObjectProperty -Token $lock -Name 'packages'
    if ($null -eq $packages -or (Get-NpmJsonTokenType -Token $packages) -ne $objectType) {
        throw 'npm package-lock does not contain an object packages closure.'
    }
    if ($null -eq $lockfileVersionToken -or (Get-NpmJsonTokenType -Token $lockfileVersionToken) -ne $integerType -or
        [string](Get-NpmJsonScalarValue -Token $lockfileVersionToken) -notin @('2', '3')) {
        $actualLockfileVersion = if ($null -eq $lockfileVersionToken) { '<missing>' }
            elseif ((Get-NpmJsonTokenType -Token $lockfileVersionToken) -in @('Object','Array')) {
                "<$((Get-NpmJsonTokenType -Token $lockfileVersionToken))>"
            }
            else { Get-NpmJsonScalarValue -Token $lockfileVersionToken }
        throw "npm package-lock must use integer lockfileVersion 2 or 3. Actual='$actualLockfileVersion'."
    }

    $rootProject = Get-NpmJsonObjectProperty -Token $packages -Name ''
    $rootDependenciesObject = $null
    if ($null -ne $rootProject) {
        $rootDependenciesObject = Get-NpmJsonObjectProperty -Token $rootProject -Name 'dependencies'
    }
    if ($null -eq $rootProject -or (Get-NpmJsonTokenType -Token $rootProject) -ne $objectType -or
        $null -eq $rootDependenciesObject -or (Get-NpmJsonTokenType -Token $rootDependenciesObject) -ne $objectType) {
        throw 'npm package-lock is missing its root project dependency entry.'
    }
    $rootDependencies = @(Get-NpmJsonObjectProperties -Token $rootDependenciesObject)
    if ($rootDependencies.Count -ne 1 -or [string]$rootDependencies[0].Name -cne 'skill-tools' -or
        (Get-NpmJsonTokenType -Token $rootDependencies[0].Value) -ne $stringType -or
        [string](Get-NpmJsonScalarValue -Token $rootDependencies[0].Value) -cne $ExpectedVersion) {
        throw "npm package-lock root dependencies must bind only skill-tools@$ExpectedVersion."
    }

    $approved = Normalize-RegistryUri -Value $ApprovedRegistry
    $entries = @()
    foreach ($property in @(Get-NpmJsonObjectProperties -Token $packages | Sort-Object Name)) {
        $packagePath = [string]$property.Name
        if ($packagePath -ceq '') {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($packagePath)) {
            throw 'npm lock contains a non-root whitespace package path.'
        }
        if (@($packagePath.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) {
            throw 'npm lock contains a package path with control characters.'
        }
        $package = $property.Value
        if ((Get-NpmJsonTokenType -Token $package) -ne $objectType) {
            throw "npm lock entry '$packagePath' must be an object."
        }
        $versionToken = Get-NpmJsonObjectProperty -Token $package -Name 'version'
        $resolvedToken = Get-NpmJsonObjectProperty -Token $package -Name 'resolved'
        $integrityToken = Get-NpmJsonObjectProperty -Token $package -Name 'integrity'
        $linkToken = Get-NpmJsonObjectProperty -Token $package -Name 'link'
        $inBundleToken = Get-NpmJsonObjectProperty -Token $package -Name 'inBundle'
        if ($null -eq $versionToken -or (Get-NpmJsonTokenType -Token $versionToken) -ne $stringType -or
            $null -eq $resolvedToken -or (Get-NpmJsonTokenType -Token $resolvedToken) -ne $stringType -or
            $null -eq $integrityToken -or (Get-NpmJsonTokenType -Token $integrityToken) -ne $stringType -or
            ($null -ne $linkToken -and ((Get-NpmJsonTokenType -Token $linkToken) -ne $booleanType -or [bool](Get-NpmJsonScalarValue -Token $linkToken))) -or
            ($null -ne $inBundleToken -and ((Get-NpmJsonTokenType -Token $inBundleToken) -ne $booleanType -or [bool](Get-NpmJsonScalarValue -Token $inBundleToken)))) {
            throw "npm lock entry '$packagePath' lacks string version/resolved/integrity or uses a link/bundled package."
        }
        $version = [string](Get-NpmJsonScalarValue -Token $versionToken)
        $resolved = [string](Get-NpmJsonScalarValue -Token $resolvedToken)
        $integrity = [string](Get-NpmJsonScalarValue -Token $integrityToken)
        foreach ($identityValue in @($version, $resolved, $integrity)) {
            if (@($identityValue.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) {
                throw "npm lock entry '$packagePath' contains control characters in closure identity fields."
            }
        }
        if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($resolved) -or
            -not (Test-NpmSha512Integrity -Integrity $integrity)) {
            throw "npm lock entry '$packagePath' lacks version, approved resolved URL, or SHA-512 integrity."
        }
        try {
            $resolvedUri = [Uri]$resolved
        }
        catch {
            throw "npm lock entry '$packagePath' has invalid resolved URL '$resolved'."
        }
        if (-not $resolvedUri.IsAbsoluteUri -or $resolvedUri.Scheme -cne 'https' -or
            -not [string]::IsNullOrEmpty($resolvedUri.UserInfo) -or
            -not [string]::IsNullOrEmpty($resolvedUri.Query) -or
            -not [string]::IsNullOrEmpty($resolvedUri.Fragment) -or
            -not $resolvedUri.AbsoluteUri.StartsWith($approved, [StringComparison]::Ordinal)) {
            throw "npm lock entry '$packagePath' resolved from untrusted endpoint '$resolved'."
        }
        $entries += [pscustomobject][ordered]@{
            path = $packagePath
            version = $version
            resolved = $resolved
            integrity = $integrity
        }
    }
    if ($entries.Count -eq 0) {
        throw 'npm package-lock dependency closure is empty.'
    }
    $root = @($entries | Where-Object { $_.path -ceq 'node_modules/skill-tools' })
    if ($root.Count -ne 1 -or [string]$root[0].version -cne $ExpectedVersion -or
        [string]$root[0].integrity -cne $ExpectedRootIntegrity) {
        throw 'npm package-lock root version or integrity does not match the resolved skill-tools package.'
    }
    $rootPackage = Get-NpmJsonObjectProperty -Token $packages -Name 'node_modules/skill-tools'
    $rootBinObject = $null
    if ($null -ne $rootPackage) {
        $rootBinObject = Get-NpmJsonObjectProperty -Token $rootPackage -Name 'bin'
    }
    $rootBins = @()
    if ($null -ne $rootBinObject -and (Get-NpmJsonTokenType -Token $rootBinObject) -eq $objectType) {
        $rootBins = @(Get-NpmJsonObjectProperties -Token $rootBinObject)
    }
    if ($rootBins.Count -ne 1 -or [string]$rootBins[0].Name -cne 'skill-tools' -or
        (Get-NpmJsonTokenType -Token $rootBins[0].Value) -ne $stringType) {
        throw 'npm package-lock contains an unsafe or missing skill-tools bin target.'
    }
    try {
        $rootBinTarget = Get-CanonicalNpmBinTarget `
            -Value ([string](Get-NpmJsonScalarValue -Token $rootBins[0].Value)) `
            -Context 'npm package-lock skill-tools bin target'
    }
    catch {
        throw "npm package-lock contains an unsafe or missing skill-tools bin target. $($_.Exception.Message)"
    }

    $canonicalLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        [void]$canonicalLines.Add("$($entry.path)`t$($entry.version)`t$($entry.resolved)`t$($entry.integrity)")
    }
    $canonicalLines.Sort([StringComparer]::Ordinal)
    $canonical = [string]::Join("`n", $canonicalLines) + "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $closureSha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    return [ordered]@{
        packageLockSha256 = Get-BytesSha256 -Bytes $lockBytes
        closureSha256 = $closureSha256
        rootBinTarget = $rootBinTarget
        entries = $entries
    }
}

function Test-NpmSha512Integrity {
    param([Parameter(Mandatory = $true)][string] $Integrity)

    if ($Integrity -notmatch '^sha512-(?<value>[A-Za-z0-9+/]+={0,2})\z') {
        return $false
    }
    try {
        return ([Convert]::FromBase64String($Matches.value).Length -eq 64)
    }
    catch {
        return $false
    }
}

function Assert-NoConflictingGoEnvironment {
    param(
        [Parameter(Mandatory = $true)] $ExpectedEnvironment,
        [string[]] $DeniedEnvironmentNames = @()
    )

    foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
        $actual = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
            continue
        }
        if ([string]$actual -cne [string]$entry.Value) {
            throw "Untrusted Go environment override for '$($entry.Key)': '$actual'. Expected '$($entry.Value)'."
        }
    }
    foreach ($name in $DeniedEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Go environment override for '$name': '$actual'. Expected an unset value."
        }
    }
}

function Invoke-WithApprovedGoEnvironment {
    param(
        [Parameter(Mandatory = $true)] $ExpectedEnvironment,
        [Parameter(Mandatory = $true)] $DistributionPolicy,
        [string] $InstallBinPath,
        [scriptblock] $EnvironmentProbe,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingGoEnvironment -ExpectedEnvironment $ExpectedEnvironment -DeniedEnvironmentNames $deniedGoEnvironmentNames
    $dynamicNames = @('GOMODCACHE', 'GOCACHE', 'GOTMPDIR', 'GOBIN')
    foreach ($name in $dynamicNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Go environment override for '$name': '$actual'. Expected an unset value."
        }
    }
    foreach ($entry in $trustedGoDistribution.GetEnumerator()) {
        $actual = $DistributionPolicy.($entry.Key)
        if ($entry.Value -is [bool]) {
            if ($actual -isnot [bool] -or [bool]$actual -ne [bool]$entry.Value) {
                throw "Unsupported Go distribution control '$($entry.Key)'."
            }
        }
        elseif ($actual -isnot [string] -or [string]$actual -cne [string]$entry.Value) {
            throw "Unsupported Go distribution control '$($entry.Key)'."
        }
    }

    $previous = [ordered]@{}
    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ("standard-go-work-{0}" -f [guid]::NewGuid().ToString('N'))
    $moduleCachePath = Join-Path $workRoot 'module-cache'
    $buildCachePath = Join-Path $workRoot 'build-cache'
    $temporaryPath = Join-Path $workRoot 'tmp'
    $effectiveBinPath = if ([string]::IsNullOrWhiteSpace($InstallBinPath)) {
        Join-Path $workRoot 'bin'
    }
    else {
        [IO.Path]::GetFullPath($InstallBinPath)
    }
    try {
        $allNames = @(Get-OrdinalUniqueStrings -Values @(
            @($ExpectedEnvironment.Keys) + $deniedGoEnvironmentNames + $dynamicNames
        ))
        foreach ($name in $allNames) {
            $previous[$name] = [Environment]::GetEnvironmentVariable([string]$name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
        }
        foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
        }
        foreach ($path in @($moduleCachePath, $buildCachePath, $temporaryPath, $effectiveBinPath)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        [Environment]::SetEnvironmentVariable('GOMODCACHE', $moduleCachePath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('GOCACHE', $buildCachePath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('GOTMPDIR', $temporaryPath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('GOBIN', $effectiveBinPath, [EnvironmentVariableTarget]::Process)

        $processGoEnv = [Environment]::GetEnvironmentVariable('GOENV', [EnvironmentVariableTarget]::Process)
        if ([string]$processGoEnv -cne 'off') {
            throw "Canonical Go process environment requires GOENV=off. Actual='$processGoEnv'."
        }

        $effectiveNames = @(Get-OrdinalUniqueStrings -Values @(
            @($ExpectedEnvironment.Keys) + $dynamicNames
        ))
        $goCommand = $null
        if ($null -eq $EnvironmentProbe) {
            $goCommand = Assert-Command -Name 'go'
            $effectiveJson = (Invoke-CheckedCommand -Command $goCommand -Arguments (@('env', '-json') + $effectiveNames)) -join "`n"
            $effective = $effectiveJson | ConvertFrom-Json
        }
        else {
            $effective = & $EnvironmentProbe $effectiveNames
            if ($null -eq $effective) {
                throw 'The injected Go environment probe returned no evidence.'
            }
        }
        foreach ($name in $ExpectedEnvironment.Keys) {
            $property = $effective.PSObject.Properties[[string]$name]
            if ($null -eq $property) {
                throw "Go environment evidence omitted approved setting '$name'."
            }
            $actual = [string]$property.Value
            $expected = [string]$ExpectedEnvironment[$name]
            if ([string]$name -ceq 'GOENV' -and $expected -ceq 'off') {
                if ($actual -cne '' -and $actual -cne 'off') {
                    throw "Go did not confirm disabled environment configuration for 'GOENV': '$actual'. Expected an empty effective configuration path or 'off'."
                }
                continue
            }
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
        $expectedPaths = [ordered]@{
            GOMODCACHE = $moduleCachePath
            GOCACHE = $buildCachePath
            GOTMPDIR = $temporaryPath
            GOBIN = $effectiveBinPath
        }
        foreach ($entry in $expectedPaths.GetEnumerator()) {
            $effectivePath = [IO.Path]::GetFullPath([string]$effective.($entry.Key))
            $expectedPath = [IO.Path]::GetFullPath([string]$entry.Value)
            if (-not [string]::Equals($effectivePath, $expectedPath, $pathComparison)) {
                throw "Go did not apply isolated path '$($entry.Key)=$expectedPath'. Actual='$effectivePath'."
            }
            if (@(Get-ChildItem -LiteralPath $expectedPath -Force).Count -ne 0) {
                throw "The isolated Go path '$($entry.Key)' was not empty before resolution: '$expectedPath'."
            }
        }

        return & $Action $goCommand $effectiveBinPath
    }
    finally {
        try {
            if (Test-Path -LiteralPath $workRoot) {
                if ($null -ne $goCommand) {
                    [void](Invoke-CheckedCommand -Command $goCommand -Arguments @('clean', '-cache', '-modcache'))
                }
                Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
            }
        }
        finally {
            foreach ($entry in $previous.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
            }
        }
    }
}

function Get-ApprovedGoRuntimeVersion {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $VersionOutput,
        [Parameter(Mandatory = $true)][string] $ExpectedVersion
    )

    $lines = @($VersionOutput | ForEach-Object { [string]$_ })
    if ($lines.Count -ne 1) {
        throw "Go returned ambiguous runtime-version evidence: '$($lines -join ' ')'."
    }
    $versionMatch = [regex]::Match(
        [string]$lines[0],
        '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+) [^\s]+/[^\s]+$'
    )
    $runtimeVersion = if ($versionMatch.Success) { [string]$versionMatch.Groups['version'].Value } else { $null }
    if ([string]$runtimeVersion -cne $ExpectedVersion) {
        throw "Unapproved Go runtime '$($lines[0])'. Expected exact version '$ExpectedVersion'."
    }

    return $runtimeVersion
}

function Resolve-Pester {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)][string] $RepositoryEndpoint,
        [string] $RequestedInstallRoot
    )

    $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop
    $expectedRepository = $RepositoryEndpoint.TrimEnd('/')
    $actualRepository = ([string]$repository.SourceLocation).TrimEnd('/')
    if ($actualRepository -cne $expectedRepository) {
        throw "Untrusted PSGallery endpoint '$actualRepository'. Expected '$expectedRepository'."
    }

    $package = Find-Module -Name Pester -Repository PSGallery -ErrorAction Stop
    $version = [string]$package.Version
    if ([string]::IsNullOrWhiteSpace($version) -or $version.Contains('-')) {
        throw "Could not resolve a stable Pester version. Resolved='$version'."
    }

    $toolInstallPath = $null
    $modulePath = $null
    $moduleClosure = $null
    if ($ShouldInstall) {
        $toolInstallPath = New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'pester'
        try {
            Save-Module Pester -Repository PSGallery -RequiredVersion $version -Path $toolInstallPath -Force -ErrorAction Stop
            $modulePath = Join-Path (Join-Path (Join-Path $toolInstallPath 'Pester') $version) 'Pester.psd1'
            if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
                throw "Saved Pester module manifest was not found: $modulePath"
            }
            $manifest = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
            if ([string]$manifest.Version -cne $version) {
                throw "Saved Pester version mismatch. Expected '$version', got '$($manifest.Version)'."
            }
            [void](Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop)
            $invokePester = Get-Command Invoke-Pester -CommandType Function, Cmdlet -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $invokePester -or [string]$invokePester.Module.Version -cne $version) {
                throw "Saved Pester module did not expose Invoke-Pester@$version."
            }
            $moduleClosure = Get-DirectoryClosureIdentity -Path $toolInstallPath
            Add-ProcessPathValue -Name 'PSModulePath' -Value $toolInstallPath
        }
        catch {
            if (Test-Path -LiteralPath $toolInstallPath) {
                Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }

    $identity = "PowerShellGallery:Pester@$version#repository=$expectedRepository"
    if ($null -ne $moduleClosure) {
        $identity += "#moduleClosureSha256=$($moduleClosure.sha256)"
    }
    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = $identity
        identityKind = 'package-coordinate-and-installed-closure'
        installRoot = $toolInstallPath
        modulePath = $modulePath
        executablePath = $modulePath
        executableSha256 = if ($null -eq $modulePath) { $null } else { Get-FileSha256 -Path $modulePath }
        dependencyClosureSha256 = if ($null -eq $moduleClosure) { $null } else { [string]$moduleClosure.sha256 }
        dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $moduleClosure)
    }
}

function Resolve-SkillTools {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)][string] $Registry,
        [Parameter(Mandatory = $true)] $DistributionPolicy,
        [string] $RequestedInstallRoot
    )

    if ([string]$DistributionPolicy.configIsolation -cne 'empty-config-and-workdir' -or
        [string]$DistributionPolicy.environmentOverridePolicy -cne 'deny-by-default' -or
        [string]$DistributionPolicy.dependencyAcquisition -cne 'package-lock' -or
        [string]$DistributionPolicy.installEnvironment -cne 'isolated-prefix' -or
        -not [bool]$DistributionPolicy.ignoreScripts -or
        -not [bool]$DistributionPolicy.recordDependencyClosureIntegrity) {
        throw 'npm distribution policy is incomplete or untrusted.'
    }

    $npmCommand = Assert-NpmCommand
    $nodeCommand = Assert-Command -Name 'node'
    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ("standard-npm-work-{0}" -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $workRoot)
    $toolInstallPath = if ($ShouldInstall) {
        New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'skill-tools'
    }
    else {
        $null
    }
    try {
        return Invoke-WithApprovedNpmEnvironment -NpmCommand $npmCommand -ApprovedRegistry $Registry -WorkPath $workRoot -Action {
            param($approvedRegistry)

            $registryArgument = "--registry=$approvedRegistry"
            $versionJson = (Invoke-CheckedCommand -Command $npmCommand -Arguments @('view', 'skill-tools', 'version', '--json', $registryArgument)) -join "`n"
            $parsedVersion = $versionJson | ConvertFrom-Json
            if ($parsedVersion -isnot [string]) {
                throw 'npm returned a non-string skill-tools version.'
            }
            $version = [string]$parsedVersion
            if (-not (Test-StableNpmPackageVersion -Version $version)) {
                throw "Could not resolve a stable SemVer skill-tools version. Resolved='$version'."
            }

            $integrityJson = (Invoke-CheckedCommand -Command $npmCommand -Arguments @('view', "skill-tools@$version", 'dist.integrity', '--json', $registryArgument)) -join "`n"
            $parsedIntegrity = $integrityJson | ConvertFrom-Json
            if ($parsedIntegrity -isnot [string] -or -not (Test-NpmSha512Integrity -Integrity ([string]$parsedIntegrity))) {
                throw 'npm did not return a SHA-512 package integrity for skill-tools.'
            }
            $integrity = [string]$parsedIntegrity

            $lockIdentity = $null
            $executablePath = $null
            $executableSha256 = $null
            $entryPointPath = $null
            $entryPointSha256 = $null
            $nodeSha256 = $null
            $installedClosureSha256 = $null
            $executableVerified = $false
            if ($ShouldInstall) {
                $controlledProjectConfig = @(
                    "registry=$approvedRegistry",
                    'dry-run=false',
                    'ignore-scripts=true',
                    'package-lock=true',
                    'omit-lockfile-registry-resolved=false',
                    'audit=false',
                    'fund=false'
                ) -join [Environment]::NewLine
                [IO.File]::WriteAllText((Join-Path $toolInstallPath '.npmrc'), $controlledProjectConfig + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
                $packageJsonPath = Join-Path $toolInstallPath 'package.json'
                $packageJson = [ordered]@{
                    name = 'standard-validation-skill-tools'
                    private = $true
                    version = '1.0.0'
                    dependencies = [ordered]@{ 'skill-tools' = $version }
                } | ConvertTo-Json -Depth 5
                [IO.File]::WriteAllText($packageJsonPath, $packageJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

                [void](Invoke-CheckedCommand -Command $npmCommand -Arguments @(
                    'install', '--package-lock-only', '--ignore-scripts=true', '--dry-run=false',
                    '--package-lock=true', '--omit-lockfile-registry-resolved=false',
                    '--workspaces=false', '--global=false', '--replace-registry-host=never', '--no-audit', '--no-fund',
                    "--prefix=$toolInstallPath", $registryArgument
                ))
                $lockPath = Join-Path $toolInstallPath 'package-lock.json'
                if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
                    throw 'npm did not create the required package-lock.json.'
                }
                $lockIdentity = Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry $approvedRegistry -ExpectedRootIntegrity $integrity -ExpectedVersion $version
                $lockBeforeInstall = [string]$lockIdentity.packageLockSha256

                [void](Invoke-CheckedCommand -Command $npmCommand -Arguments @(
                    'ci', '--ignore-scripts=true', '--dry-run=false', '--workspaces=false', '--global=false',
                    '--replace-registry-host=never', '--no-audit', '--no-fund',
                    "--prefix=$toolInstallPath", $registryArgument
                ))
                if ((Get-FileSha256 -Path $lockPath) -cne $lockBeforeInstall) {
                    throw 'npm ci modified the verified package-lock.json.'
                }
                [void](Invoke-CheckedCommand -Command $npmCommand -Arguments @(
                    'ls', '--all', '--loglevel=error', "--prefix=$toolInstallPath"
                ))
                $installedManifestPath = Join-Path $toolInstallPath 'node_modules/skill-tools/package.json'
                if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
                    throw "Installed skill-tools manifest was not found: $installedManifestPath"
                }
                $installedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $installedManifestPath | ConvertFrom-Json
                if ($installedManifest.name -isnot [string] -or [string]$installedManifest.name -cne 'skill-tools' -or
                    $installedManifest.version -isnot [string] -or [string]$installedManifest.version -cne $version) {
                    throw "Installed skill-tools package identity mismatch. Expected 'skill-tools@$version'."
                }
                $installedBins = @($installedManifest.bin.PSObject.Properties)
                if ($installedBins.Count -ne 1 -or [string]$installedBins[0].Name -cne 'skill-tools' -or
                    $installedBins[0].Value -isnot [string]) {
                    throw 'Installed skill-tools bin metadata does not match package-lock.'
                }
                try {
                    $installedBinTarget = Get-CanonicalNpmBinTarget `
                        -Value ([string]$installedBins[0].Value) `
                        -Context 'Installed skill-tools bin target'
                }
                catch {
                    throw "Installed skill-tools bin metadata does not match package-lock. $($_.Exception.Message)"
                }
                if ([string]$installedBinTarget -cne [string]$lockIdentity.rootBinTarget) {
                    throw 'Installed skill-tools bin metadata does not match package-lock.'
                }

                $packageRoot = [IO.Path]::GetFullPath((Join-Path $toolInstallPath 'node_modules/skill-tools')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
                $entryPointPath = [IO.Path]::GetFullPath((Join-Path $packageRoot $installedBinTarget))
                $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    [StringComparison]::OrdinalIgnoreCase
                }
                else {
                    [StringComparison]::Ordinal
                }
                if (-not $entryPointPath.StartsWith($packageRoot, $pathComparison) -or
                    -not (Test-Path -LiteralPath $entryPointPath -PathType Leaf)) {
                    throw 'Installed skill-tools entry point escapes or is absent from its package root.'
                }
                $executablePath = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    Join-Path $toolInstallPath 'node_modules\.bin\skill-tools.cmd'
                }
                else {
                    Join-Path $toolInstallPath 'node_modules/.bin/skill-tools'
                }
                if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                    throw "Installed skill-tools executable was not found: $executablePath"
                }
                [void](Invoke-CheckedCommand -Command $nodeCommand -Arguments @($entryPointPath, '--help'))
                $executableVerified = $true
                $executableSha256 = Get-FileSha256 -Path $executablePath
                $entryPointSha256 = Get-FileSha256 -Path $entryPointPath
                $nodeSha256 = Get-FileSha256 -Path $nodeCommand
                $installedClosureSha256 = [string](Get-DirectoryClosureIdentity -Path $toolInstallPath).sha256
                Add-ProcessPathValue -Name 'PATH' -Value (Split-Path -Parent $executablePath)
            }

            $identity = "npm:skill-tools@$version#$integrity#registry=$approvedRegistry"
            if ($null -ne $lockIdentity) {
                $identity += "#packageLockSha256=$($lockIdentity.packageLockSha256)#dependencyClosureSha256=$($lockIdentity.closureSha256)#executableSha256=$executableSha256#installedClosureSha256=$installedClosureSha256"
            }
            return [ordered]@{
                resolvedVersion = $version
                resolvedIdentity = $identity
                identityKind = 'registry-integrity-and-locked-dependency-closure'
                installRoot = $toolInstallPath
                executablePath = $executablePath
                executableSha256 = $executableSha256
                packageLockSha256 = if ($null -eq $lockIdentity) { $null } else { [string]$lockIdentity.packageLockSha256 }
                dependencyClosureSha256 = if ($null -eq $lockIdentity) { $null } else { [string]$lockIdentity.closureSha256 }
                dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $lockIdentity)
                installedClosureSha256 = $installedClosureSha256
                entryPointPath = $entryPointPath
                entryPointSha256 = $entryPointSha256
                nodePath = $nodeCommand
                nodeSha256 = $nodeSha256
                executableVerified = $executableVerified
            }
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($toolInstallPath) -and (Test-Path -LiteralPath $toolInstallPath)) {
            Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-SkillValidator {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)] $ToolPolicy,
        [string] $RequestedInstallRoot
    )

    $modulePath = 'github.com/agent-ecosystem/skill-validator'
    $commandPath = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    $expectedEnvironment = [ordered]@{}
    foreach ($entry in $trustedGoEnvironment.GetEnumerator()) {
        $expectedEnvironment[$entry.Key] = [string]$ToolPolicy.goEnvironment.($entry.Key)
    }

    $toolInstallPath = if ($ShouldInstall) {
        New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'skill-validator'
    }
    else {
        $null
    }
    $installBinPath = if ($ShouldInstall) { Join-Path $toolInstallPath 'bin' } else { $null }

    try {
        return Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -DistributionPolicy $ToolPolicy.goDistribution -InstallBinPath $installBinPath -Action {
            param($goCommand, $effectiveBinPath)

            $goRuntimeVersion = Get-ApprovedGoRuntimeVersion `
                -VersionOutput @(Invoke-CheckedCommand -Command $goCommand -Arguments @('version')) `
                -ExpectedVersion ([string]$ToolPolicy.goRuntimeVersion)

            $metadataJson = (Invoke-CheckedCommand -Command $goCommand -Arguments @('list', '-m', '-json', "$modulePath@latest")) -join "`n"
            $metadata = $metadataJson | ConvertFrom-Json
            $version = [string]$metadata.Version
            if ([string]$metadata.Path -cne $modulePath -or -not (Test-StableGoModuleVersion -Version $version)) {
                throw "Go did not resolve the expected stable release for skill-validator. Path='$($metadata.Path)' Version='$version'."
            }

            $executablePath = $null
            $executableSha256 = $null
            $installedClosure = $null
            if ($ShouldInstall) {
                [void](Invoke-CheckedCommand -Command $goCommand -Arguments @('install', "$commandPath@$version"))
                $executableName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    'skill-validator.exe'
                }
                else {
                    'skill-validator'
                }
                $executablePath = [IO.Path]::GetFullPath((Join-Path $effectiveBinPath $executableName))
                if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                    throw "Installed skill-validator executable was not found: $executablePath"
                }

                $buildInfo = @(Invoke-CheckedCommand -Command $goCommand -Arguments @('version', '-m', $executablePath))
                $modulePattern = '^\s*mod\s+{0}\s+{1}\s+h1:[A-Za-z0-9+/=]+\s*$' -f
                    [regex]::Escape($modulePath), [regex]::Escape($version)
                if (@($buildInfo | Where-Object { $_ -match $modulePattern }).Count -ne 1) {
                    throw "Installed skill-validator build identity did not bind '$modulePath@$version'."
                }
                [void](Invoke-CheckedCommand -Command $executablePath -Arguments @('--help'))
                $executableSha256 = Get-FileSha256 -Path $executablePath
                $installedClosure = Get-DirectoryClosureIdentity -Path $toolInstallPath
                Add-ProcessPathValue -Name 'PATH' -Value $effectiveBinPath
            }

            $identity = "go:$modulePath@$version#goRuntime=$goRuntimeVersion#proxy=$($ToolPolicy.proxy)#sumdb=$($ToolPolicy.checksumDatabase)#moduleCache=$($ToolPolicy.goDistribution.moduleCacheIsolation)#buildCache=$($ToolPolicy.goDistribution.buildCacheIsolation)#goflags=empty#temporaryDirectory=$($ToolPolicy.goDistribution.temporaryDirectoryIsolation)#binaryInstall=$($ToolPolicy.goDistribution.binaryInstallIsolation)"
            if ($null -ne $installedClosure) {
                $identity += "#binarySha256=$executableSha256#installedClosureSha256=$($installedClosure.sha256)"
            }
            return [ordered]@{
                resolvedVersion = $version
                resolvedIdentity = $identity
                identityKind = 'go-module-version-build-info-and-binary-hash'
                installRoot = $toolInstallPath
                executablePath = $executablePath
                executableSha256 = $executableSha256
                dependencyClosureSha256 = if ($null -eq $installedClosure) { $null } else { [string]$installedClosure.sha256 }
                dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $installedClosure)
                goRuntimeVersion = $goRuntimeVersion
                moduleCacheIsolation = [string]$ToolPolicy.goDistribution.moduleCacheIsolation
                buildCacheIsolation = [string]$ToolPolicy.goDistribution.buildCacheIsolation
                temporaryDirectoryIsolation = [string]$ToolPolicy.goDistribution.temporaryDirectoryIsolation
                binaryInstallIsolation = [string]$ToolPolicy.goDistribution.binaryInstallIsolation
            }
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($toolInstallPath) -and (Test-Path -LiteralPath $toolInstallPath)) {
            Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Resolve-SkillSpector {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)] $ToolPolicy,
        [string] $RequestedInstallRoot
    )

    $pythonCommand = Assert-Command -Name 'python'
    $closureHelperPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Resolve-PythonWheelClosure.py'))
    if (-not (Test-Path -LiteralPath $closureHelperPath -PathType Leaf)) {
        throw "Python wheel closure helper not found: $closureHelperPath"
    }
    $closureHelperSha256 = Get-FileSha256 -Path $closureHelperPath
    $approvedIndex = Normalize-RegistryUri -Value ([string]$ToolPolicy.pythonPackageIndex)
    Assert-NoConflictingPipEnvironment -ApprovedIndex $approvedIndex
    Assert-NoConflictingPythonEnvironment
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
    $assetUri = Get-ApprovedSkillSpectorAssetUri -Value ([string]$wheel.browser_download_url) -Tag $tag -FileName $expectedWheelName

    $digest = [string]$wheel.digest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'SkillSpector release wheel does not expose a SHA-256 digest.'
    }

    $interpreterIsolation = [string]$ToolPolicy.pythonDistribution.interpreterIsolation
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("skillspector-{0}-{1}" -f $version, [guid]::NewGuid().ToString('N'))
    $wheelhouse = Join-Path $tempRoot 'wheelhouse'
    [void](New-Item -ItemType Directory -Path $wheelhouse -Force)

    $closure = $null
    $installEnvironment = $null
    $toolInstallPath = $null
    $executablePath = $null
    $executableSha256 = $null
    $installedClosure = $null
    $backtrackingEvidence = $null
    $consoleEntryPoint = $null
    $installedMetadataVerification = $null
    try {
        $wheelPath = Join-Path $tempRoot ([string]$wheel.name)
        Invoke-WebRequest -Uri $assetUri -Headers $headers -OutFile $wheelPath -UseBasicParsing

        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheelPath).Hash.ToLowerInvariant()
        $expectedHash = $digest.Substring('sha256:'.Length)
        if ($actualHash -cne $expectedHash) {
            throw "SkillSpector wheel hash mismatch. Expected '$expectedHash', got '$actualHash'."
        }

        $wheelMetadata = Get-PythonWheelMetadata -WheelPath $wheelPath
        Assert-SkillSpectorWheelIdentity -ReleaseVersion $version -WheelFileName ([string]$wheel.name) -MetadataName ([string]$wheelMetadata.name) -MetadataVersion ([string]$wheelMetadata.version)
        Assert-NoPythonDirectReferences -Metadata $wheelMetadata -WheelFileName ([string]$wheel.name)

        # GitHub credentials are needed only for the authenticated release API/download calls above.
        # No resolver-managed Python or package-manager subprocess may inherit them.
        if ($headers.ContainsKey('Authorization')) { [void]$headers.Remove('Authorization') }
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue

        if ($ShouldInstall) {
            $toolInstallPath = New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'skillspector'
            $venvPath = Join-Path $toolInstallPath 'venv'
            $installation = Invoke-WithApprovedPipEnvironment -ApprovedIndex $approvedIndex -Action {
                [void](Invoke-IsolatedPythonCommand -PythonCommand $pythonCommand -Arguments @('-S', '-m', 'venv', $venvPath))
                $venvPython = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    Join-Path $venvPath 'Scripts\python.exe'
                }
                else {
                    Join-Path $venvPath 'bin/python'
                }
                if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
                    throw "SkillSpector isolated virtual environment Python was not created: $venvPython"
                }

                $dependencyResolutionPath = Join-Path $tempRoot 'dependency-resolution'
                $candidatePath = Join-Path $tempRoot 'verified-candidates'
                $resolutionEvidence = Resolve-PythonWheelClosureFromApprovedIndex `
                    -PythonCommand $venvPython `
                    -HelperPath $closureHelperPath `
                    -ApprovedIndex $approvedIndex `
                    -RootWheelPath $wheelPath `
                    -RootWheelSha256 $expectedHash `
                    -CandidatePath $candidatePath `
                    -WheelhousePath $wheelhouse `
                    -WorkPath $dependencyResolutionPath

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
                $selectedEntries = @($resolutionEvidence.selectedEntries)
                if ($selectedEntries.Count -ne @($manifest.entries).Count) {
                    throw "Offline backtracking selection count mismatch. Expected '$(@($manifest.entries).Count)', got '$($selectedEntries.Count)'."
                }
                foreach ($entry in @($manifest.entries)) {
                    $selectedMatches = @($selectedEntries | Where-Object {
                        [string]$_.normalizedName -ceq [string]$entry.normalizedName -and
                        [string]$_.version -ceq [string]$entry.version -and
                        [string]$_.file -ceq [string]$entry.file -and
                        [string]$_.sha256 -ceq [string]$entry.sha256
                    })
                    if ($selectedMatches.Count -ne 1) {
                        throw "Offline backtracking evidence did not bind '$($entry.file)'."
                    }
                }

                $planPath = Join-Path $tempRoot 'skillspector-offline-install-plan.json'
                [void](Invoke-IsolatedPythonCommand -PythonCommand $venvPython -Arguments @(
                    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir',
                    '--dry-run', '--ignore-installed', '--no-index', "--find-links=$wheelhouse",
                    '--only-binary=:all:', '--require-hashes', '--report', $planPath, '-r', $lockPath
                ))
                if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
                    throw 'Offline SkillSpector dependency resolution did not produce an install plan.'
                }
                $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
                $planned = @($plan.install)
                if ($planned.Count -ne @($manifest.entries).Count) {
                    throw "Offline SkillSpector dependency plan count mismatch. Expected '$(@($manifest.entries).Count)', got '$($planned.Count)'."
                }
                foreach ($entry in @($manifest.entries)) {
                    $plannedMatches = @($planned | Where-Object {
                        (Normalize-PythonPackageName -Name ([string]$_.metadata.name)) -ceq [string]$entry.normalizedName -and
                        [string]$_.metadata.version -ceq [string]$entry.version
                    })
                    if ($plannedMatches.Count -ne 1) {
                        throw "Offline SkillSpector dependency plan did not bind '$($entry.name)==$($entry.version)'."
                    }
                }

                [void](Invoke-IsolatedPythonCommand -PythonCommand $venvPython -Arguments @(
                    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir',
                    '--no-index', "--find-links=$wheelhouse", '--require-hashes', '--no-deps', '--force-reinstall',
                    '-r', $lockPath
                ))

                # Read the installed dist-info files directly. Starting the installed interpreter here
                # would process site-packages .pth startup lines before the resolver has verified metadata.
                $installedMetadata = Get-InstalledPythonDistributionMetadata `
                    -VirtualEnvironmentPath $venvPath `
                    -DistributionName 'skillspector'
                if ([string]$installedMetadata.version -cne $version) {
                    throw "Installed SkillSpector version mismatch. Expected '$version', got '$($installedMetadata.version)'."
                }

                $installedExecutablePath = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    Join-Path $venvPath 'Scripts\skillspector.exe'
                }
                else {
                    Join-Path $venvPath 'bin/skillspector'
                }
                $installedExecutablePath = [IO.Path]::GetFullPath($installedExecutablePath)
                if (-not (Test-Path -LiteralPath $installedExecutablePath -PathType Leaf)) {
                    throw "Installed SkillSpector executable was not found: $installedExecutablePath"
                }

                return [ordered]@{
                    manifest = $manifest
                    executablePath = $installedExecutablePath
                    consoleEntryPoint = [string]$installedMetadata.consoleEntryPoint
                    installedMetadataVerification = 'static-dist-info-metadata'
                    resolutionEvidence = $resolutionEvidence
                }
            }
            $closure = $installation.manifest
            $backtrackingEvidence = $installation.resolutionEvidence
            $executablePath = [string]$installation.executablePath
            $consoleEntryPoint = [string]$installation.consoleEntryPoint
            $installedMetadataVerification = [string]$installation.installedMetadataVerification
            $installEnvironment = 'isolated-venv'
            $executableSha256 = Get-FileSha256 -Path $executablePath
            $installedClosure = Get-DirectoryClosureIdentity -Path $toolInstallPath
            Add-ProcessPathValue -Name 'PATH' -Value (Split-Path -Parent $executablePath)
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($toolInstallPath) -and (Test-Path -LiteralPath $toolInstallPath)) {
            Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $identity = "github:NVIDIA/SkillSpector@$tag#commit=$commitSha#asset=$digest#metadata=skillspector@$version#rootDirectReferences=blocked#credentialIsolation=github-token-cleared-before-python#dependencyClosure=unresolved"
    $identityKind = 'release-commit-asset-metadata'
    if ($null -ne $closure) {
        $identity = $identity.Replace('#dependencyClosure=unresolved', '#directReferences=blocked#pipOnlineDependencyTraversal=disabled#dependencyDiscovery=approved-simple-json-lazy#requiresPython=simple-json-wheel-metadata-normalized-specifier-set-current-interpreter#offlineBacktracking=verified')
        $identity += "#pythonIndex=$approvedIndex#pipVersion=$($backtrackingEvidence.pipVersion)#resolutionRounds=$($backtrackingEvidence.resolutionRounds)#candidateCount=$($backtrackingEvidence.candidateCount)#resolverHelperSha256=$closureHelperSha256#candidateInventorySha256=$($backtrackingEvidence.candidateInventorySha256)#selectionPlanSha256=$($backtrackingEvidence.selectionPlanSha256)#selectedClosureSha256=$($backtrackingEvidence.selectedClosureSha256)#installEnvironment=$installEnvironment#interpreterIsolation=$interpreterIsolation#installedMetadataVerification=$installedMetadataVerification#consoleEntryPoint=$consoleEntryPoint#offlineResolution=verified#dependencyClosureSha256=$($closure.closureSha256)#executableSha256=$executableSha256#installedClosureSha256=$($installedClosure.sha256)"
        $identityKind = 'release-commit-asset-metadata-dependency-closure-and-executable'
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = $identity
        identityKind = $identityKind
        installRoot = $toolInstallPath
        executablePath = $executablePath
        executableSha256 = $executableSha256
        pythonPackageIndex = $approvedIndex
        installEnvironment = $installEnvironment
        interpreterIsolation = $interpreterIsolation
        credentialIsolation = 'github-token-cleared-before-python'
        installedMetadataVerification = $installedMetadataVerification
        directReferencesAllowed = [bool]$ToolPolicy.pythonDistribution.allowDirectReferences
        pipOnlineDependencyTraversalAllowed = [bool]$ToolPolicy.pythonDistribution.allowPipOnlineDependencyTraversal
        dependencyDiscovery = [string]$ToolPolicy.pythonDistribution.candidateDiscovery
        requiresPythonPolicy = [string]$ToolPolicy.pythonDistribution.requiresPythonPolicy
        dependencyResolver = [string]$ToolPolicy.pythonDistribution.dependencyResolver
        yankedAllowed = [bool]$ToolPolicy.pythonDistribution.allowYanked
        resolverHelperPath = $closureHelperPath
        resolverHelperSha256 = $closureHelperSha256
        consoleEntryPoint = $consoleEntryPoint
        pipVersion = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.pipVersion }
        resolutionRounds = if ($null -eq $backtrackingEvidence) { $null } else { [int64]$backtrackingEvidence.resolutionRounds }
        candidateCount = if ($null -eq $backtrackingEvidence) { $null } else { [int64]$backtrackingEvidence.candidateCount }
        candidateInventorySha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.candidateInventorySha256 }
        selectionPlanSha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.selectionPlanSha256 }
        rawSelectionPlanSha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.rawSelectionPlanSha256 }
        selectedClosureSha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.selectedClosureSha256 }
        offlineResolutionVerified = if ($null -eq $closure) { $false } else { $true }
        dependencyClosureSha256 = if ($null -eq $closure) { $null } else { [string]$closure.closureSha256 }
        dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $closure)
        installedClosureSha256 = if ($null -eq $installedClosure) { $null } else { [string]$installedClosure.sha256 }
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
        trustedPowerShellRepository = $trustedPowerShellRepository
        trustedGoRuntimeVersion = $trustedGoRuntimeVersion
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
        'pester' {
            Resolve-Pester -ShouldInstall ([bool]$Install) -RepositoryEndpoint ([string]$policy.tools.pester.repository) -RequestedInstallRoot $InstallRoot
        }
        'skill-tools' {
            Resolve-SkillTools -ShouldInstall ([bool]$Install) -Registry ([string]$policy.tools.'skill-tools'.registry) -DistributionPolicy $policy.tools.'skill-tools'.npmDistribution -RequestedInstallRoot $InstallRoot
        }
        'skill-validator' {
            Resolve-SkillValidator -ShouldInstall ([bool]$Install) -ToolPolicy $policy.tools.'skill-validator' -RequestedInstallRoot $InstallRoot
        }
        'skillspector' {
            Resolve-SkillSpector -ShouldInstall ([bool]$Install) -ToolPolicy $policy.tools.skillspector -RequestedInstallRoot $InstallRoot
        }
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
        installRoot = $resolved.installRoot
        executablePath = $resolved.executablePath
        executableSha256 = $resolved.executableSha256
        dependencyClosureSha256 = $resolved.dependencyClosureSha256
        dependencyClosure = $resolved.dependencyClosure
    }
    if ($ToolName -eq 'pester') {
        $result.modulePath = $resolved.modulePath
    }
    if ($ToolName -eq 'skill-tools') {
        $result.registry = [string]$toolPolicy.registry
        $result.packageLockSha256 = $resolved.packageLockSha256
        $result.entryPointPath = $resolved.entryPointPath
        $result.entryPointSha256 = $resolved.entryPointSha256
        $result.nodePath = $resolved.nodePath
        $result.nodeSha256 = $resolved.nodeSha256
        $result.executableVerified = $resolved.executableVerified
        $result.installedClosureSha256 = $resolved.installedClosureSha256
    }
    if ($ToolName -eq 'skill-validator') {
        $result.proxy = [string]$toolPolicy.proxy
        $result.checksumDatabase = [string]$toolPolicy.checksumDatabase
        $result.goRuntimeVersion = [string]$resolved.goRuntimeVersion
        $result.moduleCacheIsolation = [string]$resolved.moduleCacheIsolation
        $result.buildCacheIsolation = [string]$resolved.buildCacheIsolation
        $result.temporaryDirectoryIsolation = [string]$resolved.temporaryDirectoryIsolation
        $result.binaryInstallIsolation = [string]$resolved.binaryInstallIsolation
    }
    if ($ToolName -eq 'skillspector') {
        $result.pythonPackageIndex = [string]$resolved.pythonPackageIndex
        $result.installEnvironment = $resolved.installEnvironment
        $result.interpreterIsolation = [string]$resolved.interpreterIsolation
        $result.credentialIsolation = [string]$resolved.credentialIsolation
        $result.installedMetadataVerification = $resolved.installedMetadataVerification
        $result.directReferencesAllowed = [bool]$resolved.directReferencesAllowed
        $result.pipOnlineDependencyTraversalAllowed = [bool]$resolved.pipOnlineDependencyTraversalAllowed
        $result.dependencyDiscovery = [string]$resolved.dependencyDiscovery
        $result.requiresPythonPolicy = [string]$resolved.requiresPythonPolicy
        $result.dependencyResolver = [string]$resolved.dependencyResolver
        $result.yankedAllowed = [bool]$resolved.yankedAllowed
        $result.resolverHelperPath = [string]$resolved.resolverHelperPath
        $result.resolverHelperSha256 = [string]$resolved.resolverHelperSha256
        $result.consoleEntryPoint = $resolved.consoleEntryPoint
        $result.pipVersion = $resolved.pipVersion
        $result.resolutionRounds = $resolved.resolutionRounds
        $result.candidateCount = $resolved.candidateCount
        $result.candidateInventorySha256 = $resolved.candidateInventorySha256
        $result.selectionPlanSha256 = $resolved.selectionPlanSha256
        $result.rawSelectionPlanSha256 = $resolved.rawSelectionPlanSha256
        $result.selectedClosureSha256 = $resolved.selectedClosureSha256
        $result.offlineResolutionVerified = [bool]$resolved.offlineResolutionVerified
        $result.dependencyClosureSha256 = $resolved.dependencyClosureSha256
        $result.dependencyClosure = $resolved.dependencyClosure
        $result.installedClosureSha256 = $resolved.installedClosureSha256
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
