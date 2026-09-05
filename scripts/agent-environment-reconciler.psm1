Set-StrictMode -Version 2.0

function Get-AgentEnvironmentSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-AgentEnvironmentBytesSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-AgentEnvironmentPathComparison {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

function Get-AgentEnvironmentInventorySha256 {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Files
    )

    $canonical = (@($Files | Sort-Object { [string]$_.targetPath } | ForEach-Object {
        "{0}`t{1}`n" -f ([string]$_.targetPath), ([string]$_.sha256)
    }) -join '')
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return Get-AgentEnvironmentBytesSha256 -Bytes $encoding.GetBytes($canonical)
}

function New-AgentEnvironmentOwnershipEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('managed','known-legacy','unmanaged-unknown','managed-drift','controlled-candidate')][string] $Classification,
        [Parameter(Mandatory = $true)][string] $Owner,
        [Parameter(Mandatory = $true)][string] $Evidence,
        [Parameter(Mandatory = $true)][bool] $DestructiveChangeAllowed,
        [ValidateSet('observe','install','replace','remove','adopt','preserve')][string] $Operation = 'observe'
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        skillId = $SkillId
        path = $Path
        classification = $Classification
        owner = $Owner
        evidence = $Evidence
        destructiveChangeAllowed = $DestructiveChangeAllowed
        operation = $Operation
    }
}

function New-AgentEnvironmentFailureDetail {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('managed','known-legacy','unmanaged-unknown','managed-drift','controlled-candidate')][string] $Classification,
        [Parameter(Mandatory = $true)][string] $Owner,
        [Parameter(Mandatory = $true)][string] $Evidence,
        [Parameter(Mandatory = $true)][bool] $DestructiveChangeAllowed,
        [Parameter(Mandatory = $true)][bool] $BackupCreated,
        [Parameter(Mandatory = $true)][string[]] $Remediation,
        [AllowNull()][object] $ExpectedSha256,
        [AllowNull()][object] $ActualSha256
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        code = $Code
        skillId = $SkillId
        path = $Path
        classification = $Classification
        owner = $Owner
        evidence = $Evidence
        destructiveChangeAllowed = $DestructiveChangeAllowed
        backupCreated = $BackupCreated
        expectedSha256 = $ExpectedSha256
        actualSha256 = $ActualSha256
        remediation = @($Remediation)
    }
}

function Get-AgentEnvironmentManifestBytes {
    param([Parameter(Mandatory = $true)][object] $Manifest)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return $encoding.GetBytes(($Manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Get-AgentEnvironmentStagedFileSnapshot {
    param([Parameter(Mandatory = $true)][object] $File)

    $skillIdProperty = $File.PSObject.Properties['skillId']
    $targetPathProperty = $File.PSObject.Properties['targetPath']
    $expectedProperty = $File.PSObject.Properties['sha256']
    $stagedProperty = $File.PSObject.Properties['stagedPath']
    $skillId = if ($null -ne $skillIdProperty) { [string]$skillIdProperty.Value } else { '<unknown>' }
    $targetPath = if ($null -ne $targetPathProperty) { [string]$targetPathProperty.Value } else { '<unknown>' }
    $expected = if ($null -ne $expectedProperty) { [string]$expectedProperty.Value } else { $null }

    if ($null -eq $stagedProperty -or $stagedProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$stagedProperty.Value) -or
        -not [System.IO.Path]::IsPathRooted([string]$stagedProperty.Value)) {
        return [pscustomobject][ordered]@{
            valid = $false; skillId = $skillId; targetPath = $targetPath; expectedSha256 = $expected
            actualSha256 = $null; bytes = $null
            message = "Controlled candidate staging path is missing or not absolute: $targetPath"
        }
    }

    $bytes = $null
    try {
        $stagedPath = [System.IO.Path]::GetFullPath([string]$stagedProperty.Value)
        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
            throw "Controlled candidate staged file is missing: $targetPath"
        }
        $item = Get-Item -Force -LiteralPath $stagedPath
        if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Controlled candidate staged file must be a regular non-reparse file: $targetPath"
        }
        $directory = $item.Directory
        while ($null -ne $directory) {
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Controlled candidate staging path crosses a reparse point: $targetPath"
            }
            $parent = $directory.Parent
            if ($null -eq $parent -or $parent.FullName -ceq $directory.FullName) { break }
            $directory = $parent
        }
        if ($expected -notmatch '^[0-9a-f]{64}$') {
            throw "Controlled candidate staged hash is invalid: $targetPath"
        }
        $bytes = [System.IO.File]::ReadAllBytes($stagedPath)
        $actual = Get-AgentEnvironmentBytesSha256 -Bytes $bytes
        if ($actual -cne $expected) {
            throw "Controlled candidate staged hash mismatch: $targetPath"
        }
        return [pscustomobject][ordered]@{
            valid = $true; skillId = $skillId; targetPath = $targetPath; expectedSha256 = $expected
            actualSha256 = $actual; bytes = $bytes; message = $null
        }
    }
    catch {
        $actual = $null
        if ($null -ne (Get-Variable -Name bytes -ErrorAction SilentlyContinue) -and $null -ne $bytes) {
            $actual = Get-AgentEnvironmentBytesSha256 -Bytes $bytes
        }
        return [pscustomobject][ordered]@{
            valid = $false; skillId = $skillId; targetPath = $targetPath; expectedSha256 = $expected
            actualSha256 = $actual; bytes = $null; message = [string]$_.Exception.Message
        }
    }
}

function Get-AgentEnvironmentTransactionStagePath {
    param(
        [Parameter(Mandatory = $true)][string] $TransactionRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.StartsWith('/') -or
        $RelativePath.Contains('\') -or $RelativePath.Contains(':')) {
        throw "Unsafe Agent environment transaction stage path: $RelativePath"
    }
    foreach ($segment in @($RelativePath.Split('/'))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -ceq '.' -or $segment -ceq '..' -or
            $segment.IndexOfAny([char[]]@([char]0..([char]31) + [char]127)) -ge 0) {
            throw "Unsafe Agent environment transaction stage path: $RelativePath"
        }
    }
    $root = [System.IO.Path]::GetFullPath($TransactionRoot).TrimEnd([char[]]@('\','/'))
    $stageRoot = Join-Path $root 'staged'
    $full = [System.IO.Path]::GetFullPath((Join-Path $stageRoot $RelativePath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
    $prefix = $stageRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,(Get-AgentEnvironmentPathComparison))) {
        throw "Agent environment transaction stage path resolves outside its root: $RelativePath"
    }
    return $full
}

function Assert-AgentEnvironmentManifestMatchesDesired {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $DesiredFiles
    )
    $expectedByPath = @{}
    foreach ($file in @($DesiredFiles)) {
        $path = [string]$file.targetPath
        if ($expectedByPath.ContainsKey($path)) { throw "Duplicate desired user Skill path: $path" }
        $expectedByPath[$path] = [string]$file.sha256
    }
    $actualByPath = @{}
    foreach ($file in @($Manifest.files)) {
        $path = [string]$file.targetPath
        if ($actualByPath.ContainsKey($path)) { throw "Final user Skills manifest contains a duplicate target path: $path" }
        $actualByPath[$path] = [string]$file.sha256
    }
    if ($actualByPath.Count -ne $expectedByPath.Count) {
        throw 'Final user Skills manifest inventory does not match the desired inventory.'
    }
    foreach ($path in @($expectedByPath.Keys)) {
        if (-not $actualByPath.ContainsKey($path) -or [string]$actualByPath[$path] -cne [string]$expectedByPath[$path]) {
            throw "Final user Skills manifest inventory mismatch: $path"
        }
    }
}

function Get-AgentEnvironmentFullPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.StartsWith('/') -or
        $RelativePath.Contains('\') -or $RelativePath.Contains(':') -or
        @($RelativePath.Split('/')) -contains '..') {
        throw "Unsafe user Agent environment relative path: $RelativePath"
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix,(Get-AgentEnvironmentPathComparison))) {
        throw "User Agent environment path resolves outside its root: $RelativePath"
    }
    return $fullPath
}

