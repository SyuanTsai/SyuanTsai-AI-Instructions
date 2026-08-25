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
    [string] $ExpectedUpdateRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InstallerMutationRoot = $null
$script:InstallerHeldLockPath = $null
$script:InstallerFileTransactionStates = @{}

$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(
    'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquacieaWsOWinuaIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkY29kZXhIb21lID0gaWYgKC1ub3QgW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkZW52OkNPREVYX0hPTUUpKSB7ICRlbnY6Q09ERVhfSE9NRSB9IGVsc2UgeyBKb2luLVBhdGggJEhPTUUgJy5jb2RleCcgfTsgJiAoSm9pbi1QYXRoICRjb2RleEhvbWUgJ2hvb2tzXGJvb3RzdHJhcC1haS1pbnN0cnVjdGlvbnMucHMxJylg77yb5Zau57SU5ZWP5ZWP6aGM44CB6YeQ5riF6ZyA5rGC44CB56K66KqN5oiW6Kej6YeL5ZWP6aGM77yM5Lul5Y+K5YW25LuW5bCa5pyq6ZaL5aeL6KaP5YqDIGNvZGUg55qE5bel5L2c5LiN5b6X5Z+36KGMIGJvb3RzdHJhcOOAggotIOWQjOatpeWujOaIkOW+jO+8jOWFiOiugOWPliBSZXBvc2l0b3J5IOaWsOWinuaIluabtOaWsOeahCBgQUdFTlRTLm1kYCDoiIfnm67liY3ku7vli5npgannlKjnmoTopo/liYfmqKHntYTvvJvkvb/nlKjogIXmmI7norrmjIflrpogU2tpbGwg5oiW5Lu75YuZ56ym5ZCIIGAuYWdlbnRzL3NraWxscy9gIOS4reeahCBTa2lsbCBkZXNjcmlwdGlvbiDmmYLvvIzlho3oroDlj5blsI3mh4kgYFNLSUxMLm1kYOOAggotIOS7pSBgLmNvZGV4L2FpLWluc3RydWN0aW9ucy5tYW5pZmVzdC5qc29uYCDnrqHnkIblhbHkuqsgSW5zdHJ1Y3Rpb25zIOiIhyBBZ2VudCBTa2lsbHPvvJvlj6rmm7TmlrDmnKrooqvlgIvkurrkv67mlLnnmoTlj5fnrqHnkIbmqpTmoYjvvIzkuI3opoblr6sgY3VzdG9taXplZCBvciB1bm1hbmFnZWQgSW5zdHJ1Y3Rpb25zIG9yIEFnZW50IFNraWxsc+OAggotIFJlcG9zaXRvcnkg55qEIG9yaWdpbiDoi6XliJflnKggYH4vLmNvZGV4L2FpLWluc3RydWN0aW9ucy1zeW5jLmpzb25gIOeahCBgZXhjbHVkZWRSZXBvc2l0b3J5VXJsc2DvvIzmiJYgdGFzayDllZ/li5Xnm67pjITkvY3mlrwgYGV4Y2x1ZGVkUmVwb3NpdG9yeVBhdGhzYO+8jOebtOaOpeeVpemBjuWQjOatpeOAggotIFJlcG9zaXRvcnktbG9jYWwgSW5zdHJ1Y3Rpb25z44CBU2tpbGxzIOiIhyBtYW5pZmVzdCDmmK/miYDmnIkgYnJhbmNoIOWFseeUqOeahOWAi+S6uiBydW50aW1lIGFydGlmYWN0c++8jOW/hemgiOS/neaMgSBsb2NhbCBpZ25vcmVkIOS4lOS4jeW+lyBjb21taXQg5Yiw55Si5ZOBIFJlcG9zaXRvcnnvvJvoi6Xlj5fnrqHot6/lvpHlt7LooqsgR2l0IHRyYWNrZWTvvIxib290c3RyYXAg5b+F6aCIIGZhaWwgY2xvc2VkIOS4puWbnuWgseaxoeafk+i3r+W+ke+8jOS4jeW+l+iHquWLlSBzdGFnZeOAgWNvbW1pdCDmiJYgcHVzaOOAgg=='
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

function Write-InstallerUtf8File {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Content)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
    if (-not [string]::IsNullOrWhiteSpace([string]$script:InstallerMutationRoot)) {
        $relativePath = Get-InstallerMutationRelativePath -Root $script:InstallerMutationRoot -Path $Path
        Set-InstallerTransactionalFileBytes -RelativePath $relativePath -Bytes $bytes
        return
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllBytes($Path,$bytes)
}

function Set-InstallerBootstrapSection {
    param([Parameter(Mandatory = $true)][string] $AgentsPath,[Parameter(Mandatory = $true)][string] $Section)
    $normalizedSection = $Section.Trim() + "`n"
    $content = if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) { [System.IO.File]::ReadAllText($AgentsPath).Replace("`r`n","`n").Replace("`r","`n") } else { '' }
    $pattern = '(?ms)^## Repository Instructions Bootstrap\s*\n.*?(?=^##\s|\z)'
    $updated = if ([regex]::IsMatch($content,$pattern)) { [regex]::Replace($content,$pattern,$normalizedSection) }
    elseif ([string]::IsNullOrWhiteSpace($content)) { $normalizedSection }
    else { $content.TrimEnd() + "`n`n" + $normalizedSection }
    Write-InstallerUtf8File -Path $AgentsPath -Content $updated
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
        }
        $parent = Split-Path -Parent $inspectionPath
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($inspectionPath,[System.StringComparison]::OrdinalIgnoreCase)) { break }
        $inspectionPath = $parent
    }
    if ($ExpectedType -ceq 'File' -and (Test-Path -LiteralPath $fullPath -PathType Leaf) -and
        ([string]::IsNullOrWhiteSpace([string]$script:InstallerHeldLockPath) -or
            -not $fullPath.Equals([string]$script:InstallerHeldLockPath,[System.StringComparison]::OrdinalIgnoreCase))) {
        Assert-InstallerMutationFileOwnership -Path $fullPath
    }
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

