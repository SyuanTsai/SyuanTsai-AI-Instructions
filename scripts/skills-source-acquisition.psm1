Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force

function Get-ArchiveSha256 {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')][string] $Path,
        [Parameter(Mandatory = $true, ParameterSetName = 'Stream')][System.IO.Stream] $Stream
    )

    $ownsStream = $PSCmdlet.ParameterSetName -ceq 'Path'
    $hashStream = if ($ownsStream) { [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path)) } else { $Stream }
    if (-not $hashStream.CanRead) { throw 'SHA-256 input stream must be readable.' }
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($hashStream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        if ($ownsStream) { $hashStream.Dispose() }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return Get-ArchiveSha256 -Path $Path
}

function New-SkillInventoryPathMap {
    $pathMap = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    return ,$pathMap
}

function ConvertTo-AsciiFoldSkillInventoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $builder = New-Object System.Text.StringBuilder($Path.Length)
    foreach ($character in $Path.ToCharArray()) {
        $codePoint = [int]$character
        if ($codePoint -ge [int][char]'A' -and $codePoint -le [int][char]'Z') {
            $null = $builder.Append([char]($codePoint + 32))
        }
        else {
            $null = $builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Assert-PortableSkillInventoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)] $NfcPaths,
        [Parameter(Mandatory = $true)] $AsciiFoldPaths,
        [Parameter(Mandatory = $true)] $TargetPathCasings
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.StartsWith('/') -or
        $RelativePath.EndsWith('/') -or
        $RelativePath.Contains('\') -or
        $RelativePath.Contains(':')) {
        throw "Skill inventory contains an unsafe portable path: $RelativePath"
    }
    foreach ($character in $RelativePath.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw 'Skill inventory paths must not contain control characters.'
        }
    }

    $parts = $RelativePath.Split('/')
    $prefixParts = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $parts) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Skill inventory contains an empty or dot path segment: $RelativePath"
        }
        $prefixParts.Add($segment)
        $prefix = [string]::Join('/', $prefixParts.ToArray())
        $nfcPrefix = $prefix.Normalize([System.Text.NormalizationForm]::FormC)
        if ($NfcPaths.ContainsKey($nfcPrefix)) {
            if (-not [string]::Equals([string]$NfcPaths[$nfcPrefix],$prefix,[System.StringComparison]::Ordinal)) {
                throw "Skill inventory contains a Unicode NFC path collision: '$($NfcPaths[$nfcPrefix])' and '$prefix'."
            }
        }
        else {
            $NfcPaths.Add($nfcPrefix, $prefix)
        }

        $asciiFoldPrefix = ConvertTo-AsciiFoldSkillInventoryPath -Path $nfcPrefix
        if ($AsciiFoldPaths.ContainsKey($asciiFoldPrefix)) {
            if (-not [string]::Equals([string]$AsciiFoldPaths[$asciiFoldPrefix],$prefix,[System.StringComparison]::Ordinal)) {
                throw "Skill inventory contains an ASCII case-folded path collision: '$($AsciiFoldPaths[$asciiFoldPrefix])' and '$prefix'."
            }
        }
        else {
            $AsciiFoldPaths.Add($asciiFoldPrefix, $prefix)
        }

        # Also enforce the local adapter's broader ordinal-ignore-case collision model.
        if ($TargetPathCasings.ContainsKey($nfcPrefix)) {
            if (-not [string]::Equals([string]$TargetPathCasings[$nfcPrefix],$prefix,[System.StringComparison]::Ordinal)) {
                throw "Skill inventory contains a case-insensitive path collision: '$($TargetPathCasings[$nfcPrefix])' and '$prefix'."
            }
        }
        else {
            $TargetPathCasings.Add($nfcPrefix, $prefix)
        }
    }
}

function Assert-SkillInventoryDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a non-reparse directory: $Path"
    }
}