function Assert-AgentEnvironmentPathSafe {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    if ($RelativePath -cne '.agents/catalog-skills.manifest.json' -and
        $RelativePath -cne '.agents/update-agent-environment.recovery.json' -and
        -not $RelativePath.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
        throw "User Agent environment mutation is outside the approved scope: $RelativePath"
    }
    $fullPath = Get-AgentEnvironmentFullPath -Root $Root -RelativePath $RelativePath
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $relativeNative = $fullPath.Substring($rootPath.Length).TrimStart([char[]]@('\','/'))
    $current = $rootPath
    foreach ($segment in @($relativeNative.Split([char[]]@('\','/'),[System.StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -Force -LiteralPath $current
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "User Agent environment path crosses a reparse point: $RelativePath"
        }
    }
    return $fullPath
}

function Set-AgentEnvironmentFileBytes {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )
    $target = Assert-AgentEnvironmentPathSafe -Root $Root -RelativePath $RelativePath
    $parent = [System.IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Assert-AgentEnvironmentPathSafe -Root $Root -RelativePath $RelativePath | Out-Null
    $temporary = Join-Path $parent ('.agent-environment-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($temporary,$Bytes)
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Write-AgentEnvironmentJson {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][object] $Document
    )
    $json = $Document | ConvertTo-Json -Depth 20
    $bytes = New-Object System.Text.UTF8Encoding($false)
    Set-AgentEnvironmentFileBytes -Root $Root -RelativePath $RelativePath -Bytes ($bytes.GetBytes($json + [Environment]::NewLine))
}

function Assert-AgentEnvironmentOriginalState {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][object] $State
    )
    $relative = [string]$State.relativePath
    $full = Assert-AgentEnvironmentPathSafe -Root $Root -RelativePath $relative
    if ([bool]$State.existed) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-AgentEnvironmentSha256 -Path $full) -cne [string]$State.originalSha256) {
            throw "Agent environment target changed concurrently before mutation: $relative"
        }
    }
    elseif (Test-Path -LiteralPath $full) { throw "Agent environment target appeared concurrently before mutation: $relative" }
}

function Get-AgentEnvironmentObservedState {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    $full = Assert-AgentEnvironmentPathSafe -Root $Root -RelativePath $RelativePath
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        return [pscustomobject][ordered]@{
            relativePath=$RelativePath
            existed=$true
            sha256=(Get-AgentEnvironmentSha256 -Path $full)
        }
    }
    if (Test-Path -LiteralPath $full) { throw "Agent environment target must be a regular file or absent: $RelativePath" }
    return [pscustomobject][ordered]@{ relativePath=$RelativePath; existed=$false; sha256=$null }
}

function Assert-AgentEnvironmentObservedState {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][object] $Observation
    )
    $relative = [string]$Observation.relativePath
    $current = Get-AgentEnvironmentObservedState -Root $Root -RelativePath $relative
    if ([bool]$current.existed -ne [bool]$Observation.existed -or
        ([bool]$current.existed -and [string]$current.sha256 -cne [string]$Observation.sha256)) {
        throw "Agent environment target changed after planning and before backup: $relative"
    }
}

