Set-StrictMode -Version 2.0

function Assert-LicenseRelativePath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path -match '[:\x00-\x1f]' -or
        $Path.StartsWith('/') -or @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_ -match '[. ]$' }).Count -gt 0) {
        throw "Unsafe license source path: $Path"
    }
}

function Test-LicenseDocumentName {
    param([string] $Name)
    return $Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|THIRD_PARTY_NOTICES|PROVENANCE)([-_][^.]+)?(\.(md|txt|rst|html))?$' -or $Name -ieq 'licensing-scope.json'
}

function Get-LicenseAncestorPaths {
    param([string[]] $ArtifactPaths)
    $ancestors = @{ '' = $true }
    foreach ($path in $ArtifactPaths) {
        Assert-LicenseRelativePath $path
        $parent = $path
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            $ancestors[$parent] = $true
        }
    }
    return @($ancestors.Keys | Sort-Object)
}

# Also used on git ls-tree paths, before acquiring the exact installer snapshot.
function Select-LicenseDeliveryDocumentPaths {
    [CmdletBinding()]
    param([string[]] $ArtifactPaths, [string[]] $SourcePaths)
    $ancestors = @(Get-LicenseAncestorPaths $ArtifactPaths)
    foreach ($path in @($SourcePaths | Sort-Object -Unique)) {
        foreach ($ancestor in $ancestors) {
            $prefix = if ($ancestor) { "$ancestor/" } else { '' }
            if (-not $path.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
            $relative = $path.Substring($prefix.Length)
            if (($relative -notmatch '/' -and (Test-LicenseDocumentName $relative)) -or $relative -imatch '^LICENSES/') {
                Assert-LicenseRelativePath $path
                $path
                break
            }
        }
    }
}

function Get-LicenseSafeItem {
    param([string] $Root, [string] $RelativePath)
    $current = $Root
    foreach ($part in @('') + @($RelativePath.Split('/') | Where-Object { $_ })) {
        if ($part) { $current = Join-Path $current $part }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "License source contains a reparse point: $RelativePath"
        }
    }
    return $item
}

function Get-LicenseDirectoryFiles {
    param([string] $Root, [string] $RelativePath)
    $directory = Get-LicenseSafeItem $Root $RelativePath
    foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
        $relative = "$RelativePath/$($child.Name)".TrimStart('/')
        Assert-LicenseRelativePath $relative
        $safe = Get-LicenseSafeItem $Root $relative
        if ($safe.PSIsContainer) { Get-LicenseDirectoryFiles $Root $relative }
        else { $relative }
    }
}

