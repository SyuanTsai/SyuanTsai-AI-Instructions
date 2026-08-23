[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SourceArchivePath,
    [string] $TargetRoot,
    [Parameter(Mandatory = $true)]
    [string] $ConfigurationPath,
    [Parameter(Mandatory = $true)]
    [string] $ProvenancePath,
    [string] $GitExecutable = 'git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($GitExecutable)) {
    throw 'GitExecutable must be a non-empty command name or path.'
}

$manifestRelativePath = '.codex/ai-instructions.manifest.json'
$excludeBeginMarker = '# BEGIN Codex AI Instructions managed paths'
$excludeEndMarker = '# END Codex AI Instructions managed paths'

Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ai-instructions-runtime-contract.psm1') -Force

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $GitExecutable -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Get-GitExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & $GitExecutable -C $Repository @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-FullPathWithoutTrailingSeparator {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($rootPath) -and
        $fullPath.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase)) {
        return $rootPath
    }
    return $fullPath.TrimEnd([char[]]@('\', '/'))
}

function Get-NormalizedRepositoryLocation {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)

    $trimmedUrl = $RepositoryUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedUrl)) {
        throw 'Repository URL cannot be empty.'
    }

    $hostName = $null
    $repositoryPath = $null
    $absoluteUri = $null
    if ([System.Uri]::TryCreate($trimmedUrl, [System.UriKind]::Absolute, [ref] $absoluteUri) -and
        -not [string]::IsNullOrWhiteSpace($absoluteUri.Host)) {
        $hostName = $absoluteUri.Host
        $repositoryPath = $absoluteUri.AbsolutePath
    }
    elseif ($trimmedUrl -match '^(?:[^@/]+@)?(?<Host>[^:/]+):(?<Path>.+)$') {
        $hostName = $Matches.Host
        $repositoryPath = $Matches.Path
    }
    else {
        throw "Repository URL must identify a remote Git repository: $RepositoryUrl"
    }

    $normalizedPath = $repositoryPath.Trim([char[]]@('/', '\'))
    if ($normalizedPath.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedPath = $normalizedPath.Substring(0, $normalizedPath.Length - 4)
    }

    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        throw "Repository URL does not contain a repository path: $RepositoryUrl"
    }

    return "$($hostName.ToLowerInvariant())/$normalizedPath"
}

function Test-RepositoryLocationMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryLocation,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ConfiguredRepositoryLocations
    )

    foreach ($configuredRepositoryLocation in $ConfiguredRepositoryLocations) {
        if ($RepositoryLocation.Equals($configuredRepositoryLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-NormalizedRepositoryRelativeDirectoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $trimmedPath = $Path.Trim().Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        throw 'Repository-relative directory path cannot be empty.'
    }

    if ([System.IO.Path]::IsPathRooted($Path) -or $trimmedPath -match '^[A-Za-z]:') {
        throw "Repository-relative directory path must not be rooted: $Path"
    }

    $parts = @($trimmedPath -split '/+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..') {
            throw "Repository-relative directory path must not contain . or .. segments: $Path"
        }
    }

    return $parts -join '/'
}

function Test-RepositoryDirectoryMatches {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RepositoryRelativePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ConfiguredRepositoryPaths
    )

    foreach ($configuredRepositoryPath in $ConfiguredRepositoryPaths) {
        if ($RepositoryRelativePath.Equals($configuredRepositoryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $RepositoryRelativePath.StartsWith("$configuredRepositoryPath/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $FullPath
    )

    return $FullPath.Substring($RepositoryRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
}

function Get-NormalizedContentHash {
    param([Parameter(Mandatory = $true)][string] $Path)

    $content = [System.IO.File]::ReadAllText($Path)
    $normalizedContent = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $contentBytes = $utf8WithoutBom.GetBytes($normalizedContent)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($contentBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-RawContentHash {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-ManagedContentHash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath
    )

    if ($TargetPath.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal)) {
        return Get-RawContentHash -Path $Path
    }

    return Get-NormalizedContentHash -Path $Path
}

function Test-IsAllowedManagedPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ($Path -eq 'AGENTS.md' -or
        $Path -eq '.github/copilot-instructions.md' -or
        $Path -match '^\.codex/AI-Rules/[^/\\]+\.en\.md$' -or
        $Path -match '^\.github/AI-Rules/[^/\\]+\.en\.md$') {
        return $true
    }

    if (-not $Path.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal)) {
        return $false
    }

    $skillPathParts = @($Path.Substring('.agents/skills/'.Length) -split '/')
    if ($skillPathParts.Count -lt 2 -or
        $skillPathParts[0] -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        return $false
    }

    foreach ($skillPathPart in $skillPathParts) {
        if ([string]::IsNullOrWhiteSpace($skillPathPart) -or
            $skillPathPart -eq '.' -or
            $skillPathPart -eq '..' -or
            $skillPathPart.Contains('\')) {
            return $false
        }
    }

    return $true
}

function Test-IsCanonicalInstructionSourceRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)

    if ((Get-GitExitCode -Repository $Repository -Arguments @('remote','get-url','origin')) -ne 0) { return $false }
    foreach ($originUrl in @(Invoke-Git -Repository $Repository -Arguments @('remote','get-url','--all','origin'))) {
        try {
            Assert-AiInstructionsCanonicalRepository -Repository ([string]$originUrl)
            return $true
        }
        catch { }
    }
    return $false
}

function Get-GitInfoExcludePath {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $path = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-path','info/exclude')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Repository $path }
    return [System.IO.Path]::GetFullPath($path)
}

function Assert-GitInfoExcludeMutationPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -Force -LiteralPath $Path
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Unsafe shared Git exclude mutation path '$Path': expected a non-reparse file or a missing path."
    }
}

function Get-GitPathComparer {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $ignoreCase = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ((Get-GitExitCode -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase')) -eq 0) {
        $configured = ((Invoke-Git -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase')) | Select-Object -First 1).Trim()
        if ($configured -ceq 'true') { $ignoreCase = $true }
    }
    if ($ignoreCase) { return [System.StringComparer]::OrdinalIgnoreCase }
    return [System.StringComparer]::Ordinal
}

function Open-RepositoryOperationLock {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $commonGitDirectory = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $Repository $commonGitDirectory }
    $lockPath = Join-Path ([System.IO.Path]::GetFullPath($commonGitDirectory)) 'codex-ai-instructions.lock'
    try {
        return [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw 'Another AI instruction repository operation is already running; bootstrap stopped before mutation.'
    }
}

function Assert-ManagedPathDoesNotCrossReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $resolvedRoot = Get-FullPathWithoutTrailingSeparator -Path $Root
    $rootPrefix = $resolvedRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) { throw "$Context is outside its worktree: $resolvedPath" }
    $inspectionPath = $resolvedPath
    while ($inspectionPath.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $inspectionPath) {
            $item = Get-Item -Force -LiteralPath $inspectionPath
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context crosses a reparse point: $inspectionPath" }
        }
        $inspectionPath = Split-Path -Parent $inspectionPath
    }
}

