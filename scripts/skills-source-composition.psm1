Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'license-delivery.psm1') -Force

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

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archiveStream = [System.IO.File]::Open(
        $destination,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            $rootName = [System.IO.Path]::GetFileName($source)
            $null = $archive.CreateEntry("$rootName/")
            foreach ($directory in @(Get-ChildItem -LiteralPath $source -Directory -Recurse -Force | Sort-Object FullName)) {
                $relativePath = $directory.FullName.Substring($source.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $null = $archive.CreateEntry("$rootName/$relativePath/")
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse -Force | Sort-Object FullName)) {
                $relativePath = $file.FullName.Substring($source.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry = $archive.CreateEntry(
                    "$rootName/$relativePath",
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $inputStream = [System.IO.File]::OpenRead($file.FullName)
                try {
                    $entryStream = $entry.Open()
                    try {
                        $inputStream.CopyTo($entryStream)
                    }
                    finally {
                        $entryStream.Dispose()
                    }
                }
                finally {
                    $inputStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        $archiveStream.Dispose()
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        $archiveStream.Dispose()
    }

    return $destination
}

function New-ComposedBootstrapSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstructionSourceRoot,
        [Parameter(Mandatory = $true)][object] $ResolvedSkills,
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [switch] $InstructionsOnly
    )

    foreach ($skill in @($ResolvedSkills)) {
        $layoutVersionProperty = $skill.PSObject.Properties['sourceLayoutVersion']
        if (-not $InstructionsOnly -and $null -ne $layoutVersionProperty -and
            ($layoutVersionProperty.Value -is [int] -or $layoutVersionProperty.Value -is [long]) -and
            [int64]$layoutVersionProperty.Value -eq 3) {
            throw 'Skills catalog schema version 3 requires a projection-aware installer.'
        }
    }

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

    $skillsRoot = Join-Path (Join-Path $destination '.agents') 'skills'
    if (Test-Path -LiteralPath $skillsRoot) {
        Remove-Item -LiteralPath $skillsRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null

    $seenSkillIds = @{}
    $skillInventories = @{}
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

        $targetPathProperty = $skill.PSObject.Properties['targetPath']
        $targetPath = if ($null -ne $targetPathProperty) { [string]$targetPathProperty.Value } else { ".agents/skills/$skillId" }
        if ($targetPath -cne ".agents/skills/$skillId") {
            throw "Resolved Skill '$skillId' has an unsafe runtime target path: $targetPath"
        }
        $targetSkillRoot = Join-Path $destination ($targetPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath (Join-Path $skillRoot '.ai-instructions-licenses')) { throw "Skill source already owns the license delivery namespace: $skillId" }
        $sourceRoot = [IO.Path]::GetFullPath([string]$skill.sourceRootPath).TrimEnd([char[]]@('\','/'))
        $artifactPaths = @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse -Force | ForEach-Object {
            $_.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        })
        $licenses = New-LicenseDeliveryPackage -SourceRoot $sourceRoot -ArtifactPaths $artifactPaths `
            -SourceRepository $skill.sourceRepository -SourceCommit $skill.sourceCommit -ArtifactId $skillId
        $files = @(
            foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse -Force)) {
                $relative = $file.FullName.Substring($skillRoot.TrimEnd([char[]]@('\','/')).Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                [pscustomobject]@{targetPath="$targetPath/$relative"; sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()}
            }
            foreach ($file in @($licenses.Files)) {
                [pscustomobject]@{targetPath="$targetPath/.ai-instructions-licenses/$($file.relativePath)"; sha256=$file.sha256}
            }
        )
        $skillInventories[$skillId] = $files
        if (-not $InstructionsOnly) {
            Copy-Item -LiteralPath $skillRoot -Destination $targetSkillRoot -Recurse -Force
            Write-LicenseDeliveryPackage -Package $licenses -DestinationRoot (Join-Path $targetSkillRoot ".ai-instructions-licenses/$($skill.sourceCommit)")
        }
    }

    return [pscustomobject][ordered]@{
        RootPath = $destination
        SkillIds = @($seenSkillIds.Keys | Sort-Object)
        SkillInventories = $skillInventories
    }
}

function New-ProjectSkillsCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]] $ResolvedSkills,
        [Parameter(Mandatory = $true)][hashtable] $SourcePlansById,
        [Parameter(Mandatory = $true)][string[]] $ProjectionIds,
        [Parameter(Mandatory = $true)][string] $CatalogId,
        [Parameter(Mandatory = $true)][string] $LockSha256,
        [Parameter(Mandatory = $true)][string] $ProjectionContractSha256,
        [Parameter(Mandatory = $true)][string] $DestinationRoot
    )

    $destination = [IO.Path]::GetFullPath($DestinationRoot)
    if (Test-Path -LiteralPath $destination) { throw "Project candidate destination already exists: $destination" }
    if ($CatalogId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        $LockSha256 -cnotmatch '^[0-9a-f]{64}$' -or $ProjectionContractSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Project candidate identity is invalid.'
    }
    [string[]]$sortedProjections = @($ProjectionIds)
    [Array]::Sort($sortedProjections,[StringComparer]::Ordinal)
    if ($sortedProjections.Count -eq 0 -or @($sortedProjections | Select-Object -Unique).Count -ne $sortedProjections.Count) {
        throw 'Project candidate projections must be a non-empty unique array.'
    }
    foreach ($projectionId in $sortedProjections) {
        if ($projectionId -notin @('project-agents','project-claude','project-github')) {
            throw "Unsupported project candidate projection '$projectionId'."
        }
    }

    New-Item -ItemType Directory -Path $destination | Out-Null
    $payloadRoot = Join-Path $destination 'payload'
    New-Item -ItemType Directory -Path $payloadRoot | Out-Null
    $skillDocuments = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($skill in @($ResolvedSkills | Sort-Object id)) {
        $skillId = [string]$skill.id
        if ($skillId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or $seen.ContainsKey($skillId)) {
            throw "Project candidate contains an invalid or duplicate Skill ID: $skillId"
        }
        $seen[$skillId] = $true
        $sourceId = [string]$skill.sourceId
        if (-not $SourcePlansById.ContainsKey($sourceId)) { throw "Project candidate is missing source plan '$sourceId'." }
        $sourcePlan = $SourcePlansById[$sourceId]
        $skillRoot = [IO.Path]::GetFullPath([string]$skill.skillRootPath).TrimEnd([char[]]@('\','/'))
        $repositoryRoot = [IO.Path]::GetFullPath([string]$skill.sourceRootPath).TrimEnd([char[]]@('\','/'))
        if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') -PathType Leaf)) { throw "Project candidate Skill '$skillId' is missing SKILL.md." }
        if (Test-Path -LiteralPath (Join-Path $skillRoot '.ai-instructions-licenses')) { throw "Skill source already owns the license delivery namespace: $skillId" }
        $skillPayloadRoot = Join-Path $payloadRoot $skillId
        New-Item -ItemType Directory -Path $skillPayloadRoot | Out-Null
        $files = New-Object System.Collections.Generic.List[object]
        $artifactPaths = New-Object System.Collections.Generic.List[string]
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse -Force | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($skillRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $sourceRelative = $file.FullName.Substring($repositoryRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $payloadPath = "payload/$skillId/$relative"
            $target = Join-Path $skillPayloadRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Copy-Item -LiteralPath $file.FullName -Destination $target
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
            $files.Add([pscustomobject][ordered]@{sourcePath=$sourceRelative;relativePath=$relative;payloadPath=$payloadPath;sha256=$hash})
            $artifactPaths.Add($sourceRelative)
        }
        $licenses = New-LicenseDeliveryPackage -SourceRoot $repositoryRoot -ArtifactPaths ([string[]]$artifactPaths.ToArray()) `
            -SourceRepository ([string]$sourcePlan.repository) -SourceCommit ([string]$sourcePlan.resolvedCommit) -ArtifactId $skillId
        $licenseRoot = Join-Path $skillPayloadRoot '.ai-instructions-licenses'
        Write-LicenseDeliveryPackage -Package $licenses -DestinationRoot $licenseRoot
        foreach ($licenseFile in @($licenses.Files | Sort-Object relativePath)) {
            $relative = ".ai-instructions-licenses/$([string]$licenseFile.relativePath)"
            $files.Add([pscustomobject][ordered]@{
                sourcePath=[string]$licenseFile.sourcePath;relativePath=$relative
                payloadPath="payload/$skillId/$relative";sha256=[string]$licenseFile.sha256
            })
        }
        $skillDocuments.Add([pscustomobject][ordered]@{
            id=$skillId;sourceId=[string]$sourcePlan.id;sourceRepository=[string]$sourcePlan.repository
            sourceRef=[string]$sourcePlan.requestedRef;sourceCommit=[string]$sourcePlan.resolvedCommit
            sourceVersion=[string]$sourcePlan.resolvedVersion;files=@($files | Sort-Object relativePath)
        })
    }
    $document = [ordered]@{
        schemaVersion=1;catalogId=$CatalogId;lockSha256=$LockSha256
        projectionContractSha256=$ProjectionContractSha256;projections=$sortedProjections
        skills=@($skillDocuments.ToArray())
    }
    $json = ($document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $destination 'project-candidate.json'),$json,[Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{RootPath=$destination;Inventory=$document;SkillIds=@($seen.Keys | Sort-Object)}
}

Export-ModuleMember -Function New-ComposedBootstrapArchive, New-ComposedBootstrapSource, New-ProjectSkillsCandidate