function Assert-AgentEnvironmentBackupFileSafe {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path
    )
    $backupRoot = [System.IO.Path]::GetFullPath((Join-Path $Root '.agents/backups')).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { throw 'Agent environment backups root is missing.' }
    $backupRootItem = Get-Item -Force -LiteralPath $backupRoot
    if (($backupRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent environment backups root must not be a reparse point.' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($backupRoot + [System.IO.Path]::DirectorySeparatorChar,(Get-AgentEnvironmentPathComparison))) {
        throw "Agent environment backup resolves outside the approved backup root: $Path"
    }
    $current = $backupRoot
    $relative = $fullPath.Substring($backupRoot.Length).TrimStart([char[]]@('\','/'))
    foreach ($segment in @($relative.Split([char[]]@('\','/'),[System.StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -Force -LiteralPath $current
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Agent environment backup path crosses a reparse point: $Path"
        }
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Rollback backup is missing: $Path" }
    return $fullPath
}

function Assert-AgentEnvironmentExactProperties {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string[]] $Required,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Object -isnot [pscustomobject]) { throw "$Context must be an object." }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Required.Count) { throw "$Context has an invalid property set." }
    foreach ($name in $Required) {
        if ($actual -cnotcontains $name) { throw "$Context is missing '$name'." }
    }
}

function Assert-AgentEnvironmentBackupDirectorySafe {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path
    )
    $approvedRoot = [System.IO.Path]::GetFullPath((Join-Path $Root '.agents/backups')).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath $approvedRoot -PathType Container)) { throw 'Agent environment backups root is missing.' }
    $approvedItem = Get-Item -Force -LiteralPath $approvedRoot
    if (($approvedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent environment backups root must not be a reparse point.' }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $fullPath.StartsWith($approvedRoot + [System.IO.Path]::DirectorySeparatorChar,$comparison)) {
        throw "Agent environment transaction backup resolves outside the approved backup root: $Path"
    }
    $current = $approvedRoot
    $relative = $fullPath.Substring($approvedRoot.Length).TrimStart([char[]]@('\','/'))
    foreach ($segment in @($relative.Split([char[]]@('\','/'),[System.StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current -PathType Container)) { throw "Agent environment transaction backup directory is missing: $Path" }
        $item = Get-Item -Force -LiteralPath $current
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Agent environment transaction backup path crosses a reparse point: $Path"
        }
    }
    return $fullPath
}

function Restore-AgentEnvironmentFileState {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][object] $State,
        [AllowNull()][byte[]] $ValidatedBackupBytes
    )
    $relative = [string]$State.relativePath
    $full = Assert-AgentEnvironmentPathSafe -Root $Root -RelativePath $relative
    if ([bool]$State.existed) {
        $originalSha256 = [string]$State.originalSha256
        if ($originalSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Rollback original SHA-256 is invalid: $relative"
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $actual = Get-AgentEnvironmentSha256 -Path $full
            if ([string]::Equals($actual,$originalSha256,[System.StringComparison]::Ordinal)) { return }
            if ([string]::IsNullOrWhiteSpace([string]$State.appliedSha256) -or $actual -cne [string]$State.appliedSha256) {
                throw "Rollback preserved concurrently changed file: $relative"
            }
        }
        elseif (Test-Path -LiteralPath $full) { throw "Rollback preserved a non-file target: $relative" }
        if ($PSBoundParameters.ContainsKey('ValidatedBackupBytes')) {
            $backupBytes = $ValidatedBackupBytes
        }
        else {
            $backupPath = Assert-AgentEnvironmentBackupFileSafe -Root $Root -Path ([string]$State.backupPath)
            $backupBytes = [System.IO.File]::ReadAllBytes($backupPath)
        }
        $backupSha256 = Get-AgentEnvironmentBytesSha256 -Bytes $backupBytes
        if (-not [string]::Equals($backupSha256,$originalSha256,[System.StringComparison]::Ordinal)) {
            throw "Rollback backup SHA-256 does not match the journaled original: $relative"
        }
        Set-AgentEnvironmentFileBytes -Root $Root -RelativePath $relative -Bytes $backupBytes
        return
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $actual = Get-AgentEnvironmentSha256 -Path $full
        if ([string]::IsNullOrWhiteSpace([string]$State.appliedSha256) -or $actual -cne [string]$State.appliedSha256) {
            throw "Rollback preserved concurrently created file: $relative"
        }
        Remove-Item -LiteralPath $full -Force
    }
    elseif (Test-Path -LiteralPath $full) { throw "Rollback preserved a concurrently created non-file target: $relative" }
}

function Import-AgentEnvironmentRuntimeModules {
    param([Parameter(Mandatory = $true)][string] $RuntimeRoot)
    foreach ($moduleName in @(
        'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
        'skills-source-retrieval.psm1','skills-source-acquisition.psm1','license-delivery.psm1'
    )) {
        $modulePath = Join-Path $RuntimeRoot $moduleName
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Installed Agent environment runtime module is missing: $moduleName" }
        Import-Module $modulePath -Force
    }
}

function Get-UserSkillsDesiredState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][object] $Configuration,
        [Parameter(Mandatory = $true)][string] $CatalogRepository,
        [Parameter(Mandatory = $true)][string] $CatalogCommit,
        [Parameter(Mandatory = $true)][string] $WorkingRoot,
        [hashtable] $LocalArchiveOverrides = @{}
    )
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
    if ($CatalogCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Agent environment Catalog commit must be a full lowercase commit SHA.' }
    $catalogPath = Join-Path $RuntimeRoot 'catalog/skills-catalog.json'
    $lockPath = Join-Path $RuntimeRoot 'catalog/skills-catalog-lock.json'
    $catalog = Test-SkillsCatalogDocument -CatalogPath $catalogPath
    $lock = Test-SkillsCatalogLockDocument -CatalogPath $catalogPath -LockPath $lockPath
    $skillIds = @(Resolve-SkillsSelection -Catalog $catalog -Selection $Configuration.catalog)
    $plan = Resolve-SkillsSourcePlan -Catalog $catalog -Lock $lock -SkillIds $skillIds
    $archiveRoot = Join-Path $WorkingRoot 'archives'
    $sourceRoot = Join-Path $WorkingRoot 'sources'
    $archives = Get-SkillsSourceArchives -Plan $plan -DestinationRoot $archiveRoot -LocalArchiveOverrides $LocalArchiveOverrides
    $resolved = Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths $archives -WorkingRoot $sourceRoot
    $sourceById = @{}
    foreach ($source in @($plan.Sources)) { $sourceById[[string]$source.id] = $source }
    $files = New-Object System.Collections.Generic.List[object]
    $licenseWarnings = New-Object System.Collections.Generic.List[string]
    foreach ($skill in @($resolved.Skills | Sort-Object id)) {
        $source = $sourceById[[string]$skill.sourceId]
        $skillRoot = [System.IO.Path]::GetFullPath([string]$skill.skillRootPath).TrimEnd([char[]]@('\','/'))
        $repositoryRoot = [System.IO.Path]::GetFullPath([string]$skill.sourceRootPath).TrimEnd([char[]]@('\','/'))
        if (Test-Path -LiteralPath (Join-Path $skillRoot '.ai-instructions-licenses')) { throw "Skill source already owns the license delivery namespace: $($skill.id)" }
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse -Force | Sort-Object FullName)) {
            $skillRelative = $file.FullName.Substring($skillRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $sourceRelative = $file.FullName.Substring($repositoryRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $files.Add([pscustomobject][ordered]@{
                skillId = [string]$skill.id
                sourceId = [string]$source.id
                sourceRepository = [string]$source.repository
                sourceRef = [string]$source.requestedRef
                sourceCommit = [string]$source.resolvedCommit
                sourceVersion = [string]$source.resolvedVersion
                sourcePath = $sourceRelative
                targetPath = ".agents/skills/$([string]$skill.id)/$skillRelative"
                sha256 = Get-AgentEnvironmentSha256 -Path $file.FullName
                stagedPath = $file.FullName
            })
        }
        $artifactPaths = @($files | Where-Object skillId -eq $skill.id | ForEach-Object sourcePath)
        $licenses = New-LicenseDeliveryPackage -SourceRoot $repositoryRoot -ArtifactPaths $artifactPaths `
            -SourceRepository $source.repository -SourceCommit $source.resolvedCommit -ArtifactId $skill.id `
            -WarningAction SilentlyContinue -WarningVariable sourceLicenseWarnings
        foreach ($warning in @($sourceLicenseWarnings)) { $licenseWarnings.Add([string]$warning) }
        $licenseRoot = Join-Path $WorkingRoot "licenses/$($skill.id)"
        Write-LicenseDeliveryPackage -Package $licenses -DestinationRoot $licenseRoot
        foreach ($licenseFile in @($licenses.Files)) {
            $files.Add([pscustomobject][ordered]@{
                skillId = [string]$skill.id; sourceId = [string]$source.id
                sourceRepository = [string]$source.repository; sourceRef = [string]$source.requestedRef
                sourceCommit = [string]$source.resolvedCommit; sourceVersion = [string]$source.resolvedVersion
                sourcePath = [string]$licenseFile.sourcePath
                targetPath = ".agents/skills/$($skill.id)/.ai-instructions-licenses/$($licenseFile.relativePath)"
                sha256 = [string]$licenseFile.sha256; stagedPath = (Join-Path $licenseRoot $licenseFile.relativePath)
            })
        }
    }
    $manifestFiles = @($files | ForEach-Object {
        [pscustomobject][ordered]@{
            skillId=$_.skillId; sourceId=$_.sourceId; sourceRepository=$_.sourceRepository; sourceRef=$_.sourceRef
            sourceCommit=$_.sourceCommit; sourceVersion=$_.sourceVersion; sourcePath=$_.sourcePath
            targetPath=$_.targetPath; sha256=$_.sha256
        }
    })
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        catalogRepository = $CatalogRepository
        catalogCommit = $CatalogCommit
        catalogId = [string]$catalog.catalogId
        lockSha256 = Get-AgentEnvironmentSha256 -Path $lockPath
        files = $manifestFiles
    }
    Assert-UserSkillsManagedManifestV1 -Manifest $manifest
    return [pscustomobject][ordered]@{
        RuntimeRoot=$RuntimeRoot; Catalog=$catalog; Lock=$lock; SkillIds=$skillIds; Files=[object[]]$files.ToArray(); Manifest=$manifest
        LicenseWarnings=[string[]]$licenseWarnings.ToArray()
    }
}

function Get-AgentEnvironmentManifest {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json }
    catch { throw "User Skills managed manifest is not valid JSON: $($_.Exception.Message)" }
    Assert-UserSkillsManagedManifestV1 -Manifest $manifest
    return $manifest
}

function New-AgentEnvironmentResult {
    param(
        [string] $Outcome,
        [object] $DesiredState,
        [object[]] $Installed,
        [object[]] $Updated,
        [object[]] $Removed,
        [object[]] $Preserved,
        [object[]] $Failed,
        [string] $RollbackState,
        [string] $BackupPath,
        [object[]] $FailureDetails = @(),
        [object[]] $Ownership = @()
    )
    $exitCode = switch ($Outcome) {
        'failed' { 1 }
        'drift' { 2 }
        'concurrent' { 3 }
        default { 0 }
    }
    return [pscustomobject][ordered]@{
        schemaVersion=1; outcome=$Outcome; exitCode=$exitCode; catalogCommit=[string]$DesiredState.Manifest.catalogCommit
        catalogLockSha256=[string]$DesiredState.Manifest.lockSha256
        installed=@($Installed); updated=@($Updated); removed=@($Removed); preserved=@($Preserved); failed=@($Failed)
        failureDetails=@($FailureDetails); ownership=@($Ownership)
        rollbackState=$RollbackState; backupPath=$BackupPath
        licenseWarnings=@(if ($null -ne $DesiredState.PSObject.Properties['LicenseWarnings']) { $DesiredState.LicenseWarnings })
    }
}

function Get-AgentEnvironmentCatalogNames {
    param([object] $Catalog)
    $names = @{}
    foreach ($skill in @($Catalog.skills)) {
        $names[[string]$skill.id] = $true
        foreach ($alias in @($skill.lifecycle.aliases)) { $names[[string]$alias] = $true }
    }
    return $names
}

function Invoke-UserSkillsReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $DesiredState,
        [Parameter(Mandatory = $true)][string] $UserHome,
        [ValidateSet('Apply','VerifyOnly','WhatIf')][string] $Mode = 'VerifyOnly',
        [switch] $ForceReinstallManagedSkills,
        [switch] $MigrateLegacyCatalogSkills,
        [int] $FailureAfterMutationCount = 0,
        [scriptblock] $BeforeBackupValidationAction
    )
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot ([string]$DesiredState.RuntimeRoot)
    $home = [System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\','/'))
    $agentsRoot = Join-Path $home '.agents'
    $skillsRoot = Join-Path $agentsRoot 'skills'
    if ((Test-Path -LiteralPath $agentsRoot) -and ((Get-Item -Force -LiteralPath $agentsRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'User .agents root must not be a reparse point.' }
    if ((Test-Path -LiteralPath $skillsRoot) -and ((Get-Item -Force -LiteralPath $skillsRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'User Skills root must not be a reparse point.' }
    $lockPath = Join-Path $agentsRoot 'update-agent-environment.lock'
    $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
    $journalRelative = '.agents/update-agent-environment.recovery.json'
    $manifestRelative = '.agents/catalog-skills.manifest.json'
    $manifestPath = Get-AgentEnvironmentFullPath -Root $home -RelativePath $manifestRelative
    if (Test-Path -LiteralPath $journalPath) {
        Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $journalRelative | Out-Null
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'Agent environment recovery journal path must be a file.' }
        throw 'An interrupted Agent environment transaction requires -Recover before another reconciliation.'
    }

    # Candidate and desired-manifest validation is deliberately completed before Apply
    # creates .agents or the user-scope lock. A bad candidate must not leave even an
    # apparently empty consumer root behind.
    $installed = New-Object System.Collections.Generic.List[string]
    $updated = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $preserved = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $failureDetails = New-Object System.Collections.Generic.List[object]
    $ownership = New-Object System.Collections.Generic.List[object]
    $stagedSnapshots = @{}
    foreach ($file in @($DesiredState.Files)) {
        $targetPath = [string]$file.targetPath
        try {
            Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $targetPath | Out-Null
        }
        catch {
            $failed.Add("Controlled candidate target path is unsafe: $targetPath")
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'unsafe-target-path' -SkillId ([string]$file.skillId) -Path $targetPath -Classification 'controlled-candidate' -Owner 'desired-state-staged-inventory' -Evidence ([string]$_.Exception.Message) -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 ([string]$file.sha256) -ActualSha256 $null -Remediation @('Rebuild the desired state with a repository-relative .agents/skills path.','Do not apply a candidate containing an absolute, traversal, or reparse-backed target path.')))
            continue
        }
        $snapshot = Get-AgentEnvironmentStagedFileSnapshot -File $file
        $ownership.Add((New-AgentEnvironmentOwnershipEvidence -SkillId ([string]$file.skillId) -Path $targetPath -Classification 'controlled-candidate' -Owner 'desired-state-staged-inventory' -Evidence 'Desired candidate path and SHA-256 were evaluated before any user-environment mutation.' -DestructiveChangeAllowed $false -Operation 'observe'))
        if (-not [bool]$snapshot.valid) {
            $failed.Add("Controlled candidate failed integrity verification: $targetPath")
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'staged-integrity-mismatch' -SkillId ([string]$file.skillId) -Path $targetPath -Classification 'controlled-candidate' -Owner 'desired-state-staged-inventory' -Evidence ([string]$snapshot.message) -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $snapshot.expectedSha256 -ActualSha256 $snapshot.actualSha256 -Remediation @('Reacquire the immutable candidate and rebuild the staged inventory.','Do not retry mutation with a changed or incomplete staged file.')))
            continue
        }
        if ($stagedSnapshots.ContainsKey($targetPath)) {
            $failed.Add("Controlled candidate contains a duplicate target path: $targetPath")
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'candidate-path-collision' -SkillId ([string]$file.skillId) -Path $targetPath -Classification 'controlled-candidate' -Owner 'desired-state-staged-inventory' -Evidence 'Two desired candidate entries resolve to the same user-scope target path.' -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 ([string]$file.sha256) -ActualSha256 $snapshot.actualSha256 -Remediation @('Regenerate the desired inventory with one stable entry per target path.','Do not resolve a target collision by overwriting one candidate entry.')))
            continue
        }
        $stagedSnapshots[$targetPath] = $snapshot
    }
    $manifestBytes = Get-AgentEnvironmentManifestBytes -Manifest $DesiredState.Manifest
    $manifestSha = Get-AgentEnvironmentBytesSha256 -Bytes $manifestBytes
    $desiredInventorySha = Get-AgentEnvironmentInventorySha256 -Files ([object[]]$DesiredState.Files)
    try {
        Assert-AgentEnvironmentManifestMatchesDesired -Manifest $DesiredState.Manifest -DesiredFiles ([object[]]$DesiredState.Files)
    }
    catch {
        $failed.Add('Desired managed manifest inventory does not match the candidate file inventory.')
        $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'desired-manifest-mismatch' -SkillId 'managed-manifest' -Path '.agents/catalog-skills.manifest.json' -Classification 'controlled-candidate' -Owner 'desired-state-manifest' -Evidence ([string]$_.Exception.Message) -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $manifestSha -ActualSha256 $null -Remediation @('Rebuild the desired state from the same validated candidate inventory.','Do not apply a manifest whose target/hash inventory differs from the candidate files.')))
    }
    if ($failed.Count -gt 0) {
        return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed $failed -RollbackState 'not-started' -BackupPath $null -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership ([object[]]$ownership.ToArray())
    }

    if ($Mode -eq 'Apply') { New-Item -ItemType Directory -Force -Path $agentsRoot,$skillsRoot | Out-Null }
    if (Test-Path -LiteralPath $lockPath) {
        $lockItem = Get-Item -Force -LiteralPath $lockPath
        if ($lockItem.PSIsContainer -or ($lockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent environment lock must be a non-reparse file.' }
    }
    $lockStream = $null
    try {
        try {
            if ($Mode -eq 'Apply') { $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
            elseif (Test-Path -LiteralPath $lockPath -PathType Leaf) { $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None) }
        }
        catch [System.IO.IOException] { return New-AgentEnvironmentResult -Outcome 'concurrent' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved @() -Failed @('Another Agent environment update is already running.') -RollbackState 'not-started' -BackupPath $null }
        if (Test-Path -LiteralPath $manifestPath) {
            Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $manifestRelative | Out-Null
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'User Skills managed manifest path must be a file.' }
        }
        $manifestObservation = Get-AgentEnvironmentObservedState -Root $home -RelativePath $manifestRelative
        $existing = Get-AgentEnvironmentManifest -Path $manifestPath
        $oldByPath = @{}
        if ($null -ne $existing) { foreach ($file in @($existing.files)) { $oldByPath[[string]$file.targetPath] = $file } }
        $desiredByPath = @{}
        foreach ($file in @($DesiredState.Files)) {
            if ($desiredByPath.ContainsKey([string]$file.targetPath)) { throw "Duplicate desired user Skill path: $($file.targetPath)" }
            $desiredByPath[[string]$file.targetPath] = $file
        }
        $catalogNames = Get-AgentEnvironmentCatalogNames -Catalog $DesiredState.Catalog
        $catalogOwnership = @{}
        foreach ($skill in @($DesiredState.Catalog.skills)) {
            $skillId = [string]$skill.id
            $lifecycleStatus = [string]$skill.lifecycle.status
            $idKind = if ($lifecycleStatus -eq 'removed') { 'retired-tombstone-id' } else { "$lifecycleStatus-id" }
            $catalogOwnership[$skillId] = [pscustomobject][ordered]@{ skillId=$skillId; catalogName=$skillId; kind=$idKind; status=$lifecycleStatus }
            foreach ($alias in @($skill.lifecycle.aliases)) {
                $catalogOwnership[[string]$alias] = [pscustomobject][ordered]@{ skillId=$skillId; catalogName=[string]$alias; kind='lifecycle-alias'; status=$lifecycleStatus }
            }
        }
        $migrationPaths = @{}
        if ($MigrateLegacyCatalogSkills -and (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force -ErrorAction Stop)) {
                if (-not $catalogNames.ContainsKey($directory.Name)) { continue }
                if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Legacy Catalog Skill directory is a reparse point: $($directory.Name)" }
                $catalogEvidence = $catalogOwnership[$directory.Name]
                $legacyItems = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop)
                foreach ($item in $legacyItems) {
                    $itemRelative = $item.FullName.Substring($home.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $failed.Add("Legacy Catalog Skill contains a reparse point: $itemRelative")
                        $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'legacy-unsafe-entry' -SkillId ([string]$catalogEvidence.skillId) -Path $itemRelative -Classification 'unmanaged-unknown' -Owner 'none' -Evidence 'The legacy inventory contains a reparse point, so ownership and destructive scope cannot be proven.' -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $null -ActualSha256 $null -Remediation @('Remove the reparse point manually and rerun the explicit legacy migration.','Do not follow or delete reparse-backed legacy content.')))
                    }
                    elseif (-not $item.PSIsContainer -and -not (Test-Path -LiteralPath $item.FullName -PathType Leaf)) {
                        $failed.Add("Legacy Catalog Skill contains a non-regular entry: $itemRelative")
                        $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'legacy-unsafe-entry' -SkillId ([string]$catalogEvidence.skillId) -Path $itemRelative -Classification 'unmanaged-unknown' -Owner 'none' -Evidence 'The legacy inventory entry is not a regular file and cannot be proven safe to migrate or remove.' -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $null -ActualSha256 $null -Remediation @('Replace the special entry with a regular file or remove it manually.','Do not mutate a legacy tree containing special filesystem entries.')))
                    }
                }
                foreach ($file in @($legacyItems | Where-Object { -not $_.PSIsContainer -and (Test-Path -LiteralPath $_.FullName -PathType Leaf) })) {
                    $relative = $file.FullName.Substring($home.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                    $legacyDefinitionPath = ".agents/skills/$($directory.Name)/SKILL.md"
                    if ($desiredByPath.ContainsKey($relative) -or $relative -ceq $legacyDefinitionPath) {
                        $migrationPaths[$relative] = $true
                        $legacyOperation = if ($desiredByPath.ContainsKey($relative)) { 'adopt' } else { 'remove' }
                        $ownership.Add((New-AgentEnvironmentOwnershipEvidence -SkillId ([string]$catalogEvidence.skillId) -Path $relative -Classification 'known-legacy' -Owner 'catalog-lifecycle' -Evidence ("Explicit -MigrateLegacyCatalogSkills; catalog $($catalogEvidence.kind) '$($catalogEvidence.catalogName)' with status '$($catalogEvidence.status)' proves this exact legacy path.") -DestructiveChangeAllowed $true -Operation $legacyOperation))
                    }
                    else {
                        $failed.Add("Legacy Catalog Skill contains an unmanaged file that cannot be migrated safely: $relative")
                        $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'legacy-unmanaged-content' -SkillId ([string]$catalogEvidence.skillId) -Path $relative -Classification 'unmanaged-unknown' -Owner 'none' -Evidence ("Catalog $($catalogEvidence.kind) identifies the directory, but this file is outside the desired inventory and known legacy definition path.") -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $null -ActualSha256 $null -Remediation @('Preserve the file or provide explicit legacy ownership evidence.','Do not delete the path based only on its directory name.')))
                    }
                }
            }
        }
        if ($failed.Count -gt 0) { return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed $failed -RollbackState 'not-started' -BackupPath $null -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership ([object[]]$ownership.ToArray()) }
        $observationsByPath = @{}
        $observationsByPath[$manifestRelative] = $manifestObservation
        $observedTargetPaths = @(@($oldByPath.Keys) + @($desiredByPath.Keys) + @($migrationPaths.Keys) | Sort-Object -Unique)
        foreach ($path in $observedTargetPaths) {
            $observationsByPath[$path] = Get-AgentEnvironmentObservedState -Root $home -RelativePath $path
        }
        $writes = @{}
        $deletes = @{}
        foreach ($path in @($oldByPath.Keys)) {
            $observation = $observationsByPath[$path]
            $managedExpected = [string]$oldByPath[$path].sha256
            $managedActual = if ([bool]$observation.existed) { [string]$observation.sha256 } else { $null }
            $managedDrift = [bool]$observation.existed -and $managedActual -cne $managedExpected
            $managedClassification = if ($managedDrift) { 'managed-drift' } else { 'managed' }
            $managedDestructiveAllowed = [bool](-not $managedDrift -or $ForceReinstallManagedSkills)
            $managedOperation = if ($desiredByPath.ContainsKey($path)) { 'replace' } else { 'remove' }
            $ownership.Add((New-AgentEnvironmentOwnershipEvidence -SkillId ([string]$oldByPath[$path].skillId) -Path $path -Classification $managedClassification -Owner 'managed-manifest-v1' -Evidence ("Validated .agents/catalog-skills.manifest.json schemaVersion 1 entry; expected SHA-256 $managedExpected, observed SHA-256 $managedActual.") -DestructiveChangeAllowed $managedDestructiveAllowed -Operation $managedOperation))
            if ([bool]$observation.existed) {
                $actual = [string]$observation.sha256
                if ($actual -cne $managedExpected -and -not $ForceReinstallManagedSkills) {
                    $failed.Add("Managed Skill file was customized: $path")
                    $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'managed-local-drift' -SkillId ([string]$oldByPath[$path].skillId) -Path $path -Classification 'managed-drift' -Owner 'managed-manifest-v1' -Evidence ("Manifest SHA-256 $managedExpected does not match observed SHA-256 $actual.") -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $managedExpected -ActualSha256 $actual -Remediation @('Review the local change and restore the managed hash, or explicitly use -ForceReinstallManagedSkills after backup review.','Do not silently replace locally changed managed content.')))
                    continue
                }
            }
            if (-not $desiredByPath.ContainsKey($path) -and [bool]$observation.existed) { $deletes[$path] = $true; $removed.Add($path) }
        }
        foreach ($path in @($migrationPaths.Keys)) {
            if (-not $desiredByPath.ContainsKey($path)) {
                $deletes[$path] = $true
                if (-not $removed.Contains($path)) { $removed.Add($path) }
            }
        }
        foreach ($path in @($desiredByPath.Keys)) {
            $file = $desiredByPath[$path]
            $observation = $observationsByPath[$path]
            if ([bool]$observation.existed) {
                $actual = [string]$observation.sha256
                if ($actual -ceq [string]$file.sha256) {
                    $preserved.Add($path)
                    if (-not $oldByPath.ContainsKey($path) -and -not $migrationPaths.ContainsKey($path)) {
                        $ownership.Add((New-AgentEnvironmentOwnershipEvidence -SkillId ([string]$file.skillId) -Path $path -Classification 'unmanaged-unknown' -Owner 'none' -Evidence 'Existing bytes match the desired candidate, but no managed manifest or explicit legacy ownership evidence exists.' -DestructiveChangeAllowed $false -Operation 'preserve'))
                    }
                    continue
                }
                if (-not $oldByPath.ContainsKey($path) -and -not $migrationPaths.ContainsKey($path)) {
                    $failed.Add("Unmanaged Skill file conflicts with selected Catalog content: $path")
                    $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'unmanaged-collision' -SkillId ([string]$file.skillId) -Path $path -Classification 'unmanaged-unknown' -Owner 'none' -Evidence 'No current managed manifest entry or explicit known-legacy migration evidence proves ownership of the existing bytes.' -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 ([string]$file.sha256) -ActualSha256 $actual -Remediation @('Preserve or manually rename the unmanaged file, or confirm a known legacy migration before rerunning.','Do not delete or overwrite unmanaged content based only on a matching target path.')))
                    continue
                }
                $updated.Add($path)
            }
            elseif ($oldByPath.ContainsKey($path)) { $updated.Add($path) }
            else { $installed.Add($path) }
            $writeOperation = if ($oldByPath.ContainsKey($path)) { 'replace' } elseif ($migrationPaths.ContainsKey($path)) { 'adopt' } else { 'install' }
            $writeClassification = if ($migrationPaths.ContainsKey($path)) { 'known-legacy' } else { 'controlled-candidate' }
            $writeOwner = if ($migrationPaths.ContainsKey($path)) { 'catalog-lifecycle' } else { 'desired-state-staged-inventory' }
            $writeEvidence = if ($migrationPaths.ContainsKey($path)) { 'Explicit legacy adoption evidence authorizes this exact replacement path.' } else { 'No existing managed or legacy ownership was required; candidate bytes are installed only after collision checks.' }
            $ownership.Add((New-AgentEnvironmentOwnershipEvidence -SkillId ([string]$file.skillId) -Path $path -Classification $writeClassification -Owner $writeOwner -Evidence $writeEvidence -DestructiveChangeAllowed $true -Operation $writeOperation))
            $writes[$path] = $file
        }
        if ($null -eq $existing -and -not $MigrateLegacyCatalogSkills -and (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                if (-not $catalogNames.ContainsKey($directory.Name)) { $preserved.Add(".agents/skills/$($directory.Name)/") }
            }
        }
        if ($failed.Count -gt 0) { return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed $failed -RollbackState 'not-started' -BackupPath $null -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership ([object[]]$ownership.ToArray()) }
        $manifestFileSetMatches = $null -ne $existing -and $oldByPath.Count -eq $desiredByPath.Count
        if ($manifestFileSetMatches) {
            foreach ($path in @($desiredByPath.Keys)) {
                if (-not $oldByPath.ContainsKey($path) -or [string]$oldByPath[$path].sha256 -cne [string]$desiredByPath[$path].sha256) { $manifestFileSetMatches = $false; break }
            }
        }
        $manifestMatches = $manifestFileSetMatches -and [string]$existing.catalogRepository -ceq [string]$DesiredState.Manifest.catalogRepository -and
            [string]$existing.catalogCommit -ceq [string]$DesiredState.Manifest.catalogCommit -and [string]$existing.lockSha256 -ceq [string]$DesiredState.Manifest.lockSha256
        if ($Mode -eq 'VerifyOnly') {
            $outcome = if ($writes.Count -eq 0 -and $deletes.Count -eq 0 -and $manifestMatches) { 'current' } else { 'drift' }
            return New-AgentEnvironmentResult -Outcome $outcome -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed @() -RollbackState 'not-started' -BackupPath $null -FailureDetails @() -Ownership ([object[]]$ownership.ToArray())
        }
        if ($Mode -eq 'WhatIf') { return New-AgentEnvironmentResult -Outcome 'planned' -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed @() -RollbackState 'not-started' -BackupPath $null -FailureDetails @() -Ownership ([object[]]$ownership.ToArray()) }
        if ($writes.Count -eq 0 -and $deletes.Count -eq 0 -and $manifestMatches) { return New-AgentEnvironmentResult -Outcome 'current' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved $preserved -Failed @() -RollbackState 'not-needed' -BackupPath $null -FailureDetails @() -Ownership ([object[]]$ownership.ToArray()) }
        $mutationPaths = @(@($writes.Keys) + @($deletes.Keys) + @($manifestRelative) | Sort-Object -Unique)
        if ($null -ne $BeforeBackupValidationAction) { & $BeforeBackupValidationAction }
        foreach ($path in $mutationPaths) {
            Assert-AgentEnvironmentObservedState -Root $home -Observation $observationsByPath[$path]
        }
        $transactionId = [Guid]::NewGuid().ToString('N')
        $backupsRoot = Join-Path $agentsRoot 'backups'
        if (Test-Path -LiteralPath $backupsRoot) {
            $backupsItem = Get-Item -Force -LiteralPath $backupsRoot
            if (-not $backupsItem.PSIsContainer -or ($backupsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent environment backups root must be a non-reparse directory.' }
        }
        else { New-Item -ItemType Directory -Path $backupsRoot | Out-Null }
        $backupRoot = Join-Path $backupsRoot ("update-agent-environment-$transactionId")
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $transactionStagePaths = @{}
        try {
            foreach ($path in @($desiredByPath.Keys)) {
                $stagePath = Get-AgentEnvironmentTransactionStagePath -TransactionRoot $backupRoot -RelativePath $path
                $stageParent = [System.IO.Path]::GetDirectoryName($stagePath)
                New-Item -ItemType Directory -Force -Path $stageParent | Out-Null
                [System.IO.File]::WriteAllBytes($stagePath,[byte[]]$stagedSnapshots[$path].bytes)
                $stagedHash = Get-AgentEnvironmentSha256 -Path $stagePath
                if ($stagedHash -cne [string]$desiredByPath[$path].sha256) {
                    throw "Transaction candidate staging hash mismatch: $path"
                }
                $transactionStagePaths[$path] = $stagePath
            }
        }
        catch {
            if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
            throw "Agent environment transaction candidate staging failed: $($_.Exception.Message)"
        }
        $states = New-Object System.Collections.Generic.List[object]
        $statesByPath = @{}
        try {
            foreach ($path in $mutationPaths) {
                $observation = $observationsByPath[$path]
                Assert-AgentEnvironmentObservedState -Root $home -Observation $observation
                $full = Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $path
                $existed = [bool]$observation.existed
                $backup = $null
                $backupSha = $null
                $originalSha = if ($existed) { [string]$observation.sha256 } else { $null }
                if ($existed) {
                    $backup = Join-Path $backupRoot $path.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
                    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($backup)) | Out-Null
                    $originalBytes = [System.IO.File]::ReadAllBytes($full)
                    if ((Get-AgentEnvironmentBytesSha256 -Bytes $originalBytes) -cne $originalSha) {
                        throw "Agent environment target changed after planning and before backup: $path"
                    }
                    [System.IO.File]::WriteAllBytes($backup,$originalBytes)
                    $backupSha = Get-AgentEnvironmentSha256 -Path $backup
                }
                $appliedSha = $null
                if ($writes.ContainsKey($path)) { $appliedSha = [string]$writes[$path].sha256 }
                elseif ($path -ceq $manifestRelative) {
                    $encoding = New-Object System.Text.UTF8Encoding($false)
                    $appliedSha = Get-AgentEnvironmentBytesSha256 -Bytes ($encoding.GetBytes(($DesiredState.Manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine))
                }
                $state = [pscustomobject][ordered]@{ relativePath=$path; existed=$existed; backupPath=$backup; originalSha256=$originalSha; backupSha256=$backupSha; appliedSha256=$appliedSha }
                $states.Add($state)
                $statesByPath[$path] = $state
            }
            $journal = [pscustomobject][ordered]@{
                schemaVersion=1
                transactionId=$transactionId
                userHome=$home
                backupPath=$backupRoot
                phase='prepared'
                desiredManifestSha256=$manifestSha
                desiredInventorySha256=$desiredInventorySha
                states=[object[]]$states.ToArray()
            }
            Write-AgentEnvironmentJson -Root $home -RelativePath $journalRelative -Document $journal
            $journal.phase = 'mutating'
            Write-AgentEnvironmentJson -Root $home -RelativePath $journalRelative -Document $journal
        }
        catch {
            if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
            throw "Agent environment transaction preparation failed: $($_.Exception.Message)"
        }
        $mutationCount = 0
        $failurePhase = 'mutation'
        try {
            foreach ($path in @($deletes.Keys | Sort-Object)) {
                Assert-AgentEnvironmentOriginalState -Root $home -State $statesByPath[$path]
                $full = Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $path
                if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
                $mutationCount++; if ($FailureAfterMutationCount -gt 0 -and $mutationCount -ge $FailureAfterMutationCount) { throw 'Injected Agent environment transaction failure.' }
            }
            foreach ($path in @($writes.Keys | Sort-Object)) {
                Assert-AgentEnvironmentOriginalState -Root $home -State $statesByPath[$path]
                Set-AgentEnvironmentFileBytes -Root $home -RelativePath $path -Bytes ([System.IO.File]::ReadAllBytes([string]$transactionStagePaths[$path]))
                $mutationCount++; if ($FailureAfterMutationCount -gt 0 -and $mutationCount -ge $FailureAfterMutationCount) { throw 'Injected Agent environment transaction failure.' }
            }
            Assert-AgentEnvironmentOriginalState -Root $home -State $statesByPath[$manifestRelative]
            Write-AgentEnvironmentJson -Root $home -RelativePath $manifestRelative -Document $DesiredState.Manifest
            $failurePhase = 'post-install-verification'
            foreach ($path in @($desiredByPath.Keys)) {
                $full = Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $path
                if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-AgentEnvironmentSha256 -Path $full) -cne [string]$desiredByPath[$path].sha256) { throw "Final user Skill inventory verification failed: $path" }
            }
            foreach ($path in @($deletes.Keys)) {
                $full = Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $path
                if (Test-Path -LiteralPath $full) { throw "Retired managed path still exists after cleanup: $path" }
            }
            $verified = Get-AgentEnvironmentManifest -Path $manifestPath
            if ((Get-AgentEnvironmentSha256 -Path $manifestPath) -cne $manifestSha) { throw 'Final user Skills manifest byte verification failed.' }
            if ([string]$verified.lockSha256 -cne [string]$DesiredState.Manifest.lockSha256) { throw 'Final user Skills manifest verification failed.' }
            Assert-AgentEnvironmentManifestMatchesDesired -Manifest $verified -DesiredFiles ([object[]]$DesiredState.Files)
            if ((Get-AgentEnvironmentInventorySha256 -Files ([object[]]$verified.files)) -cne $desiredInventorySha) { throw 'Final user Skills managed inventory hash verification failed.' }
            $managedDirectories = @{}
            foreach ($path in @($deletes.Keys)) {
                $directoryPath = [System.IO.Path]::GetDirectoryName((Get-AgentEnvironmentFullPath -Root $home -RelativePath $path))
                while ($directoryPath.StartsWith($skillsRoot + [System.IO.Path]::DirectorySeparatorChar,(Get-AgentEnvironmentPathComparison))) {
                    $managedDirectories[$directoryPath] = $true
                    $directoryPath = [System.IO.Path]::GetDirectoryName($directoryPath)
                }
            }
            foreach ($directoryPath in @($managedDirectories.Keys | Sort-Object Length -Descending)) {
                if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) { continue }
                $directory = Get-Item -Force -LiteralPath $directoryPath
                if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Managed Skill cleanup found a reparse point: $directoryPath" }
                if (@(Get-ChildItem -LiteralPath $directoryPath -Force).Count -eq 0) { Remove-Item -LiteralPath $directoryPath -Force }
            }
            Remove-Item -LiteralPath $journalPath -Force
            return New-AgentEnvironmentResult -Outcome 'applied' -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed @() -RollbackState 'not-needed' -BackupPath $backupRoot -FailureDetails @() -Ownership ([object[]]$ownership.ToArray())
        }
        catch {
            $applyError = $_
            $rollbackErrors = New-Object System.Collections.Generic.List[string]
            $reverseStates = [object[]]$states.ToArray()
            [array]::Reverse($reverseStates)
            foreach ($state in $reverseStates) {
                try { Restore-AgentEnvironmentFileState -Root $home -State $state }
                catch { $rollbackErrors.Add("$($state.relativePath): $($_.Exception.Message)") }
            }
            $failureCode = if ($rollbackErrors.Count -eq 0) { 'post-install-integrity-failure' } else { 'recovery-required' }
            $rollbackState = if ($rollbackErrors.Count -eq 0) { 'completed' } else { 'recovery-required' }
            $evidence = "Transaction phase '$failurePhase' failed: $($applyError.Exception.Message)"
            if ($rollbackErrors.Count -gt 0) { $evidence += " Rollback errors: $($rollbackErrors -join ' | ')" }
            $remediation = if ($rollbackErrors.Count -eq 0) { @('Review the failed transaction evidence and retry from the unchanged original state.') } else { @('Run -Recover after verifying the retained journal and backup.','Do not start another reconciliation while recovery is required.') }
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code $failureCode -SkillId 'transaction' -Path $journalRelative -Classification 'controlled-candidate' -Owner 'transaction-journal' -Evidence $evidence -DestructiveChangeAllowed $false -BackupCreated $true -ExpectedSha256 $manifestSha -ActualSha256 $null -Remediation $remediation))
            if ($rollbackErrors.Count -eq 0) { Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue }
            $transactionFailures = @($failed.ToArray()) + @([string]$applyError.Exception.Message)
            return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved $preserved -Failed $transactionFailures -RollbackState $rollbackState -BackupPath $backupRoot -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership ([object[]]$ownership.ToArray())
        }
    }
    finally { if ($null -ne $lockStream) { $lockStream.Dispose() } }
}