function Get-SharedManagedExcludePaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $CurrentManagedPaths
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($currentManagedPath in $CurrentManagedPaths) { [void]$paths.Add($currentManagedPath.Replace('\','/')) }
    foreach ($line in @(Invoke-Git -Repository $Repository -Arguments @('worktree','list','--porcelain'))) {
        $text = [string]$line
        if (-not $text.StartsWith('worktree ',[System.StringComparison]::Ordinal)) { continue }
        $worktreeRoot = $text.Substring('worktree '.Length)
        $worktreeManifestPath = Join-Path $worktreeRoot $manifestRelativePath.Replace('/','\')
        if (-not (Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf)) { continue }
        Assert-ManagedPathDoesNotCrossReparsePoint -Root $worktreeRoot -Path $worktreeManifestPath -Context 'Linked worktree managed manifest'
        try {
            $worktreeManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $worktreeManifestPath | ConvertFrom-Json
            $worktreeManifestSchemaVersion = $worktreeManifest.schemaVersion
            if ($worktreeManifestSchemaVersion -isnot [int] -and $worktreeManifestSchemaVersion -isnot [long]) {
                throw 'schemaVersion must be an integer.'
            }
            if ($worktreeManifestSchemaVersion -eq 2) { Assert-ManagedManifestV2 -Manifest $worktreeManifest }
            elseif ($worktreeManifestSchemaVersion -eq 1) { Assert-LegacyManagedManifestV1 -Manifest $worktreeManifest }
            else {
                throw "unsupported schemaVersion '$worktreeManifestSchemaVersion'."
            }
        }
        catch {
            throw "Cannot compose shared Git exclusions because a linked worktree manifest is invalid: $worktreeManifestPath. $($_.Exception.Message)"
        }
        [void]$paths.Add($manifestRelativePath)
        foreach ($entry in @($worktreeManifest.files)) {
            $targetPath = [string]$entry.targetPath
            if (-not (Test-IsAllowedManagedPath -Path $targetPath)) {
                throw "Cannot compose shared Git exclusions because a linked worktree manifest contains an unsafe path: $targetPath"
            }
            [void]$paths.Add($targetPath)
        }
    }
    return @($paths | Sort-Object)
}

function New-GitInfoExcludeSnapshot {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $path = Get-GitInfoExcludePath -Repository $Repository
    Assert-GitInfoExcludeMutationPath -Path $path
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    return [pscustomobject][ordered]@{
        Path = $path
        Existed = $exists
        Bytes = if ($exists) { [System.IO.File]::ReadAllBytes($path) } else { $null }
    }
}

function Restore-GitInfoExcludeSnapshot {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    if ([bool]$Snapshot.Existed) {
        Assert-GitInfoExcludeMutationPath -Path ([string]$Snapshot.Path)
        $parent = Split-Path -Parent ([string]$Snapshot.Path)
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        [System.IO.File]::WriteAllBytes([string]$Snapshot.Path,[byte[]]$Snapshot.Bytes)
    }
    elseif (Test-Path -LiteralPath ([string]$Snapshot.Path)) {
        Assert-GitInfoExcludeMutationPath -Path ([string]$Snapshot.Path)
        Remove-Item -LiteralPath ([string]$Snapshot.Path) -Force
    }
}

function ConvertTo-GitExcludeLiteralPattern {
    param([Parameter(Mandatory = $true)][string] $Path)

    $escaped = $Path.Replace('\','/')
    foreach ($character in @('\','[',']','*','?')) { $escaped = $escaped.Replace($character,"\$character") }
    if ($escaped.StartsWith('!') -or $escaped.StartsWith('#')) { $escaped = "\$escaped" }
    return "/$escaped"
}

function Set-ManagedGitInfoExclude {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ManagedPaths
    )

    $path = Get-GitInfoExcludePath -Repository $Repository
    Assert-GitInfoExcludeMutationPath -Path $path
    $content = if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::ReadAllText($path).Replace("`r`n","`n").Replace("`r","`n") } else { '' }
    $pattern = '(?ms)^' + [regex]::Escape($excludeBeginMarker) + '\n.*?^' + [regex]::Escape($excludeEndMarker) + '\n?'
    $beginCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($excludeBeginMarker) + '$').Count
    $endCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($excludeEndMarker) + '$').Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1 -or ($beginCount -eq 1 -and -not [regex]::IsMatch($content,$pattern))) {
        throw "The Codex AI Instructions managed exclude block is malformed: $path"
    }
    $withoutBlock = [regex]::Replace($content,$pattern,'').TrimEnd("`n")
    $sharedManagedPaths = @(Get-SharedManagedExcludePaths -Repository $Repository -CurrentManagedPaths $ManagedPaths)
    $lines = @($sharedManagedPaths | ForEach-Object { ConvertTo-GitExcludeLiteralPattern -Path $_ })
    $updated = $withoutBlock
    if ($lines.Count -gt 0) {
        $block = $excludeBeginMarker + "`n" + ($lines -join "`n") + "`n" + $excludeEndMarker + "`n"
        $updated = if ([string]::IsNullOrWhiteSpace($withoutBlock)) { $block } else { $withoutBlock + "`n`n" + $block }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($updated)) { $updated += "`n" }
    if ($content -cne $updated) {
        $parent = Split-Path -Parent $path
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        [System.IO.File]::WriteAllText($path,$updated,(New-Object System.Text.UTF8Encoding($false)))
    }
}

function Test-GitPathHasChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $workingTreeExitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--quiet', '--', $Path)
    $indexExitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path)

    if ($workingTreeExitCode -gt 1 -or $indexExitCode -gt 1) {
        throw "Unable to inspect local changes for managed path: $Path"
    }

    return $workingTreeExitCode -eq 1 -or $indexExitCode -eq 1
}

