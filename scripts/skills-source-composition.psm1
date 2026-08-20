Set-StrictMode -Version 2.0

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Composition source directory does not exist: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function New-ComposedBootstrapArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    $source = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\', '/'))
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Composition archive source does not exist: $source"
    }

    $destination = [System.IO.Path]::GetFullPath($DestinationPath)
    if (Test-Path -LiteralPath $destination) {
        throw "Composition archive destination already exists: $destination"
    }

    $sourcePrefix = $source + [System.IO.Path]::DirectorySeparatorChar
    if ($destination.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Composition archive destination must be outside its source: $destination"
    }

    $destinationParent = [System.IO.Path]::GetDirectoryName($destination)
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationParent | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $source,
        $destination,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )

    return $destination
}

function New-ComposedBootstrapSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstructionSourceRoot,
        [Parameter(Mandatory = $true)][object] $ResolvedSkills,
        [Parameter(Mandatory = $true)][string] $DestinationRoot
    )

    $instructionRoot = [System.IO.Path]::GetFullPath($InstructionSourceRoot)
    if (-not (Test-Path -LiteralPath $instructionRoot -PathType Container)) {
        throw "Instruction source root does not exist: $instructionRoot"
    }

    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (Test-Path -LiteralPath $destination) {
        throw "Composition destination already exists: $destination"
    }

    New-Item -ItemType Directory -Path $destination | Out-Null
    Copy-DirectoryContents -Source $instructionRoot -Destination $destination

    $skillsRoot = Join-Path $destination '.agents\skills'
    if (Test-Path -LiteralPath $skillsRoot) {
        Remove-Item -LiteralPath $skillsRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null

    $seenSkillIds = @{}
    foreach ($skill in @($ResolvedSkills | Sort-Object id)) {
        $skillId = [string] $skill.id
        if ($skillId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "Unsafe selected Skill ID for composition: $skillId"
        }
        if ($seenSkillIds.ContainsKey($skillId)) {
            throw "Duplicate selected Skill during composition: $skillId"
        }
        $seenSkillIds[$skillId] = $true

        $skillRoot = [System.IO.Path]::GetFullPath([string] $skill.skillRootPath)
        if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
            throw "Resolved Skill '$skillId' root does not exist: $skillRoot"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') -PathType Leaf)) {
            throw "Resolved Skill '$skillId' is missing SKILL.md before composition."
        }

        $targetSkillRoot = Join-Path $skillsRoot $skillId
        Copy-Item -LiteralPath $skillRoot -Destination $targetSkillRoot -Recurse -Force
    }

    return [pscustomobject][ordered]@{
        RootPath = $destination
        SkillIds = @($seenSkillIds.Keys | Sort-Object)
    }
}

Export-ModuleMember -Function New-ComposedBootstrapArchive, New-ComposedBootstrapSource