function Test-SkillInventoryRegularFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
        return -not $item.PSIsContainer -and
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
            ($item.Attributes -band [System.IO.FileAttributes]::Device) -eq 0
    }

    # PowerShell 7's FileSystem provider reports FIFOs as ordinary leaf files. Use the
    # CoreCLR's non-following Unix lstat wrapper so detection never blocks opening one.
    try {
        $flags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static'
        $coreAssembly = [System.IO.File].Assembly
        $interopType = $coreAssembly.GetType('Interop+Sys',$false)
        $statusType = $coreAssembly.GetType('Interop+Sys+FileStatus',$false)
        if ($null -eq $interopType -or $null -eq $statusType) { throw 'CoreCLR Unix file status API is unavailable.' }
        $lstat = @($interopType.GetMethods($flags) | Where-Object {
            $_.Name -ceq 'LStat' -and $_.GetParameters().Count -eq 2 -and $_.GetParameters()[0].ParameterType -eq [string]
        } | Select-Object -First 1)[0]
        $modeField = $statusType.GetField('Mode',$flags)
        if ($null -eq $lstat -or $null -eq $modeField) { throw 'CoreCLR Unix file status contract is unavailable.' }
        $arguments = [object[]]::new(2)
        $arguments[0] = [string][System.IO.Path]::GetFullPath($Path)
        $arguments[1] = [Activator]::CreateInstance($statusType)
        if ([int]$lstat.Invoke($null,$arguments) -ne 0) { throw 'Unix lstat failed.' }
        $mode = [int]$modeField.GetValue($arguments[1])
        return ($mode -band 0xF000) -eq 0x8000
    }
    catch {
        throw "Could not determine whether Skill inventory entry is a regular file: $Path"
    }
}

function Get-SkillInventorySha256 {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $SkillRoot
    )

    $repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\', '/'))
    $skillRootPath = [System.IO.Path]::GetFullPath($SkillRoot).TrimEnd([char[]]@('\', '/'))
    $repositoryPrefix = $repositoryRootPath + [System.IO.Path]::DirectorySeparatorChar
    $pathComparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $skillRootPath.StartsWith($repositoryPrefix, $pathComparison)) {
        throw "Skill root is outside repository root: $skillRootPath"
    }

    Assert-SkillInventoryDirectory -Path $repositoryRootPath -Context 'Skill inventory repository root'
    $skillRelativePath = $skillRootPath.Substring($repositoryPrefix.Length)
    $currentDirectory = $repositoryRootPath
    foreach ($segment in $skillRelativePath.Split([System.IO.Path]::DirectorySeparatorChar)) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.','..')) {
            throw "Skill root contains an unsafe path segment: $skillRootPath"
        }
        $currentDirectory = Join-Path $currentDirectory $segment
        Assert-SkillInventoryDirectory -Path $currentDirectory -Context 'Skill inventory root hierarchy'
    }

    $inventoryLines = New-Object System.Collections.Generic.List[string]
    $paths = New-Object System.Collections.Generic.List[string]
    $hashesByPath = New-SkillInventoryPathMap
    $nfcPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    $asciiFoldPaths = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    $targetPathCasings = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @(Get-ChildItem -LiteralPath $skillRootPath -Recurse -Force -ErrorAction Stop)) {
        $relativePath = $item.FullName.Substring($repositoryRootPath.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        Assert-PortableSkillInventoryPath -RelativePath $relativePath -NfcPaths $nfcPaths -AsciiFoldPaths $asciiFoldPaths -TargetPathCasings $targetPathCasings
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Skill inventory contains a reparse point: $relativePath"
        }
        if ($item.PSIsContainer) { continue }

        if (-not (Test-SkillInventoryRegularFile -Path $item.FullName)) {
            throw "Skill inventory entry is not a regular file: $relativePath"
        }
        $fileStream = $null
        try {
            try {
                $fileStream = [System.IO.File]::Open(
                    $item.FullName,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read
                )
            }
            catch {
                throw "Skill inventory entry is not an accessible regular file: $relativePath"
            }
            if (-not $fileStream.CanRead -or -not $fileStream.CanSeek) {
                throw "Skill inventory entry is not a regular file: $relativePath"
            }
            $hashesByPath[$relativePath] = Get-ArchiveSha256 -Stream $fileStream
        }
        finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
        }
        $paths.Add($relativePath)
    }

    $orderedPaths = $paths.ToArray()
    [System.Array]::Sort($orderedPaths, [System.StringComparer]::Ordinal)
    foreach ($relativePath in $orderedPaths) {
        $inventoryLines.Add("$relativePath`t$($hashesByPath[$relativePath])`n")
    }

    $inventoryText = [string]::Concat($inventoryLines.ToArray())
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8WithoutBom.GetBytes($inventoryText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-YamlScalarValue {
    param(
        [Parameter(Mandatory = $true)][string] $RawValue,
        [Parameter(Mandatory = $true)][string] $Context
    )

    foreach ($character in $RawValue.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "$Context must not contain control characters."
        }
    }

    $value = $RawValue.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Context must be an explicit string scalar."
    }

    if ($value.StartsWith('[') -and -not $value.EndsWith(']')) {
        throw "$Context contains malformed YAML flow-sequence syntax."
    }
    if ($value.StartsWith('{') -and -not $value.EndsWith('}')) {
        throw "$Context contains malformed YAML flow-mapping syntax."
    }
    if ($value.StartsWith('"')) {
        if ($value.Length -lt 2 -or -not $value.EndsWith('"')) {
            throw "$Context contains an unterminated double-quoted YAML scalar."
        }
        try {
            $innerValue = ConvertFrom-Json -InputObject $value -ErrorAction Stop
        }
        catch {
            throw "$Context must use valid JSON-compatible double-quoted YAML syntax."
        }
        if ($innerValue -isnot [string]) {
            throw "$Context must decode to a string scalar."
        }
        foreach ($character in $innerValue.ToCharArray()) {
            if ([char]::IsControl($character)) {
                throw "$Context must not decode to a string containing control characters."
            }
        }
        return [string]$innerValue
    }
    if ($value.StartsWith("'")) {
        if ($value.Length -lt 2 -or -not $value.EndsWith("'")) {
            throw "$Context contains an unterminated single-quoted YAML scalar."
        }
        $innerValue = $value.Substring(1, $value.Length - 2)
        for ($index = 0; $index -lt $innerValue.Length; $index++) {
            if ($innerValue[$index] -ne "'") { continue }
            if ($index + 1 -ge $innerValue.Length -or $innerValue[$index + 1] -ne "'") {
                throw "$Context contains an unescaped single quote."
            }
            $index++
        }
        return $innerValue.Replace("''", "'")
    }

    if ($value -match '^[&*!]') {
        throw "$Context must not use YAML anchors, aliases, or custom tags."
    }
    if ($value -match '^(?:~|null|true|false|yes|no|on|off|\.nan|[-+]?\.inf)$') {
        throw "$Context must be a string and must not use an implicitly typed YAML scalar."
    }
    if ($value -match '^[-+]?(?:(?:0[xX][0-9a-fA-F_]+)|(?:0[oO][0-7_]+)|(?:0[bB][01_]+)|(?:[0-9][0-9_]*(?:\.[0-9_]*)?(?:[eE][-+]?[0-9_]+)?)|(?:\.[0-9_]+(?:[eE][-+]?[0-9_]+)?))$' -or
        $value -match '^[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+$' -or
        $value -match '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:$|[Tt ][0-9])') {
        throw "$Context must be a string and must not use an implicitly typed YAML number or timestamp."
    }
    if ($value -match '(?:^|\s)#' -or $value -match ':\s') {
        throw "$Context contains unsupported plain-scalar YAML comment or mapping syntax."
    }
    if ($value -match '^[\]\},]' -or $value -match '^[%@`]' -or $value -match '^(?:-\s|\?\s|:\s)') {
        throw "$Context starts with a reserved or unsupported YAML plain-scalar indicator."
    }

    # Required Agent Skill fields are scalar values. Reject collection/block markers here
    # instead of accepting malformed YAML that a standards-compliant validator rejects.
    if ($value -match '^[\[\{\|>]') {
        throw "$Context must be a scalar YAML value."
    }
    return $value
}

