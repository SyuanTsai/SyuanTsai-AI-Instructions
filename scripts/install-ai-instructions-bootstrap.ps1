[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $CodexHome,
    [string[]] $ExcludedRepositoryUrls = @(),
    [string[]] $ExcludedRepositoryPaths = @(),
    [string] $SourceRepository,
    [string] $SourceCommit,
    [ValidateSet('git-checkout','github-codeload')][string] $Acquisition = 'git-checkout',
    [string] $ArchiveSha256,
    [string] $SourceArchivePath,
    [string] $ExpectedCurrentCommit,
    [string] $ExpectedUpdateMode,
    [string] $ExpectedUpdateChannel,
    [string] $ExpectedUpdateRef,
    [ValidateSet('Auto','V2V4','V3V5')][string] $WriterSchema = 'Auto'
)

if ($PSVersionTable.PSEdition -cne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7 -or [Environment]::Version.Major -lt 8) {
    throw [System.InvalidOperationException]::new('AI instructions installation requires pwsh 7 on .NET 8 or later; run this installer with pwsh 7. [ai-instructions-refusal-code=runtime-baseline-unavailable]')
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectionRuntimeAvailable = $false # P7E_TEST_FIXTURE_MARKER: production remains unavailable until production pins are installed.
if ($WriterSchema -ceq 'V3V5' -and -not $projectionRuntimeAvailable) {
    throw [System.InvalidOperationException]::new(
        'Catalog v3 and the projection runtime production pin are not available. [ai-instructions-refusal-code=projection-runtime-unavailable]'
    )
}

$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(
    'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquacieaWsOWinuaIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkY29kZXhIb21lID0gaWYgKC1ub3QgW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkZW52OkNPREVYX0hPTUUpKSB7ICRlbnY6Q09ERVhfSE9NRSB9IGVsc2UgeyBKb2luLVBhdGggJEhPTUUgJy5jb2RleCcgfTsgJiAoSm9pbi1QYXRoICRjb2RleEhvbWUgJ2hvb2tzXGJvb3RzdHJhcC1haS1pbnN0cnVjdGlvbnMucHMxJylg77yb5Zau57SU5ZWP5ZWP6aGM44CB6YeQ5riF6ZyA5rGC44CB56K66KqN5oiW6Kej6YeL5ZWP6aGM77yM5Lul5Y+K5YW25LuW5bCa5pyq6ZaL5aeL6KaP5YqDIGNvZGUg55qE5bel5L2c5LiN5b6X5Z+36KGMIGJvb3RzdHJhcOOAggotIEJvb3RzdHJhcCDnrKzkuIDmrKHlpLHmlZfoi6XmmI7norrlsazmlrzmspnnrrHmiJbmrIrpmZDmi5LntZXvvIzmiY3lj6/lhYjlj5blvpfmoLjlh4blvozph43oqabkuIDmrKHvvJvlkIzkuIAgdGFzayDkuI3lvpflho3mrKHph43ot5HjgILoi6XliIbpoZ7ngrogY29tcGF0aWJpbGl0eeOAgWNvbmZpZ3VyYXRpb24g5oiWIGludGVncml0ee+8jOW/hemgiOS/neeVmSBmYWlsLWNsb3NlZCDntZDmnpzkuJTkuI3lvpfph43oqabvvJvlm57loLHliIbpoZ7oiIcgcmVtZWRpYXRpb27vvIzkuI3lvpflgb3pgKAgY2FwYWJpbGl0eSBldmlkZW5jZe+8jOS5n+S4jeW+l+WcqCBjb25zdW1lciBSZXBvc2l0b3J5IOW7uueriyB3b3JrYXJvdW5k44CCCi0gYG5vdGlmeS1vbmx5YCDnmoQgYG91dGNvbWU9YXZhaWxhYmxlYCDlj6rmmK/mm7TmlrDpgJrnn6XvvIzooajnpLogdmVyaWZpZWQgY2FuZGlkYXRlIOWwmuacquWuieijne+8m+e5vOe6jOS9v+eUqOebruWJjSB2ZXJpZmllZCBydW50aW1l77yM5Y+q5pyJ5L2/55So6ICF5Y+m6KGM5piO56K65qC45YeG5pu05paw5pmC5omN5Z+36KGMIHVwZGF0ZXLjgIIKLSDlkIzmraXlrozmiJDlvozvvIzlhYjoroDlj5YgUmVwb3NpdG9yeSDmlrDlop7miJbmm7TmlrDnmoQgYEFHRU5UUy5tZGAg6IiH55uu5YmN5Lu75YuZ6YGp55So55qE6KaP5YmH5qih57WE77yb5L2/55So6ICF5piO56K65oyH5a6aIFNraWxsIOaIluS7u+WLmeespuWQiCBgLmFnZW50cy9za2lsbHMvYCDkuK3nmoQgU2tpbGwgZGVzY3JpcHRpb24g5pmC77yM5YaN6K6A5Y+W5bCN5oeJIGBTS0lMTC5tZGDjgIIKLSDku6UgYC5jb2RleC9haS1pbnN0cnVjdGlvbnMubWFuaWZlc3QuanNvbmAg566h55CG5YWx5LqrIEluc3RydWN0aW9ucyDoiIcgQWdlbnQgU2tpbGxz77yb5Y+q5pu05paw5pyq6KKr5YCL5Lq65L+u5pS555qE5Y+X566h55CG5qqU5qGI77yM5LiN6KaG5a+rIGN1c3RvbWl6ZWQgb3IgdW5tYW5hZ2VkIEluc3RydWN0aW9ucyBvciBBZ2VudCBTa2lsbHPjgIIKLSBSZXBvc2l0b3J5IOeahCBvcmlnaW4g6Iul5YiX5Zyo55uu5YmNIENvZGV4IEhvbWUg55qEIGBhaS1pbnN0cnVjdGlvbnMtc3luYy5qc29uYCDkuYsgYGV4Y2x1ZGVkUmVwb3NpdG9yeVVybHNg77yM5oiWIHRhc2sg5ZWf5YuV55uu6YyE5L2N5pa8IGBleGNsdWRlZFJlcG9zaXRvcnlQYXRoc2DvvIznm7TmjqXnlaXpgY7lkIzmraXjgIIKLSBSZXBvc2l0b3J5LWxvY2FsIEluc3RydWN0aW9uc+OAgVNraWxscyDoiIcgbWFuaWZlc3Qg5piv5omA5pyJIGJyYW5jaCDlhbHnlKjnmoTlgIvkurogcnVudGltZSBhcnRpZmFjdHPvvIzlv4XpoIjkv53mjIEgbG9jYWwgaWdub3JlZOOAguiLpSByZXNlcnZlZCBBZ2VudCBhcnRpZmFjdCDlt7LooqsgR2l0IHRyYWNrZWTvvIxib290c3RyYXAg5b+F6aCI5YWI5ZyoIFJlcG9zaXRvcnkg5aSW5a6M5pW05YKZ5Lu95qqU5qGI6IiHIEdpdCDni4DmhYvvvIzku6XpmpTpm6IgaW5kZXgg5bu656uL5Y+q5YyF5ZCr57K+56K6IHJlc2VydmVkIHBhdGggZGVsZXRpb25zIOeahOS4gOasoeaAp+acrOapnyByZW1lZGlhdGlvbiBjb21taXTvvIzkv53nlZnmiYDmnInnhKHpl5zorormm7TvvIzlho3kvp3mnIDmlrDkuK3lpK7kvobmupDph43lu7rkuKbnubznuozlkIzmraXvvJvkuI3lvpfoh6rli5UgcHVzaCBjb25zdW1lciBSZXBvc2l0b3J544CCUmVzZXJ2ZWQg56+E5ZyN5aSWIHRyYWNrZWQgZmlsZSDmiJbnhKHms5XlronlhajpmpTpm6LnmoTni4DmhYvku43poIggZmFpbCBjbG9zZWTjgII='
))

function Invoke-InstallerGit {
    param([Parameter(Mandatory = $true)][string] $WorkingDirectory,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $WorkingDirectory @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Get-InstallerMutationRelativePath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer mutation path is outside Codex Home: $fullPath"
    }
    return $fullPath.Substring($prefix.Length).Replace('\','/')
}

function Get-InstallerBootstrapSectionContent {
    param([Parameter(Mandatory = $true)][string] $AgentsPath,[Parameter(Mandatory = $true)][string] $Section)
    $normalizedSection = $Section.Trim() + "`n"
    $content = if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) { [System.IO.File]::ReadAllText($AgentsPath).Replace("`r`n","`n").Replace("`r","`n") } else { '' }
    $pattern = '(?ms)^## Repository Instructions Bootstrap\s*\n.*?(?=^##\s|\z)'
    $updated = if ([regex]::IsMatch($content,$pattern)) { [regex]::Replace($content,$pattern,$normalizedSection) }
    elseif ([string]::IsNullOrWhiteSpace($content)) { $normalizedSection }
    else { $content.TrimEnd() + "`n`n" + $normalizedSection }
    return $updated
}

