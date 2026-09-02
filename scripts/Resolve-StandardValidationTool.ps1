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

function Resolve-Pester {
    param([bool] $ShouldInstall)

    $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop
    $expectedRepository = 'https://www.powershellgallery.com/api/v2'
    if ([string]$repository.SourceLocation.TrimEnd('/') -cne $expectedRepository) {
        throw "Untrusted PSGallery endpoint '$($repository.SourceLocation)'. Expected '$expectedRepository'."
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
    param([bool] $ShouldInstall)

    [void](Assert-Command -Name 'npm')
    $versionJson = (Invoke-CheckedCommand -Command 'npm' -Arguments @('view', 'skill-tools', 'version', '--json')) -join "`n"
    $version = [string]($versionJson | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace($version) -or $version.Contains('-')) {
        throw "Could not resolve a stable skill-tools version. Resolved='$version'."
    }

    $integrityJson = (Invoke-CheckedCommand -Command 'npm' -Arguments @('view', "skill-tools@$version", 'dist.integrity', '--json')) -join "`n"
    $integrity = [string]($integrityJson | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace($integrity)) {
        throw 'npm did not return package integrity for skill-tools.'
    }

    if ($ShouldInstall) {
        [void](Invoke-CheckedCommand -Command 'npm' -Arguments @('install', '--global', '--no-audit', '--no-fund', "skill-tools@$version"))
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = "npm:skill-tools@$version#$integrity"
        identityKind = 'registry-integrity'
    }
}

function Resolve-SkillValidator {
    param([bool] $ShouldInstall)

    [void](Assert-Command -Name 'go')
    $modulePath = 'github.com/agent-ecosystem/skill-validator'
    $commandPath = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    $metadataJson = (Invoke-CheckedCommand -Command 'go' -Arguments @('list', '-m', '-json', "$modulePath@latest")) -join "`n"
    $metadata = $metadataJson | ConvertFrom-Json
    $version = [string]$metadata.Version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'Go did not return a version for skill-validator.'
    }

    if ($ShouldInstall) {
        [void](Invoke-CheckedCommand -Command 'go' -Arguments @('install', "$commandPath@$version"))
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = "go:$modulePath@$version"
        identityKind = 'go-module-version'
    }
}

function Resolve-SkillSpector {
    param([bool] $ShouldInstall)

    $headers = Get-GitHubHeaders
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/NVIDIA/SkillSpector/releases/latest' -Headers $headers -Method Get
    if ($null -eq $release -or [bool]$release.draft -or [bool]$release.prerelease) {
        throw 'GitHub did not return a stable SkillSpector release.'
    }

    $tag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw 'SkillSpector latest release has no tag.'
    }
    $version = $tag.TrimStart('v')

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
    $digest = [string]$wheel.digest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'SkillSpector release wheel does not expose a SHA-256 digest.'
    }

    if ($ShouldInstall) {
        [void](Assert-Command -Name 'python')
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("skillspector-{0}-{1}" -f $version, [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $tempRoot -Force)
        try {
            $wheelPath = Join-Path $tempRoot ([string]$wheel.name)
            Invoke-WebRequest -Uri ([string]$wheel.browser_download_url) -Headers $headers -OutFile $wheelPath -UseBasicParsing
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheelPath).Hash.ToLowerInvariant()
            $expectedHash = $digest.Substring('sha256:'.Length)
            if ($actualHash -cne $expectedHash) {
                throw "SkillSpector wheel hash mismatch. Expected '$expectedHash', got '$actualHash'."
            }
            [void](Invoke-CheckedCommand -Command 'python' -Arguments @('-m', 'pip', 'install', '--disable-pip-version-check', $wheelPath))
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = "github:NVIDIA/SkillSpector@$tag#commit=$commitSha#asset=$digest"
        identityKind = 'release-commit-and-asset-digest'
    }
}

$policy = Get-Policy -Path $PolicyPath

if ($ValidatePolicyOnly) {
    $result = [ordered]@{
        schemaVersion = 1
        policy = [string]$policy.policy
        trustedSources = $trustedSources
        recordResolvedIdentityWhenAvailable = [bool]$policy.resolution.recordResolvedIdentityWhenAvailable
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        throw 'ToolName is required unless -ValidatePolicyOnly is specified.'
    }

    $resolved = switch ($ToolName) {
        'pester' { Resolve-Pester -ShouldInstall ([bool]$Install) }
        'skill-tools' { Resolve-SkillTools -ShouldInstall ([bool]$Install) }
        'skill-validator' { Resolve-SkillValidator -ShouldInstall ([bool]$Install) }
        'skillspector' { Resolve-SkillSpector -ShouldInstall ([bool]$Install) }
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
}

$json = $result | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $directory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

$json