function Test-GitPathHasStagedChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect staged changes for managed path: $Path"
    }

    return $exitCode -eq 1
}

function New-ManifestEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

    $artifactType = 'instruction'
    $artifactId = $null
    $source = $script:instructionProvenance
    if ($TargetPath.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal)) {
        $artifactType = 'skill'
        $skillParts = @($TargetPath.Split('/'))
        $artifactId = $skillParts[2]
        if (-not $script:skillProvenanceById.ContainsKey($artifactId)) {
            throw "Managed Skill '$artifactId' has no source provenance."
        }
        $source = $script:skillProvenanceById[$artifactId]
    }
    elseif ($TargetPath -eq 'AGENTS.md') {
        $artifactId = 'codex-base'
    }
    elseif ($TargetPath -eq '.github/copilot-instructions.md') {
        $artifactId = 'copilot-base'
    }
    elseif ($TargetPath.StartsWith('.codex/AI-Rules/', [System.StringComparison]::Ordinal)) {
        $ruleName = [regex]::Replace(
            [System.IO.Path]::GetFileName($TargetPath).Replace('.en.md', '').ToLowerInvariant(),
            '[^a-z0-9-]',
            '-'
        ).Trim('-')
        $artifactId = "codex-rule-$ruleName"
    }
    elseif ($TargetPath.StartsWith('.github/AI-Rules/', [System.StringComparison]::Ordinal)) {
        $ruleName = [regex]::Replace(
            [System.IO.Path]::GetFileName($TargetPath).Replace('.en.md', '').ToLowerInvariant(),
            '[^a-z0-9-]',
            '-'
        ).Trim('-')
        $artifactId = "copilot-rule-$ruleName"
    }
    else {
        throw "Cannot derive instruction artifact ID for managed target: $TargetPath"
    }

    if ($artifactId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "Derived artifact ID is not lowercase kebab-case: $artifactId"
    }

    return [pscustomobject][ordered]@{
        artifactType = $artifactType
        artifactId = $artifactId
        sourceId = [string] $source.sourceId
        sourceRepository = [string] $source.sourceRepository
        sourceRef = [string] $source.sourceRef
        sourceCommit = [string] $source.sourceCommit
        sourceVersion = [string] $source.sourceVersion
        sourcePath = $SourcePath
        targetPath = $TargetPath
        sha256 = $Sha256
    }
}

function Copy-ExistingManifestEntry {
    param([Parameter(Mandatory = $true)][object] $Entry)

    return [pscustomobject][ordered]@{
        artifactType = [string] $Entry.artifactType
        artifactId = [string] $Entry.artifactId
        sourceId = [string] $Entry.sourceId
        sourceRepository = [string] $Entry.sourceRepository
        sourceRef = [string] $Entry.sourceRef
        sourceCommit = [string] $Entry.sourceCommit
        sourceVersion = [string] $Entry.sourceVersion
        sourcePath = [string] $Entry.sourcePath
        targetPath = [string] $Entry.targetPath
        sha256 = [string] $Entry.sha256
    }
}

function New-TargetMutationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string[]] $RelativePaths,
        [Parameter(Mandatory = $true)][string] $BackupRoot
    )

    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $resolvedTargetRoot = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
    $targetPrefix = $resolvedTargetRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $fileStates = New-Object System.Collections.Generic.List[object]
    $missingDirectories = @{}
    $backupIndex = 0

    foreach ($relativePath in @($RelativePaths | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        $targetPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedTargetRoot $relativePath.Replace('/', '\')))
        if (-not $targetPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe target mutation snapshot path: $relativePath"
        }

        $inspectionPath = $targetPath
        while ($inspectionPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $inspectionPath) {
                $inspectionItem = Get-Item -LiteralPath $inspectionPath -Force
                if (($inspectionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Managed target path crosses a reparse point: $relativePath"
                }
            }
            $inspectionPath = Split-Path -Parent $inspectionPath
        }

        $originalType = 'missing'
        $backupPath = $null
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $originalType = 'file'
            $backupPath = Join-Path $BackupRoot ('{0:D6}.bin' -f $backupIndex)
            Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
            $backupIndex++
        }
        elseif (Test-Path -LiteralPath $targetPath) {
            throw "Managed target path must be a file or missing: $relativePath"
        }

        $fileStates.Add([pscustomobject][ordered]@{
            RelativePath = $relativePath
            TargetPath = $targetPath
            OriginalType = $originalType
            BackupPath = $backupPath
        })

        $parentPath = Split-Path -Parent $targetPath
        while (-not [string]::IsNullOrWhiteSpace($parentPath) -and
            $parentPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not (Test-Path -LiteralPath $parentPath)) { $missingDirectories[$parentPath] = $true }
            $parentPath = Split-Path -Parent $parentPath
        }
    }

    return [pscustomobject][ordered]@{
        FileStates = $fileStates.ToArray()
        MissingDirectories = @($missingDirectories.Keys)
    }
}

function Restore-TargetMutationSnapshot {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    foreach ($state in @($Snapshot.FileStates)) {
        switch ([string]$state.OriginalType) {
            'file' {
                $parentPath = Split-Path -Parent ([string]$state.TargetPath)
                if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
                    New-Item -ItemType Directory -Force -Path $parentPath | Out-Null
                }
                Copy-Item -LiteralPath ([string]$state.BackupPath) -Destination ([string]$state.TargetPath) -Force
            }
            'missing' {
                if (Test-Path -LiteralPath ([string]$state.TargetPath) -PathType Leaf) {
                    Remove-Item -LiteralPath ([string]$state.TargetPath) -Force
                }
                elseif (Test-Path -LiteralPath ([string]$state.TargetPath) -PathType Container) {
                    if (@(Get-ChildItem -LiteralPath ([string]$state.TargetPath) -Force).Count -gt 0) {
                        throw "Target rollback found an unexpected non-empty directory: $($state.RelativePath)"
                    }
                    Remove-Item -LiteralPath ([string]$state.TargetPath) -Force
                }
                elseif (Test-Path -LiteralPath ([string]$state.TargetPath)) {
                    throw "Target rollback found an unexpected filesystem entry: $($state.RelativePath)"
                }
            }
        }
    }

    foreach ($directoryPath in @($Snapshot.MissingDirectories | Sort-Object { $_.Length } -Descending)) {
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) { continue }
        if (@(Get-ChildItem -LiteralPath $directoryPath -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directoryPath -Force
        }
    }
}