function Remove-InstallerSessionStartHook {
    param(
        [Parameter(Mandatory = $true)][string] $HooksPath,
        [Parameter(Mandatory = $true)][string] $BootstrapHookPath
    )
    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return }
    try { $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $HooksPath | ConvertFrom-Json }
    catch { throw "Codex hooks file is not valid JSON: $HooksPath" }
    if (-not (Test-InstallerHasProperty -Object $document -Name 'hooks') -or $null -eq $document.hooks -or
        -not (Test-InstallerHasProperty -Object $document.hooks -Name 'SessionStart')) { return }
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
    Write-InstallerUtf8File -Path $HooksPath -Content (($document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n")
    Get-Content -Raw -Encoding UTF8 -LiteralPath $HooksPath | ConvertFrom-Json | Out-Null
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

function Copy-InstallerBackupFile {
    param([Parameter(Mandatory = $true)][string] $Source,[Parameter(Mandatory = $true)][string] $Destination)
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $input = [System.IO.File]::Open($Source,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
        $output = $null
        try {
            $output = [System.IO.File]::Open($Destination,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
            $input.CopyTo($output)
            $output.Flush($true)
        }
        finally {
            if ($null -ne $output) { $output.Dispose() }
            $input.Dispose()
        }
        return $true
    }
    return $false
}

function New-InstallerFileTransactionState {
    param(
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Backup,
        [Parameter(Mandatory = $true)][bool] $OriginallyExisted
    )

    if ($script:InstallerFileTransactionStates.ContainsKey($RelativePath)) {
        throw "Duplicate installer file transaction state: $RelativePath"
    }
    $state = [pscustomobject][ordered]@{
        RelativePath = $RelativePath
        OriginallyExisted = $OriginallyExisted
        OriginalBytes = if ($OriginallyExisted) { [System.IO.File]::ReadAllBytes($Backup) } else { $null }
        Applied = $false
        AppliedBytes = $null
    }
    $script:InstallerFileTransactionStates[$RelativePath] = $state
    return $state
}

function Set-InstallerTransactionalFileBytes {
    param(
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    if (-not $script:InstallerFileTransactionStates.ContainsKey($RelativePath)) {
        throw "Installer file mutation has no original-state snapshot: $RelativePath"
    }
    $state = $script:InstallerFileTransactionStates[$RelativePath]
    if ([bool]$state.Applied) { throw "Installer file transaction state was already applied: $RelativePath" }
    if ([bool]$state.OriginallyExisted) {
        Set-InstallerSafeFileBytes -TargetRoot $script:InstallerMutationRoot -RelativePath $RelativePath `
            -Bytes $Bytes -ExpectedBytes ([byte[]]$state.OriginalBytes)
    }
    else {
        Set-InstallerSafeFileBytes -TargetRoot $script:InstallerMutationRoot -RelativePath $RelativePath `
            -Bytes $Bytes -ExpectMissing
    }
    $state.AppliedBytes = [byte[]]$Bytes.Clone()
    $state.Applied = $true
}

function Restore-InstallerFileTransactionState {
    param([Parameter(Mandatory = $true)][object] $State)

    if (-not [bool]$State.Applied) { return }
    if ([bool]$State.OriginallyExisted) {
        Set-InstallerSafeFileBytes -TargetRoot $script:InstallerMutationRoot -RelativePath ([string]$State.RelativePath) `
            -Bytes ([byte[]]$State.OriginalBytes) -ExpectedBytes ([byte[]]$State.AppliedBytes)
    }
    else {
        Remove-InstallerSafeFile -TargetRoot $script:InstallerMutationRoot -RelativePath ([string]$State.RelativePath) `
            -ExpectedBytes ([byte[]]$State.AppliedBytes)
    }
    $State.Applied = $false
}

$runtimeFiles = @(
    'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
    'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
    'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
    'ai-instructions-runtime-contract.psm1','ai-instructions-updater.psm1','update-ai-instructions.ps1',
    'cleanup-ai-instructions-pollution.ps1'
)
$stableScripts = @('bootstrap-ai-instructions-installed.ps1','update-ai-instructions.ps1','cleanup-ai-instructions-pollution.ps1')
$relativeSourcePaths = @('scripts/install-ai-instructions-bootstrap.ps1','scripts/installer-safe-mutation.psm1')
foreach ($fileName in @($runtimeFiles + $stableScripts | Sort-Object -Unique)) { $relativeSourcePaths += "scripts/$fileName" }
$relativeSourcePaths += 'catalog/skills-catalog.json','catalog/skills-catalog-lock.json'

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
        Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
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
            $repositoryRootPath = Expand-SafeZipRepository -ArchiveStream $archiveStream -DestinationRoot $archiveSourceWorkingRoot
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
        if ($Acquisition -ceq 'github-codeload') { throw "github-codeload archive runtime source was not found: $relativePath" }
        throw "Installer runtime source was not found: $relativePath"
    }
}

$runtimeContractSource = Join-Path $repositoryRootPath 'scripts\ai-instructions-runtime-contract.psm1'
Import-Module $runtimeContractSource -Force
Import-Module (Join-Path $repositoryRootPath 'scripts\installer-safe-mutation.psm1') -Force

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$codexHomePath = Get-InstallerFullDirectoryPath -Path $CodexHome
$script:InstallerMutationRoot = $codexHomePath
$codexHomeRoot = [System.IO.Path]::GetPathRoot($codexHomePath)
if (-not [string]::IsNullOrWhiteSpace($codexHomeRoot) -and $codexHomePath.Equals($codexHomeRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Codex Home must not be a filesystem root: $codexHomePath"
}
$hookDirectory = Join-Path $codexHomePath 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'
$updateScript = Join-Path $hookDirectory 'update-ai-instructions.ps1'
$cleanupScript = Join-Path $hookDirectory 'cleanup-ai-instructions-pollution.ps1'
$runtimeDirectory = Join-Path $hookDirectory 'ai-instructions-runtime'
$agentsPath = Join-Path $codexHomePath 'AGENTS.md'
$hooksPath = Join-Path $codexHomePath 'hooks.json'
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
$installLockPath = Join-Path $codexHomePath 'ai-instructions-install.lock'
$script:InstallerHeldLockPath = $installLockPath
Assert-InstallerMutationPath -Path $codexHomePath -ExpectedType Directory
Assert-InstallerMutationPath -Path $hookDirectory -ExpectedType Directory
Assert-InstallerMutationPath -Path $runtimeDirectory -ExpectedType Directory
foreach ($filePath in @($hookScript,$updateScript,$cleanupScript,$agentsPath,$hooksPath,$configurationPath,$installLockPath)) {
    Assert-InstallerMutationPath -Path $filePath -ExpectedType File
}
New-Item -ItemType Directory -Force -Path $codexHomePath,$hookDirectory | Out-Null
$installLockStream = $null
$activeMutationGuard = Open-InstallerMutationDirectoryGuard -TargetRoot $codexHomePath -RelativeDirectory 'hooks'
try {
    try {
        $installLockStream = [System.IO.File]::Open($installLockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw 'Another AI instructions installer is already running for this Codex Home.'
    }
    Assert-InstallerMutationPath -Path $codexHomePath -ExpectedType Directory
    Assert-InstallerMutationPath -Path $hookDirectory -ExpectedType Directory
    Assert-InstallerMutationPath -Path $runtimeDirectory -ExpectedType Directory
    foreach ($filePath in @($hookScript,$updateScript,$cleanupScript,$agentsPath,$hooksPath,$configurationPath,$installLockPath)) {
        Assert-InstallerMutationPath -Path $filePath -ExpectedType File
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit)) {
        $installedBundlePath = Join-Path $runtimeDirectory 'runtime-bundle.json'
        try {
            $installedBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $installedBundlePath | ConvertFrom-Json
            $installedConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
            Assert-AiInstructionsRuntimeBundleV2 `
                -Bundle $installedBundle `
                -Configuration $installedConfiguration `
                -RuntimeRoot $runtimeDirectory | Out-Null
        }
        catch {
            throw "The installed runtime changed before installation; the candidate transaction must be resolved again. $($_.Exception.Message)"
        }
        if ([string]$installedBundle.commit -cne $ExpectedCurrentCommit) {
            throw 'The installed runtime changed before installation; the candidate transaction must be resolved again.'
        }
    }

    $existingConfiguration = $null
    if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
        try { $existingConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json }
        catch { throw "AI instruction sync configuration is not valid JSON: $configurationPath" }
    }
    if ($expectedPolicySpecified) {
        try { Assert-AiInstructionsSyncConfigurationV4 -Configuration $existingConfiguration | Out-Null }
        catch { throw 'The active runtime update policy changed before installation; candidate approval must be resolved again.' }
        if ([string]$existingConfiguration.updates.mode -cne $ExpectedUpdateMode -or
            [string]$existingConfiguration.updates.channel -cne $ExpectedUpdateChannel -or
            [string]$existingConfiguration.updates.ref -cne $ExpectedUpdateRef) {
            throw 'The active runtime update policy changed before installation; candidate approval must be resolved again.'
        }
    }
    $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 `
        -ExistingConfiguration $existingConfiguration `
        -CatalogRepository $catalogRepository `
        -CatalogRef $catalogRef `
        -AdditionalExcludedRepositoryUrls $ExcludedRepositoryUrls `
        -AdditionalExcludedRepositoryPaths $ExcludedRepositoryPaths

    $transactionId = [Guid]::NewGuid().ToString('N')
    $stagingRoot = Join-Path $codexHomePath ".ai-instructions-install-$transactionId"
    $stagingRuntime = Join-Path $stagingRoot 'runtime'
    $stagingLauncher = Join-Path $stagingRoot 'bootstrap-ai-instructions.ps1'
    $stagingUpdater = Join-Path $stagingRoot 'update-ai-instructions.ps1'
    $stagingCleanup = Join-Path $stagingRoot 'cleanup-ai-instructions-pollution.ps1'
    $stagingConfiguration = Join-Path $stagingRoot 'ai-instructions-sync.json'
    $backupRoot = Join-Path $codexHomePath ".ai-instructions-backup-$transactionId"
    $backupRuntime = Join-Path $backupRoot 'runtime'
    $quarantinedRuntime = Join-Path $backupRoot 'failed-runtime'
    $retainRecoveryBackup = $false
    $stagingRootGuard = $null
    $backupRootGuard = $null
    try {
        New-Item -ItemType Directory -Force -Path $stagingRuntime,(Join-Path $stagingRuntime 'catalog'),$backupRoot | Out-Null
        $stagingRootGuard = Open-InstallerMutationDirectoryGuard -TargetRoot $codexHomePath `
            -RelativeDirectory (Split-Path -Leaf $stagingRoot)
        $backupRootGuard = Open-InstallerMutationDirectoryGuard -TargetRoot $codexHomePath `
            -RelativeDirectory (Split-Path -Leaf $backupRoot)
        Assert-InstallerMutationPath -Path $stagingRoot -ExpectedType Directory
        Assert-InstallerMutationPath -Path $stagingRuntime -ExpectedType Directory
        Assert-InstallerMutationPath -Path $backupRoot -ExpectedType Directory
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\bootstrap-ai-instructions-installed.ps1') -Destination $stagingLauncher -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\update-ai-instructions.ps1') -Destination $stagingUpdater -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\cleanup-ai-instructions-pollution.ps1') -Destination $stagingCleanup -Force
        foreach ($fileName in $runtimeFiles) { Copy-Item -LiteralPath (Join-Path $repositoryRootPath "scripts\$fileName") -Destination (Join-Path $stagingRuntime $fileName) -Force }
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog.json') -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog-lock.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -Force
        Write-AiInstructionsJsonFile -Path $stagingConfiguration -Document $configuration
        Import-Module (Join-Path $stagingRuntime 'ai-instructions-runtime-contract.psm1') -Force
        $bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $stagingRuntime -Repository $catalogRepository -Commit $catalogRef -Acquisition $Acquisition -ArchiveSha256 $ArchiveSha256
        Write-AiInstructionsJsonFile -Path (Join-Path $stagingRuntime 'runtime-bundle.json') -Document $bundle
        $stagedConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $stagingConfiguration | ConvertFrom-Json
        $stagedBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stagingRuntime 'runtime-bundle.json') | ConvertFrom-Json
        Assert-AiInstructionsRuntimeBundleV2 -Bundle $stagedBundle -Configuration $stagedConfiguration -RuntimeRoot $stagingRuntime | Out-Null
        Import-Module (Join-Path $stagingRuntime 'skills-catalog-contract.psm1') -Force
        Test-SkillsCatalogLockDocument -LockPath (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -CatalogPath (Join-Path $stagingRuntime 'catalog\skills-catalog.json') | Out-Null
        foreach ($scriptPath in @($stagingLauncher,$stagingUpdater,$stagingCleanup) + @(Get-ChildItem -LiteralPath $stagingRuntime -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') } | Select-Object -ExpandProperty FullName)) {
            $tokens=$null; $errors=$null
            [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
            if (@($errors).Count -gt 0) { throw "Staged installer runtime contains a PowerShell parse error in '$scriptPath': $(@($errors)[0].Message)" }
        }

        $hadRuntime = Test-Path -LiteralPath $runtimeDirectory -PathType Container
        $hadHook = Copy-InstallerBackupFile -Source $hookScript -Destination (Join-Path $backupRoot 'bootstrap-ai-instructions.ps1')
        $hadUpdater = Copy-InstallerBackupFile -Source $updateScript -Destination (Join-Path $backupRoot 'update-ai-instructions.ps1')
        $hadCleanup = Copy-InstallerBackupFile -Source $cleanupScript -Destination (Join-Path $backupRoot 'cleanup-ai-instructions-pollution.ps1')
        $hadConfiguration = Copy-InstallerBackupFile -Source $configurationPath -Destination (Join-Path $backupRoot 'ai-instructions-sync.json')
        $hadAgents = Copy-InstallerBackupFile -Source $agentsPath -Destination (Join-Path $backupRoot 'AGENTS.md')
        $hadHooks = Copy-InstallerBackupFile -Source $hooksPath -Destination (Join-Path $backupRoot 'hooks.json')
        $hookState = New-InstallerFileTransactionState -RelativePath 'hooks/bootstrap-ai-instructions.ps1' -Backup (Join-Path $backupRoot 'bootstrap-ai-instructions.ps1') -OriginallyExisted $hadHook
        $updaterState = New-InstallerFileTransactionState -RelativePath 'hooks/update-ai-instructions.ps1' -Backup (Join-Path $backupRoot 'update-ai-instructions.ps1') -OriginallyExisted $hadUpdater
        $cleanupState = New-InstallerFileTransactionState -RelativePath 'hooks/cleanup-ai-instructions-pollution.ps1' -Backup (Join-Path $backupRoot 'cleanup-ai-instructions-pollution.ps1') -OriginallyExisted $hadCleanup
        $configurationState = New-InstallerFileTransactionState -RelativePath 'ai-instructions-sync.json' -Backup (Join-Path $backupRoot 'ai-instructions-sync.json') -OriginallyExisted $hadConfiguration
        $agentsState = New-InstallerFileTransactionState -RelativePath 'AGENTS.md' -Backup (Join-Path $backupRoot 'AGENTS.md') -OriginallyExisted $hadAgents
        $hooksState = New-InstallerFileTransactionState -RelativePath 'hooks.json' -Backup (Join-Path $backupRoot 'hooks.json') -OriginallyExisted $hadHooks
        $fileTransactionStates = @($hookState,$updaterState,$cleanupState,$configurationState,$agentsState,$hooksState)
        $runtimeBackedUp=$false; $runtimeInstalled=$false
        try {
            Assert-InstallerMutationPath -Path $codexHomePath -ExpectedType Directory
            Assert-InstallerMutationPath -Path $hookDirectory -ExpectedType Directory
            Assert-InstallerMutationPath -Path $runtimeDirectory -ExpectedType Directory
            foreach ($filePath in @($hookScript,$updateScript,$cleanupScript,$agentsPath,$hooksPath,$configurationPath,$installLockPath)) {
                Assert-InstallerMutationPath -Path $filePath -ExpectedType File
            }
            Set-InstallerTransactionalFileBytes -RelativePath 'hooks/bootstrap-ai-instructions.ps1' -Bytes ([System.IO.File]::ReadAllBytes($stagingLauncher))
            Set-InstallerTransactionalFileBytes -RelativePath 'hooks/update-ai-instructions.ps1' -Bytes ([System.IO.File]::ReadAllBytes($stagingUpdater))
            Set-InstallerTransactionalFileBytes -RelativePath 'hooks/cleanup-ai-instructions-pollution.ps1' -Bytes ([System.IO.File]::ReadAllBytes($stagingCleanup))
            if ($hadRuntime) { Move-Item -LiteralPath $runtimeDirectory -Destination $backupRuntime; $runtimeBackedUp=$true }
            Move-Item -LiteralPath $stagingRuntime -Destination $runtimeDirectory; $runtimeInstalled=$true
            Set-InstallerTransactionalFileBytes -RelativePath 'ai-instructions-sync.json' -Bytes ([System.IO.File]::ReadAllBytes($stagingConfiguration))
            Set-InstallerBootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
            Remove-InstallerSessionStartHook -HooksPath $hooksPath -BootstrapHookPath $hookScript
        }
        catch {
            $installError=$_
            $rollbackErrors = New-Object System.Collections.Generic.List[string]
            $rollbackPathsSafe = $true
            try {
                Assert-InstallerMutationPath -Path $codexHomePath -ExpectedType Directory
                Assert-InstallerMutationPath -Path $hookDirectory -ExpectedType Directory
                Assert-InstallerMutationPath -Path $runtimeDirectory -ExpectedType Directory
                Assert-InstallerMutationPath -Path $backupRuntime -ExpectedType Directory
                foreach ($filePath in @($hookScript,$updateScript,$cleanupScript,$agentsPath,$hooksPath,$configurationPath,$installLockPath)) {
                    Assert-InstallerMutationPath -Path $filePath -ExpectedType File
                }
            }
            catch { $rollbackPathsSafe = $false; $rollbackErrors.Add($_.Exception.Message) }
            if ($rollbackPathsSafe) {
                $runtimeQuarantined = $false
                $quarantinedRuntimeVerified = $false
                if ($runtimeInstalled) {
                    try {
                        if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
                            throw 'The transaction-installed runtime is missing during rollback.'
                        }
                        if (Test-Path -LiteralPath $quarantinedRuntime) {
                            throw "The runtime quarantine path already exists: $quarantinedRuntime"
                        }
                        Move-Item -LiteralPath $runtimeDirectory -Destination $quarantinedRuntime
                        $runtimeQuarantined = $true
                        Assert-InstallerMutationPath -Path $quarantinedRuntime -ExpectedType Directory
                        $quarantinedBundlePath = Join-Path $quarantinedRuntime 'runtime-bundle.json'
                        $quarantinedBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $quarantinedBundlePath | ConvertFrom-Json
                        Assert-AiInstructionsRuntimeBundleV2 -Bundle $quarantinedBundle `
                            -Configuration $stagedConfiguration -RuntimeRoot $quarantinedRuntime | Out-Null
                        foreach ($identityProperty in @('repository','commit','acquisition','archiveSha256','inventorySha256')) {
                            if ([string]$quarantinedBundle.$identityProperty -cne [string]$stagedBundle.$identityProperty) {
                                throw "The quarantined runtime no longer matches the transaction candidate: $identityProperty"
                            }
                        }
                        $quarantinedRuntimeVerified = $true
                    }
                    catch {
                        $rollbackErrors.Add("Runtime rollback preserved the transaction runtime quarantine because its current contents could not be proven safe to delete: $($_.Exception.Message)")
                    }
                }
                if ($runtimeBackedUp) {
                    try {
                        if (Test-Path -LiteralPath $runtimeDirectory) {
                            throw "The active runtime path is occupied and the previous runtime was preserved at: $backupRuntime"
                        }
                        if (-not (Test-Path -LiteralPath $backupRuntime -PathType Container)) {
                            throw "The previous runtime backup is missing: $backupRuntime"
                        }
                        Move-Item -LiteralPath $backupRuntime -Destination $runtimeDirectory
                    }
                    catch { $rollbackErrors.Add("Runtime restore: $($_.Exception.Message)") }
                }
                if ($runtimeQuarantined -and $quarantinedRuntimeVerified) {
                    try { Remove-Item -LiteralPath $quarantinedRuntime -Recurse -Force }
                    catch { $rollbackErrors.Add("Verified transaction runtime cleanup: $($_.Exception.Message)") }
                }
                foreach ($fileState in $fileTransactionStates) {
                    try { Restore-InstallerFileTransactionState -State $fileState }
                    catch { $rollbackErrors.Add("$($fileState.RelativePath): $($_.Exception.Message)") }
                }
            }
            if ($rollbackErrors.Count -gt 0) {
                $retainRecoveryBackup = $true
                throw "AI instructions installation failed and rollback also failed. Recovery backup retained at '$backupRoot'. Original error: $($installError.Exception.Message). Rollback error: $($rollbackErrors -join ' | ')"
            }
            throw $installError
        }
    }
    finally {
        if ($null -ne $backupRootGuard) { $backupRootGuard.Dispose() }
        if ($null -ne $stagingRootGuard) { $stagingRootGuard.Dispose() }
        if (Test-Path -LiteralPath $stagingRoot) {
            $safeStagingRoot = Assert-InstallerSafeChildDirectory -Parent $codexHomePath -Path $stagingRoot -LeafPrefix '.ai-instructions-install-'
            Remove-Item -LiteralPath $safeStagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not $retainRecoveryBackup -and (Test-Path -LiteralPath $backupRoot)) {
            $safeBackupRoot = Assert-InstallerSafeChildDirectory -Parent $codexHomePath -Path $backupRoot -LeafPrefix '.ai-instructions-backup-'
            Remove-Item -LiteralPath $safeBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($null -ne $activeMutationGuard) { $activeMutationGuard.Dispose() }
    if ($null -ne $installLockStream) { $installLockStream.Dispose() }
    $script:InstallerHeldLockPath = $null
    $script:InstallerMutationRoot = $null
    $script:InstallerFileTransactionStates = @{}
}

Write-Output "Installed AI instructions bootstrap launcher: $hookScript"
Write-Output "Installed AI instructions manual updater: $updateScript"
Write-Output "Installed AI instructions pollution cleanup command: $cleanupScript"
Write-Output "Installed immutable runtime bundle: $runtimeDirectory"
Write-Output "Updated AI instructions sync configuration schema v4: $configurationPath"
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($archiveSourceWorkingRoot) -and (Test-Path -LiteralPath $archiveSourceWorkingRoot)) {
        $resolvedTempRoot = Get-InstallerFullDirectoryPath -Path ([System.IO.Path]::GetTempPath())
        $resolvedArchiveSourceRoot = Assert-InstallerSafeChildDirectory -Parent $resolvedTempRoot -Path $archiveSourceWorkingRoot -LeafPrefix 'ai-instructions-installer-source-'
        Remove-Item -LiteralPath $resolvedArchiveSourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