function Test-InstallerHasProperty {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-InstallerMutationPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('File','Directory')][string] $ExpectedType
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $inspectionPath = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($inspectionPath)) {
        if (Test-Path -LiteralPath $inspectionPath) {
            $item = Get-Item -Force -LiteralPath $inspectionPath
            $isLeaf = $inspectionPath.Equals($fullPath,[System.StringComparison]::OrdinalIgnoreCase)
            $hasExpectedType = if (-not $isLeaf) { $item.PSIsContainer }
                elseif ($ExpectedType -ceq 'Directory') { $item.PSIsContainer }
                else { -not $item.PSIsContainer }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $hasExpectedType) {
                throw "Unsafe installer mutation path '$Path': '$inspectionPath' must be a non-reparse $($(if ($isLeaf) { $ExpectedType.ToLowerInvariant() } else { 'directory' }))."
            }
            if ($isLeaf -and $ExpectedType -ceq 'File' -and [string]$item.LinkType -ceq 'HardLink') {
                throw "Unsafe installer mutation path '$Path': stable files require exclusive ownership and must not be a hard link."
            }
        }
        $parent = Split-Path -Parent $inspectionPath
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($inspectionPath,[System.StringComparison]::OrdinalIgnoreCase)) { break }
        $inspectionPath = $parent
    }
}

function Get-InstallerExistingRuntimeState {
    param(
        [Parameter(Mandatory = $true)][string] $ConfigurationPath,
        [Parameter(Mandatory = $true)][string] $RuntimeDirectory
    )

    $existingConfiguration = $null
    $existingBundle = $null
    if (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf) {
        try { $existingConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigurationPath | ConvertFrom-Json }
        catch { throw "AI instruction sync configuration is not valid JSON: $ConfigurationPath" }
    }

    $existingBundlePath = Join-Path $RuntimeDirectory 'runtime-bundle.json'
    if (Test-Path -LiteralPath $existingBundlePath -PathType Leaf) {
        try { $existingBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $existingBundlePath | ConvertFrom-Json }
        catch { throw "Installed AI instruction runtime bundle is not valid JSON: $existingBundlePath" }
    }
    $bundleVersion = if ($null -ne $existingBundle -and (Test-InstallerHasProperty -Object $existingBundle -Name 'schemaVersion')) { $existingBundle.schemaVersion } else { $null }
    $configurationVersion = if ($null -ne $existingConfiguration -and (Test-InstallerHasProperty -Object $existingConfiguration -Name 'schemaVersion')) { $existingConfiguration.schemaVersion } else { $null }
    $generation = Get-AiInstructionsRuntimeGeneration -BundleSchemaVersion $bundleVersion -ConfigurationSchemaVersion $configurationVersion -AllowAbsent
    return [pscustomobject][ordered]@{
        Bundle = $existingBundle
        Configuration = $existingConfiguration
        BundleSchemaVersion = $bundleVersion
        ConfigurationSchemaVersion = $configurationVersion
        Generation = $generation
    }
}

function Assert-InstallerExistingRuntimeGate {
    param(
        [Parameter(Mandatory = $true)][object] $State,
        [Parameter(Mandatory = $true)][string] $RuntimeDirectory,
        [Parameter(Mandatory = $true)][object] $DefaultCapabilityReceipt
    )
    if ([string]$State.Generation -ceq 'none') { return $DefaultCapabilityReceipt }
    if ([string]$State.Generation -ceq 'v2v4') {
        Assert-AiInstructionsRuntimeBundleV2 -Bundle $State.Bundle -Configuration $State.Configuration -RuntimeRoot $RuntimeDirectory | Out-Null
        return $DefaultCapabilityReceipt
    }
    try {
        Assert-AiInstructionsSyncConfigurationV5 -Configuration $State.Configuration | Out-Null
        Assert-AiInstructionsRuntimeBundleV3 -Bundle $State.Bundle -Configuration $State.Configuration -RuntimeRoot $RuntimeDirectory | Out-Null
    }
    catch {
        if ($null -ne (Get-AiInstructionsRefusalCode $_)) { throw }
        throw (New-AiInstructionsRefusalException -Code closure-invalid -Message "Installed v3/v5 runtime closure is invalid: $($_.Exception.Message)" -InnerException $_.Exception)
    }
    try { $receipt = Get-PlatformCapabilities -Required ([string[]]@($State.Bundle.requiredCapabilities)) }
    catch {
        throw (New-AiInstructionsRefusalException -Code capability-unavailable -Message "Installed v3/v5 runtime capabilities are unavailable: $($_.Exception.Message)" -InnerException $_.Exception)
    }
    Assert-AiInstructionsRuntimeGate -Bundle $State.Bundle -Configuration $State.Configuration -RuntimeRoot $RuntimeDirectory -CapabilityReceipt $receipt | Out-Null
    return $receipt
}

function Select-InstallerWriterSchemaForState {
    param(
        [Parameter(Mandatory = $true)][object] $State,
        [Parameter(Mandatory = $true)][string] $RuntimeDirectory,
        [Parameter(Mandatory = $true)][object] $DefaultCapabilityReceipt,
        [Parameter(Mandatory = $true)][object] $CatalogSchemaVersion,
        [Parameter(Mandatory = $true)][bool] $ProjectionRuntimeAvailable,
        [Parameter(Mandatory = $true)][ValidateSet('Auto','V2V4','V3V5')][string] $RequestedWriterSchema
    )
    $receipt = $DefaultCapabilityReceipt
    if ([string]$State.Generation -ceq 'v3v5' -and $RequestedWriterSchema -cne 'V2V4') {
        $receipt = Assert-InstallerExistingRuntimeGate -State $State -RuntimeDirectory $RuntimeDirectory -DefaultCapabilityReceipt $DefaultCapabilityReceipt
    }
    $expectedOs = if ([string]$State.Generation -ceq 'v3v5') { [string]$State.Bundle.platform.os } else { [string]$receipt.os }
    $expectedArchitecture = if ([string]$State.Generation -ceq 'v3v5') { [string]$State.Bundle.platform.architecture } else { [string]$receipt.architecture }
    $selection = Select-AiInstructionsInstallWriterSchema `
        -WriterSchema $RequestedWriterSchema `
        -CatalogSchemaVersion $CatalogSchemaVersion `
        -InstalledBundleSchemaVersion $State.BundleSchemaVersion `
        -InstalledConfigurationSchemaVersion $State.ConfigurationSchemaVersion `
        -CapabilityReceipt $receipt `
        -ExpectedPlatformOs $expectedOs `
        -ExpectedPlatformArchitecture $expectedArchitecture `
        -ProjectionRuntimeAvailable:$ProjectionRuntimeAvailable
    return [pscustomobject][ordered]@{ Schema=$selection; CapabilityReceipt=$receipt }
}