function Restore-TargetMutationTransaction {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Paths,
        [Parameter(Mandatory = $true)][object] $Snapshot
    )

    if ($Paths.Count -gt 0) {
        Invoke-Git -Repository $Repository -Arguments (@('reset', '--quiet', 'HEAD', '--') + $Paths) | Out-Null
    }
    Restore-TargetMutationSnapshot -Snapshot $Snapshot
}

function Get-PersonalAgentStashes {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $stashes = New-Object System.Collections.Generic.List[object]
    $stashLines = @(Invoke-Git -Repository $Repository -Arguments @('stash', 'list', '--format=%gd%x09%H%x09%gs'))
    foreach ($stashLine in $stashLines) {
        $parts = ([string] $stashLine).Split(@("`t"), 3, [System.StringSplitOptions]::None)
        if ($parts.Count -ne 3 -or $parts[2] -notmatch '(^|: )PersonalAgent$') {
            continue
        }

        $indexMatch = [System.Text.RegularExpressions.Regex]::Match($parts[0], '^stash@\{([0-9]+)\}$')
        if (-not $indexMatch.Success) {
            throw "Unexpected PersonalAgent stash reference: $($parts[0])"
        }

        $stashes.Add([pscustomobject]@{
            Reference = $parts[0]
            Hash = $parts[1]
            Index = [int] $indexMatch.Groups[1].Value
        })
    }

    return $stashes
}

function Update-PersonalAgentStash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Paths,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $ExpectedEntries
    )

    if ($Paths.Count -eq 0) {
        throw 'Cannot create PersonalAgent stash without managed changes.'
    }

    $expectedRawHashes = @{}
    foreach ($path in $Paths) {
        $fullPath = Join-Path $Repository $path.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Cannot create byte-safe PersonalAgent evidence because a managed path is missing: $path"
        }
        $expectedRawHashes[$path] = Get-RawContentHash -Path $fullPath
    }

    Invoke-Git -Repository $Repository -Arguments (@(
        '-c', 'core.autocrlf=false', 'stash', 'push', '--all', '--quiet', '-m', 'PersonalAgent', '--'
    ) + $Paths) | Out-Null

    $newStashHash = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', 'stash@{0}') | Select-Object -First 1).Trim()
    $newStash = @(Get-PersonalAgentStashes -Repository $Repository | Where-Object { $_.Hash -eq $newStashHash })
    if ($newStash.Count -ne 1) {
        throw 'PersonalAgent stash was not created as the latest stash.'
    }

    Invoke-Git -Repository $Repository -Arguments @('-c', 'core.autocrlf=false', 'stash', 'apply', '--quiet', 'stash@{0}') | Out-Null

    foreach ($path in $Paths) {
        $fullPath = Join-Path $Repository $path.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
            (Get-RawContentHash -Path $fullPath) -cne [string]$expectedRawHashes[$path]) {
            throw "PersonalAgent stash apply changed managed raw bytes; prior stashes were retained: $path"
        }
    }

    foreach ($entry in @($ExpectedEntries)) {
        $targetPath = [string]$entry.targetPath
        $targetFullPath = Join-Path $Repository $targetPath.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf) -or
            (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -cne [string]$entry.sha256) {
            throw "PersonalAgent stash apply changed managed file bytes; prior stashes were retained: $targetPath"
        }
    }

    $obsoleteStashes = @(
        Get-PersonalAgentStashes -Repository $Repository |
            Where-Object { $_.Hash -ne $newStashHash } |
            Sort-Object Index -Descending
    )
    foreach ($obsoleteStash in $obsoleteStashes) {
        try {
            Invoke-Git -Repository $Repository -Arguments @('stash', 'drop', '--quiet', $obsoleteStash.Reference) | Out-Null
        }
        catch {
            Write-Warning "Obsolete PersonalAgent stash was retained because cleanup failed: $($obsoleteStash.Reference)"
        }
    }

    return $newStashHash
}

$syncStartPath = Get-FullPathWithoutTrailingSeparator -Path (Get-Location).Path
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $resolvedRoot = & $GitExecutable -C (Get-Location).Path rev-parse --show-toplevel 2>$null
        $resolveExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($resolveExitCode -ne 0) {
        Write-Output 'AI instruction sync skipped: the current directory is not inside a Git repository.'
        return
    }

    $TargetRoot = ($resolvedRoot | Select-Object -First 1).Trim()
}

$targetRootPath = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
$syncStartRelativePath = ''
if ($syncStartPath.Equals($targetRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $syncStartRelativePath = ''
}
elseif ($syncStartPath.StartsWith($targetRootPath.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $syncStartRelativePath = Get-RepositoryRelativePath -RepositoryRoot $targetRootPath -FullPath $syncStartPath
}

$insideWorkTree = Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', '--is-inside-work-tree')
if (($insideWorkTree | Select-Object -First 1).Trim() -ne 'true') {
    Write-Output "AI instruction sync skipped: target is not a Git work tree: $targetRootPath"
    return
}

$sourceCodexBaseInTarget = Join-Path $targetRootPath '.codex\AGENTS.en.md'
$sourceCopilotBaseInTarget = Join-Path $targetRootPath '.github\copilot-instructions.en.md'
if ((Test-IsCanonicalInstructionSourceRepository -Repository $targetRootPath) -or
    ((Test-Path -LiteralPath $sourceCodexBaseInTarget -PathType Leaf) -and
     (Test-Path -LiteralPath $sourceCopilotBaseInTarget -PathType Leaf))) {
    Write-Output 'AI instruction sync skipped: the current repository is the shared instruction source.'
    return
}

if ((Get-GitExitCode -Repository $targetRootPath -Arguments @('rev-parse', '--verify', 'HEAD')) -ne 0) {
    Write-Output 'AI instruction sync skipped: the target repository has no commit, so managed changes cannot be isolated safely.'
    return
}

if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path $HOME '.codex'
    }
    $ConfigurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
}