function Convert-SkillMetadataStringValue {
    param(
        [Parameter(Mandatory = $true)][string] $RawValue,
        [Parameter(Mandatory = $true)][string] $Context
    )

    foreach ($character in $RawValue.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "$Context must not contain control characters."
        }
    }

    $trimmed = $RawValue.Trim()
    $isQuoted = $trimmed.StartsWith("'") -or $trimmed.StartsWith('"')
    if (-not $isQuoted -and $trimmed -match '^[&*!]') {
        throw "$Context must not use YAML anchors, aliases, or custom tags."
    }
    if (-not $isQuoted -and $trimmed.IndexOfAny([char[]]@('[',']','{','}',',')) -ge 0) {
        throw "$Context must quote values containing YAML flow delimiters."
    }

    $value = Get-YamlScalarValue -RawValue $RawValue -Context $Context
    foreach ($character in $value.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "$Context must not contain control characters."
        }
    }
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 1024) {
        throw "$Context must be a non-empty string of at most 1024 characters."
    }
    return $value
}

function Split-SkillMetadataFlowEntries {
    param(
        [Parameter(Mandatory = $true)][string] $InnerValue,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $entries = New-Object System.Collections.Generic.List[string]
    $entryStart = 0
    $quote = [char]0
    for ($index = 0; $index -lt $InnerValue.Length; $index++) {
        $character = $InnerValue[$index]
        if ($quote -eq [char]0) {
            if ($character -eq "'" -or $character -eq '"') {
                $quote = $character
            }
            elseif ($character -eq ',') {
                $entries.Add($InnerValue.Substring($entryStart,$index - $entryStart))
                $entryStart = $index + 1
            }
        }
        elseif ($character -eq $quote) {
            if ($quote -eq "'" -and $index + 1 -lt $InnerValue.Length -and $InnerValue[$index + 1] -eq "'") {
                $index++
            }
            elseif ($quote -eq '"' -and $index -gt 0 -and $InnerValue[$index - 1] -eq '\') {
                $backslashCount = 1
                $backslashIndex = $index - 2
                while ($backslashIndex -ge 0 -and $InnerValue[$backslashIndex] -eq '\') {
                    $backslashCount++
                    $backslashIndex--
                }
                if (($backslashCount % 2) -eq 0) { $quote = [char]0 }
            }
            else {
                $quote = [char]0
            }
        }
    }
    if ($quote -ne [char]0) {
        throw "$Context contains an unterminated quoted scalar."
    }
    $entries.Add($InnerValue.Substring($entryStart))
    return $entries.ToArray()
}

function Convert-SkillMetadataFlowMapping {
    param(
        [Parameter(Mandatory = $true)][string] $RawValue,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $value = $RawValue.Trim()
    if (-not $value.StartsWith('{') -or -not $value.EndsWith('}')) {
        throw "$Context must be a YAML mapping."
    }
    $metadata = @{}
    $inner = $value.Substring(1,$value.Length - 2).Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) { return $metadata }
    foreach ($pair in @(Split-SkillMetadataFlowEntries -InnerValue $inner -Context $Context)) {
        if ($pair -notmatch '^\s*([A-Za-z0-9][A-Za-z0-9_.-]{0,127})\s*:\s*(.+?)\s*$') {
            throw "$Context contains an unsupported flow-mapping entry."
        }
        $metadataKey = $Matches[1]
        if ($metadata.ContainsKey($metadataKey)) { throw "$Context contains duplicate key '$metadataKey'." }
        $metadataValue = Convert-SkillMetadataStringValue -RawValue $Matches[2] -Context "$Context '$metadataKey'"
        $metadata[$metadataKey] = $metadataValue
    }
    return $metadata
}

function Assert-SkillDefinition {
    param(
        [Parameter(Mandatory = $true)][string] $SkillDefinitionPath,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId
    )

    $content = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($SkillDefinitionPath))
    $normalized = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $normalized.StartsWith("---`n", [System.StringComparison]::Ordinal)) {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md must start with YAML frontmatter."
    }

    $closingMarker = "`n---`n"
    $closingIndex = $normalized.IndexOf($closingMarker, 4, [System.StringComparison]::Ordinal)
    if ($closingIndex -lt 0) {
        # Also allow a closing delimiter at EOF.
        if ($normalized.EndsWith("`n---", [System.StringComparison]::Ordinal)) {
            $closingIndex = $normalized.Length - 4
        }
        else {
            throw "Selected Skill '$ExpectedSkillId' SKILL.md has unterminated YAML frontmatter."
        }
    }

    $frontmatter = $normalized.Substring(4, $closingIndex - 4)
    $properties = @{}
    $metadataProperties = $null
    $readingMetadataBlock = $false
    $metadataIndentLength = 0
    $lineNumber = 0
    foreach ($line in $frontmatter.Split("`n")) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }
        if ($line.Contains("`t")) {
            throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter line $lineNumber contains a tab, which is invalid YAML indentation."
        }
        if ($line -match '^\s') {
            if (-not $readingMetadataBlock -or $line -notmatch '^( +)([A-Za-z0-9][A-Za-z0-9_.-]{0,127})\s*:\s*(.+?)\s*$') {
                throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter line $lineNumber is not a supported metadata mapping entry."
            }
            $indentLength = $Matches[1].Length
            if ($metadataIndentLength -eq 0) { $metadataIndentLength = $indentLength }
            elseif ($indentLength -ne $metadataIndentLength) {
                throw "Selected Skill '$ExpectedSkillId' SKILL.md metadata must use one consistent mapping indentation level."
            }
            $metadataKey = $Matches[2]
            if ($metadataProperties.ContainsKey($metadataKey)) {
                throw "Selected Skill '$ExpectedSkillId' SKILL.md metadata contains duplicate key '$metadataKey'."
            }
            $metadataValue = Convert-SkillMetadataStringValue -RawValue $Matches[3] -Context "Selected Skill '$ExpectedSkillId' SKILL.md metadata '$metadataKey'"
            $metadataProperties[$metadataKey] = $metadataValue
            continue
        }
        $readingMetadataBlock = $false
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*)$') {
            throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter line $lineNumber is not valid top-level YAML mapping syntax."
        }

        $key = $Matches[1]
        $rawValue = $Matches[2]
        if ($key -cnotin @('name','description','license','allowed-tools','metadata')) {
            throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter contains unsupported top-level key '$key'."
        }
        if ($properties.ContainsKey($key)) {
            throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter contains duplicate key '$key'."
        }
        if ($key -ceq 'metadata') {
            if ([string]::IsNullOrWhiteSpace($rawValue)) {
                $metadataProperties = @{}
                $properties[$key] = $metadataProperties
                $readingMetadataBlock = $true
                $metadataIndentLength = 0
            }
            else {
                $properties[$key] = Convert-SkillMetadataFlowMapping -RawValue $rawValue -Context "Selected Skill '$ExpectedSkillId' SKILL.md metadata"
            }
            continue
        }
        $properties[$key] = Get-YamlScalarValue -RawValue $rawValue -Context "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter '$key'"
    }

    if (-not $properties.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$properties['name'])) {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter is missing name."
    }
    $name = [string]$properties['name']
    if ($name.Length -gt 64 -or $name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md name must be a lowercase stable ID."
    }
    if ($name -cne $ExpectedSkillId) {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md name '$name' does not match its stable Skill ID."
    }
    if (-not $properties.ContainsKey('description') -or [string]::IsNullOrWhiteSpace([string]$properties['description'])) {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md frontmatter is missing description."
    }
    if (([string]$properties['description']).Length -gt 1024) {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md description must not exceed 1024 characters."
    }
    if (([string]$properties['description']) -match '[<>]') {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md description must not contain angle brackets."
    }

    $bodyStart = if ($closingIndex -lt ($normalized.Length - 4)) { $closingIndex + $closingMarker.Length } else { $normalized.Length }
    $body = $normalized.Substring($bodyStart)
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "Selected Skill '$ExpectedSkillId' SKILL.md body must not be empty."
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

    $stagedSources = @()
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
        if ($expectedArchiveHash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Selected source '$sourceId' has an invalid archive SHA-256 pin."
        }

        $archiveStream = [System.IO.File]::Open(
            $archivePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        try {
            $actualArchiveHash = Get-ArchiveSha256 -Stream $archiveStream
            if ($actualArchiveHash -ne $expectedArchiveHash) {
                throw "Selected source '$sourceId' archive SHA-256 mismatch. Expected $expectedArchiveHash; actual $actualArchiveHash."
            }
            $archiveStream.Position = 0

            $sourceStagingPath = Get-SafeSourceStagingPath -WorkingRoot $workingRootPath -SourceId $sourceId
            if (Test-Path -LiteralPath $sourceStagingPath) {
                Remove-Item -LiteralPath $sourceStagingPath -Recurse -Force
            }
            New-Item -ItemType Directory -Path $sourceStagingPath | Out-Null
            $sourceRoot = Expand-SafeZipRepository -ArchiveStream $archiveStream -DestinationRoot $sourceStagingPath
        }
        finally {
            $archiveStream.Dispose()
        }

        $stagedSources += [pscustomobject][ordered]@{
            id = $sourceId
            rootPath = $sourceRoot
            archivePath = $archivePath
            archiveSha256 = $actualArchiveHash
            resolvedCommit = [string] $sourcePlan.resolvedCommit
        }
    }

    $stagedSourcesById = @{}
    foreach ($source in $stagedSources) {
        $stagedSourcesById[[string] $source.id] = $source
    }

    $resolvedSkills = @()
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
        Assert-SkillDefinition -SkillDefinitionPath $skillDefinition -ExpectedSkillId $skillId

        $expectedContentHash = [string]$skill.contentSha256
        if ($expectedContentHash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Selected Skill '$skillId' has an invalid content SHA-256 lock."
        }
        $actualContentHash = Get-SkillInventorySha256 -RepositoryRoot $sourceRoot -SkillRoot $skillRoot
        if ($actualContentHash -ne $expectedContentHash) {
            throw "Selected Skill '$skillId' content SHA-256 mismatch. Expected $expectedContentHash; actual $actualContentHash."
        }

        $resolvedSkills += [pscustomobject][ordered]@{
            id = $skillId
            sourceId = $sourceId
            sourcePath = $sourcePath
            sourceRootPath = $sourceRoot
            skillRootPath = $skillRoot
            contentSha256 = $actualContentHash
        }
    }

    return [pscustomobject][ordered]@{
        Sources = $stagedSources
        Skills = $resolvedSkills
    }
}

Export-ModuleMember -Function Expand-ValidatedSkillsSourceArchives, Get-SkillInventorySha256, Assert-SkillDefinition
