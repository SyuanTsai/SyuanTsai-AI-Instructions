Set-StrictMode -Version 2.0

function Get-ArchiveSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SafeSourceStagingPath {
    param(
        [Parameter(Mandatory = $true)][string] $WorkingRoot,
        [Parameter(Mandatory = $true)][string] $SourceId
    )

    if ($SourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "Unsafe source ID for staging: $SourceId"
    }

    $root = [System.IO.Path]::GetFullPath($WorkingRoot).TrimEnd([char[]]@('\', '/'))
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $SourceId))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe source staging path for '$SourceId': $candidate"
    }

    return $candidate
}

function Test-SafeSourceRelativePath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.StartsWith('/') -or
        $Path.EndsWith('/') -or
        $Path.Contains('\') -or
        $Path.Contains('//') -or
        $Path.Contains(':')) {
        return $false
    }

    foreach ($segment in $Path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            return $false
        }
    }

    return $true
}

function Expand-ValidatedSkillsSourceArchives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][hashtable] $SourceArchivePaths,
        [Parameter(Mandatory = $true)][string] $WorkingRoot
    )

    $workingRootPath = [System.IO.Path]::GetFullPath($WorkingRoot)
    if (Test-Path -LiteralPath $workingRootPath) {
        if (-not (Test-Path -LiteralPath $workingRootPath -PathType Container)) {
            throw "Skills source working root is not a directory: $workingRootPath"
        }
    }
    else {
        New-Item -ItemType Directory -Path $workingRootPath | Out-Null
    }

    $planSources = @($Plan.Sources)
    $planSkills = @($Plan.Skills)
    $sourcePlansById = @{}
    foreach ($source in $planSources) {
        $sourceId = [string] $source.id
        if ($sourcePlansById.ContainsKey($sourceId)) {
            throw "Duplicate source in acquisition plan: $sourceId"
        }
        $sourcePlansById[$sourceId] = $source
    }

    $stagedSources = New-Object System.Collections.Generic.List[object]
    foreach ($sourceId in @($sourcePlansById.Keys | Sort-Object)) {
        if (-not $SourceArchivePaths.ContainsKey($sourceId)) {
            throw "Selected source '$sourceId' has no archive input."
        }

        $archivePath = [System.IO.Path]::GetFullPath([string] $SourceArchivePaths[$sourceId])
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw "Selected source '$sourceId' archive does not exist: $archivePath"
        }

        $sourcePlan = $sourcePlansById[$sourceId]
        $expectedArchiveHash = [string] $sourcePlan.archiveSha256
        if ($expectedArchiveHash -notmatch '^[0-9a-f]{64}$') {
            throw "Selected source '$sourceId' has an invalid archive SHA-256 pin."
        }

        $actualArchiveHash = Get-ArchiveSha256 -Path $archivePath
        if ($actualArchiveHash -ne $expectedArchiveHash) {
            throw "Selected source '$sourceId' archive SHA-256 mismatch. Expected $expectedArchiveHash; actual $actualArchiveHash."
        }

        $sourceStagingPath = Get-SafeSourceStagingPath -WorkingRoot $workingRootPath -SourceId $sourceId
        if (Test-Path -LiteralPath $sourceStagingPath) {
            Remove-Item -LiteralPath $sourceStagingPath -Recurse -Force
        }
        New-Item -ItemType Directory -Path $sourceStagingPath | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $sourceStagingPath

        $archiveRoots = @(Get-ChildItem -LiteralPath $sourceStagingPath -Directory)
        if ($archiveRoots.Count -ne 1) {
            throw "Selected source '$sourceId' archive must contain exactly one repository root; found $($archiveRoots.Count)."
        }

        $stagedSources.Add([pscustomobject][ordered]@{
            id = $sourceId
            rootPath = $archiveRoots[0].FullName
            archivePath = $archivePath
            archiveSha256 = $actualArchiveHash
            resolvedCommit = [string] $sourcePlan.resolvedCommit
        })
    }

    $stagedSourcesById = @{}
    foreach ($source in $stagedSources) {
        $stagedSourcesById[[string] $source.id] = $source
    }

    $resolvedSkills = New-Object System.Collections.Generic.List[object]
    foreach ($skill in @($planSkills | Sort-Object id)) {
        $skillId = [string] $skill.id
        $sourceId = [string] $skill.sourceId
        $sourcePath = [string] $skill.sourcePath
        if (-not $stagedSourcesById.ContainsKey($sourceId)) {
            throw "Selected Skill '$skillId' references source '$sourceId' that was not staged."
        }
        if (-not (Test-SafeSourceRelativePath -Path $sourcePath)) {
            throw "Unsafe source path for selected Skill '$skillId': $sourcePath"
        }

        $sourceRoot = [string] $stagedSourcesById[$sourceId].rootPath
        $skillRoot = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot $sourcePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        $sourceRootPrefix = $sourceRoot.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $skillRoot.StartsWith($sourceRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Selected Skill '$skillId' resolved outside source '$sourceId'."
        }
        if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
            throw "Selected Skill '$skillId' is missing from source '$sourceId': $sourcePath"
        }
        $skillDefinition = Join-Path $skillRoot 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillDefinition -PathType Leaf)) {
            throw "Selected Skill '$skillId' is missing SKILL.md in source '$sourceId'."
        }

        $resolvedSkills.Add([pscustomobject][ordered]@{
            id = $skillId
            sourceId = $sourceId
            sourcePath = $sourcePath
            sourceRootPath = $sourceRoot
            skillRootPath = $skillRoot
        })
    }

    return [pscustomobject][ordered]@{
        Sources = @($stagedSources)
        Skills = @($resolvedSkills)
    }
}

Export-ModuleMember -Function Expand-ValidatedSkillsSourceArchives