function Invoke-UserSkillsRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $UserHome)
    $home = [System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\','/'))
    $agentsRoot = Join-Path $home '.agents'
    $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
    $lockPath = Join-Path $agentsRoot 'update-agent-environment.lock'
    $journalRelative = '.agents/update-agent-environment.recovery.json'
    if (-not (Test-Path -LiteralPath $journalPath)) { return [pscustomobject][ordered]@{ schemaVersion=1; outcome='nothing-to-recover'; exitCode=0; rollbackState='not-needed' } }
    Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $journalRelative | Out-Null
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'Agent environment recovery journal path must be a file.' }
    if (Test-Path -LiteralPath $lockPath) {
        $lockItem = Get-Item -Force -LiteralPath $lockPath
        if ($lockItem.PSIsContainer -or ($lockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent environment lock must be a non-reparse file.' }
    }
    $lockStream = $null
    try {
        try { $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
        catch [System.IO.IOException] { throw 'Another Agent environment update is already running.' }
        $journal = Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
        Assert-AgentEnvironmentExactProperties -Object $journal -Required @('schemaVersion','transactionId','userHome','backupPath','phase','desiredManifestSha256','desiredInventorySha256','states') -Context 'Agent environment recovery journal'
        if (($journal.schemaVersion -isnot [int] -and $journal.schemaVersion -isnot [long]) -or [long]$journal.schemaVersion -ne 1 -or
            $journal.transactionId -isnot [string] -or [string]$journal.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
            $journal.userHome -isnot [string] -or -not [string]::Equals([string]$journal.userHome,$home,[System.StringComparison]::Ordinal) -or
            $journal.backupPath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$journal.backupPath) -or
            $journal.phase -isnot [string] -or @('prepared','mutating') -cnotcontains [string]$journal.phase -or
            $journal.desiredManifestSha256 -isnot [string] -or [string]$journal.desiredManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $journal.desiredInventorySha256 -isnot [string] -or [string]$journal.desiredInventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $journal.states -isnot [System.Array] -or @($journal.states).Count -eq 0) {
            throw 'Agent environment recovery journal identity or type contract is invalid.'
        }
        $journalBackupRoot = Assert-AgentEnvironmentBackupDirectorySafe -Root $home -Path ([string]$journal.backupPath)
        $pathComparison = Get-AgentEnvironmentPathComparison
        $pathComparer = if ($pathComparison -eq [System.StringComparison]::OrdinalIgnoreCase) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
        $seenRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' $pathComparer
        $validatedStates = New-Object System.Collections.Generic.List[object]
        foreach ($state in @($journal.states)) {
            Assert-AgentEnvironmentExactProperties -Object $state -Required @('relativePath','existed','backupPath','originalSha256','backupSha256','appliedSha256') -Context 'Agent environment recovery state'
            if ($state.relativePath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$state.relativePath) -or
                $state.existed -isnot [bool] -or -not $seenRelativePaths.Add([string]$state.relativePath)) {
                throw 'Agent environment recovery state path or type contract is invalid.'
            }
            $relative = [string]$state.relativePath
            if ($relative -cne '.agents/catalog-skills.manifest.json' -and -not $relative.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
                throw "Agent environment recovery state is outside the recoverable scope: $relative"
            }
            Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $relative | Out-Null
            $appliedSha256 = $state.appliedSha256
            if ($null -ne $appliedSha256 -and ($appliedSha256 -isnot [string] -or [string]$appliedSha256 -cnotmatch '^[0-9a-f]{64}$')) {
                throw "Agent environment recovery state has an invalid applied SHA-256: $relative"
            }
            $validatedBackupBytes = $null
            if ([bool]$state.existed) {
                if ($state.backupPath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$state.backupPath) -or
                    $state.originalSha256 -isnot [string] -or [string]$state.originalSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                    $state.backupSha256 -isnot [string] -or [string]$state.backupSha256 -cnotmatch '^[0-9a-f]{64}$') {
                    throw "Agent environment recovery state has invalid original backup metadata: $relative"
                }
                $stateBackupPath = Assert-AgentEnvironmentBackupFileSafe -Root $home -Path ([string]$state.backupPath)
                $expectedBackupPath = [System.IO.Path]::GetFullPath((Join-Path $journalBackupRoot $relative.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
                if (-not [string]::Equals($stateBackupPath,$expectedBackupPath,$pathComparison)) {
                    throw "Agent environment recovery state backup is not bound to its transaction and target: $relative"
                }
                $validatedBackupBytes = [System.IO.File]::ReadAllBytes($stateBackupPath)
                $validatedBackupSha256 = Get-AgentEnvironmentBytesSha256 -Bytes $validatedBackupBytes
                if (-not [string]::Equals($validatedBackupSha256,[string]$state.originalSha256,[System.StringComparison]::Ordinal)) {
                    throw "Agent environment recovery state backup SHA-256 does not match its journaled original: $relative"
                }
                if (-not [string]::Equals($validatedBackupSha256,[string]$state.backupSha256,[System.StringComparison]::Ordinal)) {
                    throw "Agent environment recovery state backup SHA-256 does not match its journaled backup identity: $relative"
                }
            }
            elseif ($null -ne $state.backupPath -or $null -ne $state.originalSha256 -or $null -ne $state.backupSha256) {
                throw "Agent environment recovery state for a previously absent target must not declare original backup metadata: $relative"
            }
            $validatedStates.Add([pscustomobject][ordered]@{
                State=$state
                HasBackup=[bool]$state.existed
                BackupBytes=if ([bool]$state.existed) { $validatedBackupBytes } else { $null }
            })
        }
        foreach ($validatedState in $validatedStates.ToArray()) {
            if ([bool]$validatedState.HasBackup) {
                Restore-AgentEnvironmentFileState -Root $home -State $validatedState.State -ValidatedBackupBytes $validatedState.BackupBytes
            }
            else {
                Restore-AgentEnvironmentFileState -Root $home -State $validatedState.State
            }
            Assert-AgentEnvironmentOriginalState -Root $home -State $validatedState.State
        }
        Remove-Item -LiteralPath $journalPath -Force
        return [pscustomobject][ordered]@{ schemaVersion=1; outcome='recovered'; exitCode=0; rollbackState='completed'; backupPath=[string]$journal.backupPath }
    }
    finally { if ($null -ne $lockStream) { $lockStream.Dispose() } }
}

Export-ModuleMember -Function Get-UserSkillsDesiredState, Invoke-UserSkillsReconciliation, Invoke-UserSkillsRecovery
