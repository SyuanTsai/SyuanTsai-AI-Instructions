[CmdletBinding()]
param(
    [string] $SourceRepository = 'SyuanTsai/SyuanTsai-AI-Instructions',
    [string] $SourceRef = 'main',
    [string] $SourceArchivePath,
    [string] $TargetRoot,
    [string] $ConfigurationPath,
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
$initialCommitMessage = 'chore: add shared AI instructions'
$syncCommitMessage = 'chore: sync shared AI instructions'

Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force

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

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
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

function Test-GitPathIsTracked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('ls-files', '--error-unmatch', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect tracked managed path: $Path"
    }

    return $exitCode -eq 0
}

function Test-GitPathNeedsCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (Test-GitPathHasStagedChanges -Repository $Repository -Path $Path) {
        return $false
    }

    if (-not (Test-GitPathIsTracked -Repository $Repository -Path $Path)) {
        return Test-Path -LiteralPath (Join-Path $Repository $Path.Replace('/', '\'))
    }

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--quiet', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect pending managed path: $Path"
    }

    return $exitCode -eq 1
}

function Test-WasCreatedByPreviousBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (Test-GitPathHasChanges -Repository $Repository -Path $Path) {
        return $false
    }

    $addCommits = @(Invoke-Git -Repository $Repository -Arguments @('log', '--diff-filter=A', '--format=%H', '--', $Path))
    if ($addCommits.Count -eq 0) {
        return $false
    }

    $addCommit = ($addCommits | Select-Object -First 1).Trim()
    $subject = (Invoke-Git -Repository $Repository -Arguments @('show', '-s', '--format=%s', $addCommit) | Select-Object -First 1).Trim()
    if ($subject -cne $initialCommitMessage) {
        return $false
    }

    $createdBlob = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', "$addCommit`:$Path") | Select-Object -First 1).Trim()
    $currentBlob = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', "HEAD`:$Path") | Select-Object -First 1).Trim()
    return $createdBlob -eq $currentBlob
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

    if (-not $script:manifestV2Enabled) {
        return [pscustomobject][ordered]@{
            sourcePath = $SourcePath
            targetPath = $TargetPath
            sha256 = $Sha256
        }
    }

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

    if (-not $script:manifestV2Enabled) {
        return New-ManifestEntry -SourcePath ([string]$Entry.sourcePath) -TargetPath ([string]$Entry.targetPath) -Sha256 ([string]$Entry.sha256)
    }

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
    $targetPrefix = $resolvedTargetRoot + [System.IO.Path]::DirectorySeparatorChar
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

    Invoke-Git -Repository $Repository -Arguments (@(
        '-c', 'core.autocrlf=false', 'stash', 'push', '--all', '--quiet', '-m', 'PersonalAgent', '--'
    ) + $Paths) | Out-Null

    $newStashHash = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', 'stash@{0}') | Select-Object -First 1).Trim()
    $newStash = @(Get-PersonalAgentStashes -Repository $Repository | Where-Object { $_.Hash -eq $newStashHash })
    if ($newStash.Count -ne 1) {
        throw 'PersonalAgent stash was not created as the latest stash.'
    }

    Invoke-Git -Repository $Repository -Arguments @('-c', 'core.autocrlf=false', 'stash', 'apply', '--quiet', 'stash@{0}') | Out-Null

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
elseif ($syncStartPath.StartsWith($targetRootPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $syncStartRelativePath = Get-RepositoryRelativePath -RepositoryRoot $targetRootPath -FullPath $syncStartPath
}

$insideWorkTree = Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', '--is-inside-work-tree')
if (($insideWorkTree | Select-Object -First 1).Trim() -ne 'true') {
    Write-Output "AI instruction sync skipped: target is not a Git work tree: $targetRootPath"
    return
}

$sourceCodexBaseInTarget = Join-Path $targetRootPath '.codex\AGENTS.en.md'
$sourceCopilotBaseInTarget = Join-Path $targetRootPath '.github\copilot-instructions.en.md'
if ((Test-Path -LiteralPath $sourceCodexBaseInTarget -PathType Leaf) -and
    (Test-Path -LiteralPath $sourceCopilotBaseInTarget -PathType Leaf)) {
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
$autoCommitEnabled = $false
if (Test-Path -LiteralPath $configurationFullPath -PathType Leaf) {
    try {
        $configuration = Get-Content -Raw -LiteralPath $configurationFullPath | ConvertFrom-Json
    }
    catch {
        throw "AI instruction sync configuration is not valid JSON: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        $configuration.schemaVersion -ne 2) {
        throw "Unsupported AI instruction sync configuration schema: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -notcontains 'autoCommitRepositoryUrls') {
        throw "AI instruction sync configuration is missing autoCommitRepositoryUrls: $configurationFullPath"
    }

    $configuredRepositoryLocations = @(
        foreach ($configuredRepositoryUrl in @($configuration.autoCommitRepositoryUrls)) {
            try {
                Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $configuredRepositoryUrl)
            }
            catch {
                throw "autoCommitRepositoryUrls contains an invalid repository URL '$configuredRepositoryUrl': $($_.Exception.Message)"
            }
        }
    )

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

    if (($configuredRepositoryLocations.Count -gt 0 -or $excludedRepositoryLocations.Count -gt 0) -and
        (Get-GitExitCode -Repository $targetRootPath -Arguments @('remote', 'get-url', 'origin')) -eq 0) {
        $originUrls = @(Invoke-Git -Repository $targetRootPath -Arguments @('remote', 'get-url', '--all', 'origin'))
        foreach ($originUrl in $originUrls) {
            $originLocation = Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $originUrl)
            if (Test-RepositoryLocationMatches -RepositoryLocation $originLocation -ConfiguredRepositoryLocations $excludedRepositoryLocations) {
                Write-Output "AI instruction sync skipped: repository is excluded by ai-instructions-sync.json: $originUrl"
                return
            }

            if (Test-RepositoryLocationMatches -RepositoryLocation $originLocation -ConfiguredRepositoryLocations $configuredRepositoryLocations) {
                $autoCommitEnabled = $true
            }
            if ($autoCommitEnabled) {
                break
            }
        }
    }
}

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
$script:manifestV2Enabled = -not [string]::IsNullOrWhiteSpace($ProvenancePath)
$script:instructionProvenance = $null
$script:skillProvenanceById = @{}
$provenance = $null