$configurationFullPath = [System.IO.Path]::GetFullPath($ConfigurationPath)
if (Test-Path -LiteralPath $configurationFullPath -PathType Leaf) {
    try {
        $configuration = Get-Content -Raw -LiteralPath $configurationFullPath | ConvertFrom-Json
    }
    catch {
        throw "AI instruction sync configuration is not valid JSON: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        $configuration.schemaVersion -ne 3) {
        throw "Unsupported AI instruction sync configuration schema: $configurationFullPath"
    }

    $excludedRepositoryLocations = @(
        if ($configuration.PSObject.Properties.Name -contains 'excludedRepositoryUrls') {
            foreach ($excludedRepositoryUrl in @($configuration.excludedRepositoryUrls)) {
                try {
                    Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $excludedRepositoryUrl)
                }
                catch {
                    throw "excludedRepositoryUrls contains an invalid repository URL '$excludedRepositoryUrl': $($_.Exception.Message)"
                }
            }
        }
    )

    $excludedRepositoryPaths = @(
        if ($configuration.PSObject.Properties.Name -contains 'excludedRepositoryPaths') {
            foreach ($excludedRepositoryPath in @($configuration.excludedRepositoryPaths)) {
                try {
                    Get-NormalizedRepositoryRelativeDirectoryPath -Path ([string] $excludedRepositoryPath)
                }
                catch {
                    throw "excludedRepositoryPaths contains an invalid repository-relative path '$excludedRepositoryPath': $($_.Exception.Message)"
                }
            }
        }
    )

    if (-not [string]::IsNullOrWhiteSpace($syncStartRelativePath) -and
        (Test-RepositoryDirectoryMatches -RepositoryRelativePath $syncStartRelativePath -ConfiguredRepositoryPaths $excludedRepositoryPaths)) {
        Write-Output "AI instruction sync skipped: directory is excluded by ai-instructions-sync.json: $syncStartRelativePath"
        return
    }

    if ($excludedRepositoryLocations.Count -gt 0 -and
        (Get-GitExitCode -Repository $targetRootPath -Arguments @('remote', 'get-url', 'origin')) -eq 0) {
        $originUrls = @(Invoke-Git -Repository $targetRootPath -Arguments @('remote', 'get-url', '--all', 'origin'))
        foreach ($originUrl in $originUrls) {
            $originLocation = Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $originUrl)
            if (Test-RepositoryLocationMatches -RepositoryLocation $originLocation -ConfiguredRepositoryLocations $excludedRepositoryLocations) {
                Write-Output "AI instruction sync skipped: repository is excluded by ai-instructions-sync.json: $originUrl"
                return
            }
        }
    }
}

