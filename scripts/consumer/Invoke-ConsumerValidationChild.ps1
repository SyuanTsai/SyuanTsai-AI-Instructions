# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('package-adapter', 'skill-validator', 'skill-tools', 'static')][string] $Mode,
    [Parameter(Mandatory = $true)][string] $ToolchainPath,
    [Parameter(Mandatory = $true)][string] $ToolchainSha256,
    [string] $SourceRepository,
    [string] $SourceRevision,
    [string] $ArchiveSha256,
    [string] $SemanticRequired = 'false'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
function Assert-FileIdentity {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Sha256, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileSha256 -Path $Path) -cne $Sha256) { throw "$Context changed or is missing." }
}
function Get-Property {
    param([Parameter(Mandatory = $true)] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { throw "$Context is missing '$Name'." }
    return $Object.PSObject.Properties[$Name].Value
}
function Read-Json {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100) }
    catch { throw "$Context is not valid JSON: $($_.Exception.Message)" }
}
function Test-PathEqual {
    param([Parameter(Mandatory = $true)][string] $Left, [Parameter(Mandatory = $true)][string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}
function Test-PathWithin {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}
function Assert-CandidateRegularFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($CandidateRoot)
    if (-not (Test-PathWithin -Path $fullPath -Root $fullRoot)) { throw "$Context is outside the bound candidate snapshot." }
    $cursor = $fullPath
    while ($true) {
        if (-not (Test-Path -LiteralPath $cursor)) { throw "$Context is missing." }
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context has a linked path component." }
        if (Test-PathEqual -Left $cursor -Right $fullRoot) { break }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or (Test-PathEqual -Left $parent -Right $cursor)) {
            throw "$Context is outside the bound candidate snapshot."
        }
        $cursor = $parent
    }
    if ((Get-Item -LiteralPath $fullPath -Force) -isnot [IO.FileInfo]) { throw "$Context must be a regular file." }
    return $fullPath
}
function Get-SkillSpectorBaselineSelection {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string[]] $ActiveSkills
    )
    $registryPath = Join-Path $CandidateRoot 'config/skillspector-exceptions.json'
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return [pscustomobject]@{ HasRegistry = $false
         Bindings = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
    }
    $registryPath = Assert-CandidateRegularFile -Path $registryPath -CandidateRoot $CandidateRoot -Context 'SkillSpector exception registry'
    $registry = Read-Json -Path $registryPath -Context 'SkillSpector exception registry'
    $bindingsProperty = $registry.PSObject.Properties['baselines']
    if ($null -eq $bindingsProperty -or $bindingsProperty.Value -isnot [array] -or $bindingsProperty.Value.Count -eq 0) {
        throw 'SkillSpector exception registry baselines must be a nonempty array.'
    }
    $active = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skillId in $ActiveSkills) { [void]$active.Add($skillId) }
    $bindings = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($binding in $bindingsProperty.Value) {
        $skillId = Get-Property -Object $binding -Name 'skillId' -Context 'SkillSpector baseline binding'
        $relativePath = Get-Property -Object $binding -Name 'path' -Context 'SkillSpector baseline binding'
        if ($skillId -isnot [string] -or [string]::IsNullOrWhiteSpace($skillId) -or
            $relativePath -isnot [string] -or [string]::IsNullOrWhiteSpace($relativePath)) {
            throw 'SkillSpector baseline binding requires nonempty string skillId and path.'
        }
        if (-not $active.Contains($skillId) -or $bindings.ContainsKey($skillId)) {
            throw 'SkillSpector baseline binding skillId must be active and unique.'
        }
        $expectedPath = "config/skillspector-exceptions/$skillId.baseline.json"
        if (-not [string]::Equals($relativePath, $expectedPath, [StringComparison]::Ordinal)) {
            throw 'SkillSpector baseline binding path must match config/skillspector-exceptions/<skillId>.baseline.json.'
        }
        $baselinePath = Assert-CandidateRegularFile -Path (Join-Path $CandidateRoot $relativePath) -CandidateRoot $CandidateRoot `
            -Context "SkillSpector baseline for '$skillId'"
        $bindings.Add($skillId, [pscustomobject]@{ Path = $baselinePath
             Sha256 = Get-FileSha256 -Path $baselinePath })
    }
    return [pscustomobject]@{ HasRegistry = $true
     Bindings = $bindings }
}
function Get-ActiveSkills {
    $values = @([string]$env:STANDARD_VALIDATION_ACTIVE_SKILLS -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw 'Central runner did not provide active Skill identities.' }
    return [string[]]$values
}
function Get-SkillRoot {
    param([Parameter(Mandatory = $true)][string] $SkillId)
    $skillsRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_SKILLS_ROOT)
    $skillRoot = [IO.Path]::GetFullPath((Join-Path $skillsRoot $SkillId))
    if (-not (Test-PathWithin -Path $skillRoot -Root $skillsRoot) -or -not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
        throw "Central runner supplied an unsafe or missing Skill root: $SkillId"
    }
    return $skillRoot
}
function Get-InventoryPaths {
    param([Parameter(Mandatory = $true)][string] $SkillRoot)
    $root = [IO.Path]::GetFullPath($SkillRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $paths = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            ForEach-Object {
                $_.FullName.Substring($root.Length).TrimStart(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ).Replace([IO.Path]::DirectorySeparatorChar, '/')
            }
    )
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    if ($paths.Count -eq 0) { throw "Skill inventory is empty: $SkillRoot" }
    return [string[]]$paths
}
function Resolve-ReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context must identify a file." }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) { throw "$Context must be a local file." }
        $candidate = $uri.LocalPath
    }
    elseif (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $SkillRoot $candidate }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-PathWithin -Path $full -Root $SkillRoot)) { throw "$Context escapes the Skill root." }
    foreach ($relative in $ExpectedPaths) {
        if (Test-PathEqual -Left $full -Right (Join-Path $SkillRoot $relative)) { return $full }
    }
    throw "$Context is outside the candidate-bound inventory."
}
function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string] $Text)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function Test-KnownTextPath {
    param([Parameter(Mandatory = $true)][string] $RelativePath)
    $knownExtensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in @(
            '.md', '.markdown', '.txt', '.yaml', '.yml', '.json', '.jsonc', '.toml', '.ini', '.cfg', '.csv', '.tsv',
            '.xml', '.html', '.htm', '.css', '.js', '.mjs', '.cjs', '.ts', '.ps1', '.psm1', '.psd1', '.py', '.sh',
            '.bash', '.zsh', '.rb', '.lua', '.sql', '.cs', '.go', '.rs', '.java', '.kt', '.bat', '.cmd')) {
        [void]$knownExtensions.Add($extension)
    }
    $knownNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('SKILL.md', 'LICENSE', 'README', 'NOTICE')) { [void]$knownNames.Add($name) }
    $fileName = [IO.Path]::GetFileName($RelativePath)
    $extension = [IO.Path]::GetExtension($fileName)
    return [string]::IsNullOrEmpty($extension) -or $knownNames.Contains($fileName) -or $knownExtensions.Contains($extension)
}
function Test-KnownBinaryMagic {
    param(
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )
    $extension = [IO.Path]::GetExtension([IO.Path]::GetFileName($RelativePath)).ToLowerInvariant()
    switch ($extension) {
        '.png' {
            return $Bytes.Length -ge 8 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and
                $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47 -and $Bytes[4] -eq 0x0D -and
                $Bytes[5] -eq 0x0A -and $Bytes[6] -eq 0x1A -and $Bytes[7] -eq 0x0A
        }
        { $_ -in @('.jpg', '.jpeg') } {
            return $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF
        }
        '.gif' {
            return $Bytes.Length -ge 6 -and $Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and
                $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x38 -and $Bytes[4] -in @(0x37, 0x39) -and $Bytes[5] -eq 0x61
        }
        '.webp' {
            return $Bytes.Length -ge 12 -and $Bytes[0] -eq 0x52 -and $Bytes[1] -eq 0x49 -and
                $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x46 -and $Bytes[8] -eq 0x57 -and
                $Bytes[9] -eq 0x45 -and $Bytes[10] -eq 0x42 -and $Bytes[11] -eq 0x50
        }
        '.ico' { return $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0x01 -and $Bytes[3] -eq 0x00 }
        '.pdf' { return $Bytes.Length -ge 5 -and $Bytes[0] -eq 0x25 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x44 -and $Bytes[3] -eq 0x46 -and $Bytes[4] -eq 0x2D }
        '.zip' {
            return $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x50 -and $Bytes[1] -eq 0x4B -and
                $Bytes[2] -in @(0x03, 0x05) -and $Bytes[3] -in @(0x04, 0x06) -and
                (($Bytes[2] -eq 0x03 -and $Bytes[3] -eq 0x04) -or ($Bytes[2] -eq 0x05 -and $Bytes[3] -eq 0x06))
        }
        '.gz' { return $Bytes.Length -ge 2 -and $Bytes[0] -eq 0x1F -and $Bytes[1] -eq 0x8B }
        '.woff' { return $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x77 -and $Bytes[1] -eq 0x4F -and $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x46 }
        '.woff2' { return $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x77 -and $Bytes[1] -eq 0x4F -and $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x32 }
        '.ttf' { return $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x01 -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00 }
        '.otf' { return $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x4F -and $Bytes[1] -eq 0x54 -and $Bytes[2] -eq 0x54 -and $Bytes[3] -eq 0x4F }
        default { return $false }
    }
}
function Test-KnownBinaryExtension {
    param([Parameter(Mandatory = $true)][string] $RelativePath)
    return [IO.Path]::GetExtension([IO.Path]::GetFileName($RelativePath)) -in
        @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf', '.zip', '.gz', '.woff', '.woff2', '.ttf', '.otf')
}
function Test-EmojiScalar {
    param([Parameter(Mandatory = $true)][int] $Value)
    return ($Value -ge 0x2600 -and $Value -le 0x27BF) -or
        ($Value -ge 0x2B00 -and $Value -le 0x2BFF) -or
        ($Value -ge 0x1F000 -and $Value -le 0x1FAFF)
}
function Get-HiddenUnicodeCategory {
    param([Parameter(Mandatory = $true)][int] $Value, [Parameter(Mandatory = $true)][bool] $IsLeadingBom)
    if ($Value -ge 0xE0000 -and $Value -le 0xE007F) { return 'tag' }
    if ($Value -eq 0x061C -or ($Value -ge 0x200E -and $Value -le 0x200F) -or
        ($Value -ge 0x202A -and $Value -le 0x202E) -or ($Value -ge 0x2066 -and $Value -le 0x2069)) { return 'bidi' }
    if ($Value -ge 0x206A -and $Value -le 0x206F) { return 'deprecated-format' }
    if ($Value -ge 0x2061 -and $Value -le 0x2064) { return 'invisible-operator' }
    if (($Value -ge 0x200B -and $Value -le 0x200D) -or $Value -eq 0x2060 -or $Value -eq 0x180E -or $Value -eq 0x034F) {
        return 'zero-width'
    }
    if ($Value -eq 0xFEFF -and -not $IsLeadingBom) { return 'bom-not-at-start' }
    return $null
}
function New-UnicodePackageFinding {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $RuleId,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter(Mandatory = $true)][string] $FingerprintSource
    )
    return [ordered]@{
        severity = 'high'
        fingerprint = Get-TextSha256 -Text $FingerprintSource
        ruleId = $RuleId
        message = $Message
        path = $RelativePath
        skillId = $SkillId
    }
}
function Get-UnicodePackageFindings {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string[]] $Inventory
    )
    $findings = @()
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    foreach ($relativePath in $Inventory) {
        $fullPath = Join-Path $SkillRoot $relativePath
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $knownText = Test-KnownTextPath -RelativePath $relativePath
        $knownBinary = Test-KnownBinaryExtension -RelativePath $relativePath
        $containsNul = $bytes -contains [byte]0
        if ($knownBinary -and (Test-KnownBinaryMagic -RelativePath $relativePath -Bytes $bytes)) { continue }
        if (-not $knownText -and -not $knownBinary -and $containsNul) {
            $ruleId = 'unicode-unrecognized-binary'
            $findings += New-UnicodePackageFinding -SkillId $SkillId -RelativePath $relativePath -RuleId $ruleId `
                -Message 'File contains a NUL byte but is not a recognized binary format.' -FingerprintSource "$SkillId|$relativePath|$ruleId"
            continue
        }
        if ($knownText -and $containsNul) {
            $ruleId = 'unicode-nul-in-text'
            $findings += New-UnicodePackageFinding -SkillId $SkillId -RelativePath $relativePath -RuleId $ruleId `
                -Message 'Known text file contains a NUL byte.' -FingerprintSource "$SkillId|$relativePath|$ruleId"
        }
        elseif ($knownBinary -and $containsNul) {
            $ruleId = 'unicode-unrecognized-binary'
            $findings += New-UnicodePackageFinding -SkillId $SkillId -RelativePath $relativePath -RuleId $ruleId `
                -Message 'File contains a NUL byte but does not match its binary format magic.' -FingerprintSource "$SkillId|$relativePath|$ruleId"
        }
        try { $text = $strictUtf8.GetString($bytes) }
        catch {
            $ruleId = 'unicode-invalid-utf8'
            $findings += New-UnicodePackageFinding -SkillId $SkillId -RelativePath $relativePath -RuleId $ruleId `
                -Message 'Text file is not valid UTF-8.' -FingerprintSource "$SkillId|$relativePath|$ruleId"
            continue
        }
        $hasLeadingBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        # Fast path: skip the per-scalar walk when no candidate code unit exists. Tag characters
        # U+E0000-U+E007F are the surrogate pair \uDB40 followed by \uDC00-\uDC7F.
        $candidatePattern = '[͏؜᠎​-‏‪-‮⁠-⁤⁦-⁯﻿]|\uDB40[\uDC00-\uDC7F]'
        if (-not [regex]::IsMatch($text, $candidatePattern)) { continue }
        $hiddenCount = 0
        $line = 1
        $column = 1
        $previousRelevantValue = -1
        for ($offset = 0; $offset -lt $text.Length;) {
            $firstValue = [int]$text[$offset]
            if ([char]::IsHighSurrogate([char]$firstValue) -and $offset + 1 -lt $text.Length -and
                [char]::IsLowSurrogate($text[$offset + 1])) {
                $value = [char]::ConvertToUtf32([char]$firstValue, $text[$offset + 1])
                $width = 2
            }
            else {
                $value = $firstValue
                $width = 1
            }
            $category = Get-HiddenUnicodeCategory -Value $value -IsLeadingBom ($hasLeadingBom -and $offset -eq 0)
            if ($null -ne $category) {
                $isEmojiZwJ = $false
                if ($value -eq 0x200D -and $offset + $width -lt $text.Length) {
                    $nextOffset = $offset + $width
                    $nextFirstValue = [int]$text[$nextOffset]
                    if ([char]::IsHighSurrogate([char]$nextFirstValue) -and $nextOffset + 1 -lt $text.Length -and
                        [char]::IsLowSurrogate($text[$nextOffset + 1])) {
                        $nextValue = [char]::ConvertToUtf32([char]$nextFirstValue, $text[$nextOffset + 1])
                    }
                    else { $nextValue = $nextFirstValue }
                    $isEmojiZwJ = (Test-EmojiScalar -Value $previousRelevantValue) -and (Test-EmojiScalar -Value $nextValue)
                }
                if (-not $isEmojiZwJ) {
                    $hiddenCount++
                    if ($hiddenCount -le 50) {
                        $hex = '{0:X4}' -f $value
                        $ruleId = 'unicode-hidden-character'
                        $message = "Hidden or control character U+$hex ($category) at line $line, column $column."
                        $fingerprintSource = "$SkillId|$relativePath|$ruleId|U+$hex|$line|$column"
                        $findings += New-UnicodePackageFinding -SkillId $SkillId -RelativePath $relativePath -RuleId $ruleId `
                            -Message $message -FingerprintSource $fingerprintSource
                    }
                }
            }
            if ($value -ne 0xFE0F -and ($value -lt 0x1F3FB -or $value -gt 0x1F3FF)) { $previousRelevantValue = $value }
            if ($value -eq 0x0A) { $line++; $column = 1 } else { $column++ }
            $offset += $width
        }
        if ($hiddenCount -gt 50) {
            $ruleId = 'unicode-hidden-character-truncated'
            $message = "Hidden or control character findings truncated after 50 of $hiddenCount matches."
            $findings += New-UnicodePackageFinding -SkillId $SkillId -RelativePath $relativePath -RuleId $ruleId `
                -Message $message -FingerprintSource "$SkillId|$relativePath|$ruleId|$hiddenCount"
        }
    }
    return ,$findings
}
function ConvertTo-CanonicalSeverity {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $severity = [string]$Value
    if ([string]::IsNullOrWhiteSpace($severity)) { throw "$Context returned an empty severity." }
    $canonical = switch ($severity.ToLowerInvariant()) {
        'critical' { 'critical'
         break }
        'high' { 'high'
         break }
        'medium' { 'medium'
         break }
        'low' { 'low'
         break }
        'informational' { 'informational'
         break }
        'info' { 'informational'
         break }
        default { throw "$Context returned unsupported severity '$severity'." }
    }
    return $canonical
}
function New-Finding {
    param([Parameter(Mandatory = $true)] $Issue, [Parameter(Mandatory = $true)][string] $SkillId, [Parameter(Mandatory = $true)][string] $Stage)
    $severity = ConvertTo-CanonicalSeverity -Value (Get-Property -Object $Issue -Name 'severity' -Context "$Stage issue") `
        -Context "$Stage for '$SkillId'"
    $issueJson = $Issue | ConvertTo-Json -Depth 30 -Compress
    $path = if ($null -ne $Issue.PSObject.Properties['file']) {
        [string]$Issue.file
    } elseif ($null -ne $Issue.PSObject.Properties['path']) {
        [string]$Issue.path
    } else { '' }
    return [ordered]@{
        severity = $severity
        fingerprint = Get-TextSha256 -Text $issueJson
        ruleId = if ($null -ne $Issue.PSObject.Properties['rule_id']) {
            [string]$Issue.rule_id
        } elseif ($null -ne $Issue.PSObject.Properties['ruleId']) {
            [string]$Issue.ruleId
        } else { $Stage }
        message = if ($null -ne $Issue.PSObject.Properties['message']) { [string]$Issue.message } else { $issueJson }
        path = $path
        skillId = $SkillId
    }
}
function New-Envelope {
    param(
        [Parameter(Mandatory = $true)][string[]] $ActiveSkills,
        [array] $Findings = @(),
        [hashtable] $Additional
    )
    $value = [ordered]@{
        schemaVersion = 1
        status = 'passed'
        decision = 'PASS'
        candidateIdentity = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
        activeSkills = @($ActiveSkills)
        findings = @($Findings)
    }
    if ($Mode -cin @('skill-validator', 'skill-tools', 'static')) { $value.nativeReports = @($script:NativeReports) }
    if ($null -ne $Additional) {
        foreach ($key in $Additional.Keys) { $value[$key] = $Additional[$key] }
    }
    [Console]::Out.WriteLine(($value | ConvertTo-Json -Depth 100 -Compress))
    exit 0
}
$script:NativeReports = @()
function Add-NativeReport {
    param([Parameter(Mandatory = $true)][string] $Command, [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][int] $ExitCode, [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SkillId)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'Native tool did not create its raw report file.' }
    $script:NativeReports += [pscustomobject][ordered]@{
        skillId = $SkillId
        command = [IO.Path]::GetFullPath($Command)
        commandSha256 = Get-FileSha256 -Path $Command
        arguments = @($Arguments)
        exitCode = $ExitCode
        path = $fullPath
        sha256 = Get-FileSha256 -Path $fullPath
    }
}
function Invoke-NativeJson {
    param([Parameter(Mandatory = $true)][string] $Command, [Parameter(Mandatory = $true)][string[]] $Arguments, [Parameter(Mandatory = $true)][string] $Context)
    $stderrPath = Join-Path (Get-Location) (([guid]::NewGuid().ToString('N')) + '.stderr')
    try {
        $lines = @(& $Command @Arguments 2> $stderrPath)
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        $json = ($lines -join "`n").Trim()
        $nativePath = Join-Path (Get-Location) ("native-$Mode-$($env:STANDARD_VALIDATION_SKILL_ID).json")
        [IO.File]::WriteAllText($nativePath, $json, [Text.UTF8Encoding]::new($false))
        Add-NativeReport -Command $Command -Arguments $Arguments -ExitCode $exitCode -Path $nativePath -SkillId ([string]$env:STANDARD_VALIDATION_SKILL_ID)
        if ($exitCode -ne 0) { throw "$Context returned exit code $exitCode. $stderr" }
        if ([string]::IsNullOrWhiteSpace($json)) { throw "$Context produced no JSON output." }
        return ($json | ConvertFrom-Json -Depth 100)
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
    }
}
function Assert-SkillValidatorReport {
    param([Parameter(Mandatory = $true)] $Report, [Parameter(Mandatory = $true)][string] $SkillRoot, [Parameter(Mandatory = $true)][string[]] `
        $Inventory, [Parameter(Mandatory = $true)][string] $SkillId)
    $results = @(Assert-StandardValidationSkillValidatorReport -Report $Report -SkillRoot $SkillRoot -SkillId $SkillId)
    $findings = @()
    foreach ($result in $results) {
        $level = [string](Get-Property -Object $result -Name 'level' -Context 'skill-validator result')
        if ($null -ne $result.PSObject.Properties['file']) {
            [void](Resolve-ReportedFilePath -Value $result.file -SkillRoot $SkillRoot -ExpectedPaths $Inventory -Context 'skill-validator result file')
        }
        if ($level -eq 'info') {
            $findings += [ordered]@{ severity = 'informational'
             fingerprint = Get-TextSha256 -Text ($result | ConvertTo-Json -Depth 20 -Compress)
             ruleId = [string]$result.category
             message = [string]$result.message
             path = if ($null -ne $result.PSObject.Properties['file']) { [string]$result.file } else { '' }
             skillId = $SkillId }
        }
    }
    return ,$findings
}
function Assert-SkillToolsReport {
    param([Parameter(Mandatory = $true)] $Report, [Parameter(Mandatory = $true)][string] $SkillRoot, [Parameter(Mandatory = $true)][string[]] `
        $Inventory, [Parameter(Mandatory = $true)][string] $SkillId)
    $version = [string](Get-Property -Object $Report -Name 'version' -Context 'skill-tools SARIF')
    $runs = @(Get-Property -Object $Report -Name 'runs' -Context 'skill-tools SARIF')
    if ($version -cne '2.1.0' -or $runs.Count -ne 1) { throw "skill-tools did not produce SARIF 2.1.0 for '$SkillId'." }
    $run = $runs[0]
    $driver = Get-Property -Object (Get-Property -Object $run -Name 'tool' -Context 'skill-tools SARIF run') -Name 'driver' -Context 'skill-tools SARIF tool'
    $driverName = [string](Get-Property -Object $driver -Name 'name' -Context 'skill-tools SARIF driver')
    $rules = @(Get-Property -Object $driver -Name 'rules' -Context 'skill-tools SARIF driver')
    $results = @(Get-Property -Object $run -Name 'results' -Context 'skill-tools SARIF run')
    if ($driverName -cne 'skill-tools') { throw "skill-tools SARIF driver identity is invalid for '$SkillId'." }
    $ruleById = @{}
    foreach ($rule in $rules) { $ruleById[[string](Get-Property -Object $rule -Name 'id' -Context 'skill-tools SARIF rule')] = $rule }
    $findings = @()
    foreach ($result in $results) {
        $ruleId = [string](Get-Property -Object $result -Name 'ruleId' -Context 'skill-tools SARIF result')
        if (-not $ruleById.ContainsKey($ruleId)) { throw "skill-tools SARIF references an unknown rule for '$SkillId'." }
        $level = if ($null -ne $result.PSObject.Properties['level']) { [string]$result.level } else {
            [string](Get-Property -Object (Get-Property -Object $ruleById[$ruleId] -Name 'defaultConfiguration' -Context `
                'skill-tools SARIF rule') -Name 'level' -Context 'skill-tools SARIF rule default')
        }
        if ($level -notin @('none', 'note', 'warning', 'error')) { throw "skill-tools SARIF level is malformed for '$SkillId'." }
        if ($level -in @('warning', 'error')) { throw "skill-tools SARIF contains a blocking result for '$SkillId'." }
        $message = Get-Property -Object $result -Name 'message' -Context 'skill-tools SARIF result'
        $locations = @(Get-Property -Object $result -Name 'locations' -Context 'skill-tools SARIF result')
        if ([string]::IsNullOrWhiteSpace([string](Get-Property -Object $message -Name 'text' -Context 'skill-tools SARIF message')) -or `
            $locations.Count -eq 0) { throw "skill-tools SARIF lacks candidate-bound evidence for '$SkillId'." }
        foreach ($location in $locations) {
            $physical = Get-Property -Object $location -Name 'physicalLocation' -Context 'skill-tools SARIF location'
            $artifact = Get-Property -Object $physical -Name 'artifactLocation' -Context 'skill-tools SARIF physical location'
            [void](Resolve-ReportedFilePath -Value (Get-Property -Object $artifact -Name 'uri' -Context 'skill-tools SARIF artifact location') `
                -SkillRoot $SkillRoot -ExpectedPaths $Inventory -Context 'skill-tools SARIF artifact location')
        }
        if ($level -eq 'note') {
            $findings += [ordered]@{ severity = 'informational'
             fingerprint = Get-TextSha256 -Text ($result | ConvertTo-Json -Depth 20 -Compress)
             ruleId = $ruleId
             message = [string]$message.text
             path = ''
             skillId = $SkillId }
        }
    }
    return ,$findings
}
function Assert-SkillSpectorReport {
    param([Parameter(Mandatory = $true)] $Report, [Parameter(Mandatory = $true)][string] $SkillRoot, [Parameter(Mandatory = $true)][string] `
        $SkillId, [Parameter(Mandatory = $true)][string[]] $Inventory)
    $execution = Get-Property -Object $Report -Name 'execution_successful' -Context 'SkillSpector report'
    $completeness = Get-Property -Object $Report -Name 'analysis_completeness' -Context 'SkillSpector report'
    if ($execution -isnot [bool] -or -not $execution -or
        (Get-Property -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-Property -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -or
        (Get-Property -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-Property -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -or
        [string](Get-Property -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -cne 'complete' -or
        [double](Get-Property -Object $completeness -Name 'coverage_percent' -Context 'SkillSpector completeness') -ne 100) {
        throw "SkillSpector did not prove complete static analysis for '$SkillId'."
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        if (@(Get-Property -Object $completeness -Name $name -Context 'SkillSpector completeness').Count -ne 0) { throw `
            "SkillSpector reported incomplete '$name' evidence for '$SkillId'." }
    }
    $skill = Get-Property -Object $Report -Name 'skill' -Context 'SkillSpector report'
    if ([string](Get-Property -Object $skill -Name 'name' -Context 'SkillSpector skill identity') -cne $SkillId -or
        -not (Test-PathEqual -Left ([string](Get-Property -Object $skill -Name 'source' -Context 'SkillSpector skill identity')) -Right $SkillRoot)) {
        throw "SkillSpector report identity does not match '$SkillId'."
    }
    $components = @(Get-Property -Object $Report -Name 'components' -Context 'SkillSpector report')
    if ($components.Count -ne $Inventory.Count) { throw "SkillSpector did not cover the exact inventory for '$SkillId'." }
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($component in $components) {
        $path = [string](Get-Property -Object $component -Name 'path' -Context 'SkillSpector component')
        if (-not ($Inventory -ccontains $path) -or -not $observed.Add($path)) { throw "SkillSpector did not cover the exact inventory for '$SkillId'." }
    }
    $issues = @(Get-Property -Object $Report -Name 'issues' -Context 'SkillSpector report')
    $findings = @()
    foreach ($issue in $issues) { $findings += New-Finding -Issue $issue -SkillId $SkillId -Stage 'skillspector-static' }
    return ,$findings
}
function Get-SkillSpectorSuppressedFindings {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string[]] $Inventory
    )
    $suppressedProperty = $Report.PSObject.Properties['suppressed']
    if ($null -eq $suppressedProperty) { throw "SkillSpector report is missing 'suppressed'." }
    $suppressed = $suppressedProperty.Value
    $suppressedCount = Get-Property -Object $Report -Name 'suppressed_count' -Context 'SkillSpector report'
    if ($suppressed -isnot [array] -or
        ($suppressedCount -isnot [int] -and $suppressedCount -isnot [long]) -or
        [long]$suppressedCount -ne $suppressed.Count) {
        throw "SkillSpector suppression evidence is malformed for '$SkillId'."
    }
    $result = @()
    foreach ($entry in $suppressed) {
        $suppressedFlag = Get-Property -Object $entry -Name 'suppressed' -Context 'SkillSpector suppressed finding'
        $ruleId = Get-Property -Object $entry -Name 'id' -Context 'SkillSpector suppressed finding'
        $location = Get-Property -Object $entry -Name 'location' -Context 'SkillSpector suppressed finding'
        $file = Get-Property -Object $location -Name 'file' -Context 'SkillSpector suppressed finding location'
        $line = Get-Property -Object $location -Name 'start_line' -Context 'SkillSpector suppressed finding location'
        $reason = Get-Property -Object $entry -Name 'suppression_reason' -Context 'SkillSpector suppressed finding'
        if ($suppressedFlag -isnot [bool] -or -not $suppressedFlag -or
            $ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or
            $file -isnot [string] -or [string]::IsNullOrWhiteSpace($file) -or
            ($line -isnot [int] -and $line -isnot [long]) -or [long]$line -lt 1 -or
            $reason -isnot [string] -or [string]::IsNullOrWhiteSpace($reason)) {
            throw "SkillSpector suppression evidence is malformed for '$SkillId'."
        }
        [void](Resolve-ReportedFilePath -Value $file -SkillRoot $SkillRoot -ExpectedPaths $Inventory `
            -Context 'SkillSpector suppressed finding file')
        $result += [ordered]@{
            skillId = $SkillId
            ruleId = [string]$ruleId
            severity = ConvertTo-CanonicalSeverity -Value (Get-Property -Object $entry -Name 'severity' `
                -Context 'SkillSpector suppressed finding') -Context "SkillSpector suppression for '$SkillId'"
            file = [string]$file
            line = [long]$line
            suppressionReason = [string]$reason
        }
    }
    return ,$result
}

try {
    $toolchain = Read-Json -Path $ToolchainPath -Context 'run-owned validation toolchain'
    Assert-FileIdentity -Path $ToolchainPath -Sha256 $ToolchainSha256 -Context 'run-owned validation toolchain'
    $candidateRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_CANDIDATE_ROOT)
    if ($Mode -eq 'skill-validator') {
        Assert-FileIdentity -Path ([string]$toolchain.centralRunnerPath) -Sha256 ([string]$toolchain.centralRunnerSha256) -Context 'central validation runner'
        $sharedReportFunctions = & {
            param($RunnerPath, $CandidateRoot, $ToolchainPath)
            . $RunnerPath -DefineFunctionsOnly -CandidateRoot $CandidateRoot -AdapterPath $ToolchainPath `
                -ArtifactsRoot ([IO.Path]::GetFullPath((Get-Location).Path)) -SourceRepository 'https://example.test' `
                -SourceRevision ('0' * 40) -BaseRevision ('0' * 40)
            $exports = @{}
            foreach ($name in @(
                'Get-StandardValidationFullPath',
                'Get-StandardValidationCaseVariant',
                'Get-StandardValidationPathCaseBehavior',
                'Get-StandardValidationPathComparison',
                'Test-StandardValidationSameResolvedPath',
                'Assert-StandardValidationSkillValidatorReport'
            )) {
                $exports[$name] = (Get-Command $name -CommandType Function -ErrorAction Stop).ScriptBlock
            }
            return $exports
        } ([string]$toolchain.centralRunnerPath) $candidateRoot $ToolchainPath
        foreach ($name in $sharedReportFunctions.Keys) {
            Set-Item -Path "function:$name" -Value $sharedReportFunctions[$name]
        }
    }
    $activeSkills = @(Get-ActiveSkills)
    $candidateId = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
    if ([string]::IsNullOrWhiteSpace($candidateId)) { throw 'Central runner did not provide a candidate identity.' }

    switch ($Mode) {
        'package-adapter' {
            Assert-FileIdentity -Path ([string]$toolchain.upstreamAdapterValidatorPath) `
                -Sha256 ([string]$toolchain.upstreamAdapterValidatorSha256) `
                -Context 'upstream adapter validator'
            Assert-FileIdentity -Path ([string]$toolchain.upstreamPolicyPath) -Sha256 ([string]$toolchain.upstreamPolicySha256) -Context `
                'upstream adapter policy'
            $reportPath = Join-Path (Get-Location) 'upstream-adapter-report.json'
            & ([string]$toolchain.upstreamAdapterValidatorPath) -PackageRoot $candidateRoot -PolicyPath ([string]$toolchain.upstreamPolicyPath) `
                -SourceRepository $SourceRepository -SourceRevision $SourceRevision -ArchiveSha256 $ArchiveSha256 -OutputPath $reportPath | Out-Null
            $report = Read-Json -Path $reportPath -Context 'upstream adapter report'
            $status = [string](Get-Property -Object $report -Name 'status' -Context 'upstream adapter report')
            $decision = [string](Get-Property -Object $report -Name 'decision' -Context 'upstream adapter report')
            if (($status -eq 'passed' -and $decision -ne 'PASS') -or ($status -eq 'not-applicable' -and $decision -ne 'NOT_APPLICABLE') -or `
                $status -notin @('passed', 'not-applicable')) { throw 'Upstream adapter report did not pass or prove not-applicable.' }
            $findings = @()
            foreach ($skillId in $activeSkills) {
                $skillRoot = Get-SkillRoot -SkillId $skillId
                $inventory = Get-InventoryPaths -SkillRoot $skillRoot
                $findings += Get-UnicodePackageFindings -SkillId $skillId -SkillRoot $skillRoot -Inventory $inventory
            }
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ adapterStatus = $status
             adapterSurfaces = @($report.surfaces)
             semanticRequired = $false }
        }
        'skill-validator' {
            $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
            $skillRoot = Get-SkillRoot -SkillId $skillId
            $inventory = Get-InventoryPaths -SkillRoot $skillRoot
            Assert-FileIdentity -Path ([string]$toolchain.skillValidatorPath) -Sha256 ([string]$toolchain.skillValidatorSha256) -Context `
                'skill-validator executable'
            $report = Invoke-NativeJson -Command ([string]$toolchain.skillValidatorPath) -Arguments @('-o', 'json', 'validate', 'structure', `
                '--allow-dirs=agents', $skillRoot) -Context "skill-validator '$skillId'"
            $findings = Assert-SkillValidatorReport -Report $report -SkillRoot $skillRoot -Inventory $inventory -SkillId $skillId
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ skillId = $skillId
             skillInventorySha256 = [string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256
             semanticRequired = $false }
        }
        'skill-tools' {
            $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
            $skillRoot = Get-SkillRoot -SkillId $skillId
            $inventory = Get-InventoryPaths -SkillRoot $skillRoot
            Assert-FileIdentity -Path ([string]$toolchain.skillToolsNodePath) -Sha256 ([string]$toolchain.skillToolsNodeSha256) -Context `
                'skill-tools Node runtime'
            Assert-FileIdentity -Path ([string]$toolchain.skillToolsEntryPointPath) -Sha256 ([string]$toolchain.skillToolsEntryPointSha256) `
                -Context 'skill-tools entry point'
            $arguments = @(
                [string]$toolchain.skillToolsEntryPointPath,
                'check', $skillRoot, '--format', 'sarif', '--fail-on', 'warning', '--min-score', '91'
            )
            $report = Invoke-NativeJson -Command ([string]$toolchain.skillToolsNodePath) `
                -Arguments $arguments -Context "skill-tools '$skillId'"
            $findings = Assert-SkillToolsReport -Report $report -SkillRoot $skillRoot -Inventory $inventory -SkillId $skillId
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ skillId = $skillId
             skillInventorySha256 = [string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256
             semanticRequired = $false }
        }
        'static' {
            Assert-FileIdentity -Path ([string]$toolchain.skillSpectorPath) -Sha256 ([string]$toolchain.skillSpectorSha256) -Context 'SkillSpector executable'
            # Keep Python import caches outside the frozen installed tool closure.
            $env:PYTHONDONTWRITEBYTECODE = '1'
            $baselineSelection = Get-SkillSpectorBaselineSelection -CandidateRoot $candidateRoot -ActiveSkills $activeSkills
            $findings = @()
            $suppressedFindings = @()
            foreach ($skillId in $activeSkills) {
                $skillRoot = Get-SkillRoot -SkillId $skillId
                $inventory = Get-InventoryPaths -SkillRoot $skillRoot
                $reportPath = Join-Path (Get-Location) ("skillspector-$skillId.json")
                if (Test-Path -LiteralPath $reportPath) { throw "SkillSpector stdout report path already exists for '$skillId'." }
                $staticStderrPath = Join-Path (Get-Location) ("skillspector-$skillId.stderr")
                $nativeArguments = @('scan', $skillRoot, '--no-llm', '--format', 'json')
                $baselineBinding = if ($baselineSelection.Bindings.ContainsKey($skillId)) { $baselineSelection.Bindings[$skillId] } else { $null }
                if ($null -ne $baselineBinding) { $nativeArguments += @('--baseline', [string]$baselineBinding.Path, '--show-suppressed') }
                & ([string]$toolchain.skillSpectorPath) @nativeArguments 1> $reportPath 2> $staticStderrPath
                $nativeExit = $LASTEXITCODE
                $staticStderr = if (Test-Path -LiteralPath $staticStderrPath -PathType Leaf) { [IO.File]::ReadAllText($staticStderrPath) } else `
                    { [string]::Empty }
                if (-not [string]::IsNullOrEmpty($staticStderr) -and $staticStderr.Length -gt 4096) {
                    $staticStderr = $staticStderr.Substring(0, 4096) + '[truncated]'
                }
                $staticStderrDiagnostic = if ([string]::IsNullOrWhiteSpace($staticStderr)) { '' } else { " SkillSpector stderr: $staticStderr" }
                Add-NativeReport -Command ([string]$toolchain.skillSpectorPath) -Arguments $nativeArguments -ExitCode $nativeExit -Path `
                    $reportPath -SkillId $skillId
                if ($nativeExit -ne 0) { throw "SkillSpector returned exit code $nativeExit for '$skillId'.$staticStderrDiagnostic" }
                try {
                    $report = Read-Json -Path $reportPath -Context "SkillSpector report for '$skillId'"
                }
                catch {
                    throw "Could not read SkillSpector report for '$skillId'.$staticStderrDiagnostic $($_.Exception.Message)"
                }
                $findings += Assert-SkillSpectorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId -Inventory $inventory
                if ($null -ne $baselineBinding) {
                    $baselinePath = Assert-CandidateRegularFile -Path ([string]$baselineBinding.Path) -CandidateRoot $candidateRoot `
                        -Context "SkillSpector baseline for '$skillId'"
                    if ((Get-FileSha256 -Path $baselinePath) -cne [string]$baselineBinding.Sha256) {
                        throw 'Baseline changed during static analysis.'
                    }
                    $suppressedFindings += Get-SkillSpectorSuppressedFindings -Report $report -SkillRoot $skillRoot -SkillId $skillId `
                        -Inventory $inventory
                }
            }
            $semantic = ($SemanticRequired -ceq 'true') -or $findings.Count -gt 0
            $additional = @{ scannerIdentity = 'SkillSpector'
             analyzerCompleteness = 'complete'
             semanticRequired = $semantic }
            if ($baselineSelection.HasRegistry) { $additional.suppressedFindings = @($suppressedFindings) }
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional $additional
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
