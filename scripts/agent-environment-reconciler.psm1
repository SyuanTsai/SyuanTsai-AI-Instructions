Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'skills-catalog-contract.psm1') -Scope Local -ErrorAction Stop

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
        -not $RelativePath.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal) -and
        -not $RelativePath.StartsWith('.claude/skills/',[System.StringComparison]::Ordinal) -and
        -not $RelativePath.StartsWith('.copilot/skills/',[System.StringComparison]::Ordinal)) {
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
        'skills-source-retrieval.psm1','skills-source-acquisition.psm1','license-delivery.psm1',
        'ai-instructions-runtime-contract.psm1','platform-runtime.psm1'
    )) {
        $modulePath = Join-Path $RuntimeRoot $moduleName
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Installed Agent environment runtime module is missing: $moduleName" }
        Import-Module $modulePath -Force
    }
}

function Assert-UserProjectionRuntimeGate {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RuntimeRoot)
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
    # P7e reader/writer selection is intentionally connected here when it lands.
    throw (New-AiInstructionsRefusalException -Code 'projection-runtime-unavailable' -Message 'Projection-aware production runtime is unavailable until the P7e gate and production pins are installed.')
}

function Get-UserSkillsDesiredState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][object] $Configuration,
        [Parameter(Mandatory = $true)][string] $CatalogRepository,
        [Parameter(Mandatory = $true)][string] $CatalogCommit,
        [Parameter(Mandatory = $true)][string] $WorkingRoot,
        [string[]] $ProjectionIds,
        [hashtable] $LocalArchiveOverrides = @{}
    )
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
    if ($CatalogCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Agent environment Catalog commit must be a full lowercase commit SHA.' }
    $catalogPath = Join-Path $RuntimeRoot 'catalog/skills-catalog.json'
    $lockPath = Join-Path $RuntimeRoot 'catalog/skills-catalog-lock.json'
    [byte[]]$catalogBytes = [System.IO.File]::ReadAllBytes($catalogPath)
    [byte[]]$lockBytes = [System.IO.File]::ReadAllBytes($lockPath)
    $catalog = Test-SkillsCatalogDocument -CatalogPath $catalogPath
    $lock = Test-SkillsCatalogLockDocument -CatalogPath $catalogPath -LockPath $lockPath
    $projectionAware = [int64]$catalog.schemaVersion -eq 3
    if ($projectionAware -ne ([int64]$lock.schemaVersion -eq 3)) { throw 'Catalog and Lock projection generations are mixed.' }
    if ($projectionAware) {
        if (-not $PSBoundParameters.ContainsKey('ProjectionIds')) {
            if ($null -eq $Configuration.PSObject.Properties['schemaVersion'] -or [int64]$Configuration.schemaVersion -ne 5) {
                throw 'Projection-aware desired state requires sync configuration schemaVersion 5.'
            }
            $ProjectionIds = [string[]]@($Configuration.projections.user)
        }
        [string[]]$ProjectionIds = @($ProjectionIds)
        [System.Array]::Sort($ProjectionIds,[System.StringComparer]::Ordinal)
        if ($ProjectionIds.Count -eq 0 -or $ProjectionIds -cnotcontains 'user-agents' -or @($ProjectionIds | Select-Object -Unique).Count -ne $ProjectionIds.Count) {
            throw "USER projection selection must be unique and include 'user-agents'."
        }
        foreach ($projectionId in $ProjectionIds) {
            $projection = @($catalog.projections | Where-Object { [string]$_.id -ceq $projectionId })
            if ($projection.Count -ne 1 -or [string]$projection[0].scope -cne 'user') { throw "Unsupported USER projection '$projectionId'." }
        }
    }
    else { $ProjectionIds = @('user-agents') }
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
        $targetPathProperty = $skill.PSObject.Properties['targetPath']
        $targetRoot = if ($null -ne $targetPathProperty) { [string]$targetPathProperty.Value } else { ".agents/skills/$([string]$skill.id)" }
        if (-not $projectionAware -and $targetRoot -cne ".agents/skills/$([string]$skill.id)") { throw "Skill '$($skill.id)' has an unsafe runtime target path: $targetRoot" }
        if (Test-Path -LiteralPath (Join-Path $skillRoot '.ai-instructions-licenses')) { throw "Skill source already owns the license delivery namespace: $($skill.id)" }
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse -Force | Sort-Object FullName)) {
            $skillRelative = $file.FullName.Substring($skillRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $sourceRelative = $file.FullName.Substring($repositoryRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            foreach ($projectionId in $ProjectionIds) {
                $projectionTargetRoot = if ($projectionAware) { Get-SkillsCatalogProjectionTargetPath -Catalog $catalog -SkillId ([string]$skill.id) -ProjectionId $projectionId } else { $targetRoot }
                $entry = [ordered]@{
                    skillId = [string]$skill.id; sourceId = [string]$source.id
                    sourceRepository = [string]$source.repository; sourceRef = [string]$source.requestedRef
                    sourceCommit = [string]$source.resolvedCommit; sourceVersion = [string]$source.resolvedVersion
                    sourcePath = $sourceRelative; targetPath = "$projectionTargetRoot/$skillRelative"
                    sha256 = Get-AgentEnvironmentSha256 -Path $file.FullName; stagedPath = $file.FullName
                }
                if ($projectionAware) { $entry['projectionId'] = $projectionId }
                $files.Add([pscustomobject]$entry)
            }
        }
        $artifactPaths = @(Get-ChildItem -LiteralPath $skillRoot -File -Recurse -Force | ForEach-Object {
            $_.FullName.Substring($repositoryRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        })
        $licenses = New-LicenseDeliveryPackage -SourceRoot $repositoryRoot -ArtifactPaths $artifactPaths `
            -SourceRepository $source.repository -SourceCommit $source.resolvedCommit -ArtifactId $skill.id `
            -WarningAction SilentlyContinue -WarningVariable sourceLicenseWarnings
        foreach ($warning in @($sourceLicenseWarnings)) { $licenseWarnings.Add([string]$warning) }
        $licenseRoot = Join-Path $WorkingRoot "licenses/$($skill.id)"
        Write-LicenseDeliveryPackage -Package $licenses -DestinationRoot $licenseRoot
        foreach ($licenseFile in @($licenses.Files)) {
            foreach ($projectionId in $ProjectionIds) {
                $projectionTargetRoot = if ($projectionAware) { Get-SkillsCatalogProjectionTargetPath -Catalog $catalog -SkillId ([string]$skill.id) -ProjectionId $projectionId } else { $targetRoot }
                $entry = [ordered]@{
                    skillId = [string]$skill.id; sourceId = [string]$source.id
                    sourceRepository = [string]$source.repository; sourceRef = [string]$source.requestedRef
                    sourceCommit = [string]$source.resolvedCommit; sourceVersion = [string]$source.resolvedVersion
                    sourcePath = [string]$licenseFile.sourcePath
                    targetPath = "$projectionTargetRoot/.ai-instructions-licenses/$($licenseFile.relativePath)"
                    sha256 = [string]$licenseFile.sha256; stagedPath = (Join-Path $licenseRoot $licenseFile.relativePath)
                }
                if ($projectionAware) { $entry['projectionId'] = $projectionId }
                $files.Add([pscustomobject]$entry)
            }
        }
    }
    $manifestFiles = @($files | ForEach-Object {
        $manifestEntry = [ordered]@{
            skillId=$_.skillId; sourceId=$_.sourceId; sourceRepository=$_.sourceRepository; sourceRef=$_.sourceRef
            sourceCommit=$_.sourceCommit; sourceVersion=$_.sourceVersion; sourcePath=$_.sourcePath
            targetPath=$_.targetPath; sha256=$_.sha256
        }
        if ($projectionAware) { $manifestEntry['projectionId'] = $_.projectionId }
        [pscustomobject]$manifestEntry
    })
    $manifestData = [ordered]@{
        schemaVersion = if ($projectionAware) { 3 } elseif ([int64]$catalog.schemaVersion -eq 2) { 2 } else { 1 }
        catalogRepository = $CatalogRepository
        catalogCommit = $CatalogCommit
        catalogId = [string]$catalog.catalogId
        lockSha256 = Get-AgentEnvironmentSha256 -Path $lockPath
    }
    if ($projectionAware) {
        $manifestData['projectionContractSha256'] = Get-SkillsCatalogProjectionContractSha256 -Projections $catalog.projections
        $manifestData['generation'] = 1
        $manifestData['projections'] = [string[]]$ProjectionIds
    }
    $manifestData['files'] = $manifestFiles
    $manifest = [pscustomobject]$manifestData
    Assert-UserSkillsManagedManifest -Manifest $manifest
    if ($projectionAware) {
        Assert-UserSkillsManagedManifestBinding -Manifest $manifest -CatalogBytes $catalogBytes -LockBytes $lockBytes `
            -ExpectedCatalogRepository $CatalogRepository -ExpectedCatalogCommit $CatalogCommit | Out-Null
    }
    return [pscustomobject][ordered]@{
        RuntimeRoot=$RuntimeRoot; Catalog=$catalog; Lock=$lock; SkillIds=$skillIds; Files=[object[]]$files.ToArray(); Manifest=$manifest
        LicenseWarnings=[string[]]$licenseWarnings.ToArray(); CatalogBytes=$catalogBytes; LockBytes=$lockBytes; ProjectionIds=[string[]]$ProjectionIds
    }
}

function Get-AgentEnvironmentManifest {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json }
    catch { throw "User Skills managed manifest is not valid JSON: $($_.Exception.Message)" }
    Assert-UserSkillsManagedManifest -Manifest $manifest
    return $manifest
}

function Get-AgentEnvironmentManifestSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    # Both the pre-lock and locked observations use this helper.  Establish the
    # physical path boundary before even testing or parsing the manifest.
    $path = Assert-AgentEnvironmentPathSafe -Root $Root -RelativePath $RelativePath
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -Force -LiteralPath $path
        if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'User Skills managed manifest path must be a non-reparse file.'
        }
    }
    $manifest = Get-AgentEnvironmentManifest -Path $path
    return [pscustomobject][ordered]@{
        Manifest = $manifest
        Identity = if ($null -eq $manifest) { $null } else { [Convert]::ToBase64String((Get-AgentEnvironmentManifestBytes -Manifest $manifest)) }
    }
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
        schemaVersion=1; outcome=$Outcome; exitCode=$exitCode; Code=$(if(@($FailureDetails).Count-gt0){[string]$FailureDetails[0].code}else{$null}); catalogCommit=[string]$DesiredState.Manifest.catalogCommit
        catalogLockSha256=[string]$DesiredState.Manifest.lockSha256
        installed=@($Installed); updated=@($Updated); removed=@($Removed); preserved=@($Preserved); failed=@($Failed)
        failureDetails=@($FailureDetails); ownership=@($Ownership)
        rollbackState=$RollbackState; backupPath=$BackupPath
        licenseWarnings=@(if ($null -ne $DesiredState.PSObject.Properties['LicenseWarnings']) { $DesiredState.LicenseWarnings })
    }
}

function New-AgentEnvironmentRecoveryFailureResult {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter(Mandatory = $true)][string] $JournalRelative,
        [AllowNull()][object] $BackupPath
    )
    $safeBackupPath = if ($null -eq $BackupPath -or [string]::IsNullOrWhiteSpace([string]$BackupPath)) { $null } else { [string]$BackupPath }
    $backupCreated = $null -ne $safeBackupPath
    $evidence = "Recovery validation failed; the retained journal '$JournalRelative' was not removed: $Message"
    $failureDetail = New-AgentEnvironmentFailureDetail `
        -Code 'recovery-required' `
        -SkillId 'transaction' `
        -Path $JournalRelative `
        -Classification 'controlled-candidate' `
        -Owner 'transaction-journal' `
        -Evidence $evidence `
        -DestructiveChangeAllowed $false `
        -BackupCreated $backupCreated `
        -ExpectedSha256 $null `
        -ActualSha256 $null `
        -Remediation @(
            'Inspect the retained recovery journal and transaction backup before retrying -Recover.',
            'Repair or restore valid recovery metadata; do not delete the journal or start another reconciliation while recovery is required.'
        )
    $ownership = New-AgentEnvironmentOwnershipEvidence `
        -SkillId 'transaction' `
        -Path $JournalRelative `
        -Classification 'controlled-candidate' `
        -Owner 'transaction-journal' `
        -Evidence 'The retained recovery journal is the authoritative transaction record; recovery validation did not complete.' `
        -DestructiveChangeAllowed $false `
        -Operation 'observe'
    return [pscustomobject][ordered]@{
        schemaVersion=1; outcome='failed'; exitCode=1; catalogCommit=$null; catalogLockSha256=$null
        installed=@(); updated=@(); removed=@(); preserved=@(); failed=@($Message)
        failureDetails=@($failureDetail); ownership=@($ownership)
        rollbackState='recovery-required'; backupPath=$safeBackupPath; licenseWarnings=@()
    }
}

function New-AgentEnvironmentRecoveryConcurrentResult {
    return [pscustomobject][ordered]@{
        schemaVersion=1; outcome='concurrent'; exitCode=3; catalogCommit=$null; catalogLockSha256=$null
        installed=@(); updated=@(); removed=@(); preserved=@(); failed=@('Another Agent environment update is already running.')
        failureDetails=@(); ownership=@()
        rollbackState='not-started'; backupPath=$null; licenseWarnings=@()
    }
}

function Remove-AgentEnvironmentRecoveryJournal {
    param([Parameter(Mandatory = $true)][string] $Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) { throw 'Agent environment recovery journal remained after cleanup.' }
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

function ConvertTo-AgentEnvironmentPlatformIdentity {
    param([Parameter(Mandatory = $true)] $Observation)
    if ((Get-CurrentPlatformName) -ceq 'windows') {
        return [pscustomobject][ordered]@{ kind='windows-file-id'; device=('0x{0:x}' -f [uint64]$Observation.Device); fileId=('0x{0:x}' -f [uint64]$Observation.Inode) }
    }
    return [pscustomobject][ordered]@{ kind='unix-device-inode'; device=([uint64]$Observation.Device).ToString(); fileId=([uint64]$Observation.Inode).ToString() }
}

function ConvertTo-AgentEnvironmentPermissionSnapshot {
    param([Parameter(Mandatory = $true)] $Snapshot)
    if ((Get-CurrentPlatformName) -ceq 'windows') {
        return [pscustomobject][ordered]@{ kind='windows-sddl'; sddl=[string]$Snapshot.Sddl; readOnly=[bool]$Snapshot.ReadOnly }
    }
    return [pscustomobject][ordered]@{ kind='unix-mode'; mode=[string]$Snapshot.Mode; uid=[int64]$Snapshot.Uid; gid=[int64]$Snapshot.Gid }
}

function Open-AgentEnvironmentDirectoryLease {
    param([Parameter(Mandatory = $true)][string]$Home,[Parameter(Mandatory = $true)][string]$RelativePath)
    if ([string]::IsNullOrEmpty($RelativePath)) { return Open-PlatformDirectory -Root $Home -RootOnly }
    return Open-PlatformDirectory -Root $Home -RelativePath $RelativePath
}

function Get-AgentEnvironmentFileJournalState {
    param([Parameter(Mandatory = $true)][string]$Home,[Parameter(Mandatory = $true)][string]$RelativePath)
    $full=Assert-AgentEnvironmentPathSafe -Root $Home -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $full)) { return [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null} }
    $parentRelative=[IO.Path]::GetDirectoryName($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)).Replace('\','/')
    $leaf=[IO.Path]::GetFileName($full); $parent=$null; $file=$null
    try {
        $parent=Open-AgentEnvironmentDirectoryLease $Home $parentRelative
        $file=Open-PlatformFile -ParentLease $parent -Leaf $leaf -Access Read -CreateMode OpenExisting
        $observed=Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath
        return [pscustomobject][ordered]@{exists=$true;sha256=(Get-AgentEnvironmentSha256 $full);length=[int64]$observed.Size;identity=(ConvertTo-AgentEnvironmentPlatformIdentity $observed)}
    }
    finally { if($null-ne$file){$file.Dispose()};if($null-ne$parent){$parent.Dispose()} }
}

function Get-AgentEnvironmentPrivateFileJournalState {
    param(
        [Parameter(Mandatory = $true)][string] $TransactionPath,
        [Parameter(Mandatory = $true)][string] $Leaf
    )
    if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf -ne [IO.Path]::GetFileName($Leaf) -or $Leaf.IndexOfAny([char[]]@('/', '\')) -ge 0) {
        throw 'Transaction-private file state requires one safe leaf.'
    }
    $full = Join-Path $TransactionPath $Leaf
    if (-not (Test-Path -LiteralPath $full)) {
        return [pscustomobject][ordered]@{ exists=$false; sha256=$null; length=$null; identity=$null }
    }
    $transactionLease = $null
    $file = $null
    try {
        $transactionLease = Open-PlatformDirectory -Root $TransactionPath -RootOnly
        $file = Open-PlatformFile -ParentLease $transactionLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
        $observed = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath
        return [pscustomobject][ordered]@{
            exists = $true
            sha256 = Get-AgentEnvironmentSha256 $full
            length = [int64]$observed.Size
            identity = ConvertTo-AgentEnvironmentPlatformIdentity $observed
        }
    }
    finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $transactionLease) { $transactionLease.Dispose() }
    }
}

function Get-AgentEnvironmentDirectoryInventory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/')); $entries=New-Object Collections.Generic.List[object]
    foreach($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)){
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw "Directory inventory crosses a reparse point: $($item.FullName)"}
        if(-not $item.PSIsContainer){$relative=$item.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/');$entries.Add([pscustomobject]@{path=$relative;sha256=(Get-AgentEnvironmentSha256 $item.FullName)})}
    }
    return [object[]]$entries.ToArray()
}

function Get-AgentEnvironmentDirectoryJournalState {
    param([Parameter(Mandatory = $true)][string]$Home,[Parameter(Mandatory = $true)][string]$RelativePath)
    $full=Get-AgentEnvironmentFullPath -Root $Home -RelativePath $RelativePath
    if(-not(Test-Path -LiteralPath $full)){return [pscustomobject][ordered]@{exists=$false;identity=$null;inventorySha256=$null;entryCount=$null}}
    $lease=$null
    try{$lease=Open-PlatformDirectory -Root $Home -RelativePath $RelativePath;$observed=Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -VerifyPath;$inventory=@(Get-AgentEnvironmentDirectoryInventory $full);return [pscustomobject][ordered]@{exists=$true;identity=(ConvertTo-AgentEnvironmentPlatformIdentity $observed);inventorySha256=(Get-AiInstructionsRuntimeInventorySha256V3 $inventory);entryCount=$inventory.Count}}
    finally{if($null-ne$lease){$lease.Dispose()}}
}

function Write-AgentEnvironmentInstallJournal {
    param([Parameter(Mandatory = $true)][string]$TransactionPath,[Parameter(Mandatory = $true)][object]$Journal)
    Assert-AiInstructionsInstallJournalV1 -Journal $Journal | Out-Null
    $path=Join-Path $TransactionPath 'journal.json';$stage=Join-Path $TransactionPath 'journal.stage';$previous=Join-Path $TransactionPath 'journal.prev'
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Journal|ConvertTo-Json -Depth 30)+[Environment]::NewLine)
    $stream=[IO.File]::Open($stage,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);if([string]$env:AI_INSTRUCTIONS_USER_RECONCILER_FAILFAST-ceq'after-journal-stage-flush'){[Environment]::FailFast('Injected USER reconciler FailFast after journal stage flush.')}}finally{$stream.Dispose()}
    if(Test-Path -LiteralPath $path){if(Test-Path -LiteralPath $previous){Remove-Item -LiteralPath $previous -Force};[IO.File]::Move($path,$previous)}
    [IO.File]::Move($stage,$path)
    if([string]$env:AI_INSTRUCTIONS_USER_RECONCILER_FAILFAST-ceq'after-journal-publish'){[Environment]::FailFast('Injected USER reconciler FailFast after journal publish.')}
}

function Get-AgentEnvironmentProcessStartIdentity {
    $process=[Diagnostics.Process]::GetCurrentProcess();try{return $process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}finally{$process.Dispose()}
}

function Invoke-AgentEnvironmentFailpoint {
    param([string]$Name,[string]$ConfiguredName,[int]$MutationCount,[int]$FailureAfterMutationCount)
    $allowed=@('after-original-rename','after-applied-rename','after-operation-journal','after-journal-stage-flush','after-journal-publish','after-parent-flush','during-rollback','before-committed-cleanup')
    if(-not[string]::IsNullOrEmpty($ConfiguredName)-and $ConfiguredName -cnotin $allowed){throw "Unknown Agent environment failpoint '$ConfiguredName'."}
    $trigger=$ConfiguredName -ceq $Name -or ($FailureAfterMutationCount -gt 0 -and $Name -ceq 'after-operation-journal' -and $MutationCount -ge $FailureAfterMutationCount)
    if($trigger){
        if([string]$env:AI_INSTRUCTIONS_USER_RECONCILER_FAILFAST -ceq $Name){[Environment]::FailFast("Injected USER reconciler FailFast at $Name.")}
        throw "Injected Agent environment transaction failure at $Name."
    }
}

function New-AgentEnvironmentPlatformOperation {
    param([int]$Sequence,[string]$Kind,[string]$Target,[string]$StageLeaf,[string]$BackupLeaf,[string]$QuarantineLeaf,$Original,$Applied,$Permissions)
    [pscustomobject][ordered]@{sequence=$Sequence;kind=$Kind;method=$(if($Kind-ceq'remove-file'){'tombstone-rename'}else{'stage-rename'});targetRelativePath=$Target;stageLeaf=$StageLeaf;backupLeaf=$BackupLeaf;quarantineLeaf=$QuarantineLeaf;original=$Original;backupIdentity=$(if([bool]$Original.exists){$Original.identity}else{$null});applied=$Applied;permissions=$Permissions;state='pending'}
}

function Assert-AgentEnvironmentProjectionVolumes {
    param([string]$Home,[object]$DesiredState)
    $homeFull = [IO.Path]::GetFullPath($Home).TrimEnd([char[]]@('\','/'))
    $homePhysical=if(Test-Path -LiteralPath $homeFull){Resolve-PlatformPhysicalPath -Path $homeFull}else{$homeFull};$homeVolume=[IO.Path]::GetPathRoot([string]$homePhysical)
    $roots=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($file in @($DesiredState.Files)){$segments=@(([string]$file.targetPath).Split('/'));if($segments.Count-ge2){[void]$roots.Add("$($segments[0])/$($segments[1])")}}
    foreach($relative in $roots){
        $path=Get-AgentEnvironmentFullPath $homeFull $relative
        $existing=$path
        while(-not(Test-Path -LiteralPath $existing)){
            $parent=[IO.Path]::GetDirectoryName($existing)
            if([string]::IsNullOrEmpty($parent)-or-not$parent.StartsWith($homeFull,(Get-AgentEnvironmentPathComparison))){$existing=$homeFull;break}
            $existing=$parent
        }
        $physical=if(Test-Path -LiteralPath $existing){Resolve-PlatformPhysicalPath -Path $existing}else{$existing}
        $volume=[IO.Path]::GetPathRoot([string]$physical)
        if(-not[string]::Equals($homeVolume,$volume,[StringComparison]::OrdinalIgnoreCase)){throw (New-AiInstructionsRefusalException -Code 'capability-unavailable' -Message "USER projection '$relative' is not on the USER-home volume.")}
    }
}

function Get-AgentEnvironmentFilePermissionSnapshot {
    param([string]$Home,[string]$RelativePath)
    $full=Get-AgentEnvironmentFullPath $Home $RelativePath;$parentRelative=[IO.Path]::GetDirectoryName($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)).Replace('\','/');$parent=$null;$file=$null
    try{$parent=Open-AgentEnvironmentDirectoryLease $Home $parentRelative;$file=Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access Read -CreateMode OpenExisting;return ConvertTo-AgentEnvironmentPermissionSnapshot (Get-PlatformPermissions -Lease $file)}finally{if($null-ne$file){$file.Dispose()};if($null-ne$parent){$parent.Dispose()}}
}

function Set-AgentEnvironmentJournalTargetPermissions {
    param([string]$Home,[object]$Operation)
    if($null-eq$Operation.permissions){return}
    $relative=[string]$Operation.targetRelativePath;$full=Get-AgentEnvironmentFullPath $Home $relative;$parentRelative=[IO.Path]::GetDirectoryName($relative.Replace('/',[IO.Path]::DirectorySeparatorChar)).Replace('\','/');$parent=$null;$file=$null
    try{$parent=Open-AgentEnvironmentDirectoryLease $Home $parentRelative;$file=Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access ReadWrite -CreateMode OpenExisting;Set-PlatformPermissions -Lease $file -Snapshot $Operation.permissions|Out-Null}finally{if($null-ne$file){$file.Dispose()};if($null-ne$parent){$parent.Dispose()}}
}

function Invoke-AgentEnvironmentJournalRollback {
    param([string]$Home,[string]$TransactionPath,$TransactionLease,[object]$Journal,[string]$FailpointName)
    $Journal.phase='rolling-back';Write-AgentEnvironmentInstallJournal $TransactionPath $Journal
    $operations=[object[]]@($Journal.operations);[array]::Reverse($operations)
    foreach($operation in $operations){
        if([string]$operation.state -cne 'applied'){continue}
        Invoke-AgentEnvironmentFailpoint -Name 'during-rollback' -ConfiguredName $FailpointName -MutationCount 0 -FailureAfterMutationCount 0
        $relative=[string]$operation.targetRelativePath;$parentRelative=[IO.Path]::GetDirectoryName($relative.Replace('/',[IO.Path]::DirectorySeparatorChar)).Replace('\','/');$leaf=([string]$relative).Split('/')[-1];$parent=$null
        try{
            $parent=Open-AgentEnvironmentDirectoryLease $Home $parentRelative
            switch([string]$operation.kind){
                'create-directory'{Move-PlatformOwnedDirectory -SourceParentLease $parent -SourceLeaf $leaf -DestinationParentLease $TransactionLease -DestinationLeaf ([string]$operation.quarantineLeaf) -ExpectedState $operation.applied|Out-Null}
                'create-file'{Remove-PlatformOwnedFile -ParentLease $parent -Leaf $leaf -ExpectedState $operation.applied -TransactionLease $TransactionLease -TombstoneLeaf ("rollback-$($operation.sequence)")|Out-Null}
                'write-file'{
                    Remove-PlatformOwnedFile -ParentLease $parent -Leaf $leaf -ExpectedState $operation.applied -TransactionLease $TransactionLease -TombstoneLeaf ("rollback-$($operation.sequence)")|Out-Null
                    $backup=Open-PlatformFile -ParentLease $TransactionLease -Leaf ([string]$operation.backupLeaf) -Access Read -CreateMode OpenExisting
                    Publish-PlatformFile -ParentLease $parent -Leaf $leaf -TransactionLease $TransactionLease -StageLease $backup -ExpectedState ([pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}) -ExpectedStage $operation.original -NoReplace|Out-Null
                    Set-AgentEnvironmentJournalTargetPermissions $Home $operation
                }
                'remove-file'{
                    $backup=Open-PlatformFile -ParentLease $TransactionLease -Leaf ([string]$operation.backupLeaf) -Access Read -CreateMode OpenExisting
                    Publish-PlatformFile -ParentLease $parent -Leaf $leaf -TransactionLease $TransactionLease -StageLease $backup -ExpectedState ([pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}) -ExpectedStage $operation.original -NoReplace|Out-Null
                    Set-AgentEnvironmentJournalTargetPermissions $Home $operation
                }
            }
            $operation.state='rolled-back';Write-AgentEnvironmentInstallJournal $TransactionPath $Journal
        }finally{if($null-ne$parent){$parent.Dispose()}}
    }
    $Journal.phase='rolled-back';Write-AgentEnvironmentInstallJournal $TransactionPath $Journal
}

function Invoke-AgentEnvironmentPlatformTransaction {
    param([string]$Home,[object]$DesiredState,[hashtable]$Writes,[hashtable]$Deletes,[hashtable]$StagedSnapshots,[byte[]]$ManifestBytes,[string]$ManifestSha,[int]$FailureAfterMutationCount,[string]$FailpointName)
    $transactionId=[guid]::NewGuid().ToString('N');$transactionRelative=".ai-instructions-txn/$transactionId";$transactionPath=Get-AgentEnvironmentFullPath $Home $transactionRelative
    $transactionLease=$null;$transactionContainerLease=$null;$journal=$null;$mutationCount=0
    try{
        $transactionLease=Open-PlatformDirectory -Root $Home -RelativePath $transactionRelative -CreatePrivate
        $transactionContainerLease=Open-PlatformDirectory -Root $Home -RelativePath '.ai-instructions-txn'
        $allWrites=@{};foreach($key in $Writes.Keys){$allWrites[$key]=[pscustomobject]@{bytes=[byte[]]$StagedSnapshots[$key].bytes;sha256=[string]$Writes[$key].sha256}}
        $allWrites['.agents/catalog-skills.manifest.json']=[pscustomobject]@{bytes=$ManifestBytes;sha256=$ManifestSha}
        $directoryGroups=@{};$fileWritePaths=New-Object Collections.Generic.List[string]
        foreach($path in @($allWrites.Keys)){
            $segments=@($path.Split('/'));$current='';$missing=$null
            for($i=0;$i-lt$segments.Count-1;$i++){$current=if($current){"$current/$($segments[$i])"}else{$segments[$i]};$full=Get-AgentEnvironmentFullPath $Home $current;if(-not(Test-Path -LiteralPath $full)){ $missing=$current;break };$item=Get-Item -Force -LiteralPath $full;if(-not$item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Unsafe target ancestor: $current"}}
            if($null-eq$missing){$fileWritePaths.Add($path)}else{if(-not$directoryGroups.ContainsKey($missing)){$directoryGroups[$missing]=New-Object Collections.Generic.List[string]};$directoryGroups[$missing].Add($path)}
        }
        $operations=New-Object Collections.Generic.List[object];$sequence=0
        foreach($path in @($Deletes.Keys|Sort-Object)){$sequence++;$original=Get-AgentEnvironmentFileJournalState $Home $path;$permissions=Get-AgentEnvironmentFilePermissionSnapshot $Home $path;$operations.Add((New-AgentEnvironmentPlatformOperation $sequence 'remove-file' $path $null ("backup-$sequence") $null $original ([pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}) $permissions))}
        foreach($root in @($directoryGroups.Keys|Sort-Object)){
            $sequence++;$stageLeaf="directory-$sequence";$stagePath=Join-Path $transactionPath $stageLeaf;New-Item -ItemType Directory -Path $stagePath|Out-Null
            foreach($path in $directoryGroups[$root]){$suffix=$path.Substring($root.Length).TrimStart('/');$destination=Join-Path $stagePath $suffix.Replace('/',[IO.Path]::DirectorySeparatorChar);New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination))|Out-Null;[IO.File]::WriteAllBytes($destination,[byte[]]$allWrites[$path].bytes)}
            $stageState=Get-AgentEnvironmentDirectoryJournalState $transactionPath $stageLeaf
            $operations.Add((New-AgentEnvironmentPlatformOperation $sequence 'create-directory' $root $stageLeaf $null ("quarantine-$sequence") ([pscustomobject][ordered]@{exists=$false;identity=$null;inventorySha256=$null;entryCount=$null}) $stageState $null))
        }
        $orderedFileWrites=@($fileWritePaths|Where-Object{$_-cne'.agents/catalog-skills.manifest.json'}|Sort-Object)+@($fileWritePaths|Where-Object{$_-ceq'.agents/catalog-skills.manifest.json'})
        foreach($path in $orderedFileWrites){
            $sequence++;$stageLeaf="file-$sequence.stage";$stagePath=Join-Path $transactionPath $stageLeaf;[IO.File]::WriteAllBytes($stagePath,[byte[]]$allWrites[$path].bytes)
            $stageLease=Open-PlatformFile -ParentLease $transactionLease -Leaf $stageLeaf -Access Read -CreateMode OpenExisting
            try{$stageObserved=Assert-PlatformFileIdentity -Lease $stageLease -Expected $stageLease.Observation -SingleLink;$applied=[pscustomobject][ordered]@{exists=$true;sha256=[string]$allWrites[$path].sha256;length=[int64]$stageObserved.Size;identity=(ConvertTo-AgentEnvironmentPlatformIdentity $stageObserved)}}finally{$stageLease.Dispose()}
            $original=Get-AgentEnvironmentFileJournalState $Home $path;$kind=if($original.exists){'write-file'}else{'create-file'};$permissions=if($original.exists){Get-AgentEnvironmentFilePermissionSnapshot $Home $path}else{$null};$backup=if($original.exists){"backup-$sequence"}else{$null}
            $operations.Add((New-AgentEnvironmentPlatformOperation $sequence $kind $path $stageLeaf $backup $null $original $applied $permissions))
        }
        $manifestPath=Get-AgentEnvironmentFullPath $Home '.agents/catalog-skills.manifest.json';$previousHash=if(Test-Path -LiteralPath $manifestPath){Get-AgentEnvironmentSha256 $manifestPath}else{'0'*64}
        $platform=Get-CurrentPlatformName;$architecture=if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()-ceq'Arm64'){'arm64'}else{'x64'}
        $journal=New-AiInstructionsInstallJournalV1 -TransactionId $transactionId -OwnerComponent 'user-reconciler' -OwnerProcessId $PID -OwnerProcessStartIdentity (Get-AgentEnvironmentProcessStartIdentity) -PlatformOs $platform -PlatformArchitecture $architecture -LockPrimitive $(if($platform-ceq'windows'){'windows-fileshare'}else{'flock'}) -LockLeaf 'update-agent-environment.lock' -PreviousBundleSha256 $previousHash -CandidateBundleSha256 $ManifestSha -Phase 'prepared' -Operations ([object[]]$operations.ToArray())
        Write-AgentEnvironmentInstallJournal $transactionPath $journal;Invoke-AgentEnvironmentFailpoint 'after-journal-publish' $FailpointName $mutationCount $FailureAfterMutationCount
        $journal.phase='applying';Write-AgentEnvironmentInstallJournal $transactionPath $journal
        foreach($operation in $journal.operations){
            $relative=[string]$operation.targetRelativePath;$parentRelative=[IO.Path]::GetDirectoryName($relative.Replace('/',[IO.Path]::DirectorySeparatorChar)).Replace('\','/');$leaf=$relative.Split('/')[-1];$parent=$null
            try{$parent=Open-AgentEnvironmentDirectoryLease $Home $parentRelative
                switch([string]$operation.kind){
                    'create-directory'{Move-PlatformOwnedDirectory -SourceParentLease $transactionLease -SourceLeaf ([string]$operation.stageLeaf) -DestinationParentLease $parent -DestinationLeaf $leaf -ExpectedState $operation.applied|Out-Null}
                    'remove-file'{Remove-PlatformOwnedFile -ParentLease $parent -Leaf $leaf -ExpectedState $operation.original -TransactionLease $transactionLease -TombstoneLeaf ([string]$operation.backupLeaf) -Journal $operation|Out-Null}
                    default{$stage=Open-PlatformFile -ParentLease $transactionLease -Leaf ([string]$operation.stageLeaf) -Access Read -CreateMode OpenExisting;Publish-PlatformFile -ParentLease $parent -Leaf $leaf -TransactionLease $transactionLease -StageLease $stage -ExpectedState $operation.original -DisplacedLeaf $operation.backupLeaf -ExpectedStage $operation.applied -NoReplace:([string]$operation.kind-ceq'create-file') -Journal $operation|Out-Null}
                }
                $operation.state='applied';$mutationCount++;Write-AgentEnvironmentInstallJournal $transactionPath $journal
                Invoke-AgentEnvironmentFailpoint 'after-original-rename' $FailpointName $mutationCount $FailureAfterMutationCount
                Invoke-AgentEnvironmentFailpoint 'after-applied-rename' $FailpointName $mutationCount $FailureAfterMutationCount
                Invoke-AgentEnvironmentFailpoint 'after-parent-flush' $FailpointName $mutationCount $FailureAfterMutationCount
                Invoke-AgentEnvironmentFailpoint 'after-operation-journal' $FailpointName $mutationCount $FailureAfterMutationCount
            }finally{if($null-ne$parent){$parent.Dispose()}}
        }
        $journal.phase='applied';Write-AgentEnvironmentInstallJournal $transactionPath $journal
        foreach($file in $DesiredState.Files){$full=Assert-AgentEnvironmentPathSafe $Home ([string]$file.targetPath);if(-not(Test-Path -LiteralPath $full -PathType Leaf)-or(Get-AgentEnvironmentSha256 $full)-cne[string]$file.sha256){throw "Final user Skill inventory verification failed: $($file.targetPath)"}}
        foreach($path in $Deletes.Keys){if(Test-Path -LiteralPath (Get-AgentEnvironmentFullPath $Home $path)){throw "Retired managed path still exists after cleanup: $path"}}
        if((Get-AgentEnvironmentSha256 $manifestPath)-cne$ManifestSha){throw 'Final user Skills manifest byte verification failed.'}
        $journal.phase='committed';Write-AgentEnvironmentInstallJournal $transactionPath $journal;Invoke-AgentEnvironmentFailpoint 'before-committed-cleanup' $FailpointName $mutationCount $FailureAfterMutationCount
        $transactionLease.Dispose();$transactionLease=$null;Remove-PlatformOwnedDirectoryTree -ParentLease $transactionContainerLease -Leaf $transactionId|Out-Null
        return [pscustomobject]@{success=$true;transactionPath=$transactionPath;journal=$journal}
    }catch{
        $failure=$_
        if($null-ne$journal){try{Invoke-AgentEnvironmentJournalRollback $Home $transactionPath $transactionLease $journal $FailpointName}catch{$rollbackFailure=[IO.IOException]::new("Agent environment transaction failed: $($failure.Exception.Message) Rollback failed: $($_.Exception.Message)",$_.Exception);$rollbackFailure.Data['Code']='recovery-required';$rollbackFailure.Data['TransactionPath']=$transactionPath;throw $rollbackFailure}}
        if($null-ne$transactionLease){$transactionLease.Dispose();$transactionLease=$null}
        if(Test-Path -LiteralPath $transactionPath){Remove-PlatformOwnedDirectoryTree -ParentLease $transactionContainerLease -Leaf $transactionId|Out-Null}
        throw $failure
    }finally{if($null-ne$transactionLease){$transactionLease.Dispose()};if($null-ne$transactionContainerLease){$transactionContainerLease.Dispose()}}
}

function Get-AgentEnvironmentDirectoryPermissionSnapshot {
    param([string]$Home,[string]$RelativePath)
    $lease=$null;try{$lease=Open-PlatformDirectory -Root $Home -RelativePath $RelativePath;return ConvertTo-AgentEnvironmentPermissionSnapshot (Get-PlatformPermissions $lease)}finally{if($null-ne$lease){$lease.Dispose()}}
}

function Get-AgentEnvironmentRecoveryObservation {
    param([string]$Home,[string]$TransactionPath,[object]$Operation)
    $directoryOperation=[string]$Operation.kind-in@('swap-directory','create-directory')
    $target=if($directoryOperation){Get-AgentEnvironmentDirectoryJournalState $Home ([string]$Operation.targetRelativePath)}else{Get-AgentEnvironmentFileJournalState $Home ([string]$Operation.targetRelativePath)}
    $permissions=if($target.exists){if($directoryOperation){Get-AgentEnvironmentDirectoryPermissionSnapshot $Home ([string]$Operation.targetRelativePath)}else{Get-AgentEnvironmentFilePermissionSnapshot $Home ([string]$Operation.targetRelativePath)}}else{$null}
    $backup=$null
    if($null-ne$Operation.backupLeaf){$backup=if($directoryOperation){Get-AgentEnvironmentDirectoryJournalState $TransactionPath ([string]$Operation.backupLeaf)}else{Get-AgentEnvironmentPrivateFileJournalState $TransactionPath ([string]$Operation.backupLeaf)}}
    $data=[ordered]@{exists=[bool]$target.exists}
    if($directoryOperation){$data.identity=$target.identity;$data.inventorySha256=$target.inventorySha256;$data.entryCount=$target.entryCount}else{$data.sha256=$target.sha256;$data.length=$target.length;$data.identity=$target.identity}
    $data.permissions=$permissions;$data.backup=$backup;return [pscustomobject]$data
}

function New-AgentEnvironmentInterruptedResult {
    param([string]$Message)
    $detail=New-AgentEnvironmentFailureDetail -Code 'interrupted-install' -SkillId 'transaction' -Path '.ai-instructions-txn' -Classification 'controlled-candidate' -Owner 'transaction-journal' -Evidence $Message -DestructiveChangeAllowed $false -BackupCreated $true -ExpectedSha256 $null -ActualSha256 $null -Remediation @('Preserve the transaction evidence and run recovery with the verified USER reconciler.')
    [pscustomobject][ordered]@{schemaVersion=1;outcome='failed';exitCode=1;Code='interrupted-install';catalogCommit=$null;catalogLockSha256=$null;installed=@();updated=@();removed=@();preserved=@();failed=@($Message);failureDetails=@($detail);ownership=@();rollbackState='recovery-required';backupPath=$null;licenseWarnings=@()}
}

function Test-AgentEnvironmentInstallReadLease {
    param([object] $Lease)
    return $Lease -is [IO.FileStream] -and $Lease.CanRead -and
        [IO.Path]::GetFileName([string]$Lease.Name) -ceq 'ai-instructions-install.lock'
}

function Invoke-AgentEnvironmentNewJournalRecoveryLocked {
    param([string]$Home,[ValidateSet('Apply','VerifyOnly','WhatIf')][string]$Mode='Apply')
    $root=Join-Path $Home '.ai-instructions-txn'
    if(-not(Test-Path -LiteralPath $root)){return [pscustomobject]@{outcome='nothing-to-recover';exitCode=0}}
    $rootItem=Get-Item -Force -LiteralPath $root
    if(-not$rootItem.PSIsContainer-or($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return New-AgentEnvironmentInterruptedResult 'USER transaction root is not a physical directory.'}
    $entries=@(Get-ChildItem -Force -LiteralPath $root)
    if($entries.Count-eq0){return [pscustomobject]@{outcome='nothing-to-recover';exitCode=0}}
    if($Mode-cne'Apply'){return New-AgentEnvironmentInterruptedResult 'USER transaction residue requires Apply recovery before read-only reconciliation.'}
    $containerLease=$null
    try{
        $containerLease=Open-PlatformDirectory -Root $Home -RelativePath '.ai-instructions-txn'
        foreach($entry in $entries){
            $journalPath=Join-Path $entry.FullName 'journal.json';$previousPath=Join-Path $entry.FullName 'journal.prev'
            $classification=Get-AiInstructionsInstallTransactionClassification -Name $entry.Name -EntryKind $(if($entry.PSIsContainer){'directory'}else{'other'}) -JournalEntryKind $(if(Test-Path -LiteralPath $journalPath -PathType Leaf){'file'}elseif(Test-Path -LiteralPath $journalPath){'other'}else{$null}) -JournalJson $(if(Test-Path -LiteralPath $journalPath -PathType Leaf){Get-Content -Raw -Encoding UTF8 $journalPath}else{$null}) -PreviousJournalEntryKind $(if(Test-Path -LiteralPath $previousPath -PathType Leaf){'file'}elseif(Test-Path -LiteralPath $previousPath){'other'}else{$null}) -PreviousJournalJson $(if(Test-Path -LiteralPath $previousPath -PathType Leaf){Get-Content -Raw -Encoding UTF8 $previousPath}else{$null})
            if([string]$classification.classification-ceq'orphan-without-journal'){Remove-PlatformOwnedDirectoryTree -ParentLease $containerLease -Leaf $entry.Name|Out-Null;continue}
            if([string]$classification.classification-cne'valid-journal'-or[string]$classification.journal.owner.component-cne'user-reconciler'){return New-AgentEnvironmentInterruptedResult "USER transaction residue '$($entry.Name)' is malformed or not owned by user-reconciler."}
            $journal=$classification.journal;$transactionLease=$null
            try{
                $transactionLease=Open-PlatformDirectory -Root $Home -RelativePath ".ai-instructions-txn/$($entry.Name)"
                $observations=@{};foreach($operation in $journal.operations){$observations[[string]$operation.sequence]=Get-AgentEnvironmentRecoveryObservation $Home $entry.FullName $operation}
                $decision=Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
                if([string]$decision.action-ceq'refuse'){return New-AgentEnvironmentInterruptedResult "USER transaction residue '$($entry.Name)' does not have sufficient exact recovery evidence."}
                if([string]$decision.action-ceq'roll-back'){
                    foreach($operationDecision in $decision.operations){
                        $operation = $journal.operations[[int]$operationDecision.sequence - 1]
                        if([string]$operationDecision.action-in@('restore-original','remove-applied')){$operation.state='applied'}
                        elseif([string]$operationDecision.action-ceq'restore-permissions'){Set-AgentEnvironmentJournalTargetPermissions $Home $operation;$operation.state='rolled-back'}
                        elseif([string]$operationDecision.action-ceq'none'){$operation.state='rolled-back'}
                    }
                    Invoke-AgentEnvironmentJournalRollback $Home $entry.FullName $transactionLease $journal ''
                }elseif([string]$decision.action-ceq'commit'){$journal.phase='committed';Write-AgentEnvironmentInstallJournal $entry.FullName $journal}
                $transactionLease.Dispose();$transactionLease=$null;Remove-PlatformOwnedDirectoryTree -ParentLease $containerLease -Leaf $entry.Name|Out-Null
            }finally{if($null-ne$transactionLease){$transactionLease.Dispose()}}
        }
        return [pscustomobject]@{outcome='recovered';exitCode=0;rollbackState='completed'}
    }finally{if($null-ne$containerLease){$containerLease.Dispose()}}
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
        [string] $FailpointName,
        [object] $InstallReadLease,
        [scriptblock] $BeforeLockAcquisitionAction,
        [scriptblock] $BeforeBackupValidationAction
    )
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot ([string]$DesiredState.RuntimeRoot)
    $home = [System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\','/'))
    Assert-AgentEnvironmentProjectionVolumes -Home $home -DesiredState $DesiredState
    $agentsRoot = Join-Path $home '.agents'
    $skillsRoot = Join-Path $agentsRoot 'skills'
    if ((Test-Path -LiteralPath $agentsRoot) -and ((Get-Item -Force -LiteralPath $agentsRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'User .agents root must not be a reparse point.' }
    if ((Test-Path -LiteralPath $skillsRoot) -and ((Get-Item -Force -LiteralPath $skillsRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'User Skills root must not be a reparse point.' }
    $lockPath = Join-Path $agentsRoot 'update-agent-environment.lock'
    $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
    $journalRelative = '.agents/update-agent-environment.recovery.json'
    $manifestRelative = '.agents/catalog-skills.manifest.json'
    $manifestPath = Get-AgentEnvironmentFullPath -Root $home -RelativePath $manifestRelative
    $existingManifestSnapshot = Get-AgentEnvironmentManifestSnapshot -Root $home -RelativePath $manifestRelative
    $existingManifestIdentity = $existingManifestSnapshot.Identity
    if ((Test-Path -LiteralPath $journalPath) -and $Mode -ne 'Apply') {
        Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $journalRelative | Out-Null
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'Agent environment recovery journal path must be a file.' }
        return New-AgentEnvironmentInterruptedResult 'A legacy Agent environment transaction requires Apply recovery before read-only reconciliation.'
    }
    $newTransactionRoot=Join-Path $home '.ai-instructions-txn'
    $hasNewTransactionResidue=(Test-Path -LiteralPath $newTransactionRoot)-and(@(Get-ChildItem -Force -LiteralPath $newTransactionRoot -ErrorAction Stop).Count-gt0)
    if($hasNewTransactionResidue-and$Mode-cne'Apply'){return New-AgentEnvironmentInterruptedResult 'USER transaction residue requires Apply recovery before read-only reconciliation.'}

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
            $failureEvidence = "Rejected target path '$targetPath'. $($_.Exception.Message)"
            $failed.Add("Controlled candidate target path is unsafe: $targetPath")
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'unsafe-target-path' -SkillId ([string]$file.skillId) -Path '.agents/skills/<rejected-target-path>' -Classification 'controlled-candidate' -Owner 'desired-state-staged-inventory' -Evidence $failureEvidence -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 ([string]$file.sha256) -ActualSha256 $null -Remediation @('Rebuild the desired state with a repository-relative .agents/skills path.','Do not apply a candidate containing an absolute, traversal, or reparse-backed target path.')))
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
    $lockParentLease = $null
    try {
        try {
            if ($null -ne $BeforeLockAcquisitionAction) { & $BeforeLockAcquisitionAction }
            if ($Mode -eq 'Apply' -or (Test-Path -LiteralPath $agentsRoot -PathType Container)) {
                $lockParentLease=Open-PlatformDirectory -Root $home -RelativePath '.agents'
                $lockStream=Enter-PlatformLock -ParentLease $lockParentLease -Leaf 'update-agent-environment.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            }
        }
        catch [System.IO.IOException] { return New-AgentEnvironmentResult -Outcome 'concurrent' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved @() -Failed @('Another Agent environment update is already running.') -RollbackState 'not-started' -BackupPath $null }
        catch [TimeoutException] { return New-AgentEnvironmentResult -Outcome 'concurrent' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved @() -Failed @('Another Agent environment update is already running.') -RollbackState 'not-started' -BackupPath $null }
        $hasLegacyResidue=Test-Path -LiteralPath $journalPath
        $hasNewTransactionResidue=(Test-Path -LiteralPath $newTransactionRoot)-and(@(Get-ChildItem -Force -LiteralPath $newTransactionRoot -ErrorAction Stop).Count-gt0)
        if($Mode-eq'Apply'-and$hasLegacyResidue-and$hasNewTransactionResidue){return New-AgentEnvironmentInterruptedResult 'Legacy and install-journal USER transaction residues coexist; recovery refused before mutation.'}
        if($Mode-eq'Apply'-and$hasLegacyResidue){
            $legacyRecovery=Invoke-UserSkillsRecovery -UserHome $home -ExistingLock $lockStream -InstallReadLease $InstallReadLease
            if([string]$legacyRecovery.outcome-ceq'failed'-or[string]$legacyRecovery.outcome-ceq'concurrent'){return $legacyRecovery}
        }
        if($Mode-eq'Apply'-and$hasNewTransactionResidue){
            if(-not(Test-AgentEnvironmentInstallReadLease $InstallReadLease)){return New-AgentEnvironmentInterruptedResult 'USER install-journal recovery requires stable-launcher validation and the install read lease.'}
            $newRecovery=Invoke-AgentEnvironmentNewJournalRecoveryLocked -Home $home -Mode Apply
            if([string]$newRecovery.outcome-ceq'failed'){return $newRecovery}
        }
        if($Mode-eq'Apply'-and($hasLegacyResidue-or$hasNewTransactionResidue)){$existingManifestIdentity=(Get-AgentEnvironmentManifestSnapshot -Root $home -RelativePath $manifestRelative).Identity}
        if (Test-Path -LiteralPath $manifestPath) {
            Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $manifestRelative | Out-Null
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'User Skills managed manifest path must be a file.' }
        }
        $manifestObservation = Get-AgentEnvironmentObservedState -Root $home -RelativePath $manifestRelative
        $lockedManifestSnapshot = Get-AgentEnvironmentManifestSnapshot -Root $home -RelativePath $manifestRelative
        $existing = $lockedManifestSnapshot.Manifest
        $lockedManifestIdentity = $lockedManifestSnapshot.Identity
        if ($existingManifestIdentity -cne $lockedManifestIdentity) {
            return New-AgentEnvironmentResult -Outcome 'concurrent' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved @() -Failed @('User Skills managed manifest changed while acquiring the Agent environment lock.') -RollbackState 'not-started' -BackupPath $null
        }
        if($null-ne$existing-and[int64]$existing.schemaVersion-eq3-and[int64]$DesiredState.Manifest.schemaVersion-lt3){
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'downgrade-refused' -SkillId 'managed-manifest' -Path $manifestRelative -Classification 'managed' -Owner 'managed-manifest-v3' -Evidence 'A legacy writer cannot replace a USER coordinator manifest v3.' -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $null -ActualSha256 $null -Remediation @('Use the projection-aware USER reconciler.')))
            return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved @() -Failed @('USER managed manifest downgrade refused.') -RollbackState 'not-started' -BackupPath $null -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership @()
        }
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
            $manifestSchemaVersion = if ($null -ne $existing.PSObject.Properties['schemaVersion']) { [string]$existing.schemaVersion } else { 'unknown' }
            $ownership.Add((New-AgentEnvironmentOwnershipEvidence -SkillId ([string]$oldByPath[$path].skillId) -Path $path -Classification $managedClassification -Owner "managed-manifest-v$manifestSchemaVersion" -Evidence ("Validated .agents/catalog-skills.manifest.json schemaVersion $manifestSchemaVersion entry; expected SHA-256 $managedExpected, observed SHA-256 $managedActual.") -DestructiveChangeAllowed $managedDestructiveAllowed -Operation $managedOperation))
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
        if($manifestMatches-and[int64]$DesiredState.Manifest.schemaVersion-eq3){
            $manifestMatches=[int64]$existing.schemaVersion-eq3-and[string]$existing.projectionContractSha256-ceq[string]$DesiredState.Manifest.projectionContractSha256-and
                ((@($existing.projections)-join"`n")-ceq(@($DesiredState.Manifest.projections)-join"`n"))
        }
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
        $desiredManifestVersion=[int64]$DesiredState.Manifest.schemaVersion
        if($null-ne$existing-and[int64]$existing.schemaVersion-eq3-and$desiredManifestVersion-lt3){
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code 'downgrade-refused' -SkillId 'managed-manifest' -Path $manifestRelative -Classification 'managed' -Owner 'managed-manifest-v3' -Evidence 'A legacy writer cannot replace a USER coordinator manifest v3.' -DestructiveChangeAllowed $false -BackupCreated $false -ExpectedSha256 $null -ActualSha256 $null -Remediation @('Use the projection-aware USER reconciler.')))
            return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved $preserved -Failed @('USER managed manifest downgrade refused.') -RollbackState 'not-started' -BackupPath $null -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership ([object[]]$ownership.ToArray())
        }
        if($desiredManifestVersion-eq3){
            $nextGeneration=1
            if($null-ne$existing-and[int64]$existing.schemaVersion-eq3){
                if([int64]$existing.generation-ge[long]::MaxValue){throw 'USER managed manifest generation reached its maximum value.'}
                $nextGeneration=[int64]$existing.generation+1
            }
            $DesiredState.Manifest.generation=$nextGeneration
            Assert-UserSkillsManagedManifestBinding -Manifest $DesiredState.Manifest -CatalogBytes ([byte[]]$DesiredState.CatalogBytes) -LockBytes ([byte[]]$DesiredState.LockBytes) -ExpectedCatalogRepository ([string]$DesiredState.Manifest.catalogRepository) -ExpectedCatalogCommit ([string]$DesiredState.Manifest.catalogCommit)|Out-Null
            $manifestBytes=Get-AgentEnvironmentManifestBytes $DesiredState.Manifest;$manifestSha=Get-AgentEnvironmentBytesSha256 $manifestBytes
        }
        try{
            $transactionResult=Invoke-AgentEnvironmentPlatformTransaction -Home $home -DesiredState $DesiredState -Writes $writes -Deletes $deletes -StagedSnapshots $stagedSnapshots -ManifestBytes $manifestBytes -ManifestSha $manifestSha -FailureAfterMutationCount $FailureAfterMutationCount -FailpointName $FailpointName
            return New-AgentEnvironmentResult -Outcome 'applied' -DesiredState $DesiredState -Installed $installed -Updated $updated -Removed $removed -Preserved $preserved -Failed @() -RollbackState 'not-needed' -BackupPath $null -FailureDetails @() -Ownership ([object[]]$ownership.ToArray())
        }catch{
            $recoveryRequired=$_.Exception.Data.Contains('Code')-and[string]$_.Exception.Data['Code']-ceq'recovery-required'
            $code=if($recoveryRequired){'recovery-required'}else{'mutation-failure'}
            $retainedPath=if($recoveryRequired){[string]$_.Exception.Data['TransactionPath']}else{$null}
            $failureDetails.Add((New-AgentEnvironmentFailureDetail -Code $code -SkillId 'transaction' -Path '.ai-instructions-txn' -Classification 'controlled-candidate' -Owner 'transaction-journal' -Evidence ([string]$_.Exception.Message) -DestructiveChangeAllowed $false -BackupCreated $recoveryRequired -ExpectedSha256 $manifestSha -ActualSha256 $null -Remediation @('Review the transaction evidence and retry after recovery.')))
            return New-AgentEnvironmentResult -Outcome 'failed' -DesiredState $DesiredState -Installed @() -Updated @() -Removed @() -Preserved $preserved -Failed @([string]$_.Exception.Message) -RollbackState $(if($recoveryRequired){'recovery-required'}else{'completed'}) -BackupPath $retainedPath -FailureDetails ([object[]]$failureDetails.ToArray()) -Ownership ([object[]]$ownership.ToArray())
        }
    }
    finally { if ($null -ne $lockStream) { $lockStream.Dispose() }; if($null-ne$lockParentLease){$lockParentLease.Dispose()} }
}

function Invoke-UserSkillsRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $UserHome,
        [object] $ExistingLock,
        [object] $InstallReadLease,
        [scriptblock] $BeforeLockAcquisitionAction
    )
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot $PSScriptRoot
    $home = [System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\','/'))
    $agentsRoot = Join-Path $home '.agents'
    $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
    $lockPath = Join-Path $agentsRoot 'update-agent-environment.lock'
    $manifestPath = Join-Path $agentsRoot 'catalog-skills.manifest.json'
    $journalRelative = '.agents/update-agent-environment.recovery.json'
    $manifestRelative = '.agents/catalog-skills.manifest.json'
    $lockStream = $ExistingLock
    $ownsLock = $null -eq $ExistingLock
    $lockParentLease = $null
    $recoveryBackupPath = $null
    try {
        Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $journalRelative | Out-Null
        $transactionRoot=Join-Path $home '.ai-instructions-txn'
        $hasLegacy=Test-Path -LiteralPath $journalPath
        $hasNew=(Test-Path -LiteralPath $transactionRoot)-and(@(Get-ChildItem -Force -LiteralPath $transactionRoot -ErrorAction Stop).Count-gt0)
        if(-not$hasLegacy-and-not$hasNew){return [pscustomobject][ordered]@{ schemaVersion=1; outcome='nothing-to-recover'; exitCode=0; rollbackState='not-needed' }}
        $existingManifestSnapshot = Get-AgentEnvironmentManifestSnapshot -Root $home -RelativePath $manifestRelative
        if ($hasLegacy -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'Agent environment recovery journal path must be a file.' }
        if (Test-Path -LiteralPath $lockPath) {
            $lockItem = Get-Item -Force -LiteralPath $lockPath
            if ($lockItem.PSIsContainer -or ($lockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Agent environment lock must be a non-reparse file.' }
        }
        try {
            if ($null -ne $BeforeLockAcquisitionAction) { & $BeforeLockAcquisitionAction }
            if($ownsLock){$lockParentLease=Open-PlatformDirectory -Root $home -RelativePath '.agents';$lockStream=Enter-PlatformLock -ParentLease $lockParentLease -Leaf 'update-agent-environment.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)}
        }
        catch { if($_.Exception -is [IO.IOException]-or$_.Exception -is [TimeoutException]){return New-AgentEnvironmentRecoveryConcurrentResult};throw }
        $hasLegacy=Test-Path -LiteralPath $journalPath
        $hasNew=(Test-Path -LiteralPath $transactionRoot)-and(@(Get-ChildItem -Force -LiteralPath $transactionRoot -ErrorAction Stop).Count-gt0)
        if($hasLegacy-and$hasNew){return New-AgentEnvironmentInterruptedResult 'Legacy and install-journal USER transaction residues coexist; recovery refused before mutation.'}
        if($hasNew){if(-not(Test-AgentEnvironmentInstallReadLease $InstallReadLease)){return New-AgentEnvironmentInterruptedResult 'USER install-journal recovery requires stable-launcher validation and the install read lease.'};return Invoke-AgentEnvironmentNewJournalRecoveryLocked -Home $home -Mode Apply}
        if(-not$hasLegacy){return [pscustomobject][ordered]@{ schemaVersion=1; outcome='nothing-to-recover'; exitCode=0; rollbackState='not-needed' }}
        $lockedManifestSnapshot = Get-AgentEnvironmentManifestSnapshot -Root $home -RelativePath $manifestRelative
        if ($existingManifestSnapshot.Identity -cne $lockedManifestSnapshot.Identity) {
            return New-AgentEnvironmentRecoveryConcurrentResult
        }
        Assert-AgentEnvironmentPathSafe -Root $home -RelativePath $journalRelative | Out-Null
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'Agent environment recovery journal path must be a file.' }
        $journal = Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
        $legacyJournalProperties = @('schemaVersion','userHome','backupPath','states')
        $canonicalJournalProperties = @('schemaVersion','transactionId','userHome','backupPath','phase','desiredManifestSha256','desiredInventorySha256','states')
        $actualJournalProperties = @($journal.PSObject.Properties.Name)
        $isLegacyJournal = $actualJournalProperties.Count -eq $legacyJournalProperties.Count -and @($legacyJournalProperties | Where-Object { $actualJournalProperties -cnotcontains $_ }).Count -eq 0
        $isCanonicalJournal = $actualJournalProperties.Count -eq $canonicalJournalProperties.Count -and @($canonicalJournalProperties | Where-Object { $actualJournalProperties -cnotcontains $_ }).Count -eq 0
        if (-not $isLegacyJournal -and -not $isCanonicalJournal) { throw 'Agent environment recovery journal property set is invalid.' }
        if (($journal.schemaVersion -isnot [int] -and $journal.schemaVersion -isnot [long]) -or [long]$journal.schemaVersion -ne 1 -or
            $journal.userHome -isnot [string] -or -not [string]::Equals([string]$journal.userHome,$home,[System.StringComparison]::Ordinal) -or
            $journal.backupPath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$journal.backupPath) -or
            $journal.states -isnot [System.Array] -or @($journal.states).Count -eq 0 -or
            ($isCanonicalJournal -and (
                $journal.transactionId -isnot [string] -or [string]$journal.transactionId -cnotmatch '^[0-9a-f]{32}$' -or
                $journal.phase -isnot [string] -or @('prepared','mutating') -cnotcontains [string]$journal.phase -or
                $journal.desiredManifestSha256 -isnot [string] -or [string]$journal.desiredManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $journal.desiredInventorySha256 -isnot [string] -or [string]$journal.desiredInventorySha256 -cnotmatch '^[0-9a-f]{64}$'))) {
            throw 'Agent environment recovery journal identity or type contract is invalid.'
        }
        $journalBackupRoot = Assert-AgentEnvironmentBackupDirectorySafe -Root $home -Path ([string]$journal.backupPath)
        $recoveryBackupPath = $journalBackupRoot
        $pathComparison = Get-AgentEnvironmentPathComparison
        $pathComparer = if ($pathComparison -eq [System.StringComparison]::OrdinalIgnoreCase) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
        $seenRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' $pathComparer
        $validatedStates = New-Object System.Collections.Generic.List[object]
        foreach ($state in @($journal.states)) {
            $stateProperties = if ($isLegacyJournal) {
                @('relativePath','existed','backupPath','originalSha256','appliedSha256')
            }
            else {
                @('relativePath','existed','backupPath','originalSha256','backupSha256','appliedSha256')
            }
            Assert-AgentEnvironmentExactProperties -Object $state -Required $stateProperties -Context 'Agent environment recovery state'
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
                    (-not $isLegacyJournal -and ($state.backupSha256 -isnot [string] -or [string]$state.backupSha256 -cnotmatch '^[0-9a-f]{64}$'))) {
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
                if (-not $isLegacyJournal -and -not [string]::Equals($validatedBackupSha256,[string]$state.backupSha256,[System.StringComparison]::Ordinal)) {
                    throw "Agent environment recovery state backup SHA-256 does not match its journaled backup identity: $relative"
                }
            }
            elseif ($null -ne $state.backupPath -or $null -ne $state.originalSha256 -or (-not $isLegacyJournal -and $null -ne $state.backupSha256)) {
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
        Remove-AgentEnvironmentRecoveryJournal -Path $journalPath
        return [pscustomobject][ordered]@{ schemaVersion=1; outcome='recovered'; exitCode=0; rollbackState='completed'; backupPath=[string]$journal.backupPath }
    }
    catch {
        if ($_.Exception.Message -ceq 'USER managed manifest schema version 3 requires a projection-aware installer.') { throw }
        return New-AgentEnvironmentRecoveryFailureResult -Message ([string]$_.Exception.Message) -JournalRelative $journalRelative -BackupPath $recoveryBackupPath
    }
    finally { if ($ownsLock -and $null -ne $lockStream) { $lockStream.Dispose() };if($null-ne$lockParentLease){$lockParentLease.Dispose()} }
}

Export-ModuleMember -Function Assert-UserProjectionRuntimeGate, Get-UserSkillsDesiredState, Invoke-UserSkillsReconciliation, Invoke-UserSkillsRecovery