$repositoryOperationLock = $null
try {
    $repositoryOperationLock = Open-RepositoryOperationLock -Repository $targetRootPath

$families = @(
    @{
        Name = 'Codex'
        SourceBase = '.codex/AGENTS.en.md'
        TargetBase = 'AGENTS.md'
        SourceRules = '.codex/AI-Rules'
        TargetRules = '.codex/AI-Rules'
    },
    @{
        Name = 'GitHub Copilot'
        SourceBase = '.github/copilot-instructions.en.md'
        TargetBase = '.github/copilot-instructions.md'
        SourceRules = '.github/AI-Rules'
        TargetRules = '.github/AI-Rules'
    }
)
$sharedSkillsFamilyName = 'Shared Agent Skills'
$sharedSkillsSource = '.agents/skills'

$manifestFullPath = Join-Path $targetRootPath $manifestRelativePath.Replace('/', '\')
$manifestExists = Test-Path -LiteralPath $manifestFullPath -PathType Leaf
$manifestEntriesByTarget = @{}
$manifestSchemaVersion = $null
$script:instructionProvenance = $null
$script:skillProvenanceById = @{}
$provenance = $null

$resolvedProvenancePath = [System.IO.Path]::GetFullPath($ProvenancePath)
if (-not (Test-Path -LiteralPath $resolvedProvenancePath -PathType Leaf)) {
    throw "Managed source provenance does not exist: $resolvedProvenancePath"
}
try {
    $provenance = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedProvenancePath | ConvertFrom-Json
}
catch {
    throw "Managed source provenance is not valid JSON: $resolvedProvenancePath"
}
if ($provenance.schemaVersion -ne 1 -or
    [string]$provenance.catalogId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
    [string]$provenance.lockSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Managed source provenance has an unsupported schema, catalog ID, or lock hash.'
}

$script:instructionProvenance = $provenance.instruction
foreach ($requiredProperty in @('sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
    if ($null -eq $script:instructionProvenance.PSObject.Properties[$requiredProperty] -or
        [string]::IsNullOrWhiteSpace([string]$script:instructionProvenance.$requiredProperty)) {
        throw "Managed instruction provenance is missing '$requiredProperty'."
    }
}
if ([string]$script:instructionProvenance.sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
    [string]$script:instructionProvenance.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$script:instructionProvenance.sourceRepository -cnotmatch '^https://') {
    throw 'Managed instruction provenance contains an invalid source ID, repository, or commit.'
}

foreach ($skillSource in @($provenance.skills)) {
    $skillId = [string]$skillSource.id
    if ($skillId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        $script:skillProvenanceById.ContainsKey($skillId)) {
        throw "Managed Skill provenance contains an invalid or duplicate Skill ID: $skillId"
    }
    foreach ($requiredProperty in @('sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
        if ($null -eq $skillSource.PSObject.Properties[$requiredProperty] -or
            [string]::IsNullOrWhiteSpace([string]$skillSource.$requiredProperty)) {
            throw "Managed Skill '$skillId' provenance is missing '$requiredProperty'."
        }
    }
    if ([string]$skillSource.sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        [string]$skillSource.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$skillSource.sourceRepository -cnotmatch '^https://') {
        throw "Managed Skill '$skillId' provenance contains an invalid source."
    }
    $script:skillProvenanceById[$skillId] = $skillSource
}

if ($manifestExists) {
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestFullPath | ConvertFrom-Json
    }
    catch {
        throw "Managed instruction manifest is not valid JSON: $manifestRelativePath"
    }

    $manifestSchemaVersion = $manifest.schemaVersion
    if (($manifestSchemaVersion -isnot [int] -and $manifestSchemaVersion -isnot [long]) -or $manifestSchemaVersion -notin @(1, 2)) {
        throw "Unsupported managed instruction manifest schema: $($manifest.schemaVersion)"
    }

    if ($manifestSchemaVersion -eq 2) {
        Assert-ManagedManifestV2 -Manifest $manifest
    }
    else { Assert-LegacyManagedManifestV1 -Manifest $manifest }

    if ($manifestSchemaVersion -eq 2 -and
        ([string]$manifest.catalogId -cne [string]$provenance.catalogId -or
         [string]$manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Managed instruction manifest Catalog identity or historical lock hash is invalid.'
    }
    foreach ($entry in @($manifest.files)) {
        $targetPath = [string] $entry.targetPath
        if (-not (Test-IsAllowedManagedPath -Path $targetPath)) {
            throw "Unsafe target path in managed instruction manifest: $targetPath"
        }

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            throw "Duplicate target path in managed instruction manifest: $targetPath"
        }

        if ([string]::IsNullOrWhiteSpace([string] $entry.sourcePath) -or
            [string] $entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid managed instruction manifest entry: $targetPath"
        }
        if ($manifestSchemaVersion -eq 2) {
            foreach ($requiredProperty in @('artifactType','artifactId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
                if ($null -eq $entry.PSObject.Properties[$requiredProperty] -or
                    [string]::IsNullOrWhiteSpace([string]$entry.$requiredProperty)) {
                    throw "Managed instruction manifest entry '$targetPath' is missing '$requiredProperty'."
                }
            }
            if (@('instruction','skill') -cnotcontains [string]$entry.artifactType -or
                [string]$entry.artifactId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
                [string]$entry.sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
                [string]$entry.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
                [string]$entry.sourceRepository -cnotmatch '^https://') {
                throw "Managed instruction manifest entry '$targetPath' has invalid provenance."
            }
        }

        $manifestEntriesByTarget[$targetPath] = $entry
    }

    if ($manifestSchemaVersion -eq 1) {
        foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
            $entry = $manifestEntriesByTarget[$targetPath]
            $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf) -or
                (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) -or
                (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -cne [string]$entry.sha256) {
                throw "Cannot migrate managed manifest v1 because legacy managed file is customized, staged, or missing: $targetPath"
            }
        }
    }
}

$gitPathComparer = Get-GitPathComparer -Repository $targetRootPath
$trackedPaths = New-Object 'System.Collections.Generic.HashSet[string]' $gitPathComparer
foreach ($trackedPath in @(Invoke-Git -Repository $targetRootPath -Arguments @('ls-files'))) {
    [void]$trackedPaths.Add(([string]$trackedPath).Replace('\','/'))
}
$trackedPollutionPaths = @(@(
    if ($trackedPaths.Contains($manifestRelativePath)) { $manifestRelativePath }
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if ($trackedPaths.Contains([string]$targetPath)) { [string]$targetPath }
    }
) | Sort-Object -Unique)
if ($trackedPollutionPaths.Count -gt 0) {
    throw "Repository pollution detected: manifest-proven managed personal AI instruction paths are Git tracked: $($trackedPollutionPaths -join ', '). Bootstrap did not modify the index. Review and run cleanup-ai-instructions-pollution.ps1 with explicit authorization."
}

if ($manifestExists -and
    (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $manifestRelativePath)) {
    Write-Output 'AI instruction sync skipped because the managed manifest has staged changes.'
    return
}

$tempRootPath = Get-FullPathWithoutTrailingSeparator -Path ([System.IO.Path]::GetTempPath())
$workingPath = Join-Path $tempRootPath ('codex-ai-instructions-' + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $workingPath 'source.zip'
$extractPath = Join-Path $workingPath 'source'
$preserveWorkingPath = $false

try {
    New-Item -ItemType Directory -Path $workingPath, $extractPath | Out-Null

    $providedArchivePath = Get-FullPathWithoutTrailingSeparator -Path $SourceArchivePath
    if (-not (Test-Path -LiteralPath $providedArchivePath -PathType Leaf)) {
        throw "Source archive does not exist: $providedArchivePath"
    }

    Copy-Item -LiteralPath $providedArchivePath -Destination $archivePath

    $sourceRootPath = Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot $extractPath
    $desiredEntries = New-Object System.Collections.Generic.List[object]

    foreach ($family in $families) {
        $sourceBasePath = Join-Path $sourceRootPath $family.SourceBase.Replace('/', '\')
        $sourceRulesPath = Join-Path $sourceRootPath $family.SourceRules.Replace('/', '\')

        if (-not (Test-Path -LiteralPath $sourceBasePath -PathType Leaf)) {
            throw "$($family.Name) base instruction is missing from GitHub archive: $($family.SourceBase)"
        }

        if (-not (Test-Path -LiteralPath $sourceRulesPath -PathType Container)) {
            throw "$($family.Name) rule directory is missing from GitHub archive: $($family.SourceRules)"
        }

        $englishRules = @(Get-ChildItem -LiteralPath $sourceRulesPath -File -Filter '*.en.md' | Sort-Object Name)
        if ($englishRules.Count -eq 0) {
            throw "$($family.Name) has no English rule modules in the GitHub archive."
        }

        $desiredEntries.Add([pscustomobject]@{
            FamilyName = $family.Name
            SourcePath = $family.SourceBase
            TargetPath = $family.TargetBase
            SourceFullPath = $sourceBasePath
            Sha256 = Get-NormalizedContentHash -Path $sourceBasePath
        })

        foreach ($sourceRule in $englishRules) {
            $sourceRelativePath = "$($family.SourceRules)/$($sourceRule.Name)"
            $targetRelativePath = "$($family.TargetRules)/$($sourceRule.Name)"
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $family.Name
                SourcePath = $sourceRelativePath
                TargetPath = $targetRelativePath
                SourceFullPath = $sourceRule.FullName
                Sha256 = Get-NormalizedContentHash -Path $sourceRule.FullName
            })
        }
    }

    $sourceSkillsPath = Join-Path $sourceRootPath $sharedSkillsSource.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $sourceSkillsPath -PathType Container)) {
        throw "Shared Agent Skill directory is missing from GitHub archive: $sharedSkillsSource"
    }

    $unexpectedRootSkillFiles = @(
        Get-ChildItem -LiteralPath $sourceSkillsPath -File |
            Where-Object { $_.Name -ne '.gitkeep' }
    )
    if ($unexpectedRootSkillFiles.Count -gt 0) {
        throw "Shared Agent Skill files must be inside a named skill directory: $($unexpectedRootSkillFiles.Name -join ', ')"
    }

    $sourceSkillDirectories = @(Get-ChildItem -LiteralPath $sourceSkillsPath -Directory | Sort-Object Name)
    foreach ($sourceSkillDirectory in $sourceSkillDirectories) {
        if ($sourceSkillDirectory.Name -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "Invalid shared Agent Skill directory name: $($sourceSkillDirectory.Name)"
        }

        $sourceSkillDefinition = Join-Path $sourceSkillDirectory.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $sourceSkillDefinition -PathType Leaf)) {
            throw "Shared Agent Skill is missing SKILL.md: $($sourceSkillDirectory.Name)"
        }

        $sourceSkillFiles = @(
            Get-ChildItem -LiteralPath $sourceSkillDirectory.FullName -Recurse -File |
                Where-Object { $_.Name -ne '.gitkeep' } |
                Sort-Object FullName
        )
        foreach ($sourceSkillFile in $sourceSkillFiles) {
            $sourceRelativePath = Get-RepositoryRelativePath -RepositoryRoot $sourceRootPath -FullPath $sourceSkillFile.FullName
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $sharedSkillsFamilyName
                SourcePath = $sourceRelativePath
                TargetPath = $sourceRelativePath
                SourceFullPath = $sourceSkillFile.FullName
                Sha256 = Get-RawContentHash -Path $sourceSkillFile.FullName
            })
        }
    }

    $desiredEntriesByTarget = @{}
    foreach ($entry in $desiredEntries) {
        if (-not (Test-IsAllowedManagedPath -Path $entry.TargetPath)) {
            throw "Unsafe desired instruction target path: $($entry.TargetPath)"
        }

        if ($desiredEntriesByTarget.ContainsKey($entry.TargetPath)) {
            throw "Duplicate desired instruction target path: $($entry.TargetPath)"
        }

        $desiredEntriesByTarget[$entry.TargetPath] = $entry
    }

    $eligibleFamilies = @{}
    foreach ($family in $families) {
        $baseTargetPath = $family.TargetBase
        $baseTargetFullPath = Join-Path $targetRootPath $baseTargetPath.Replace('/', '\')
        $baseTargetIsTracked = $trackedPaths.Contains($baseTargetPath)
        $baseTargetMatchesDesired = $false
        if ((Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -and
            -not $baseTargetIsTracked -and
            $desiredEntriesByTarget.ContainsKey($baseTargetPath)) {
            $baseTargetMatchesDesired =
                (Get-ManagedContentHash -Path $baseTargetFullPath -TargetPath $baseTargetPath) -ceq
                [string]$desiredEntriesByTarget[$baseTargetPath].Sha256
        }
        $eligibleFamilies[$family.Name] =
            -not $baseTargetIsTracked -and
            ($manifestEntriesByTarget.ContainsKey($baseTargetPath) -or
             -not (Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -or
             $baseTargetMatchesDesired)
    }
    $eligibleSkillIds = @{}
    foreach ($sourceSkillDirectory in $sourceSkillDirectories) {
        $skillId = [string]$sourceSkillDirectory.Name
        $skillPrefix = ".agents/skills/$skillId/"
        $skillBasePath = $skillPrefix + 'SKILL.md'
        $skillBaseFullPath = Join-Path $targetRootPath $skillBasePath.Replace('/','\')
        $skillManifestOwned = @($manifestEntriesByTarget.Keys | Where-Object { ([string]$_).StartsWith($skillPrefix,[System.StringComparison]::Ordinal) }).Count -gt 0
        $skillHasTrackedPath = @($trackedPaths | Where-Object {
            $trackedPath = [string]$_
            $trackedPath.Length -gt $skillPrefix.Length -and
                $gitPathComparer.Equals($trackedPath.Substring(0,$skillPrefix.Length),$skillPrefix)
        }).Count -gt 0
        $skillBaseMatchesDesired = $false
        if ((Test-Path -LiteralPath $skillBaseFullPath -PathType Leaf) -and
            -not $skillHasTrackedPath -and
            $desiredEntriesByTarget.ContainsKey($skillBasePath)) {
            $skillBaseMatchesDesired =
                (Get-ManagedContentHash -Path $skillBaseFullPath -TargetPath $skillBasePath) -ceq
                [string]$desiredEntriesByTarget[$skillBasePath].Sha256
        }
        $eligibleSkillIds[$skillId] =
            -not $skillHasTrackedPath -and
            ($skillManifestOwned -or -not (Test-Path -LiteralPath $skillBaseFullPath -PathType Leaf) -or $skillBaseMatchesDesired)
    }

    $createdPaths = New-Object System.Collections.Generic.List[string]
    $updatedPaths = New-Object System.Collections.Generic.List[string]
    $removedPaths = New-Object System.Collections.Generic.List[string]
    $skippedPaths = New-Object System.Collections.Generic.List[string]
    $nextManifestEntries = New-Object System.Collections.Generic.List[object]

    $mutationPaths = @(
        @($desiredEntries | ForEach-Object { [string]$_.TargetPath })
        @($manifestEntriesByTarget.Keys)
        $manifestRelativePath
    )
    $mutationBackupRoot = Join-Path $workingPath 'target-backup'
    $mutationSnapshot = New-TargetMutationSnapshot -TargetRoot $targetRootPath -RelativePaths $mutationPaths -BackupRoot $mutationBackupRoot
    $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRootPath

    try {
        foreach ($desiredEntry in @($desiredEntries | Sort-Object TargetPath)) {
        $targetPath = $desiredEntry.TargetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        $targetExists = Test-Path -LiteralPath $targetFullPath -PathType Leaf
        $managedEntry = $null

        $entryIsEligible = [bool]$eligibleFamilies[$desiredEntry.FamilyName]
        if ($targetPath.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
            $skillId = @($targetPath.Split('/'))[2]
            $entryIsEligible = $eligibleSkillIds.ContainsKey($skillId) -and [bool]$eligibleSkillIds[$skillId]
        }
        if (-not $entryIsEligible) {
            $skippedPaths.Add($targetPath)
            continue
        }

        $desiredManifestEntry = New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            $managedEntry = $manifestEntriesByTarget[$targetPath]
        }

        if ($null -ne $managedEntry) {
            if (-not $targetExists) {
                if (Test-GitPathHasChanges -Repository $targetRootPath -Path $targetPath) {
                    $skippedPaths.Add($targetPath)
                    $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                    continue
                }

                $targetDirectory = Split-Path -Parent $targetFullPath
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
                Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath
                $updatedPaths.Add($targetPath)
                $nextManifestEntries.Add($desiredManifestEntry)
                continue
            }

            if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                continue
            }

            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath
            if ($currentHash -eq [string] $managedEntry.sha256 -or $currentHash -eq $desiredEntry.Sha256) {
                if ($currentHash -ne $desiredEntry.Sha256) {
                    Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath -Force
                    $updatedPaths.Add($targetPath)
                }

                $nextManifestEntries.Add($desiredManifestEntry)
            }
            else {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
            }

            continue
        }

        if (-not $targetExists) {
            if ($trackedPaths.Contains($targetPath)) {
                $skippedPaths.Add($targetPath)
                continue
            }
            $targetDirectory = Split-Path -Parent $targetFullPath
            if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) {
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            }

            Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath
            $createdPaths.Add($targetPath)
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        if (-not $trackedPaths.Contains($targetPath) -and
            -not (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) -and
            (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -ceq $desiredEntry.Sha256) {
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        $skippedPaths.Add($targetPath)
        }

        foreach ($managedTargetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if ($desiredEntriesByTarget.ContainsKey($managedTargetPath)) {
            continue
        }

        $managedEntry = $manifestEntriesByTarget[$managedTargetPath]
        $targetFullPath = Join-Path $targetRootPath $managedTargetPath.Replace('/', '\')
        if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $managedTargetPath) {
            $skippedPaths.Add($managedTargetPath)
            $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
            continue
        }

        if (Test-Path -LiteralPath $targetFullPath -PathType Leaf) {
            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $managedTargetPath
            if ($currentHash -ne [string] $managedEntry.sha256) {
                $skippedPaths.Add($managedTargetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                continue
            }

            Remove-Item -LiteralPath $targetFullPath -Force
            $removedPaths.Add($managedTargetPath)
        }
        }

        $shouldWriteManifest = $manifestExists -or $nextManifestEntries.Count -gt 0
        $manifestChanged = $false
        if ($shouldWriteManifest) {
        $manifestDirectory = Split-Path -Parent $manifestFullPath
        New-Item -ItemType Directory -Force -Path $manifestDirectory | Out-Null

        $manifestObject = [ordered]@{
            schemaVersion = 2
            catalogId = [string] $provenance.catalogId
            lockSha256 = [string] $provenance.lockSha256
            files = @($nextManifestEntries | Sort-Object targetPath)
        }
        $manifestJson = ($manifestObject | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
        $existingManifestJson = if ($manifestExists) {
            ([System.IO.File]::ReadAllText($manifestFullPath)).Replace("`r`n", "`n").Replace("`r", "`n")
        }
        else {
            $null
        }

        if ($existingManifestJson -ne $manifestJson) {
            $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($manifestFullPath, $manifestJson, $utf8WithoutBom)
            $manifestChanged = $true
        }
        }
        $managedExcludePaths = @($nextManifestEntries | ForEach-Object { [string]$_.targetPath })
        if ($shouldWriteManifest) { $managedExcludePaths += $manifestRelativePath }
        Set-ManagedGitInfoExclude -Repository $targetRootPath -ManagedPaths $managedExcludePaths
    }
    catch {
        $mutationError = $_
        try {
            Restore-TargetMutationSnapshot -Snapshot $mutationSnapshot
            Restore-GitInfoExcludeSnapshot -Snapshot $excludeSnapshot
        }
        catch {
            $rollbackError = $_
            $preserveWorkingPath = $true
            throw "AI instruction target mutation failed: $($mutationError.Exception.Message) Rollback also failed: $($rollbackError.Exception.Message) Recovery files were preserved at: $mutationBackupRoot"
        }
        throw $mutationError
    }

    if ($skippedPaths.Count -gt 0) {
        $uniqueSkippedPaths = @($skippedPaths | Sort-Object -Unique)
        Write-Output "AI instructions customized or unmanaged; not overwritten: $($uniqueSkippedPaths -join ', ')"
    }

    $changedPaths = @(
        @($createdPaths) +
        @($updatedPaths) +
        @($removedPaths) +
        $(if ($manifestChanged) { @($manifestRelativePath) } else { @() }) |
            Sort-Object -Unique
    )

    $stashPathArguments = @()
    try {
        $personalAgentStashes = @(Get-PersonalAgentStashes -Repository $targetRootPath)
        $shouldRefreshPersonalAgentStash = $changedPaths.Count -gt 0 -or $personalAgentStashes.Count -eq 0
        if ($shouldRefreshPersonalAgentStash) {
            $stashPaths = New-Object System.Collections.Generic.List[string]
            foreach ($manifestEntry in $nextManifestEntries) {
                $targetPath = [string]$manifestEntry.targetPath
                $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
                if ((Test-Path -LiteralPath $targetFullPath -PathType Leaf) -and
                    (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -ceq [string]$manifestEntry.sha256) {
                    $stashPaths.Add($targetPath)
                }
            }
            if (Test-Path -LiteralPath $manifestFullPath -PathType Leaf) { $stashPaths.Add($manifestRelativePath) }
            $stashPathArguments = @($stashPaths | Sort-Object -Unique)
            if ($stashPathArguments.Count -gt 0) {
                $expectedStashEntries = @($nextManifestEntries | Where-Object { [string]$_.targetPath -cin $stashPathArguments })
                $newStashHash = Update-PersonalAgentStash -Repository $targetRootPath -Paths $stashPathArguments -ExpectedEntries $expectedStashEntries
                Write-Output "PersonalAgent recovery evidence updated, reapplied, and retained: $newStashHash"
            }
        }
    }
    catch {
        $finalizationError = $_
        try {
            Restore-TargetMutationTransaction -Repository $targetRootPath -Paths $stashPathArguments -Snapshot $mutationSnapshot
            Restore-GitInfoExcludeSnapshot -Snapshot $excludeSnapshot
        }
        catch {
            $rollbackError = $_
            $preserveWorkingPath = $true
            throw "PersonalAgent stash finalization failed: $($finalizationError.Exception.Message) Rollback also failed: $($rollbackError.Exception.Message) Recovery files were preserved at: $mutationBackupRoot"
        }
        throw $finalizationError
    }

    if ($changedPaths.Count -eq 0) { Write-Output 'AI instructions are up to date; no Git commit was created.' }
    else { Write-Output "AI instructions synchronized as local ignored runtime artifacts without Git commit: $($changedPaths -join ', ')" }
}
finally {
    $resolvedWorkingPath = [System.IO.Path]::GetFullPath($workingPath)
    $expectedPrefix = $tempRootPath.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe temporary cleanup path: $resolvedWorkingPath"
    }

    if ($preserveWorkingPath) {
        Write-Warning "AI instruction sync temporary recovery files were preserved at: $resolvedWorkingPath"
    }
    else {
        Remove-Item -LiteralPath $resolvedWorkingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
}
finally {
    if ($null -ne $repositoryOperationLock) { $repositoryOperationLock.Dispose() }
}