function Get-InstallerFullDirectoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($rootPath) -and $fullPath.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase)) { return $rootPath }
    return $fullPath.TrimEnd([char[]]@('\','/'))
}

function Get-InstallerStreamSha256 {
    param([Parameter(Mandatory = $true)][System.IO.Stream] $Stream)

    if (-not $Stream.CanRead -or -not $Stream.CanSeek) { throw 'Installer archive stream must be readable and seekable.' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-InstallerCanonicalRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)
    $value = $Repository.Trim()
    if ($value -match '^(?:https|ssh|git)://(?:[^@/]+@)?github\.com/(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?/?$' -or
        $value -match '^(?:[^@/]+@)?github\.com:(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?$') {
        $identity = "github.com/$($Matches.Owner)/$($Matches.Repository)".ToLowerInvariant()
        if ($identity -ceq 'github.com/syuantsai/syuantsai-ai-instructions') { return }
    }
    throw "AI-Instructions runtime accepts only the canonical repository; actual: '$Repository'."
}

function Assert-InstallerSafeChildDirectory {
    param([Parameter(Mandatory = $true)][string] $Parent,[Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $LeafPrefix)
    $parentPath = Get-InstallerFullDirectoryPath -Path $Parent
    $childPath = Get-InstallerFullDirectoryPath -Path $Path
    $childParent = Get-InstallerFullDirectoryPath -Path (Split-Path -Parent $childPath)
    if (-not $childParent.Equals($parentPath,[System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $childPath).StartsWith($LeafPrefix,[System.StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $childPath -PathType Container)) {
        throw "Unsafe installer transaction cleanup path: $childPath"
    }
    $item = Get-Item -Force -LiteralPath $childPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unsafe reparse-backed installer transaction cleanup path: $childPath" }
    return $childPath
}

function Test-InstallerOwnedBootstrapHook {
    param(
        [AllowNull()][object] $Hook,
        [Parameter(Mandatory = $true)][string] $BootstrapHookPath
    )
    if ($null -eq $Hook -or -not (Test-InstallerHasProperty -Object $Hook -Name 'type') -or
        [string]$Hook.type -cne 'command') { return $false }

    $ownedPath = [System.IO.Path]::GetFullPath($BootstrapHookPath).Replace('/','\')
    $ownedPathPattern = '(?i)(?<![A-Za-z0-9_.-])' + [regex]::Escape($ownedPath) + '(?![A-Za-z0-9_.-])'
    foreach ($propertyName in @('command','commandWindows')) {
        if ((Test-InstallerHasProperty -Object $Hook -Name $propertyName) -and $Hook.$propertyName -is [string]) {
            $command = ([string]$Hook.$propertyName).Replace('/','\')
            if ([regex]::IsMatch($command,$ownedPathPattern)) { return $true }
        }
    }
    return $false
}

function Get-InstallerHooksWithoutSessionStart {
    param(
        [Parameter(Mandatory = $true)][string] $HooksPath,
        [Parameter(Mandatory = $true)][string] $BootstrapHookPath
    )
    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return $null }
    try { $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $HooksPath | ConvertFrom-Json }
    catch { throw "Codex hooks file is not valid JSON: $HooksPath" }
    if (-not (Test-InstallerHasProperty -Object $document -Name 'hooks') -or $null -eq $document.hooks -or
        -not (Test-InstallerHasProperty -Object $document.hooks -Name 'SessionStart')) { return $null }
    $retained = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($document.hooks.SessionStart)) {
        if ($null -eq $entry) { continue }
        if (-not (Test-InstallerHasProperty -Object $entry -Name 'hooks')) { $retained.Add($entry); continue }
        $removedBootstrap = $false
        $retainedHooks = New-Object System.Collections.Generic.List[object]
        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) { $retainedHooks.Add($hook); continue }
            $isBootstrap = Test-InstallerOwnedBootstrapHook -Hook $hook -BootstrapHookPath $BootstrapHookPath
            if ($isBootstrap) { $removedBootstrap = $true }
            else { $retainedHooks.Add($hook) }
        }
        if (-not $removedBootstrap) { $retained.Add($entry); continue }
        if ($retainedHooks.Count -gt 0) {
            $entry.PSObject.Properties['hooks'].Value = @($retainedHooks.ToArray())
            $retained.Add($entry)
        }
    }
    if ($retained.Count -eq 0) { $document.hooks.PSObject.Properties.Remove('SessionStart') }
    else { $document.hooks.PSObject.Properties['SessionStart'].Value = @($retained.ToArray()) }
    $json = (($document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n")
    $json | ConvertFrom-Json | Out-Null
    return $json
}

function Expand-InstallerGitSnapshotArchive {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [Parameter(Mandatory = $true)][string[]] $RelativePaths
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $repositoryRoot = Join-Path $DestinationRoot 'repository'
    if (Test-Path -LiteralPath $repositoryRoot) { throw "Git snapshot extraction destination already exists: $repositoryRoot" }
    $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $allowedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    [void]$allowedDirectories.Add('candidate-root')
    foreach ($relativePath in $RelativePaths) {
        $normalizedPath = $relativePath.Replace('\','/')
        if ($normalizedPath -match '(^|/)\.\.(/|$)' -or $normalizedPath.StartsWith('/') -or $normalizedPath.Contains(':')) {
            throw "Unsafe Git snapshot source path: $relativePath"
        }
        [void]$expectedFiles.Add("candidate-root/$normalizedPath")
        $parts = @($normalizedPath.Split('/'))
        if ($parts.Count -gt 1) {
            foreach ($index in 0..($parts.Count - 2)) {
                [void]$allowedDirectories.Add('candidate-root/' + [string]::Join('/',[string[]]$parts[0..$index]))
            }
        }
    }
    $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $stream = [System.IO.File]::Open(
        [System.IO.Path]::GetFullPath($ArchivePath),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::None
    )
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Read,$false)
        try {
            foreach ($entry in @($archive.Entries)) {
                $entryName = ([string]$entry.FullName).TrimEnd('/')
                $isDirectory = [string]::IsNullOrEmpty([string]$entry.Name) -or ([string]$entry.FullName).EndsWith('/')
                if ($entryName.Contains('\') -or $entryName.StartsWith('/') -or $entryName.Contains(':') -or $entryName -match '(^|/)\.\.(/|$)') {
                    throw "Unsafe Git snapshot archive entry: $($entry.FullName)"
                }
                if ($isDirectory) {
                    if (-not $allowedDirectories.Contains($entryName)) { throw "Unexpected Git snapshot archive directory: $($entry.FullName)" }
                    continue
                }
                if (-not $expectedFiles.Contains($entryName) -or -not $seenFiles.Add($entryName)) {
                    throw "Unexpected or duplicate Git snapshot archive file: $($entry.FullName)"
                }
                $externalAttributes = ([int64]$entry.ExternalAttributes) -band 0xFFFFFFFFL
                if ((($externalAttributes -shr 16) -band 0xF000L) -eq 0xA000L -or ($externalAttributes -band 0x400L) -ne 0) {
                    throw "Git snapshot archive contains a symbolic link or reparse entry: $($entry.FullName)"
                }
            }
            if ($seenFiles.Count -ne $expectedFiles.Count) { throw 'Git snapshot archive is missing required runtime source files.' }

            New-Item -ItemType Directory -Path $repositoryRoot | Out-Null
            $repositoryPrefix = $repositoryRoot + [System.IO.Path]::DirectorySeparatorChar
            foreach ($entry in @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Name) })) {
                $relativeName = ([string]$entry.FullName).Substring('candidate-root/'.Length)
                $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $relativeName.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
                if (-not $destinationPath.StartsWith($repositoryPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Git snapshot archive entry escapes the snapshot root: $($entry.FullName)"
                }
                $parent = Split-Path -Parent $destinationPath
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                $input = $entry.Open()
                try {
                    $output = [System.IO.File]::Open($destinationPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
                    try { $input.CopyTo($output) }
                    finally { $output.Dispose() }
                }
                finally { $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    catch {
        if (Test-Path -LiteralPath $repositoryRoot) { Remove-Item -LiteralPath $repositoryRoot -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally { $stream.Dispose() }
    return $repositoryRoot
}

function Expand-InstallerSafeSourceArchive {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream] $ArchiveStream,
        [Parameter(Mandatory = $true)][string] $DestinationRoot
    )
    if (-not $ArchiveStream.CanRead -or -not $ArchiveStream.CanSeek -or $ArchiveStream.Position -ne 0) {
        throw 'ZIP archive stream must be readable, seekable, and positioned at byte zero.'
    }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $repositoryRoot = Join-Path ([IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]@('\','/'))) 'repository'
    if (Test-Path -LiteralPath $repositoryRoot) { throw "ZIP extraction destination already exists: $repositoryRoot" }
    $archive = New-Object IO.Compression.ZipArchive($ArchiveStream,[IO.Compression.ZipArchiveMode]::Read,$true)
    try {
        try { $entries = @($archive.Entries) }
        catch { throw 'Unsafe ZIP entry path: unreadable archive entry metadata.' }
        if ($entries.Count -eq 0) { throw 'ZIP archive is empty.' }
        $pathCasings = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        $explicitEntries = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $explicitFiles = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $roots = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($entry in $entries) {
            if ($null -eq $entry) { throw 'Unsafe ZIP entry path: unreadable archive entry metadata.' }
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.StartsWith('/') -or $name.Contains(':') -or
                @($name.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) { throw "Unsafe ZIP entry path: $name" }
            $isDirectory = [string]::IsNullOrEmpty([string]$entry.Name) -or $name.EndsWith('/',[StringComparison]::Ordinal)
            $normalized = if ($isDirectory) { $name.TrimEnd('/') } else { $name }
            $parts = @($normalized.Split('/'))
            if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0]) -or ($parts.Count -eq 1 -and -not $isDirectory)) {
                throw "ZIP archive must contain exactly one repository root and no top-level files: $name"
            }
            foreach ($part in $parts) {
                if ([string]::IsNullOrWhiteSpace($part) -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ')) { throw "Unsafe ZIP entry path: $name" }
                if ($part.Split('.')[0] -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw "Unsafe Windows device name in ZIP entry: $name" }
            }
            for ($index = 0; $index -lt $parts.Count; $index++) {
                $prefix = [string]::Join('/',[string[]]$parts[0..$index])
                $existing = $null
                $known = $pathCasings.TryGetValue($prefix,[ref]$existing)
                if ($known -and $existing -cne $prefix) { throw "ZIP archive contains a case-insensitive path collision: $name" }
                if (-not $known) { $pathCasings.Add($prefix,$prefix) }
                $leaf = $index -eq $parts.Count - 1
                if (-not $leaf -and $explicitFiles.Contains($prefix)) { throw "ZIP archive contains a file/directory path collision: $name" }
                if ($leaf -and ($explicitEntries.Contains($prefix) -or (-not $isDirectory -and $known))) { throw "ZIP archive contains a duplicate or file/directory path collision: $name" }
            }
            [void]$explicitEntries.Add($normalized)
            if (-not $isDirectory) { [void]$explicitFiles.Add($normalized) }
            [void]$roots.Add($parts[0])
            $attributes = ([int64]$entry.ExternalAttributes) -band 0xFFFFFFFFL
            $unixType = ($attributes -shr 16) -band 0xF000L
            $expectedType = if ($isDirectory) { 0x4000L } else { 0x8000L }
            if ($unixType -eq 0xA000L -or ($unixType -ne 0 -and $unixType -ne $expectedType) -or ($attributes -band 0x400L) -ne 0) {
                throw "ZIP archive contains a symbolic link, special file, or reparse-point entry: $name"
            }
        }
        if ($roots.Count -ne 1) { throw "ZIP archive must contain exactly one repository root; found $($roots.Count)." }
        $archiveRootName = @($roots)[0]
        New-Item -ItemType Directory -Path $repositoryRoot | Out-Null
        $destinationPrefix = $repositoryRoot + [IO.Path]::DirectorySeparatorChar
        foreach ($entry in $entries) {
            $name = [string]$entry.FullName
            $relativeName = $name.Substring($archiveRootName.Length).TrimStart('/')
            if ([string]::IsNullOrEmpty($relativeName)) { continue }
            $destinationPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relativeName.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            if (-not $destinationPath.StartsWith($destinationPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "ZIP entry escapes its repository root: $name" }
            $isDirectory = [string]::IsNullOrEmpty([string]$entry.Name) -or $name.EndsWith('/',[StringComparison]::Ordinal)
            if ($isDirectory) { New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null; continue }
            $parent = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $input = $entry.Open()
            try {
                $output = [IO.File]::Open($destinationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            }
            finally { $input.Dispose() }
        }
    }
    catch {
        if (Test-Path -LiteralPath $repositoryRoot) { Remove-Item -LiteralPath $repositoryRoot -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally { $archive.Dispose() }
    return $repositoryRoot
}

function Get-InstallerCanonicalTextSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    [byte[]]$bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { throw 'Platform runtime inventory files must be UTF-8 without BOM.' }
    $utf8 = New-Object Text.UTF8Encoding($false,$true)
    $text = $utf8.GetString($bytes).Replace("`r`n","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-InstallerLicenseDocumentName {
    param([Parameter(Mandatory = $true)][string] $Name)
    return $Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|THIRD_PARTY_NOTICES|THIRD_PARTY_LICENSES|PROVENANCE)([-_][^.]+)?(\.(md|txt|rst|html))?$' -or
        $Name -ieq 'licensing-scope.json'
}

function Select-InstallerLicenseDeliveryDocumentPaths {
    param(
        [Parameter(Mandatory = $true)][string[]] $ArtifactPaths,
        [Parameter(Mandatory = $true)][string[]] $SourcePaths
    )
    $ancestors = @{ '' = $true }
    foreach ($path in $ArtifactPaths) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path.Contains('\') -or $path -match '[:\x00-\x1f]' -or
            $path.StartsWith('/') -or @($path.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_ -match '[. ]$' }).Count -gt 0) {
            throw "Unsafe license source path: $path"
        }
        $parent = $path
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0,$parent.LastIndexOf('/'))
            $ancestors[$parent] = $true
        }
    }
    foreach ($path in @($SourcePaths | Sort-Object -Unique)) {
        foreach ($ancestor in @($ancestors.Keys | Sort-Object)) {
            $prefix = if ($ancestor) { "$ancestor/" } else { '' }
            if (-not $path.StartsWith($prefix,[StringComparison]::Ordinal)) { continue }
            $relative = $path.Substring($prefix.Length)
            if (($relative -notmatch '/' -and (Test-InstallerLicenseDocumentName -Name $relative)) -or $relative -imatch '^LICENSES/') {
                $path
                break
            }
        }
    }
}

function Assert-InstallerPlatformRuntimeSourceInventory {
    param([Parameter(Mandatory = $true)][string] $RuntimeRoot)
    $manifestPath = Join-Path $RuntimeRoot 'platform-runtime.psd1'
    $expectedManifestSha256 = 'ba6af8ecbd09de50b9a55c57e5fa919d959296469125c12412bdc8300af5df5c'
    if ((Get-InstallerCanonicalTextSha256 -Path $manifestPath) -cne $expectedManifestSha256) { throw 'Platform runtime manifest differs from the installer trust anchor.' }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ($null -eq $manifest.PrivateData -or $null -eq $manifest.PrivateData.PlatformRuntime -or
        [string]$manifest.PrivateData.PlatformRuntime.HashMode -cne 'sha256-utf8-lf') { throw 'Platform runtime manifest has no supported bound inventory.' }
    $inventory = @($manifest.PrivateData.PlatformRuntime.Inventory)
    $declared = @($inventory | ForEach-Object { ([string]$_.Path).Replace('\','/') })
    $fileList = @($manifest.FileList | ForEach-Object { ([string]$_).Replace('\','/') })
    $expectedFileListText = (@(@('platform-runtime.psd1') + $declared | Sort-Object) -join "`n")
    $actualFileListText = (@($fileList | Sort-Object) -join "`n")
    if ($expectedFileListText -cne $actualFileListText -or @(@('platform-runtime.psd1') + $declared | Select-Object -Unique).Count -ne (1 + $declared.Count)) { throw 'Platform runtime FileList differs from its bound inventory.' }
    $platformRoot = Join-Path $RuntimeRoot 'platform'
    $actualPlatform = @(Get-ChildItem -LiteralPath $platformRoot -Recurse -File | ForEach-Object { ('platform/' + $_.FullName.Substring($platformRoot.Length).TrimStart('\','/')).Replace('\','/') })
    $declaredPlatform = @($declared | Where-Object { $_.StartsWith('platform/',[StringComparison]::Ordinal) })
    if ((@($actualPlatform | Sort-Object) -join "`n") -cne (@($declaredPlatform | Sort-Object) -join "`n")) { throw 'Platform runtime implementation directory contains missing or extra files.' }
    foreach ($entry in $inventory) {
        $relativePath = ([string]$entry.Path).Replace('\','/')
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.(/|$)' -or [string]$entry.Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Platform runtime inventory contains an unsafe entry.' }
        $path = Join-Path $RuntimeRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Platform runtime inventory file is missing: $relativePath" }
        if ((Get-InstallerCanonicalTextSha256 -Path $path) -cne [string]$entry.Sha256) { throw "Platform runtime inventory hash mismatch: $relativePath" }
    }
}

function ConvertTo-InstallerPlatformIdentity {
    param([Parameter(Mandatory = $true)] $Observation,[Parameter(Mandatory = $true)][string] $PlatformOs)
    if ($PlatformOs -ceq 'windows') {
        return [pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$Observation.Device);fileId=('0x{0:x}' -f [uint64]$Observation.Inode)}
    }
    return [pscustomobject][ordered]@{kind='unix-device-inode';device=[string][uint64]$Observation.Device;fileId=[string][uint64]$Observation.Inode}
}

function Get-InstallerJournalEntry {
    param(
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)][string] $PlatformOs
    )
    $path = Join-Path $TransactionPath $Leaf
    $missing = [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{Kind=$null;Json=$null;State=$missing} }
    $item = Get-Item -Force -LiteralPath $path
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject]@{Kind='other';Json=$null;State=$null} }
    $lease = Open-PlatformFile -ParentLease $TransactionLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
    try {
        $observation = Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -SingleLink -VerifyPath
        [byte[]]$bytes = $lease.ReadAllBytes(16777216)
        $stream = [IO.MemoryStream]::new($bytes,$false)
        try { $sha256 = Get-InstallerStreamSha256 -Stream $stream }
        finally { $stream.Dispose() }
        return [pscustomobject]@{
            Kind='file'
            Json=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)
            State=[pscustomobject][ordered]@{
                exists=$true
                sha256=$sha256
                length=[int64]$bytes.Length
                identity=ConvertTo-InstallerPlatformIdentity -Observation $observation -PlatformOs $PlatformOs
            }
        }
    }
    finally { $lease.Dispose() }
}

function Invoke-InstallerInterruptedInstallRecovery {
    param(
        [Parameter(Mandatory = $true)][string] $CodexHomePath,
        [Parameter(Mandatory = $true)] $TransactionRootLease,
        [Parameter(Mandatory = $true)][string] $PlatformOs
    )
    $storePath = Join-Path $CodexHomePath '.ai-instructions-txn'
    $records = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($entry in @(Get-ChildItem -Force -LiteralPath $storePath)) {
            $entryKind = if ($entry.PSIsContainer -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { 'directory' } else { 'other' }
            $transactionLease = $null
            $identity = $null
            $classification = $null
            $disposition = $null
            $decision = $null
            $plan = $null
            if ($entryKind -ceq 'directory') {
                $transactionLease = Open-PlatformDirectory -Root $CodexHomePath -RelativePath ('.ai-instructions-txn/' + $entry.Name)
                $identity = ConvertTo-InstallerPlatformIdentity -Observation $transactionLease.Observation -PlatformOs $PlatformOs
                $journal = Get-InstallerJournalEntry -TransactionLease $transactionLease -TransactionPath $entry.FullName -Leaf 'journal.json' -PlatformOs $PlatformOs
                $previous = Get-InstallerJournalEntry -TransactionLease $transactionLease -TransactionPath $entry.FullName -Leaf 'journal.prev' -PlatformOs $PlatformOs
                $stage = Get-InstallerJournalEntry -TransactionLease $transactionLease -TransactionPath $entry.FullName -Leaf 'journal.stage' -PlatformOs $PlatformOs
                $classification = Get-AiInstructionsInstallTransactionClassification -Name $entry.Name -EntryKind $entryKind -JournalEntryKind $journal.Kind -JournalJson $journal.Json -PreviousJournalEntryKind $previous.Kind -PreviousJournalJson $previous.Json
            }
            else {
                $classification = Get-AiInstructionsInstallTransactionClassification -Name $entry.Name -EntryKind $entryKind -JournalEntryKind $null -JournalJson $null -PreviousJournalEntryKind $null -PreviousJournalJson $null
            }
            $disposition = Get-AiInstructionsInstallTransactionDisposition -Classification ([string]$classification.classification) -Component installer
            if ([string]$disposition.action -ceq 'recover') {
                try {
                    $observations = Get-AiInstructionsInstallRecoveryObservations -Journal $classification.journal -CodexHome $CodexHomePath -TransactionLease $transactionLease -TransactionPath $entry.FullName
                    $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $classification.journal -Observations $observations
                    $plan = Get-AiInstructionsInstallRecoveryPlan -Journal $classification.journal -Decision $decision
                }
                catch {
                    $disposition = [pscustomobject]@{action='refuse';refusalCode='interrupted-install'}
                    $decision = [pscustomobject]@{action='refuse';reasons=@($_.Exception.Message)}
                }
            }
            $storeStates = if ($entryKind -ceq 'directory') { [ordered]@{'journal.json'=$journal.State;'journal.prev'=$previous.State;'journal.stage'=$stage.State} } else { $null }
            $records.Add([pscustomobject]@{Path=$entry.FullName;Name=$entry.Name;Lease=$transactionLease;Identity=$identity;Classification=$classification;Disposition=$disposition;Decision=$decision;Plan=$plan;JournalStoreStates=$storeStates})
        }
        $recordArray = $records.ToArray()
        $refusals = @($recordArray | Where-Object { [string]$_.Disposition.action -ceq 'refuse' -or ($null -ne $_.Decision -and [string]$_.Decision.action -ceq 'refuse') })
        if ($refusals.Count -gt 0) {
            $paths = @($recordArray | ForEach-Object { [string]$_.Path })
            throw (New-AiInstructionsRefusalException -Code interrupted-install -Message ("Interrupted install residue requires manual inspection: " + ($paths -join '; ')))
        }
        foreach ($record in $recordArray) {
            if ([string]$record.Disposition.action -ceq 'purge-orphan') {
                $record.Lease.Dispose(); $record.Lease=$null
                Remove-PlatformOwnedDirectoryTree -TransactionRootLease $TransactionRootLease -Leaf ([string]$record.Name) -ExpectedIdentity $record.Identity | Out-Null
                Write-Information "Purged orphan AI instructions install transaction: $($record.Path)" -InformationAction Continue
            }
            elseif ([string]$record.Disposition.action -ceq 'recover') {
                try {
                    Invoke-AiInstructionsInstallRecoveryPlan -Journal $record.Classification.journal -Plan $record.Plan -CodexHome $CodexHomePath -TransactionRootLease $TransactionRootLease -TransactionLease $record.Lease -TransactionPath $record.Path -JournalStoreStates $record.JournalStoreStates | Out-Null
                    if (@($record.Plan.retainedArtifacts).Count -gt 0) {
                        throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "Interrupted install recovery retained external-change artifacts at '$($record.Path)'; a later recovery can safely re-evaluate the same journal evidence.")
                    }
                    $record.Lease=$null
                }
                catch {
                    if ((Get-AiInstructionsRefusalCode $_) -ceq 'interrupted-install') { throw }
                    throw "Interrupted install recovery failed; evidence retained at '$($record.Path)'. $($_.Exception.Message)"
                }
            }
        }
    }
    finally { foreach ($record in $records.ToArray()) { if ($null -ne $record.Lease) { $record.Lease.Dispose() } } }
}

function ConvertTo-InstallerJsonBytes {
    param([Parameter(Mandatory = $true)] $Document)
    return (New-Object Text.UTF8Encoding($false)).GetBytes((($Document | ConvertTo-Json -Depth 30).Replace("`r`n","`n")) + "`n")
}

function New-InstallerFileJournalOperation {
    param(
        [Parameter(Mandatory = $true)][int] $Sequence,
        [Parameter(Mandatory = $true)][string] $Token,
        [Parameter(Mandatory = $true)][string] $TargetRelativePath,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)] $ParentLease,
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $DesiredBytes,
        [Parameter(Mandatory = $true)][string] $PlatformOs
    )
    $leaf = $TargetRelativePath.Split('/')[-1]
    $stageLeaf = "$Token.stage"
    $stage = New-AiInstructionsInstallStageFile -TransactionLease $TransactionLease -Leaf $stageLeaf -Bytes $DesiredBytes -PlatformOs $PlatformOs
    try { $captured = Get-AiInstructionsInstallFileState -ParentLease $ParentLease -Leaf $leaf -LiteralPath $TargetPath -PlatformOs $PlatformOs -IncludePermissions }
    catch {
        if ($_.Exception.Message -match 'exactly one link') {
            throw "Installer stable files require exclusive ownership and must not be a hard link. $($_.Exception.Message)"
        }
        throw
    }
    if ([bool]$captured.exists -and [string]$captured.sha256 -ceq [string]$stage.sha256 -and [int64]$captured.length -eq [int64]$stage.length) { return $null }
    $original = [pscustomobject][ordered]@{exists=[bool]$captured.exists;sha256=$captured.sha256;length=$captured.length;identity=$captured.identity}
    return [pscustomobject][ordered]@{
        sequence=$Sequence
        kind=$(if([bool]$captured.exists){'write-file'}else{'create-file'})
        method='stage-rename'
        targetRelativePath=$TargetRelativePath
        stageLeaf=$stageLeaf
        backupLeaf=$(if([bool]$captured.exists){"$Token.backup"}else{$null})
        quarantineLeaf=$null
        original=$original
        backupIdentity=$(if([bool]$captured.exists){$captured.identity}else{$null})
        applied=$stage
        permissions=$(if([bool]$captured.exists){$captured.permissions}else{$null})
        state='pending'
    }
}

$runtimeFiles = @(
    'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
    'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
    'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
    'ai-instructions-runtime-contract.psm1','WindowsDacl.psm1','agent-artifact-remediation.psm1','ai-instructions-rollout.psm1','invoke-ai-instructions-rollout.ps1',
    'ai-instructions-updater.psm1','update-ai-instructions.ps1','agent-environment-reconciler.psm1','update-agent-environment.ps1',
    'cleanup-ai-instructions-pollution.ps1','license-delivery.psm1','repo-shared-skills-migration.psm1',
    'ai-instructions-install-transaction.psm1','platform-runtime.psd1','platform-runtime.psm1','installer-safe-mutation.psm1',
    'platform/PlatformNative.cs','platform/UnixNative.cs','platform/WindowsNative.cs','platform/WindowsInstallerMutation.cs',
    'platform/OwnedProcess.cs','platform/UnixProcess.cs','platform/WindowsProcess.cs','platform/Unix.psm1',
    'platform/RuntimePreparation.psm1','platform/Windows.psm1','platform/Linux.psm1','platform/MacOS.psm1',
    'Resolve-StandardValidationTool.ps1'
)
$stableScripts = @('bootstrap-ai-instructions-installed.ps1','update-ai-instructions.ps1','update-agent-environment.ps1','cleanup-ai-instructions-pollution.ps1')
$relativeSourcePaths = @('scripts/install-ai-instructions-bootstrap.ps1')
foreach ($fileName in @($runtimeFiles + $stableScripts | Sort-Object -Unique)) { $relativeSourcePaths += "scripts/$fileName" }
$relativeSourcePaths += 'catalog/skills-catalog.json','catalog/skills-catalog-lock.json'
$runtimeArtifactPaths = @($relativeSourcePaths)

$archiveSourceWorkingRoot = $null
try {
if ($Acquisition -ceq 'git-checkout') {
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = ((Invoke-InstallerGit -WorkingDirectory (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
    }
    $checkoutRootPath = Get-InstallerFullDirectoryPath -Path $RepositoryRoot
    $originUrl = ((Invoke-InstallerGit -WorkingDirectory $checkoutRootPath -Arguments @('remote','get-url','origin')) | Select-Object -First 1).Trim()
    Assert-InstallerCanonicalRepository -Repository $originUrl
    $catalogRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $catalogRef = ((Invoke-InstallerGit -WorkingDirectory $checkoutRootPath -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($SourceRepository)) { Assert-InstallerCanonicalRepository -Repository $SourceRepository }
    if (-not [string]::IsNullOrWhiteSpace($SourceCommit) -and $SourceCommit -cne $catalogRef) { throw 'SourceCommit does not match the git checkout HEAD.' }
    $ArchiveSha256 = $null
    $tempRootPath = Get-InstallerFullDirectoryPath -Path ([System.IO.Path]::GetTempPath())
    $archiveSourceWorkingRoot = Join-Path $tempRootPath ('ai-instructions-installer-source-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $archiveSourceWorkingRoot | Out-Null
    $snapshotPaths = @(Invoke-InstallerGit -WorkingDirectory $checkoutRootPath -Arguments @('-c','core.quotepath=false','ls-tree','-r','--name-only',$catalogRef))
    $relativeSourcePaths += @(Select-InstallerLicenseDeliveryDocumentPaths -ArtifactPaths $runtimeArtifactPaths -SourcePaths $snapshotPaths)
    $relativeSourcePaths = @($relativeSourcePaths | Sort-Object -Unique)
    $gitSnapshotArchive = Join-Path $archiveSourceWorkingRoot 'source.zip'
    Invoke-InstallerGit -WorkingDirectory $checkoutRootPath -Arguments (@(
        'archive','--format=zip',"--output=$gitSnapshotArchive",'--prefix=candidate-root/',$catalogRef,'--'
    ) + $relativeSourcePaths) | Out-Null
    $repositoryRootPath = Expand-InstallerGitSnapshotArchive `
        -ArchivePath $gitSnapshotArchive `
        -DestinationRoot $archiveSourceWorkingRoot `
        -RelativePaths $relativeSourcePaths
}
else {
    if ([string]::IsNullOrWhiteSpace($SourceRepository) -or [string]::IsNullOrWhiteSpace($SourceCommit)) {
        throw 'github-codeload installation requires SourceRepository and SourceCommit.'
    }
    Assert-InstallerCanonicalRepository -Repository $SourceRepository
    if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'SourceCommit must be a full lowercase 40-character commit SHA.' }
    if ($ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'github-codeload installation requires ArchiveSha256.' }
    if ([string]::IsNullOrWhiteSpace($SourceArchivePath) -or -not (Test-Path -LiteralPath $SourceArchivePath -PathType Leaf)) {
        throw 'github-codeload installation requires the downloaded SourceArchivePath.'
    }
    $tempRootPath = Get-InstallerFullDirectoryPath -Path ([System.IO.Path]::GetTempPath())
    $archiveSourceWorkingRoot = Join-Path $tempRootPath ('ai-instructions-installer-source-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $archiveSourceWorkingRoot | Out-Null
    try {
        $archiveStream = [System.IO.File]::Open(
            [System.IO.Path]::GetFullPath($SourceArchivePath),
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        try {
            $actualArchiveSha256 = Get-InstallerStreamSha256 -Stream $archiveStream
            if ($actualArchiveSha256 -cne $ArchiveSha256) {
                throw "github-codeload SourceArchivePath SHA-256 does not match ArchiveSha256: expected $ArchiveSha256; actual $actualArchiveSha256."
            }
            $archiveStream.Position = 0
            $repositoryRootPath = Expand-InstallerSafeSourceArchive -ArchiveStream $archiveStream -DestinationRoot $archiveSourceWorkingRoot
        }
        finally { $archiveStream.Dispose() }
    }
    catch {
        throw "github-codeload archive cannot supply the verified runtime sources: $($_.Exception.Message)"
    }
    $catalogRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $catalogRef = $SourceCommit
}
if ($catalogRef -cnotmatch '^[0-9a-f]{40}$') { throw 'Installer source commit must be a full lowercase 40-character commit SHA.' }
if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit) -and $ExpectedCurrentCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'ExpectedCurrentCommit must be a full lowercase 40-character commit SHA.'
}
$expectedPolicyValues = @(@($ExpectedUpdateMode,$ExpectedUpdateChannel,$ExpectedUpdateRef) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$expectedPolicySpecified = $expectedPolicyValues.Count -gt 0
if ($expectedPolicySpecified -and $expectedPolicyValues.Count -ne 3) {
    throw 'ExpectedUpdateMode, ExpectedUpdateChannel, and ExpectedUpdateRef must be supplied together.'
}
if ($expectedPolicySpecified) {
    if ($ExpectedUpdateMode -cnotin @('notify-only','auto-install-approved')) { throw "Unsupported ExpectedUpdateMode '$ExpectedUpdateMode'." }
    if ($ExpectedUpdateChannel -cnotin @('protected-branch','github-release')) { throw "Unsupported ExpectedUpdateChannel '$ExpectedUpdateChannel'." }
    if (($ExpectedUpdateChannel -ceq 'protected-branch' -and $ExpectedUpdateRef -cne 'main') -or
        ($ExpectedUpdateChannel -ceq 'github-release' -and $ExpectedUpdateRef -cne 'latest')) {
        throw 'Expected update channel/ref combination is invalid.'
    }
}

foreach ($relativePath in $relativeSourcePaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRootPath $relativePath.Replace('/','\')) -PathType Leaf)) {
        $message = if ($Acquisition -ceq 'github-codeload') { "github-codeload archive runtime source was not found: $relativePath" }
            else { "Installer runtime source was not found: $relativePath" }
        throw [IO.InvalidDataException]::new("$message [ai-instructions-refusal-code=closure-invalid]")
    }
}

$runtimeContractSource = Join-Path $repositoryRootPath 'scripts\ai-instructions-runtime-contract.psm1'
$platformRuntimeRoot = Join-Path $repositoryRootPath 'scripts'
try { Assert-InstallerPlatformRuntimeSourceInventory -RuntimeRoot $platformRuntimeRoot }
catch { throw [IO.InvalidDataException]::new("The verified installer platform runtime closure is invalid. $($_.Exception.Message) [ai-instructions-refusal-code=closure-invalid]",$_.Exception) }
try { Import-Module $runtimeContractSource -Force -ErrorAction Stop }
catch { throw [IO.InvalidDataException]::new("The verified installer runtime contract is invalid. $($_.Exception.Message) [ai-instructions-refusal-code=closure-invalid]",$_.Exception) }
Import-Module (Join-Path $repositoryRootPath 'scripts\skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $repositoryRootPath 'scripts\license-delivery.psm1') -Force
$platformRuntimeModule = Import-Module (Join-Path $platformRuntimeRoot 'platform-runtime.psd1') -Force -PassThru
try { Assert-PlatformRuntimeInventory -Root $platformRuntimeRoot -ManifestPath (Join-Path $platformRuntimeRoot 'platform-runtime.psd1') | Out-Null }
catch { throw (New-AiInstructionsRefusalException -Code closure-invalid -Message "The imported installer platform runtime closure is invalid. $($_.Exception.Message)" -InnerException $_.Exception) }
Import-Module (Join-Path $repositoryRootPath 'scripts\ai-instructions-install-transaction.psm1') -Force
$capabilityReceipt = Get-PlatformCapabilities -Required @()
$capabilityReceipt = Assert-AiInstructionsInstallerCapabilities -Receipt $capabilityReceipt
$catalogDocument = Test-SkillsCatalogDocument -CatalogPath (Join-Path $repositoryRootPath 'catalog\skills-catalog.json')
$runtimeLicenses = New-LicenseDeliveryPackage -SourceRoot $repositoryRootPath -ArtifactPaths $runtimeArtifactPaths `
    -SourceRepository $catalogRepository -SourceCommit $catalogRef -ArtifactId 'ai-instructions-runtime'

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$codexHomePath = Get-InstallerFullDirectoryPath -Path $CodexHome
$codexHomeRoot = [IO.Path]::GetPathRoot($codexHomePath)
if (-not [string]::IsNullOrWhiteSpace($codexHomeRoot) -and $codexHomePath.Equals($codexHomeRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Codex Home must not be a filesystem root: $codexHomePath" }
$hookDirectory = Join-Path $codexHomePath 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'
$updateScript = Join-Path $hookDirectory 'update-ai-instructions.ps1'
$environmentUpdateScript = Join-Path $hookDirectory 'update-agent-environment.ps1'
$cleanupScript = Join-Path $hookDirectory 'cleanup-ai-instructions-pollution.ps1'
$runtimeDirectory = Join-Path $hookDirectory 'ai-instructions-runtime'
$agentsPath = Join-Path $codexHomePath 'AGENTS.md'
$hooksPath = Join-Path $codexHomePath 'hooks.json'
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
$installLockPath = Join-Path $codexHomePath 'ai-instructions-install.lock'

$prelockState = Get-InstallerExistingRuntimeState -ConfigurationPath $configurationPath -RuntimeDirectory $runtimeDirectory
$prelockSelection = Select-InstallerWriterSchemaForState `
    -State $prelockState `
    -RuntimeDirectory $runtimeDirectory `
    -DefaultCapabilityReceipt $capabilityReceipt `
    -CatalogSchemaVersion $catalogDocument.schemaVersion `
    -ProjectionRuntimeAvailable $projectionRuntimeAvailable `
    -RequestedWriterSchema $WriterSchema
$selectedWriterSchema = [string]$prelockSelection.Schema
$capabilityReceipt = $prelockSelection.CapabilityReceipt

New-Item -ItemType Directory -Force -Path $codexHomePath | Out-Null
$rootLease = Open-PlatformDirectory -Root $codexHomePath -RootOnly
$installLockLease = $null
$hookLease = $null
$transactionRootLease = $null
$transactionLease = $null
try {
    try { $installLockLease = Enter-PlatformLock -ParentLease $rootLease -Leaf 'ai-instructions-install.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero) }
    catch {
        $cause=$_.Exception
        while($null -ne $cause.InnerException){$cause=$cause.InnerException}
        if($cause -is [TimeoutException]){throw 'Another AI instructions installer is already running for this Codex Home.'}
        throw
    }

    $legacyResidue = @(Get-ChildItem -Force -LiteralPath $codexHomePath | Where-Object { $_.Name -like '.ai-instructions-install-*' -or $_.Name -like '.ai-instructions-backup-*' })
    if ($legacyResidue.Count -gt 0) {
        throw (New-AiInstructionsRefusalException -Code interrupted-install -Message ("Legacy interrupted install residue requires manual inspection: " + (@($legacyResidue.FullName) -join '; ')))
    }

    $transactionStorePath = Join-Path $codexHomePath '.ai-instructions-txn'
    if (Test-Path -LiteralPath $transactionStorePath) {
        $storeItem = Get-Item -Force -LiteralPath $transactionStorePath
        if (-not $storeItem.PSIsContainer -or ($storeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "Install transaction store must be a physical directory: $transactionStorePath")
        }
        $transactionRootLease = Open-PlatformDirectory -Root $codexHomePath -RelativePath '.ai-instructions-txn'
        Invoke-InstallerInterruptedInstallRecovery -CodexHomePath $codexHomePath -TransactionRootLease $transactionRootLease -PlatformOs ([string]$capabilityReceipt.os)
        $remainingTransactions=@(Get-ChildItem -Force -LiteralPath $transactionStorePath)
        if($remainingTransactions.Count -gt 0){
            throw (New-AiInstructionsRefusalException -Code interrupted-install -Message ('Install transaction store changed during recovery: '+(@($remainingTransactions.FullName)-join '; ')))
        }
    }
    Invoke-AiInstructionsInstallFailpoint -Name 'after-recovery-before-install'

    $lockedState = Get-InstallerExistingRuntimeState -ConfigurationPath $configurationPath -RuntimeDirectory $runtimeDirectory
    $lockedSelection = Select-InstallerWriterSchemaForState `
        -State $lockedState `
        -RuntimeDirectory $runtimeDirectory `
        -DefaultCapabilityReceipt $capabilityReceipt `
        -CatalogSchemaVersion $catalogDocument.schemaVersion `
        -ProjectionRuntimeAvailable $projectionRuntimeAvailable `
        -RequestedWriterSchema $WriterSchema
    if ([string]$lockedSelection.Schema -cne $selectedWriterSchema) {
        throw (New-AiInstructionsRefusalException -Code mixed-generation -Message 'Installed runtime generation changed while the installer acquired its exclusive lease.')
    }
    $capabilityReceipt = $lockedSelection.CapabilityReceipt

    New-Item -ItemType Directory -Force -Path $hookDirectory | Out-Null
    $hookLease = Open-PlatformDirectory -Root $codexHomePath -RelativePath 'hooks'
    Assert-InstallerMutationPath -Path $codexHomePath -ExpectedType Directory
    Assert-InstallerMutationPath -Path $hookDirectory -ExpectedType Directory
    Assert-InstallerMutationPath -Path $runtimeDirectory -ExpectedType Directory
    foreach ($filePath in @($hookScript,$updateScript,$environmentUpdateScript,$cleanupScript,$agentsPath,$hooksPath,$configurationPath,$installLockPath)) { Assert-InstallerMutationPath -Path $filePath -ExpectedType File }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit)) {
        try {
            $installedBundle = $lockedState.Bundle
            $installedConfiguration = $lockedState.Configuration
            Assert-InstallerExistingRuntimeGate -State $lockedState -RuntimeDirectory $runtimeDirectory -DefaultCapabilityReceipt $capabilityReceipt | Out-Null
        }
        catch { throw "The installed runtime changed before installation; the candidate transaction must be resolved again. $($_.Exception.Message)" }
        if ([string]$installedBundle.commit -cne $ExpectedCurrentCommit) { throw 'The installed runtime changed before installation; the candidate transaction must be resolved again.' }
    }

    $existingConfiguration = $lockedState.Configuration
    if ($expectedPolicySpecified) {
        try {
            if ([string]$lockedState.Generation -ceq 'v3v5') { Assert-AiInstructionsSyncConfigurationV5 -Configuration $existingConfiguration | Out-Null }
            else { Assert-AiInstructionsSyncConfigurationV4 -Configuration $existingConfiguration | Out-Null }
        }
        catch { throw 'The active runtime update policy changed before installation; candidate approval must be resolved again.' }
        if ([string]$existingConfiguration.updates.mode -cne $ExpectedUpdateMode -or [string]$existingConfiguration.updates.channel -cne $ExpectedUpdateChannel -or [string]$existingConfiguration.updates.ref -cne $ExpectedUpdateRef) {
            throw 'The active runtime update policy changed before installation; candidate approval must be resolved again.'
        }
    }
    $configurationParameters = @{
        ExistingConfiguration=$existingConfiguration;CatalogRepository=$catalogRepository;CatalogRef=$catalogRef
        AdditionalExcludedRepositoryUrls=$ExcludedRepositoryUrls;AdditionalExcludedRepositoryPaths=$ExcludedRepositoryPaths;Catalog=$catalogDocument
    }
    $configuration = if ($selectedWriterSchema -ceq 'v3v5') {
        ConvertTo-AiInstructionsSyncConfigurationV5 @configurationParameters
    }
    else { ConvertTo-AiInstructionsSyncConfigurationV4 @configurationParameters }

    if ($null -eq $transactionRootLease) { $transactionRootLease = Open-PlatformDirectory -Root $codexHomePath -RelativePath '.ai-instructions-txn' -CreatePrivate }
    $transactionId = [Guid]::NewGuid().ToString('N')
    $transactionPath = Join-Path $transactionStorePath $transactionId
    $transactionLease = Open-PlatformDirectory -Root $codexHomePath -RelativePath ('.ai-instructions-txn/' + $transactionId) -CreatePrivate
    $transactionIdentity = ConvertTo-InstallerPlatformIdentity -Observation $transactionLease.Observation -PlatformOs ([string]$capabilityReceipt.os)
    $journalDurable = $false
    $preserveTransaction = $false
    try {
        $runtimeStageLeaf = 'op-05-runtime.stage'
        $stagingRuntime = Join-Path $transactionPath $runtimeStageLeaf
        New-Item -ItemType Directory -Path $stagingRuntime,(Join-Path $stagingRuntime 'catalog') | Out-Null
        foreach ($fileName in $runtimeFiles) {
            $destination = Join-Path $stagingRuntime $fileName
            $destinationParent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null }
            Copy-Item -LiteralPath (Join-Path $repositoryRootPath "scripts\$fileName") -Destination $destination -Force
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog.json') -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog-lock.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -Force
        Write-LicenseDeliveryPackage -Package $runtimeLicenses -DestinationRoot (Join-Path $stagingRuntime 'licenses')
        $bundle = if ($selectedWriterSchema -ceq 'v3v5') {
            New-AiInstructionsRuntimeBundleV3 -RuntimeRoot $stagingRuntime -Repository $catalogRepository -Commit $catalogRef -Acquisition $Acquisition -ArchiveSha256 $ArchiveSha256 -CapabilityReceipt $capabilityReceipt
        }
        else {
            New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $stagingRuntime -Repository $catalogRepository -Commit $catalogRef -Acquisition $Acquisition -ArchiveSha256 $ArchiveSha256
        }
        [IO.File]::WriteAllBytes((Join-Path $stagingRuntime 'runtime-bundle.json'),(ConvertTo-InstallerJsonBytes -Document $bundle))
        if ($selectedWriterSchema -ceq 'v3v5') {
            Assert-AiInstructionsRuntimeGate -Bundle $bundle -Configuration $configuration -RuntimeRoot $stagingRuntime -CapabilityReceipt $capabilityReceipt | Out-Null
        }
        else { Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $stagingRuntime | Out-Null }
        Test-SkillsCatalogLockDocument -LockPath (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -CatalogPath (Join-Path $stagingRuntime 'catalog\skills-catalog.json') | Out-Null
        foreach ($scriptPath in @(Get-ChildItem -LiteralPath $stagingRuntime -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') } | Select-Object -ExpandProperty FullName)) {
            $tokens=$null;$errors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
            if(@($errors).Count -gt 0){throw "Staged installer runtime contains a PowerShell parse error in '$scriptPath': $(@($errors)[0].Message)"}
        }

        $agentsContent = Get-InstallerBootstrapSectionContent -AgentsPath $agentsPath -Section $bootstrapSection
        $hooksContent = Get-InstallerHooksWithoutSessionStart -HooksPath $hooksPath -BootstrapHookPath $hookScript
        $operations = New-Object System.Collections.Generic.List[object]
        $fileSpecs = @(
            [pscustomobject]@{Token='op-01-bootstrap';Relative='hooks/bootstrap-ai-instructions.ps1';Path=$hookScript;Parent=$hookLease;Bytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRootPath 'scripts\bootstrap-ai-instructions-installed.ps1'))},
            [pscustomobject]@{Token='op-02-updater';Relative='hooks/update-ai-instructions.ps1';Path=$updateScript;Parent=$hookLease;Bytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRootPath 'scripts\update-ai-instructions.ps1'))},
            [pscustomobject]@{Token='op-03-environment';Relative='hooks/update-agent-environment.ps1';Path=$environmentUpdateScript;Parent=$hookLease;Bytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRootPath 'scripts\update-agent-environment.ps1'))},
            [pscustomobject]@{Token='op-04-cleanup';Relative='hooks/cleanup-ai-instructions-pollution.ps1';Path=$cleanupScript;Parent=$hookLease;Bytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRootPath 'scripts\cleanup-ai-instructions-pollution.ps1'))}
        )
        foreach($spec in $fileSpecs){
            $operation=New-InstallerFileJournalOperation -Sequence ($operations.Count+1) -Token $spec.Token -TargetRelativePath $spec.Relative -TargetPath $spec.Path -ParentLease $spec.Parent -TransactionLease $transactionLease -DesiredBytes $spec.Bytes -PlatformOs ([string]$capabilityReceipt.os)
            if($null -ne $operation){$operations.Add($operation)}
        }

        $runtimeOriginalCapture = Get-AiInstructionsInstallDirectoryState -ParentLease $hookLease -Leaf 'ai-instructions-runtime' -LiteralPath $runtimeDirectory -IncludePermissions
        $runtimeAppliedCapture = Get-AiInstructionsInstallDirectoryState -ParentLease $transactionLease -Leaf $runtimeStageLeaf -LiteralPath $stagingRuntime
        if (-not ([bool]$runtimeOriginalCapture.exists -and [string]$runtimeOriginalCapture.inventorySha256 -ceq [string]$runtimeAppliedCapture.inventorySha256 -and [int64]$runtimeOriginalCapture.entryCount -eq [int64]$runtimeAppliedCapture.entryCount)) {
            $runtimeOriginal=[pscustomobject][ordered]@{exists=[bool]$runtimeOriginalCapture.exists;identity=$runtimeOriginalCapture.identity;inventorySha256=$runtimeOriginalCapture.inventorySha256;entryCount=$runtimeOriginalCapture.entryCount}
            $runtimeApplied=[pscustomobject][ordered]@{exists=$true;identity=$runtimeAppliedCapture.identity;inventorySha256=$runtimeAppliedCapture.inventorySha256;entryCount=$runtimeAppliedCapture.entryCount}
            $operations.Add([pscustomobject][ordered]@{sequence=$operations.Count+1;kind=$(if($runtimeOriginal.exists){'swap-directory'}else{'create-directory'});method='stage-rename';targetRelativePath='hooks/ai-instructions-runtime';stageLeaf=$runtimeStageLeaf;backupLeaf=$(if($runtimeOriginal.exists){'op-05-runtime.backup'}else{$null});quarantineLeaf='op-05-runtime.quarantine';original=$runtimeOriginal;backupIdentity=$(if($runtimeOriginal.exists){$runtimeOriginal.identity}else{$null});applied=$runtimeApplied;permissions=$(if($runtimeOriginal.exists){$runtimeOriginalCapture.permissions}else{$null});state='pending'})
        }

        $tailSpecs = New-Object System.Collections.Generic.List[object]
        $tailSpecs.Add([pscustomobject]@{Token='op-06-sync';Relative='ai-instructions-sync.json';Path=$configurationPath;Parent=$rootLease;Bytes=(ConvertTo-InstallerJsonBytes -Document $configuration)})
        $tailSpecs.Add([pscustomobject]@{Token='op-07-agents';Relative='AGENTS.md';Path=$agentsPath;Parent=$rootLease;Bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($agentsContent)})
        if($null -ne $hooksContent){$tailSpecs.Add([pscustomobject]@{Token='op-08-hooks';Relative='hooks.json';Path=$hooksPath;Parent=$rootLease;Bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($hooksContent)})}
        foreach($spec in $tailSpecs){
            $operation=New-InstallerFileJournalOperation -Sequence ($operations.Count+1) -Token $spec.Token -TargetRelativePath $spec.Relative -TargetPath $spec.Path -ParentLease $spec.Parent -TransactionLease $transactionLease -DesiredBytes $spec.Bytes -PlatformOs ([string]$capabilityReceipt.os)
            if($null -ne $operation){$operations.Add($operation)}
        }

        if($operations.Count -eq 0){
            $transactionLease.Dispose();$transactionLease=$null
            Remove-PlatformOwnedDirectoryTree -TransactionRootLease $transactionRootLease -Leaf $transactionId -ExpectedIdentity $transactionIdentity | Out-Null
        }
        else{
            $candidateBundleSha256=(Get-FileHash -LiteralPath (Join-Path $stagingRuntime 'runtime-bundle.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            $previousBundleSha256=if(Test-Path -LiteralPath (Join-Path $runtimeDirectory 'runtime-bundle.json') -PathType Leaf){(Get-FileHash -LiteralPath (Join-Path $runtimeDirectory 'runtime-bundle.json') -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
            $processStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            $currentJournal=New-AiInstructionsInstallJournalV1 -TransactionId $transactionId -OwnerComponent installer -OwnerProcessId $PID -OwnerProcessStartIdentity $processStart -PlatformOs ([string]$capabilityReceipt.os) -PlatformArchitecture ([string]$capabilityReceipt.architecture) -LockPrimitive $(if([string]$capabilityReceipt.os -ceq 'windows'){'windows-fileshare'}else{'flock'}) -LockLeaf 'ai-instructions-install.lock' -PreviousBundleSha256 $previousBundleSha256 -CandidateBundleSha256 $candidateBundleSha256 -Phase prepared -Operations $operations.ToArray()
            $journalStoreStates=[ordered]@{
                'journal.json'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
                'journal.prev'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
                'journal.stage'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
            }
            $currentJournal=Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $currentJournal -PlatformOs ([string]$capabilityReceipt.os) -JournalStoreStates $journalStoreStates
            $journalDurable=$true
            Invoke-AiInstructionsInstallFailpoint -Name 'after-journal-prepared'
            $nextJournal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($currentJournal|ConvertTo-Json -Depth 30) -ExpectedTransactionId $transactionId
            $nextJournal.phase='applying'
            $currentJournal=Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $nextJournal -PreviousJournal $currentJournal -PlatformOs ([string]$capabilityReceipt.os) -JournalStoreStates $journalStoreStates
            foreach($operation in @($currentJournal.operations|Sort-Object sequence)){
                $parent=if(([string]$operation.targetRelativePath).StartsWith('hooks/')){$hookLease}else{$rootLease}
                Invoke-AiInstructionsInstallOperation -Operation $operation -ParentLease $parent -TransactionLease $transactionLease | Out-Null
                $nextJournal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($currentJournal|ConvertTo-Json -Depth 30) -ExpectedTransactionId $transactionId
                @($nextJournal.operations|Where-Object{[int64]$_.sequence -eq [int64]$operation.sequence})[0].state='applied'
                $currentJournal=Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $nextJournal -PreviousJournal $currentJournal -PlatformOs ([string]$capabilityReceipt.os) -JournalStoreStates $journalStoreStates
                Invoke-AiInstructionsInstallFailpoint -Name ("after-operation-"+[string]$operation.sequence)
            }
            $nextJournal=ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($currentJournal|ConvertTo-Json -Depth 30) -ExpectedTransactionId $transactionId
            $nextJournal.phase='applied'
            $currentJournal=Write-AiInstructionsInstallJournalStore -TransactionLease $transactionLease -TransactionPath $transactionPath -Journal $nextJournal -PreviousJournal $currentJournal -PlatformOs ([string]$capabilityReceipt.os) -JournalStoreStates $journalStoreStates
            $observations=Get-AiInstructionsInstallRecoveryObservations -Journal $currentJournal -CodexHome $codexHomePath -TransactionLease $transactionLease -TransactionPath $transactionPath
            $decision=Get-AiInstructionsInstallRecoveryDecision -Journal $currentJournal -Observations $observations
            $plan=Get-AiInstructionsInstallRecoveryPlan -Journal $currentJournal -Decision $decision
            if([string]$plan.action -cne 'commit'){throw "Applied installer transaction did not produce a commit recovery plan: $($decision.action)"}
            Invoke-AiInstructionsInstallRecoveryPlan -Journal $currentJournal -Plan $plan -CodexHome $codexHomePath -TransactionRootLease $transactionRootLease -TransactionLease $transactionLease -TransactionPath $transactionPath -JournalStoreStates $journalStoreStates|Out-Null
            $transactionLease=$null
        }
    }
    catch{
        $installError=$_
        if($journalDurable -and $null -ne $transactionLease){
            try{
                $journalEntry=Get-InstallerJournalEntry -TransactionLease $transactionLease -TransactionPath $transactionPath -Leaf 'journal.json' -PlatformOs ([string]$capabilityReceipt.os)
                $previousEntry=Get-InstallerJournalEntry -TransactionLease $transactionLease -TransactionPath $transactionPath -Leaf 'journal.prev' -PlatformOs ([string]$capabilityReceipt.os)
                $stageEntry=Get-InstallerJournalEntry -TransactionLease $transactionLease -TransactionPath $transactionPath -Leaf 'journal.stage' -PlatformOs ([string]$capabilityReceipt.os)
                $journalStoreStates=[ordered]@{'journal.json'=$journalEntry.State;'journal.prev'=$previousEntry.State;'journal.stage'=$stageEntry.State}
                $classification=Get-AiInstructionsInstallTransactionClassification -Name $transactionId -EntryKind directory -JournalEntryKind $journalEntry.Kind -JournalJson $journalEntry.Json -PreviousJournalEntryKind $previousEntry.Kind -PreviousJournalJson $previousEntry.Json
                if([string]$classification.classification -cne 'valid-journal'){throw "Durable journal classification is $($classification.classification)."}
                $observations=Get-AiInstructionsInstallRecoveryObservations -Journal $classification.journal -CodexHome $codexHomePath -TransactionLease $transactionLease -TransactionPath $transactionPath
                $decision=Get-AiInstructionsInstallRecoveryDecision -Journal $classification.journal -Observations $observations
                if([string]$decision.action -ceq 'refuse'){$preserveTransaction=$true;throw (New-AiInstructionsRefusalException -Code interrupted-install -Message ("Installation target changed concurrently; recovery refused mutation and retained evidence at '$transactionPath'. " + (@($decision.reasons)-join '; ')) -InnerException $installError.Exception)}
                $plan=Get-AiInstructionsInstallRecoveryPlan -Journal $classification.journal -Decision $decision
                Invoke-AiInstructionsInstallRecoveryPlan -Journal $classification.journal -Plan $plan -CodexHome $codexHomePath -TransactionRootLease $transactionRootLease -TransactionLease $transactionLease -TransactionPath $transactionPath -JournalStoreStates $journalStoreStates|Out-Null
                if(@($plan.retainedArtifacts).Count -gt 0){
                    $preserveTransaction=$true
                    throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "AI instructions installation recovery retained external-change artifacts at '$transactionPath'; a later recovery can safely re-evaluate the same journal evidence." -InnerException $installError.Exception)
                }
                else{$transactionLease=$null}
            }
            catch{
                $preserveTransaction=$true
                if((Get-AiInstructionsRefusalCode $_) -ceq 'interrupted-install'){throw}
                throw "AI instructions installation failed and rollback also failed. Transaction evidence retained at '$transactionPath'. Original error: $($installError.Exception.Message). Rollback error: $($_.Exception.Message)"
            }
            if ([string]$installError.Exception.Message -match 'differs from ExpectedState|changed concurrently') {
                throw [InvalidOperationException]::new("Installation target changed concurrently; unaffected targets were rolled back without overwriting the external writer. $($installError.Exception.Message)",$installError.Exception)
            }
            throw $installError
        }
        throw
    }
    finally{
        if($null -ne $transactionLease){$transactionLease.Dispose();$transactionLease=$null}
        if(-not $journalDurable -and -not $preserveTransaction -and (Test-Path -LiteralPath $transactionPath -PathType Container)){
            try{Remove-PlatformOwnedDirectoryTree -TransactionRootLease $transactionRootLease -Leaf $transactionId -ExpectedIdentity $transactionIdentity|Out-Null}catch{}
        }
    }
}
finally{
    if($null -ne $hookLease){$hookLease.Dispose()}
    if($null -ne $transactionRootLease){$transactionRootLease.Dispose()}
    if($null -ne $installLockLease){$installLockLease.Dispose()}
    if($null -ne $rootLease){$rootLease.Dispose()}
}

Write-Output "Installed AI instructions bootstrap launcher: $hookScript"
Write-Output "Installed AI instructions manual updater: $updateScript"
Write-Output "Installed AI instructions pollution cleanup command: $cleanupScript"
Write-Output "Installed immutable runtime bundle: $runtimeDirectory"
Write-Output "Updated AI instructions sync configuration schema v$($configuration.schemaVersion): $configurationPath"
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($archiveSourceWorkingRoot) -and (Test-Path -LiteralPath $archiveSourceWorkingRoot)) {
        $resolvedTempRoot = Get-InstallerFullDirectoryPath -Path ([System.IO.Path]::GetTempPath())
        $resolvedArchiveSourceRoot = Assert-InstallerSafeChildDirectory -Parent $resolvedTempRoot -Path $archiveSourceWorkingRoot -LeafPrefix 'ai-instructions-installer-source-'
        Remove-Item -LiteralPath $resolvedArchiveSourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