if ($script:manifestV2Enabled) {
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
}

if ($manifestExists) {
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestFullPath | ConvertFrom-Json
    }
    catch {
        throw "Managed instruction manifest is not valid JSON: $manifestRelativePath"
    }

    $manifestSchemaVersion = $manifest.schemaVersion
    if ($manifestSchemaVersion -notin @(1, 2)) {
        throw "Unsupported managed instruction manifest schema: $($manifest.schemaVersion)"
    }

    if ($manifestSchemaVersion -eq 2 -and -not $script:manifestV2Enabled) {
        throw 'Managed instruction manifest schemaVersion 2 requires immutable source provenance.'
    }
    if ($manifestSchemaVersion -eq 2 -and
        ([string]$manifest.catalogId -cne [string]$provenance.catalogId -or
         [string]$manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Managed instruction manifest Catalog identity or historical lock hash is invalid.'
    }
    if ($manifestSchemaVersion -eq 1 -and -not $script:manifestV2Enabled -and
        ($manifest.sourceRepository -cne $SourceRepository -or $manifest.sourceRef -cne $SourceRef)) {
        throw 'Managed instruction manifest source does not match the configured source repository and ref.'
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

    if ($manifestSchemaVersion -eq 1 -and $script:manifestV2Enabled) {
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

    if ([string]::IsNullOrWhiteSpace($SourceArchivePath)) {
        if ($SourceRepository -notmatch '^[^/]+/[^/]+$') {
            throw "SourceRepository must use owner/repository format: $SourceRepository"
        }

        $repositoryParts = $SourceRepository.Split('/')
        $escapedOwner = [System.Uri]::EscapeDataString($repositoryParts[0])
        $escapedRepository = [System.Uri]::EscapeDataString($repositoryParts[1])
        $escapedRef = [System.Uri]::EscapeDataString($SourceRef)
        $archiveUri = "https://github.com/$escapedOwner/$escapedRepository/archive/refs/heads/$escapedRef.zip"

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{
            'User-Agent' = 'Codex-AI-Instructions-Bootstrap'
        } -OutFile $archivePath
    }
    else {
        $providedArchivePath = Get-FullPathWithoutTrailingSeparator -Path $SourceArchivePath
        if (-not (Test-Path -LiteralPath $providedArchivePath -PathType Leaf)) {
            throw "Source archive does not exist: $providedArchivePath"
        }

        Copy-Item -LiteralPath $providedArchivePath -Destination $archivePath
    }

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
        $eligibleFamilies[$family.Name] =
            $manifestEntriesByTarget.ContainsKey($baseTargetPath) -or
            -not (Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -or
            (Test-WasCreatedByPreviousBootstrap -Repository $targetRootPath -Path $baseTargetPath)
    }
    $eligibleFamilies[$sharedSkillsFamilyName] = $true

    $createdPaths = New-Object System.Collections.Generic.List[string]
    $updatedPaths = New-Object System.Collections.Generic.List[string]
    $removedPaths = New-Object System.Collections.Generic.List[string]
    $adoptedPaths = New-Object System.Collections.Generic.List[string]
    $skippedPaths = New-Object System.Collections.Generic.List[string]
    $nextManifestEntries = New-Object System.Collections.Generic.List[object]

    $mutationPaths = @(
        @($desiredEntries | ForEach-Object { [string]$_.TargetPath })
        @($manifestEntriesByTarget.Keys)
        $manifestRelativePath
    )
    $mutationBackupRoot = Join-Path $workingPath 'target-backup'
    $mutationSnapshot = New-TargetMutationSnapshot -TargetRoot $targetRootPath -RelativePaths $mutationPaths -BackupRoot $mutationBackupRoot

    try {
        foreach ($desiredEntry in @($desiredEntries | Sort-Object TargetPath)) {
        $targetPath = $desiredEntry.TargetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        $targetExists = Test-Path -LiteralPath $targetFullPath -PathType Leaf
        $managedEntry = $null

        if (-not $eligibleFamilies[$desiredEntry.FamilyName]) {
            if ($targetExists) {
                $skippedPaths.Add($targetPath)
            }
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
            $targetDirectory = Split-Path -Parent $targetFullPath
            if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) {
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            }

            Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath
            $createdPaths.Add($targetPath)
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        if (Test-WasCreatedByPreviousBootstrap -Repository $targetRootPath -Path $targetPath) {
            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath
            if ($currentHash -ne $desiredEntry.Sha256) {
                Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath -Force
                $updatedPaths.Add($targetPath)
            }

            $adoptedPaths.Add($targetPath)
            $nextManifestEntries.Add($desiredManifestEntry)
        }
        else {
            $skippedPaths.Add($targetPath)
        }
        }

        foreach ($managedTargetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if ($desiredEntriesByTarget.ContainsKey($managedTargetPath)) {
            continue
        }

        $managedEntry = $manifestEntriesByTarget[$managedTargetPath]
        $targetFullPath = Join-Path $targetRootPath $managedTargetPath.Replace('/', '\')
        if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $managedTargetPath) {
            $skippedPaths.Add($managedTargetPath)
            continue
        }

        if (Test-Path -LiteralPath $targetFullPath -PathType Leaf) {
            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $managedTargetPath
            if ($currentHash -ne [string] $managedEntry.sha256) {
                $skippedPaths.Add($managedTargetPath)
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

        $manifestObject = if ($script:manifestV2Enabled) {
            [ordered]@{
                schemaVersion = 2
                catalogId = [string] $provenance.catalogId
                lockSha256 = [string] $provenance.lockSha256
                files = @($nextManifestEntries | Sort-Object targetPath)
            }
        }
        else {
            [ordered]@{
                schemaVersion = 1
                sourceRepository = $SourceRepository
                sourceRef = $SourceRef
                files = @($nextManifestEntries | Sort-Object targetPath)
            }
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
    }
    catch {
        $mutationError = $_
        try {
            Restore-TargetMutationSnapshot -Snapshot $mutationSnapshot
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

    if (-not $autoCommitEnabled) {
        $personalAgentStashes = @(Get-PersonalAgentStashes -Repository $targetRootPath)
        $shouldRefreshPersonalAgentStash = $changedPaths.Count -gt 0 -or $personalAgentStashes.Count -eq 0

        if ($shouldRefreshPersonalAgentStash) {
            $stashPaths = New-Object System.Collections.Generic.List[string]
            foreach ($changedPath in $changedPaths) {
                $changedFullPath = Join-Path $targetRootPath $changedPath.Replace('/', '\')
                if ((Test-Path -LiteralPath $changedFullPath) -or
                    (Test-GitPathIsTracked -Repository $targetRootPath -Path $changedPath)) {
                    $stashPaths.Add($changedPath)
                }
            }

            foreach ($manifestEntry in $nextManifestEntries) {
                $targetPath = [string] $manifestEntry.targetPath
                $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
                if ((Test-Path -LiteralPath $targetFullPath -PathType Leaf) -and
                    (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -eq [string] $manifestEntry.sha256 -and
                    (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $targetPath)) {
                    $stashPaths.Add($targetPath)
                }
            }

            if ((Test-Path -LiteralPath $manifestFullPath -PathType Leaf) -and
                (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $manifestRelativePath)) {
                $stashPaths.Add($manifestRelativePath)
            }

            $stashPathArguments = @($stashPaths | Sort-Object -Unique)
            if ($stashPathArguments.Count -gt 0) {
                $expectedStashEntries = @(
                    $nextManifestEntries | Where-Object { [string]$_.targetPath -cin $stashPathArguments }
                )
                try {
                    $newStashHash = Update-PersonalAgentStash -Repository $targetRootPath -Paths $stashPathArguments -ExpectedEntries $expectedStashEntries
                }
                catch {
                    $finalizationError = $_
                    try {
                        Restore-TargetMutationTransaction -Repository $targetRootPath -Paths $stashPathArguments -Snapshot $mutationSnapshot
                    }
                    catch {
                        $rollbackError = $_
                        $preserveWorkingPath = $true
                        throw "PersonalAgent stash finalization failed: $($finalizationError.Exception.Message) Rollback also failed: $($rollbackError.Exception.Message) Recovery files were preserved at: $mutationBackupRoot"
                    }
                    throw $finalizationError
                }
                Write-Output "PersonalAgent stash updated, reapplied, and retained: $newStashHash"
            }
        }

        if ($changedPaths.Count -eq 0) {
            Write-Output 'AI instructions are up to date; this repository is not allowlisted, so no commit was created.'
        }
        else {
            Write-Output "AI instructions synchronized without commit because this repository is not allowlisted: $($changedPaths -join ', ')"
        }
        return
    }

    $commitPaths = New-Object System.Collections.Generic.List[string]
    foreach ($changedPath in $changedPaths) {
        $commitPaths.Add($changedPath)
    }

    foreach ($manifestEntry in $nextManifestEntries) {
        $targetPath = [string] $manifestEntry.targetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        if ((Test-Path -LiteralPath $targetFullPath -PathType Leaf) -and
            (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -eq [string] $manifestEntry.sha256 -and
            (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $targetPath)) {
            $commitPaths.Add($targetPath)
        }
    }

    if ((Test-Path -LiteralPath $manifestFullPath -PathType Leaf) -and
        (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $manifestRelativePath)) {
        $commitPaths.Add($manifestRelativePath)
    }

    $pathArguments = @($commitPaths | Sort-Object -Unique)
    if ($pathArguments.Count -eq 0) {
        Write-Output 'AI instructions are up to date; no commit was required.'
        return
    }

    $isInitialBootstrap = -not $manifestExists -and
        $createdPaths.Count -gt 0 -and
        $updatedPaths.Count -eq 0 -and
        $adoptedPaths.Count -eq 0
    $commitMessage = if ($isInitialBootstrap) { $initialCommitMessage } else { $syncCommitMessage }
    $headBeforeCommit = $null

    try {
        $headBeforeCommit = (Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
        Invoke-Git -Repository $targetRootPath -Arguments (@('add', '--force', '--') + $pathArguments) | Out-Null
        Invoke-Git -Repository $targetRootPath -Arguments (@('diff', '--cached', '--check', '--') + $pathArguments) | Out-Null
        Invoke-Git -Repository $targetRootPath -Arguments (@('commit', '--only', '--quiet', '-m', $commitMessage, '--') + $pathArguments) | Out-Null

        $committedPaths = @(Invoke-Git -Repository $targetRootPath -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'))
        $unexpectedPaths = @($committedPaths | Where-Object { $_ -cnotin $pathArguments })
        $missingPaths = @($pathArguments | Where-Object { $_ -cnotin $committedPaths })

        if ($unexpectedPaths.Count -gt 0 -or $missingPaths.Count -gt 0) {
            throw "Instruction sync commit verification failed. Unexpected: $($unexpectedPaths -join ', '); Missing: $($missingPaths -join ', ')"
        }
    }
    catch {
        $finalizationError = $_
        try {
            $headAfterFailure = (Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
            if ($null -ne $headBeforeCommit -and $headAfterFailure -cne $headBeforeCommit) {
                $commitDescription = (Invoke-Git -Repository $targetRootPath -Arguments @('show', '-s', '--format=%P%x09%s', 'HEAD') | Select-Object -First 1).Trim()
                $descriptionParts = $commitDescription.Split(@("`t"), 2, [System.StringSplitOptions]::None)
                if ($descriptionParts.Count -ne 2 -or
                    $descriptionParts[0] -cne $headBeforeCommit -or
                    $descriptionParts[1] -cne $commitMessage) {
                    throw 'Automatic rollback refused because HEAD no longer identifies the commit created by instruction sync.'
                }
                Invoke-Git -Repository $targetRootPath -Arguments @('reset', '--soft', $headBeforeCommit) | Out-Null
            }

            Restore-TargetMutationTransaction -Repository $targetRootPath -Paths $pathArguments -Snapshot $mutationSnapshot
        }
        catch {
            $rollbackError = $_
            $preserveWorkingPath = $true
            throw "AI instruction commit finalization failed: $($finalizationError.Exception.Message) Rollback also failed: $($rollbackError.Exception.Message) Recovery files were preserved at: $mutationBackupRoot"
        }
        throw $finalizationError
    }

    Write-Output "AI instructions synchronized from GitHub and committed: $($pathArguments -join ', ')"
}
finally {
    $resolvedWorkingPath = [System.IO.Path]::GetFullPath($workingPath)
    $expectedPrefix = $tempRootPath + [System.IO.Path]::DirectorySeparatorChar
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