function Get-LicenseBytesHash {
    param([byte[]] $Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function New-LicenseDeliveryPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string[]] $ArtifactPaths,
        [Parameter(Mandatory = $true)][string] $SourceRepository,
        [Parameter(Mandatory = $true)][string] $SourceCommit,
        [Parameter(Mandatory = $true)][string] $ArtifactId
    )
    if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'License delivery requires an immutable source commit.' }
    if ([string]::IsNullOrWhiteSpace($SourceRepository) -or [string]::IsNullOrWhiteSpace($ArtifactId)) { throw 'License delivery requires source and artifact identity.' }
    $root = [IO.Path]::GetFullPath($SourceRoot)
    $paths = @($ArtifactPaths | Sort-Object -Unique)
    if ($paths.Count -eq 0) { throw 'License delivery requires at least one source artifact.' }
    foreach ($path in $paths) {
        Assert-LicenseRelativePath $path
        if ((Get-LicenseSafeItem $root $path).PSIsContainer) { throw "License artifact must be a file: $path" }
    }
    $documents = @{}
    foreach ($ancestor in @(Get-LicenseAncestorPaths $paths)) {
        $directory = Get-LicenseSafeItem $root $ancestor
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            $relative = if ($ancestor) { "$ancestor/$($item.Name)" } else { $item.Name }
            if ($item.Name -ieq 'LICENSES') {
                foreach ($path in @(Get-LicenseDirectoryFiles $root $relative)) { $documents[$path] = $true }
            }
            elseif (Test-LicenseDocumentName $item.Name) {
                Assert-LicenseRelativePath $relative
                $safe = Get-LicenseSafeItem $root $relative
                if (-not $safe.PSIsContainer) { $documents[$relative] = $true }
            }
        }
    }
    if ($documents.Count -eq 0) {
        Write-Warning "License delivery for '$ArtifactId' at $SourceRepository@${SourceCommit}: missing source licensing declarations; no license grant inferred."
        return [pscustomobject]@{ Status = 'missing'; Files = @() }
    }
    $scope = @{}
    if ($documents.ContainsKey('licensing-scope.json')) {
        $scopeDocument = [IO.File]::ReadAllText((Join-Path $root 'licensing-scope.json')) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $scopeDocument.PSObject.Properties['schemaVersion'] -or
            ($scopeDocument.schemaVersion -isnot [int] -and $scopeDocument.schemaVersion -isnot [long]) -or $scopeDocument.schemaVersion -ne 1 -or
            $null -eq $scopeDocument.PSObject.Properties['files'] -or $scopeDocument.files -isnot [array]) { throw 'Unsupported licensing-scope.json contract.' }
        foreach ($entry in @($scopeDocument.files)) {
            if ($null -eq $entry.PSObject.Properties['path'] -or $null -eq $entry.PSObject.Properties['license'] -or
                $entry.path -isnot [string] -or $entry.license -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.license)) { throw 'Invalid licensing scope entry.' }
            Assert-LicenseRelativePath $entry.path
            if ($scope.ContainsKey($entry.path)) { throw "Duplicate licensing scope path: $($entry.path)" }
            $scope[$entry.path] = $entry.license
        }
    }
    $status = 'documents-present'
    $licenseTexts = @($documents.Keys | Where-Object {
        $name = ($_ -split '/')[-1]
        $_ -match '(^|/)LICENSES/' -or ($name -match '^(LICENSE|LICENCE|COPYING)([-_.]|$)' -and $name -notmatch '^LICENSE[-_]SCOPE([.]|$)')
    })
    if ($licenseTexts.Count -eq 0) {
        $status = 'unconfirmed'
        Write-Warning "License delivery for '$ArtifactId' at $SourceRepository@${SourceCommit}: missing license text; attribution/scope documents retained without inferring a grant."
    }
    $artifacts = @()
    foreach ($path in $paths) {
        $license = if ($scope.ContainsKey($path)) { $scope[$path] } else { 'NOASSERTION' }
        if ($documents.ContainsKey('licensing-scope.json') -and $license -eq 'NOASSERTION') {
            $status = 'unconfirmed'
            Write-Warning "License delivery for '$ArtifactId' at ${SourceCommit}: NOASSERTION or unlisted scope for '$path'; no additional grant inferred."
        }
        $artifacts += [pscustomobject][ordered]@{ sourcePath = $path; license = $license }
    }
    $files = @()
    $receipts = @()
    foreach ($path in @($documents.Keys | Sort-Object)) {
        $bytes = [IO.File]::ReadAllBytes((Get-LicenseSafeItem $root $path).FullName)
        $hash = Get-LicenseBytesHash $bytes
        $relative = "source/$path"
        $files += [pscustomobject]@{ sourcePath = $path; relativePath = $relative; bytes = $bytes; sha256 = $hash; kind = 'source' }
        $receipts += [pscustomobject][ordered]@{ sourcePath = $path; relativePath = $relative; sha256 = $hash }
    }
    $receipt = [ordered]@{ schemaVersion = 1; sourceRepository = $SourceRepository; sourceCommit = $SourceCommit; artifactId = $ArtifactId; status = $status; artifacts = $artifacts; documents = $receipts }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($receipt | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n")
    $files += [pscustomobject]@{ sourcePath = '.ai-instructions-generated/delivery.json'; relativePath = 'delivery.json'; bytes = $bytes; sha256 = (Get-LicenseBytesHash $bytes); kind = 'receipt' }
    return [pscustomobject]@{ Status = $status; Files = $files }
}

# Write only into a new staging namespace. Destination reconciliation owns adoption and rollback.
function Write-LicenseDeliveryPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Package, [Parameter(Mandatory = $true)][string] $DestinationRoot)
    if (Test-Path -LiteralPath $DestinationRoot) { throw "License delivery namespace already exists: $DestinationRoot" }
    foreach ($file in @($Package.Files)) {
        Assert-LicenseRelativePath $file.relativePath
        $target = Join-Path $DestinationRoot $file.relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        [IO.File]::WriteAllBytes($target, $file.bytes)
    }
}

function Test-InstructionLicenseDeliveryPath {
    param([string] $Path)
    if ($Path -cnotmatch '^\.(codex|github)/ai-instructions-licenses/([0-9a-f]{40}/)?(delivery\.json|source/.+)$') { return $false }
    try { Assert-LicenseRelativePath $Path; return $true } catch { return $false }
}

function Test-LicenseDeliveryTargetPath {
    param([string] $Path)
    return (Test-InstructionLicenseDeliveryPath $Path) -or $Path -cmatch '^\.agents/skills/[^/]+/\.ai-instructions-licenses/'
}

function Get-LicenseDeliveryOwner {
    param([string] $Path)
    if ($Path -cmatch '^\.agents/skills/([^/]+)/') { return "skill/$($Matches[1])" }
    if ($Path -ceq 'AGENTS.md' -or $Path.StartsWith('.codex/')) { return 'codex' }
    if ($Path.StartsWith('.github/')) { return 'copilot' }
    return ''
}

Export-ModuleMember -Function New-LicenseDeliveryPackage, Write-LicenseDeliveryPackage, Select-LicenseDeliveryDocumentPaths, Test-InstructionLicenseDeliveryPath, Test-LicenseDeliveryTargetPath, Get-LicenseDeliveryOwner
