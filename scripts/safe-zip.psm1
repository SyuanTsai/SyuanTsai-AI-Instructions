Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-ZipDirectoryEntry {
    param([Parameter(Mandatory = $true)][object] $Entry)

    return [string]::IsNullOrEmpty([string] $Entry.Name) -or
        ([string] $Entry.FullName).EndsWith('/', [System.StringComparison]::Ordinal)
}

function Assert-SafeZipEntry {
    param(
        [Parameter(Mandatory = $true)][object] $Entry,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.Dictionary[string,string]] $PathCasings,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $ExplicitEntries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $ExplicitFiles,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $Roots
    )

    $name = [string] $Entry.FullName
    if ([string]::IsNullOrWhiteSpace($name) -or
        @($name.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0 -or
        $name.Contains('\') -or
        $name.StartsWith('/', [System.StringComparison]::Ordinal) -or
        $name.Contains(':')) {
        throw "Unsafe ZIP entry path: $name"
    }

    $isDirectory = Test-ZipDirectoryEntry -Entry $Entry
    $normalizedName = if ($isDirectory) { $name.TrimEnd('/') } else { $name }
    $parts = @($normalizedName.Split('/'))
    if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        throw "Unsafe ZIP entry path: $name"
    }
    if ($parts.Count -eq 1 -and -not $isDirectory) {
        throw "ZIP archive must contain exactly one repository root and no top-level files: $name"
    }

    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or
            $part -eq '.' -or
            $part -eq '..' -or
            $part.EndsWith('.', [System.StringComparison]::Ordinal) -or
            $part.EndsWith(' ', [System.StringComparison]::Ordinal)) {
            throw "Unsafe ZIP entry path: $name"
        }

        $baseName = $part.Split('.')[0]
        if ($baseName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "Unsafe Windows device name in ZIP entry: $name"
        }
    }

    for ($index = 0; $index -lt $parts.Count; $index++) {
        $pathPrefix = [string]::Join('/', [string[]]$parts[0..$index])
        $existingCasing = $null
        $pathAlreadyKnown = $PathCasings.TryGetValue($pathPrefix, [ref]$existingCasing)
        if ($pathAlreadyKnown) {
            if ($existingCasing -cne $pathPrefix) {
                throw "ZIP archive contains a case-insensitive path collision: $name"
            }
        }
        else {
            $PathCasings.Add($pathPrefix, $pathPrefix)
        }

        $isLeaf = $index -eq ($parts.Count - 1)
        if (-not $isLeaf -and $ExplicitFiles.Contains($pathPrefix)) {
            throw "ZIP archive contains a file/directory path collision: $name"
        }
        if ($isLeaf) {
            if ($ExplicitEntries.Contains($pathPrefix)) {
                throw "ZIP archive contains a duplicate path: $name"
            }
            if (-not $isDirectory -and $pathAlreadyKnown) {
                throw "ZIP archive contains a file/directory path collision: $name"
            }
        }
    }
    $null = $ExplicitEntries.Add($normalizedName)
    if (-not $isDirectory) {
        $null = $ExplicitFiles.Add($normalizedName)
    }
    $null = $Roots.Add($parts[0])

    $externalAttributes = ([int64] $Entry.ExternalAttributes) -band 0xFFFFFFFFL
    $unixFileType = ($externalAttributes -shr 16) -band 0xF000L
    if ($unixFileType -eq 0xA000L) {
        throw "ZIP archive contains a symbolic link entry: $name"
    }
    $expectedUnixFileType = if ($isDirectory) { 0x4000L } else { 0x8000L }
    if ($unixFileType -ne 0 -and $unixFileType -ne $expectedUnixFileType) {
        throw "ZIP archive contains a special file entry: $name"
    }
    if (($externalAttributes -band 0x400L) -ne 0) {
        throw "ZIP archive contains a reparse-point entry: $name"
    }
}

function Expand-SafeZipRepository {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')][string] $ArchivePath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Stream')][System.IO.Stream] $ArchiveStream,
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [string] $RepositoryDirectoryName = 'repository'
    )

    $resolvedArchive = $null
    if ($PSCmdlet.ParameterSetName -ceq 'Path') {
        $resolvedArchive = [System.IO.Path]::GetFullPath($ArchivePath)
        if (-not (Test-Path -LiteralPath $resolvedArchive -PathType Leaf)) {
            throw "ZIP archive does not exist: $resolvedArchive"
        }
    }
    elseif (-not $ArchiveStream.CanRead -or -not $ArchiveStream.CanSeek -or $ArchiveStream.Position -ne 0) {
        throw 'ZIP archive stream must be readable, seekable, and positioned at byte zero.'
    }
    if ($RepositoryDirectoryName -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Unsafe extracted repository directory name: $RepositoryDirectoryName"
    }

    $resolvedDestination = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]@('\', '/'))
    $repositoryRoot = Join-Path $resolvedDestination $RepositoryDirectoryName
    if (Test-Path -LiteralPath $repositoryRoot) {
        throw "ZIP extraction destination already exists: $repositoryRoot"
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $ownsStream = $PSCmdlet.ParameterSetName -ceq 'Path'
    $stream = if ($ownsStream) { [System.IO.File]::OpenRead($resolvedArchive) } else { $ArchiveStream }
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            (-not $ownsStream)
        )
        try {
            $entries = @($archive.Entries)
            if ($entries.Count -eq 0) {
                throw 'ZIP archive is empty.'
            }

            $pathCasings = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $explicitEntries = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $explicitFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $roots = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($entry in $entries) {
                Assert-SafeZipEntry `
                    -Entry $entry `
                    -PathCasings $pathCasings `
                    -ExplicitEntries $explicitEntries `
                    -ExplicitFiles $explicitFiles `
                    -Roots $roots
            }
            if ($roots.Count -ne 1) {
                throw "ZIP archive must contain exactly one repository root; found $($roots.Count)."
            }

            $archiveRootName = @($roots)[0]
            New-Item -ItemType Directory -Path $repositoryRoot -Force | Out-Null
            $destinationPrefix = $repositoryRoot + [System.IO.Path]::DirectorySeparatorChar

            foreach ($entry in $entries) {
                $name = [string] $entry.FullName
                $relativeName = $name.Substring($archiveRootName.Length).TrimStart('/')
                if ([string]::IsNullOrEmpty($relativeName)) {
                    continue
                }

                $destinationPath = [System.IO.Path]::GetFullPath(
                    (Join-Path $repositoryRoot $relativeName.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                )
                if (-not $destinationPath.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "ZIP entry escapes its repository root: $name"
                }

                if (Test-ZipDirectoryEntry -Entry $entry) {
                    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
                    continue
                }

                $parent = Split-Path -Parent $destinationPath
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                $inputStream = $entry.Open()
                try {
                    $outputStream = [System.IO.File]::Open(
                        $destinationPath,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None
                    )
                    try {
                        $inputStream.CopyTo($outputStream)
                    }
                    finally {
                        $outputStream.Dispose()
                    }
                }
                finally {
                    $inputStream.Dispose()
                }
            }
        }
        catch {
            if (Test-Path -LiteralPath $repositoryRoot) {
                Remove-Item -LiteralPath $repositoryRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        if ($ownsStream) { $stream.Dispose() }
    }

    return $repositoryRoot
}

Export-ModuleMember -Function Expand-SafeZipRepository
