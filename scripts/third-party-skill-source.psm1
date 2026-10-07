#Requires -Version 7.0
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'skills-source-acquisition.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'license-delivery.psm1') -ErrorAction Stop

function Assert-RawJsonUniqueKeys {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $keys.Add($property.Name)) { throw "Duplicate or case-conflicting descriptor key: $($property.Name)" }
            Assert-RawJsonUniqueKeys $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-RawJsonUniqueKeys $item }
    }
}

function Get-RawSafeFile {
    param([string]$Root,[string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\\:\x00-\x1f]' -or $RelativePath.StartsWith('/') -or
        @($RelativePath.Split('/') | Where-Object { $_ -in @('','.', '..') -or $_ -match '[. ]$' }).Count -gt 0) {
        throw "Unsafe third-party source path: $RelativePath"
    }
    $current=[IO.Path]::GetFullPath($Root)
    foreach ($part in @('') + @($RelativePath.Split('/'))) {
        if ($part) { $current=Join-Path $current $part }
        $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse-backed source path: $RelativePath" }
    }
    if ($item.PSIsContainer) { throw "Expected a source file: $RelativePath" }
    return $item.FullName
}

function Assert-RawArchiveProjection {
    param($Descriptor,[string]$ArchivePath,[string[]]$ArtifactPaths)
    $temporaryParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('/','\'))
    $temporaryRoot=Join-Path $temporaryParent ('raw-skill-adoption-'+[guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $temporaryRoot) { throw 'Archive verification requires a new staging root.' }
    $plan=[pscustomobject]@{
        Sources=@([pscustomobject]@{id=$Descriptor.sourceId;archiveSha256=$Descriptor.archiveSha256;resolvedCommit=$Descriptor.resolvedCommit})
        Skills=@($Descriptor.skills | ForEach-Object { [pscustomobject]@{
            id=$_.id;sourceId=$Descriptor.sourceId;sourcePath=$_.sourcePath;targetPath=$_.targetPath
            sourceLayoutVersion=2;contentSha256=$_.contentSha256
        } })
    }
    $archives=@{}; $archives[$Descriptor.sourceId]=$ArchivePath
    try {
        # Reuse the central safe ZIP and complete package hash checks. No upstream program is executed.
        $acquired=Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths $archives -WorkingRoot $temporaryRoot
        $archiveRoot=$acquired.Sources[0].rootPath
        if (Test-Path -LiteralPath (Join-Path $archiveRoot 'catalog/source.json')) { throw 'Archive ownership differs from raw source inventory declaration.' }
        foreach ($skill in $Descriptor.skills) {
            if (Test-Path -LiteralPath (Join-Path $archiveRoot ($skill.sourcePath+'/agents/openai.yaml'))) { throw 'Archive ownership differs from raw interface declaration.' }
        }
        $legal=New-LicenseDeliveryPackage -SourceRoot $archiveRoot -ArtifactPaths $ArtifactPaths -SourceRepository $Descriptor.repository -SourceCommit $Descriptor.resolvedCommit -ArtifactId $Descriptor.sourceId
        $files=@($legal.Files | Where-Object kind -eq 'source')
        if ($files.Count -ne @($Descriptor.licenseDocuments).Count) { throw 'Original archive legal inventory differs from the descriptor.' }
        foreach ($document in $Descriptor.licenseDocuments) {
            $match=@($files | Where-Object { $_.sourcePath -ceq $document.path -and $_.sha256 -ceq $document.sha256 })
            if ($match.Count -ne 1) { throw 'Original archive legal bytes differ from the descriptor.' }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            $resolved=[IO.Path]::GetFullPath($temporaryRoot)
            $prefix=$temporaryParent+[IO.Path]::DirectorySeparatorChar
            $cleanupItems=@(Get-Item -LiteralPath $resolved -Force) + @(Get-ChildItem -LiteralPath $resolved -Force -Recurse)
            if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
                (Get-Item -LiteralPath $resolved -Force).FullName -cne $temporaryRoot -or
                @($cleanupItems |
                    Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
                throw 'Unsafe archive-verification cleanup target; staging retained.'
            }
            [IO.Directory]::Delete($resolved,$true)
        }
    }
}

function Test-ThirdPartySkillSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [Parameter(Mandatory=$true)][string]$DescriptorPath,
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$SourceRepository,
        [Parameter(Mandatory=$true)][string]$SourceRevision,
        [switch]$RequireApproved
    )
    $schemaPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/schemas/third-party-raw-skill-source-v1.schema.json'
    $descriptorFile=Get-Item -LiteralPath $DescriptorPath -Force -ErrorAction Stop
    if ($descriptorFile.PSIsContainer -or $descriptorFile.Length -gt 2097152 -or ($descriptorFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe or oversized adoption descriptor.' }
    $descriptorBytes=[IO.File]::ReadAllBytes($descriptorFile.FullName)
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($descriptorBytes)
    $json=[System.Text.Json.JsonDocument]::Parse($text)
    try { Assert-RawJsonUniqueKeys $json.RootElement } finally { $json.Dispose() }
    if (-not (Test-Json -Json $text -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'Third-party descriptor violates its strict schema.' }
    $descriptor=ConvertFrom-Json -InputObject $text -Depth 50
    if ($SourceRevision -cnotmatch '^[0-9a-f]{40}$' -or $SourceRevision -cne $descriptor.resolvedCommit -or $SourceRepository -cne $descriptor.repository) { throw 'Third-party source identity does not match its descriptor.' }
    $archiveFile=Get-Item -LiteralPath $ArchivePath -Force -ErrorAction Stop
    if ($archiveFile.PSIsContainer -or ($archiveFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe candidate archive.' }
    $archiveHash=(Get-FileHash -LiteralPath $archiveFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -cne $descriptor.archiveSha256) { throw 'Third-party archive hash mismatch.' }
    $approved=$descriptor.reviewState -ceq 'approved' -and $descriptor.licenseReview -ceq 'accepted' -and
        @($descriptor.reviewEvidence).Count -gt 0 -and @($descriptor.licenseEvidence).Count -gt 0
    if (($descriptor.reviewState -ceq 'approved' -and -not $approved) -or ($RequireApproved -and -not $approved)) { throw 'Approved adoption requires central human review and accepted license evidence.' }
    $root=[IO.Path]::GetFullPath($SourceRoot)
    if (Test-Path -LiteralPath (Join-Path $root 'catalog/source.json')) { throw 'Raw-source v1 requires explicitly absent source-owned inventory.' }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $artifactPaths=[Collections.Generic.List[string]]::new()
    $inventory=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $skills=@()
    foreach ($skill in $descriptor.skills) {
        if (-not $ids.Add($skill.id) -or $skill.sourcePath -cne "skills/$($skill.id)" -or $skill.targetPath -cne ".agents/skills/$($skill.id)") { throw 'Duplicate Skill identity or mismatched canonical paths.' }
        if ([string]::IsNullOrWhiteSpace($skill.hostInterface.displayName) -or [string]::IsNullOrWhiteSpace($skill.hostInterface.shortDescription) -or
            $skill.hostInterface.defaultPrompt -cnotmatch ('(?<![A-Za-z0-9_-])\$'+[regex]::Escape($skill.id)+'(?![A-Za-z0-9_-])')) { throw 'Invalid central host interface or missing explicit Skill prompt reference.' }
        $skillRoot=Join-Path $root $skill.sourcePath
        if (Test-Path -LiteralPath (Join-Path $skillRoot 'agents/openai.yaml')) { throw 'Raw-source v1 requires explicitly absent upstream interface metadata.' }
        $hash=Get-SkillInventorySha256 -RepositoryRoot $root -SkillRoot $skillRoot
        if ($hash -cne $skill.contentSha256) { throw "Complete Skill inventory hash mismatch: $($skill.id)" }
        Assert-SkillDefinition -SkillDefinitionPath (Get-RawSafeFile $root "$($skill.sourcePath)/SKILL.md") -ExpectedSkillId $skill.id
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -Force -File)) {
            $relative=$file.FullName.Substring($root.TrimEnd([char[]]@('/','\')).Length+1).Replace('\','/')
            $safe=Get-RawSafeFile $root $relative
            $inventory[$relative]=(Get-FileHash -LiteralPath $safe -Algorithm SHA256).Hash.ToLowerInvariant()
            $artifactPaths.Add($relative)
        }
        $skills += [pscustomobject]@{id=$skill.id;sourcePath=$skill.sourcePath;targetPath=$skill.targetPath;contentSha256=$hash}
    }
    $licensePackage=New-LicenseDeliveryPackage -SourceRoot $root -ArtifactPaths $artifactPaths.ToArray() -SourceRepository $SourceRepository -SourceCommit $SourceRevision -ArtifactId $descriptor.sourceId
    $licenseFiles=@($licensePackage.Files | Where-Object kind -eq 'source')
    if ($licenseFiles.Count -ne @($descriptor.licenseDocuments).Count) { throw 'Descriptor must bind every applicable original license document.' }
    $legalPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($document in $descriptor.licenseDocuments) {
        if (-not $legalPaths.Add($document.path)) { throw 'Duplicate legal document path.' }
        $safe=Get-RawSafeFile $root $document.path
        $match=@($licenseFiles | Where-Object { $_.sourcePath -ceq $document.path })
        $hash=(Get-FileHash -LiteralPath $safe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($match.Count -ne 1 -or $hash -cne $document.sha256 -or $hash -cne $match[0].sha256) { throw "Legal document scope or hash mismatch: $($document.path)" }
        $inventory[$document.path]=$hash
    }
    Assert-RawArchiveProjection -Descriptor $descriptor -ArchivePath $ArchivePath -ArtifactPaths $artifactPaths.ToArray()
    foreach ($skill in $skills) {
        if ((Get-SkillInventorySha256 -RepositoryRoot $root -SkillRoot (Join-Path $root $skill.sourcePath)) -cne $skill.contentSha256) { throw 'Source package changed during validation.' }
    }
    foreach ($path in $inventory.Keys) {
        if ((Get-FileHash -LiteralPath (Get-RawSafeFile $root $path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $inventory[$path]) { throw 'Source component changed during validation.' }
    }
    if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $archiveHash -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($descriptorFile.FullName)) -cne [Convert]::ToBase64String($descriptorBytes)) { throw 'Candidate binding changed during validation.' }
    $paths=[string[]]@($inventory.Keys); [Array]::Sort($paths,[StringComparer]::Ordinal)
    $lines=@($paths | ForEach-Object { "$_`t$($inventory[$_])`n" })
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { $inventoryHash=([BitConverter]::ToString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes([string]::Concat($lines))))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    return [pscustomobject][ordered]@{
        schemaVersion=1; validationKind='third-party-package-only'; status='passed'; releaseEligible=$false; adoptionApproved=[bool]$approved
        contract=$descriptor.contract; descriptorSha256=(Get-FileHash -LiteralPath $descriptorFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        candidateIdentity=[pscustomobject]@{sourceId=$descriptor.sourceId;repository=$SourceRepository;resolvedCommit=$SourceRevision;archiveSha256=$archiveHash}
        skills=$skills; archiveProjectionVerified=$true; componentInventorySha256=$inventoryHash
        componentInventory=@($paths | ForEach-Object { [pscustomobject]@{path=$_;sha256=$inventory[$_]} })
        requiredNextGate='standard-core-v2 SourceValidation; unchanged Static, repository checks and lifecycle approval'
    }
}

Export-ModuleMember -Function Test-ThirdPartySkillSource
