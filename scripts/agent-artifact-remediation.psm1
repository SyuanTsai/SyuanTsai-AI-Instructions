Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RemediationMessage = 'chore: stop tracking local AI instructions'
$script:RemediationUserName = 'Codex AI Instructions'
$script:RemediationUserEmail = 'codex-ai-instructions@example.invalid'
$script:RemediationExcludeBegin = '# BEGIN Codex AI Instructions remediated paths'
$script:RemediationExcludeEnd = '# END Codex AI Instructions remediated paths'

function Invoke-RemediationGit {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $GitExecutable -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-RemediationGitExitCode {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & $GitExecutable -C $Repository @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
}

function ConvertFrom-RemediationGitQuotedPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not ($Path.Length -ge 2 -and $Path[0] -eq '"' -and $Path[$Path.Length - 1] -eq '"')) {
        return $Path
    }

    $bytes = New-Object System.Collections.Generic.List[byte]
    $content = $Path.Substring(1,$Path.Length - 2)
    for ($index = 0; $index -lt $content.Length; $index++) {
        $character = $content[$index]
        if ($character -ne '\') {
            if ([int]$character -gt 0x7f) { throw "Git returned a non-ASCII byte in a quoted path: $Path" }
            $bytes.Add([byte][int]$character)
            continue
        }
        if (++$index -ge $content.Length) { throw "Git returned an incomplete quoted path escape: $Path" }
        $escape = $content[$index]
        $simpleEscapes = @{ 'a'=0x07; 'b'=0x08; 't'=0x09; 'n'=0x0a; 'v'=0x0b; 'f'=0x0c; 'r'=0x0d; '"'=0x22; '\'=0x5c }
        $escapeText = [string]$escape
        if ($simpleEscapes.ContainsKey($escapeText)) {
            $bytes.Add([byte]$simpleEscapes[$escapeText])
            continue
        }
        if ($escape -lt '0' -or $escape -gt '7' -or $index + 2 -ge $content.Length) {
            throw "Git returned an unsupported quoted path escape: $Path"
        }
        $octal = $content.Substring($index,3)
        if ($octal -cnotmatch '^[0-7]{3}$') { throw "Git returned an invalid octal path escape: $Path" }
        $bytes.Add([byte][Convert]::ToInt32($octal,8))
        $index += 2
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try { return $utf8.GetString($bytes.ToArray()) }
    catch { throw "Git returned a quoted path that is not valid UTF-8: $Path" }
}

function ConvertTo-RemediationPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('/') -or $Path.StartsWith('\')) {
        throw "Unsafe Repository-relative Agent artifact path: $Path"
    }
    $normalized = $Path.Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        [System.IO.Path]::IsPathRooted($normalized) -or
        $normalized.Contains(':') -or
        $normalized.IndexOf([char]0) -ge 0) {
        throw "Unsafe Repository-relative Agent artifact path: $Path"
    }
    foreach ($part in @($normalized -split '/')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') {
            throw "Unsafe Repository-relative Agent artifact path: $Path"
        }
    }
    return $normalized
}

function Test-IsReservedAgentArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowNull()][System.Collections.Generic.HashSet[string]] $LegacyManifestPaths
    )

    try { $normalized = ConvertTo-RemediationPath -Path $Path }
    catch { return $false }
    foreach ($exactPath in @(
        'AGENTS.md',
        'AGENTS.en.md',
        '.codex/ai-instructions.manifest.json',
        '.codex/AGENTS.md',
        '.codex/AGENTS.en.md',
        '.github/copilot-instructions.md',
        '.github/copilot-instructions.en.md'
    )) {
        if ($normalized.Equals($exactPath,[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($prefix in @(
        '.agents/',
        '.codex/skills/',
        '.github/AI-Rules/',
        '.github/agents/',
        '.github/instructions/',
        '.github/prompts/'
    )) {
        if ($normalized.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $null -ne $LegacyManifestPaths -and $LegacyManifestPaths.Contains($normalized)
}

function Test-IsAllowedLegacyAgentArtifactPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    try { $normalized = ConvertTo-RemediationPath -Path $Path }
    catch { return $false }
    if (Test-IsReservedAgentArtifactPath -Path $normalized) { return $true }
    return $normalized -match '^\.codex/AI-Rules/[^/\\]+\.md$'
}

function Get-RemediationPathComparer {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $GitExecutable)

    $ignoreCase = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ((Get-RemediationGitExitCode -Repository $Repository -GitExecutable $GitExecutable -Arguments @('config','--bool','--get','core.ignorecase')) -eq 0) {
        $configured = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('config','--bool','--get','core.ignorecase')) | Select-Object -First 1).Trim()
        if ($configured -ceq 'true') { $ignoreCase = $true }
    }
    if ($ignoreCase) { return [System.StringComparer]::OrdinalIgnoreCase }
    return [System.StringComparer]::Ordinal
}

function Get-RemediationTrackedPathSets {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $GitExecutable,[Parameter(Mandatory = $true)][System.StringComparer] $Comparer)

    $indexPaths = New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    foreach ($line in @(Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('-c','core.quotePath=true','ls-files'))) {
        [void]$indexPaths.Add((ConvertFrom-RemediationGitQuotedPath -Path ([string]$line)).Replace('\','/'))
    }
    $headPaths = New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    if ((Get-RemediationGitExitCode -Repository $Repository -GitExecutable $GitExecutable -Arguments @('rev-parse','--verify','HEAD')) -eq 0) {
        foreach ($line in @(Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('-c','core.quotePath=true','ls-tree','-r','--name-only','HEAD'))) {
            [void]$headPaths.Add((ConvertFrom-RemediationGitQuotedPath -Path ([string]$line)).Replace('\','/'))
        }
    }
    return [pscustomobject][ordered]@{ Index=$indexPaths; Head=$headPaths }
}

function Get-RemediationLegacyManifestPaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][System.StringComparer] $Comparer,
        [Parameter(Mandatory = $true)][object] $TrackedSets
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    $manifestPath = Join-Path $Repository '.codex\ai-instructions.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return ,$paths }
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json }
    catch { return ,$paths }
    foreach ($entry in @($manifest.files)) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['targetPath']) { continue }
        $targetPath = [string]$entry.targetPath
        if (-not (Test-IsAllowedLegacyAgentArtifactPath -Path $targetPath)) {
            $isTracked = $false
            try {
                $candidate = ConvertTo-RemediationPath -Path $targetPath
                $isTracked = $TrackedSets.Index.Contains($candidate) -or $TrackedSets.Head.Contains($candidate)
            }
            catch { }
            if ($isTracked) { throw "Tracked manifest target is outside the reserved Agent artifact scope: $targetPath" }
            continue
        }
        [void]$paths.Add((ConvertTo-RemediationPath -Path $targetPath))
    }
    return ,$paths
}

function Get-RemediationFullPath {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $RelativePath)

    $root = [System.IO.Path]::GetFullPath($Repository).TrimEnd([char[]]@('\','/'))
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath.Replace('/','\')))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Agent artifact path resolves outside the Repository: $RelativePath"
    }
    return $fullPath
}

function Assert-RemediationPathHasNoReparsePoint {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $RelativePath)

    $root = [System.IO.Path]::GetFullPath($Repository).TrimEnd([char[]]@('\','/'))
    $inspection = Get-RemediationFullPath -Repository $root -RelativePath $RelativePath
    while (-not $inspection.Equals($root,[System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $inspection) {
            $item = Get-Item -Force -LiteralPath $inspection
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reserved Agent artifact path crosses a reparse point: $RelativePath"
            }
        }
        $inspection = Split-Path -Parent $inspection
    }
}

function Get-RemediationSha256Text {
    param([Parameter(Mandatory = $true)][string] $Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Value)
        return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}

function Get-RemediationSha256Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-RemediationMutationPaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $TrackedPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $LegacyManifestPaths,
        [Parameter(Mandatory = $true)][System.StringComparer] $Comparer
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    foreach ($trackedPath in $TrackedPaths) { [void]$paths.Add([string]$trackedPath) }
    if (@($TrackedPaths | Where-Object { $Comparer.Equals([string]$_,'.codex/ai-instructions.manifest.json') }).Count -gt 0) {
        foreach ($manifestPath in $LegacyManifestPaths) { [void]$paths.Add([string]$manifestPath) }
    }
    foreach ($retiredPath in @(
        '.agents/skills/search-with-felo/SKILL.md',
        '.agents/skills/search-with-felo/agents/openai.yaml',
        '.agents/skills/search-with-felo/scripts/SearchWithFelo.psm1',
        '.agents/skills/search-with-felo/scripts/search-with-felo.ps1',
        '.codex/skills/search-with-felo/SKILL.md',
        '.codex/skills/search-with-felo/agents/openai.yaml',
        '.codex/skills/search-with-felo/scripts/SearchWithFelo.psm1',
        '.codex/skills/search-with-felo/scripts/search-with-felo.ps1'
    )) {
        $fullPath = Get-RemediationFullPath -Repository $Repository -RelativePath $retiredPath
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { [void]$paths.Add($retiredPath) }
    }
    return @($paths | Sort-Object)
}

function New-AgentArtifactRemediationBackup {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $TrackedPaths,
        [Parameter(Mandatory = $true)][string[]] $MutationPaths,
        [Parameter(Mandatory = $true)][System.StringComparer] $Comparer,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $CommonGitDirectory,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Head,
        [AllowEmptyString()][string] $HeadReference
    )

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
    $repositoryKey = (Get-RemediationSha256Text -Value ($Repository + '|' + $CommonGitDirectory + '|' + $HeadReference)).Substring(0,16)
    $backupRoot = Join-Path (Join-Path $tempRoot 'codex-agent-artifact-backups') ($repositoryKey + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff') + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $backupRoot 'files') -Force | Out-Null
    $backupIndexPath = Join-Path $backupRoot 'index'
    [System.IO.File]::Copy($IndexPath,$backupIndexPath,$false)
    $backupIndexSha256 = Get-RemediationSha256Bytes -Bytes ([System.IO.File]::ReadAllBytes($backupIndexPath))
    $inventory = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in $MutationPaths) {
        Assert-RemediationPathHasNoReparsePoint -Repository $Repository -RelativePath $relativePath
        $sourcePath = Get-RemediationFullPath -Repository $Repository -RelativePath $relativePath
        $exists = Test-Path -LiteralPath $sourcePath -PathType Leaf
        if ($exists) {
            $destinationPath = Join-Path (Join-Path $backupRoot 'files') $relativePath.Replace('/','\')
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
            [System.IO.File]::Copy($sourcePath,$destinationPath,$false)
            $backupFile = Get-Item -Force -LiteralPath $destinationPath
            $inventory.Add([pscustomobject][ordered]@{
                path=$relativePath
                exists=$true
                length=[long]$backupFile.Length
                sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $destinationPath).Hash.ToLowerInvariant()
                tracked=@($TrackedPaths | Where-Object { $Comparer.Equals([string]$_,$relativePath) }).Count -gt 0
            })
        }
        else {
            $inventory.Add([pscustomobject][ordered]@{
                path=$relativePath
                exists=$false
                length=0
                sha256=$null
                tracked=@($TrackedPaths | Where-Object { $Comparer.Equals([string]$_,$relativePath) }).Count -gt 0
            })
        }
    }

    $metadata = [ordered]@{
        schemaVersion=1
        createdAtUtc=[DateTime]::UtcNow.ToString('o')
        worktreeRoot=$Repository
        gitCommonDirectory=$CommonGitDirectory
        head=$Head
        headReference=$HeadReference
        indexSha256=$backupIndexSha256
        trackedReservedPaths=@($TrackedPaths | Sort-Object)
        mutationPaths=@($MutationPaths | Sort-Object)
        statusPorcelainV2=@(Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('status','--porcelain=v2','--untracked-files=all'))
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $backupRoot 'metadata.json'),(($metadata | ConvertTo-Json -Depth 10).Replace("`r`n","`n") + "`n"),$utf8)
    [System.IO.File]::WriteAllText((Join-Path $backupRoot 'sha256-inventory.json'),((@($inventory | Sort-Object path) | ConvertTo-Json -Depth 10).Replace("`r`n","`n") + "`n"),$utf8)
    [System.IO.File]::WriteAllText((Join-Path $backupRoot 'staged.diff'),((@(Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('diff','--cached','--binary')) -join "`n") + "`n"),$utf8)
    [System.IO.File]::WriteAllText((Join-Path $backupRoot 'unstaged.diff'),((@(Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('diff','--binary')) -join "`n") + "`n"),$utf8)
    return [pscustomobject][ordered]@{Root=$backupRoot;IndexSha256=$backupIndexSha256;Inventory=@($inventory | Sort-Object path)}
}

function Get-RemediationGitInfoExcludePath {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $GitExecutable,[Parameter(Mandatory = $true)][string] $CommonGitDirectory)

    $path = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('rev-parse','--git-path','info/exclude')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Repository $path }
    $path = [System.IO.Path]::GetFullPath($path)
    $expected = [System.IO.Path]::GetFullPath((Join-Path $CommonGitDirectory 'info\exclude'))
    if (-not $path.Equals($expected,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Shared Git exclude path is outside the Git common directory: $path"
    }
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $parentItem = Get-Item -Force -LiteralPath $parent
    if (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Shared Git info directory must not be a reparse point: $parent"
    }
    return $path
}

function ConvertTo-RemediationExcludePattern {
    param([Parameter(Mandatory = $true)][string] $Path)

    $escaped = $Path.Replace('\','/').TrimEnd('/')
    foreach ($character in @('\','[',']','*','?')) { $escaped = $escaped.Replace($character,"\$character") }
    if ($escaped.StartsWith('!') -or $escaped.StartsWith('#')) { $escaped = "\$escaped" }
    if ($Path.EndsWith('/')) { return "/$escaped/" }
    return "/$escaped"
}

function Set-RemediationGitInfoExclude {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string[]] $Patterns)

    $existed = Test-Path -LiteralPath $Path -PathType Leaf
    [byte[]]$beforeBytes = if ($existed) { [System.IO.File]::ReadAllBytes($Path) } else { [byte[]]@() }
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $content = if ($beforeBytes.Length -eq 0) { '' } else { $utf8.GetString($beforeBytes) }
    $content = $content.Replace("`r`n","`n").Replace("`r","`n")
    $blockPattern = '(?ms)^' + [regex]::Escape($script:RemediationExcludeBegin) + '\n.*?^' + [regex]::Escape($script:RemediationExcludeEnd) + '\n?'
    $beginCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($script:RemediationExcludeBegin) + '$').Count
    $endCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($script:RemediationExcludeEnd) + '$').Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1 -or ($beginCount -eq 1 -and -not [regex]::IsMatch($content,$blockPattern))) {
        throw "The remediated Agent artifact exclude block is malformed: $Path"
    }
    $storedPatterns = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($beginCount -eq 1) {
        foreach ($line in @([regex]::Match($content,$blockPattern).Value.Replace("`r`n","`n").Split("`n"))) {
            if (-not [string]::IsNullOrWhiteSpace($line) -and $line -cne $script:RemediationExcludeBegin -and $line -cne $script:RemediationExcludeEnd) {
                [void]$storedPatterns.Add($line)
            }
        }
    }
    foreach ($item in $Patterns) { [void]$storedPatterns.Add((ConvertTo-RemediationExcludePattern -Path $item)) }
    $withoutBlock = [regex]::Replace($content,$blockPattern,'').TrimEnd("`n")
    $block = $script:RemediationExcludeBegin + "`n" + (@($storedPatterns | Sort-Object) -join "`n") + "`n" + $script:RemediationExcludeEnd + "`n"
    $updated = if ([string]::IsNullOrWhiteSpace($withoutBlock)) { $block } else { $withoutBlock + "`n`n" + $block }
    [byte[]]$updatedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($updated)
    [System.IO.File]::WriteAllBytes($Path,$updatedBytes)
    return [pscustomobject][ordered]@{Path=$Path;Existed=$existed;Before=$beforeBytes;Applied=$updatedBytes}
}

function Set-RemediationIndexWithoutPaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $ExpectedIndexSha256,
        [Parameter(Mandatory = $true)][string[]] $Paths
    )

    $lockPath = $IndexPath + '.lock'
    $lockStream = $null
    $temporaryIndex = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-agent-remediation-index-' + [Guid]::NewGuid().ToString('N'))
    $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
    $priorAlternateIndex = $env:GIT_INDEX_FILE
    $committed = $false
    try {
        try { $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
        catch [System.IO.IOException] { throw 'The Git index is being changed by another process; remediation stopped before mutation.' }
        [byte[]]$currentIndexBytes = [System.IO.File]::ReadAllBytes($IndexPath)
        $currentIndexSha256 = Get-RemediationSha256Bytes -Bytes $currentIndexBytes
        if ($currentIndexSha256 -cne $ExpectedIndexSha256) {
            throw 'Git index changed after the remediation backup; remediation stopped before index mutation.'
        }
        [System.IO.File]::WriteAllBytes($temporaryIndex,$currentIndexBytes)
        $env:GIT_INDEX_FILE = $temporaryIndex
        Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments (@('update-index','--force-remove','--') + $Paths) | Out-Null
        [byte[]]$preparedBytes = [System.IO.File]::ReadAllBytes($temporaryIndex)
        $preparedSha256 = Get-RemediationSha256Bytes -Bytes $preparedBytes
        $lockStream.SetLength(0)
        $lockStream.Write($preparedBytes,0,$preparedBytes.Length)
        $lockStream.Flush($true)
        $lockStream.Dispose()
        $lockStream = $null
        Move-Item -LiteralPath $lockPath -Destination $IndexPath -Force
        $committed = $true
        return $preparedSha256
    }
    finally {
        if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
        else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if (-not $committed -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
        foreach ($temporaryPath in @($temporaryIndex,($temporaryIndex + '.lock'))) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function New-RemediationCommitObject {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string] $Head,
        [Parameter(Mandatory = $true)][string[]] $Paths
    )

    $temporaryIndex = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-agent-remediation-commit-index-' + [Guid]::NewGuid().ToString('N'))
    $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
    $priorAlternateIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $temporaryIndex
        Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('read-tree',$Head) | Out-Null
        Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments (@('update-index','--force-remove','--') + $Paths) | Out-Null
        $tree = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('write-tree')) | Select-Object -First 1).Trim()
        $headTree = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('rev-parse',"$Head^{tree}")) | Select-Object -First 1).Trim()
        if ($tree -ceq $headTree) { return $null }
        return ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @(
            '-c',"user.name=$script:RemediationUserName",
            '-c',"user.email=$script:RemediationUserEmail",
            'commit-tree',$tree,'-p',$Head,'-m',$script:RemediationMessage
        )) | Select-Object -First 1).Trim()
    }
    finally {
        if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
        else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        foreach ($temporaryPath in @($temporaryIndex,($temporaryIndex + '.lock'))) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Remove-RemediationFiles {
    param([Parameter(Mandatory = $true)][object] $Transaction)

    foreach ($relativePath in $Transaction.MutationPaths) {
        Assert-RemediationPathHasNoReparsePoint -Repository $Transaction.Repository -RelativePath $relativePath
        $fullPath = Get-RemediationFullPath -Repository $Transaction.Repository -RelativePath $relativePath
        $inventoryEntry = @($Transaction.Backup.Inventory | Where-Object { ([string]$_.path).Equals($relativePath,[System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
        if ($inventoryEntry.Count -ne 1) { throw "Agent artifact backup inventory is missing: $relativePath" }
        $entry = $inventoryEntry[0]
        if (-not (Test-Path -LiteralPath $fullPath)) {
            if ([bool]$entry.exists) { throw "Agent artifact changed after backup; concurrent deletion was preserved: $relativePath" }
            continue
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Expected an exact Agent artifact file but found a directory: $relativePath" }
        if (-not [bool]$entry.exists) { throw "Agent artifact changed after backup; concurrent file was preserved: $relativePath" }
        $currentSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
        if ($currentSha256 -cne [string]$entry.sha256) {
            throw "Agent artifact changed after backup; concurrent bytes were preserved: $relativePath"
        }
        $item = Get-Item -Force -LiteralPath $fullPath
        if (($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.File]::Delete($fullPath)
        $Transaction.FilesRemoved.Add($relativePath)
    }
}

function Remove-EmptyRetiredFeloDirectories {
    param([Parameter(Mandatory = $true)][string] $Repository)

    foreach ($relativePath in @(
        '.agents/skills/search-with-felo/scripts',
        '.agents/skills/search-with-felo/agents',
        '.agents/skills/search-with-felo',
        '.codex/skills/search-with-felo/scripts',
        '.codex/skills/search-with-felo/agents',
        '.codex/skills/search-with-felo'
    )) {
        Assert-RemediationPathHasNoReparsePoint -Repository $Repository -RelativePath $relativePath
        $fullPath = Get-RemediationFullPath -Repository $Repository -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { continue }
        if (@(Get-ChildItem -Force -LiteralPath $fullPath).Count -eq 0) { [System.IO.Directory]::Delete($fullPath,$false) }
    }
}

function Set-RemediationHead {
    param([Parameter(Mandatory = $true)][object] $Transaction)

    if ([string]::IsNullOrWhiteSpace([string]$Transaction.NewCommit)) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$Transaction.OriginalHeadReference)) {
        Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @(
            'update-ref',$Transaction.OriginalHeadReference,$Transaction.NewCommit,$Transaction.OriginalHead
        ) | Out-Null
        $Transaction.NewHeadReference = $Transaction.OriginalHeadReference
        return
    }

    $baseName = 'refs/heads/codex/ai-instructions-remediation-' + $Transaction.OriginalHead.Substring(0,12)
    $candidate = $baseName
    $suffix = 1
    while ((Get-RemediationGitExitCode -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @('show-ref','--verify','--quiet',$candidate)) -eq 0) {
        $candidate = $baseName + '-' + $suffix
        $suffix++
    }
    Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @('update-ref',$candidate,$Transaction.NewCommit) | Out-Null
    try { Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @('symbolic-ref','HEAD',$candidate) | Out-Null }
    catch {
        $symbolicRefError = $_
        try { Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @('update-ref','-d',$candidate,$Transaction.NewCommit) | Out-Null }
        catch { throw "Detached HEAD remediation branch activation failed: $($symbolicRefError.Exception.Message) Branch cleanup also failed: $($_.Exception.Message)" }
        throw $symbolicRefError
    }
    $Transaction.NewHeadReference = $candidate
}

function Restore-RemediationHead {
    param([Parameter(Mandatory = $true)][object] $Transaction)

    if ([string]::IsNullOrWhiteSpace([string]$Transaction.NewCommit)) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$Transaction.OriginalHeadReference)) {
        Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @(
            'update-ref',$Transaction.OriginalHeadReference,$Transaction.OriginalHead,$Transaction.NewCommit
        ) | Out-Null
        return
    }
    Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @(
        'update-ref','--no-deref','HEAD',$Transaction.OriginalHead,$Transaction.NewCommit
    ) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$Transaction.NewHeadReference)) {
        Invoke-RemediationGit -Repository $Transaction.Repository -GitExecutable $Transaction.GitExecutable -Arguments @(
            'update-ref','-d',$Transaction.NewHeadReference,$Transaction.NewCommit
        ) | Out-Null
    }
}

function Restore-RemediationFiles {
    param([Parameter(Mandatory = $true)][object] $Transaction)

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in @($Transaction.FilesRemoved)) {
        $entry = @($Transaction.Backup.Inventory | Where-Object { ([string]$_.path).Equals([string]$relativePath,[System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
        if ($null -eq $entry) { $errors.Add("Agent artifact backup inventory is missing: $relativePath"); continue }
        $relativePath = [string]$relativePath
        try { Assert-RemediationPathHasNoReparsePoint -Repository $Transaction.Repository -RelativePath $relativePath }
        catch { $errors.Add($_.Exception.Message); continue }
        $targetPath = Get-RemediationFullPath -Repository $Transaction.Repository -RelativePath $relativePath
        if (Test-Path -LiteralPath $targetPath) {
            if ([bool]$entry.exists -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                $currentSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
                if ($currentSha256 -ceq [string]$entry.sha256) { continue }
            }
            $errors.Add("Agent artifact path changed after remediation; concurrent bytes were preserved: $relativePath")
            continue
        }
        if (-not [bool]$entry.exists) { continue }
        $sourcePath = Join-Path (Join-Path $Transaction.Backup.Root 'files') $relativePath.Replace('/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        [System.IO.File]::Copy($sourcePath,$targetPath,$false)
    }
    if ($errors.Count -gt 0) { throw ($errors -join ' | ') }
}

function Restore-RemediationExclude {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Snapshot)

    if ($null -eq $Snapshot) { return }
    [byte[]]$current = if (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) { [System.IO.File]::ReadAllBytes($Snapshot.Path) } else { [byte[]]@() }
    if ([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String([byte[]]$Snapshot.Applied)) {
        throw "Shared Git exclude changed after remediation; concurrent bytes were preserved: $($Snapshot.Path)"
    }
    if ([bool]$Snapshot.Existed) { [System.IO.File]::WriteAllBytes($Snapshot.Path,[byte[]]$Snapshot.Before) }
    elseif (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) { [System.IO.File]::Delete($Snapshot.Path) }
}

function Restore-AgentArtifactRemediation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Transaction)

    if ([bool]$Transaction.RolledBack) { return }
    if ([bool]$Transaction.RollbackAttempted) { throw "Agent artifact remediation rollback was already attempted. Backup: $($Transaction.Backup.Root)" }
    $Transaction.RollbackAttempted = $true
    $errors = New-Object System.Collections.Generic.List[string]
    if ([bool]$Transaction.HeadUpdated) {
        try { Restore-RemediationHead -Transaction $Transaction } catch { $errors.Add($_.Exception.Message) }
    }
    if ([bool]$Transaction.IndexMutated) {
        try {
            if (-not (Test-Path -LiteralPath $Transaction.IndexPath -PathType Leaf)) {
                throw "Git index disappeared after remediation: $($Transaction.IndexPath)"
            }
            $currentIndexSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Transaction.IndexPath).Hash.ToLowerInvariant()
            if ($currentIndexSha256 -cne [string]$Transaction.AppliedIndexSha256) {
                throw "Git index changed after remediation; concurrent index bytes were preserved: $($Transaction.IndexPath)"
            }
            [System.IO.File]::Copy((Join-Path $Transaction.Backup.Root 'index'),$Transaction.IndexPath,$true)
        }
        catch { $errors.Add($_.Exception.Message) }
    }
    try { Restore-RemediationFiles -Transaction $Transaction } catch { $errors.Add($_.Exception.Message) }
    try { Restore-RemediationExclude -Snapshot $Transaction.ExcludeSnapshot } catch { $errors.Add($_.Exception.Message) }
    if ($errors.Count -gt 0) {
        throw "Agent artifact remediation rollback failed: $($errors -join ' | '). Backup: $($Transaction.Backup.Root)"
    }
    $Transaction.RolledBack = $true
}

function Invoke-AgentArtifactRemediation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [string] $GitExecutable = 'git'
    )

    $repositoryRoot = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
    $repositoryRoot = [System.IO.Path]::GetFullPath($repositoryRoot).TrimEnd([char[]]@('\','/'))
    $commonGitDirectory = ((Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $repositoryRoot $commonGitDirectory }
    $commonGitDirectory = [System.IO.Path]::GetFullPath($commonGitDirectory).TrimEnd([char[]]@('\','/'))
    $gitDirectory = ((Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('rev-parse','--git-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $repositoryRoot $gitDirectory }
    $gitDirectory = [System.IO.Path]::GetFullPath($gitDirectory).TrimEnd([char[]]@('\','/'))
    foreach ($directory in @($commonGitDirectory,$gitDirectory)) {
        $item = Get-Item -Force -LiteralPath $directory
        if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Git metadata directory must be a non-reparse directory: $directory"
        }
    }
    $indexPath = ((Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('rev-parse','--git-path','index')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $repositoryRoot $indexPath }
    $indexPath = [System.IO.Path]::GetFullPath($indexPath)
    $expectedIndexPath = [System.IO.Path]::GetFullPath((Join-Path $gitDirectory 'index'))
    if (-not $indexPath.Equals($expectedIndexPath,[System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "Active worktree Git index is missing or outside its Git directory: $indexPath"
    }
    if (((Get-Item -Force -LiteralPath $indexPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Active worktree Git index must not be a reparse point: $indexPath"
    }

    $comparer = Get-RemediationPathComparer -Repository $repositoryRoot -GitExecutable $GitExecutable
    $trackedSets = Get-RemediationTrackedPathSets -Repository $repositoryRoot -GitExecutable $GitExecutable -Comparer $comparer
    $legacyManifestPaths = Get-RemediationLegacyManifestPaths -Repository $repositoryRoot -Comparer $comparer -TrackedSets $trackedSets
    $trackedReserved = New-Object 'System.Collections.Generic.HashSet[string]' $comparer
    foreach ($trackedPath in @(@($trackedSets.Index) + @($trackedSets.Head))) {
        if (Test-IsReservedAgentArtifactPath -Path ([string]$trackedPath) -LegacyManifestPaths $legacyManifestPaths) {
            [void]$trackedReserved.Add([string]$trackedPath)
        }
    }
    $trackedPaths = @($trackedReserved | Sort-Object)
    $mutationPaths = @(Get-RemediationMutationPaths -Repository $repositoryRoot -TrackedPaths $trackedPaths `
        -LegacyManifestPaths $legacyManifestPaths -Comparer $comparer)
    if ($mutationPaths.Count -eq 0) { return $null }
    $head = ''
    if ((Get-RemediationGitExitCode -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('rev-parse','--verify','HEAD')) -eq 0) {
        $head = ((Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('rev-parse','--verify','HEAD')) | Select-Object -First 1).Trim()
    }
    $headReference = ''
    if ((Get-RemediationGitExitCode -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('symbolic-ref','-q','HEAD')) -eq 0) {
        $headReference = ((Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('symbolic-ref','-q','HEAD')) | Select-Object -First 1).Trim()
    }
    $backup = New-AgentArtifactRemediationBackup -Repository $repositoryRoot -GitExecutable $GitExecutable -TrackedPaths $trackedPaths `
        -MutationPaths $mutationPaths -Comparer $comparer -IndexPath $indexPath -CommonGitDirectory $commonGitDirectory `
        -Head $head -HeadReference $headReference
    $excludePath = Get-RemediationGitInfoExcludePath -Repository $repositoryRoot -GitExecutable $GitExecutable -CommonGitDirectory $commonGitDirectory
    $excludePatterns = @($mutationPaths + @('.agents/skills/search-with-felo/','.codex/skills/search-with-felo/') | Sort-Object -Unique)
    $transaction = [pscustomobject][ordered]@{
        Repository=$repositoryRoot
        GitExecutable=$GitExecutable
        CommonGitDirectory=$commonGitDirectory
        IndexPath=$indexPath
        OriginalHead=$head
        OriginalHeadReference=$headReference
        NewHeadReference=''
        NewCommit=$null
        HeadUpdated=$false
        Paths=$trackedPaths
        MutationPaths=$mutationPaths
        FilesRemoved=(New-Object 'System.Collections.Generic.List[string]')
        Backup=$backup
        ExcludeSnapshot=$null
        IndexMutated=$false
        AppliedIndexSha256=$null
        RollbackAttempted=$false
        RolledBack=$false
    }

    try {
        if ($trackedPaths.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($head)) {
            $transaction.NewCommit = New-RemediationCommitObject -Repository $repositoryRoot -GitExecutable $GitExecutable -Head $head -Paths $trackedPaths
        }
        $transaction.ExcludeSnapshot = Set-RemediationGitInfoExclude -Path $excludePath -Patterns $excludePatterns
        if ($trackedPaths.Count -gt 0) {
            $transaction.AppliedIndexSha256 = Set-RemediationIndexWithoutPaths -Repository $repositoryRoot -GitExecutable $GitExecutable `
                -IndexPath $indexPath -ExpectedIndexSha256 $backup.IndexSha256 -Paths $trackedPaths
            $transaction.IndexMutated = $true
        }
        Remove-RemediationFiles -Transaction $transaction
        Remove-EmptyRetiredFeloDirectories -Repository $repositoryRoot
        Set-RemediationHead -Transaction $transaction
        if (-not [string]::IsNullOrWhiteSpace([string]$transaction.NewCommit)) { $transaction.HeadUpdated = $true }

        $currentTrackedSets = Get-RemediationTrackedPathSets -Repository $repositoryRoot -GitExecutable $GitExecutable -Comparer $comparer
        foreach ($trackedPath in $trackedPaths) {
            if ($currentTrackedSets.Index.Contains($trackedPath)) {
                throw "Reserved Agent artifact remains in the Git index after remediation: $trackedPath"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$transaction.NewCommit)) {
            $commitChanges = @(Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('-c','core.quotePath=true','diff-tree','--no-commit-id','--name-status','-r',$transaction.NewCommit))
            if ($commitChanges.Count -eq 0) { throw 'Remediation commit unexpectedly contains no reserved path deletions.' }
            foreach ($change in $commitChanges) {
                $match = [regex]::Match([string]$change,'^D\s+(?<Path>.+)$')
                if (-not $match.Success) { throw "Remediation commit contains a non-deletion change: $change" }
                $changedPath = (ConvertFrom-RemediationGitQuotedPath -Path $match.Groups['Path'].Value).Replace('\','/')
                if (-not $trackedReserved.Contains($changedPath)) {
                    throw "Remediation commit contains a non-reserved change: $change"
                }
            }
        }
    }
    catch {
        $errorRecord = $_
        try { Restore-AgentArtifactRemediation -Transaction $transaction }
        catch { throw "Agent artifact remediation failed: $($errorRecord.Exception.Message) $($_.Exception.Message)" }
        throw "Agent artifact remediation failed: $($errorRecord.Exception.Message) Backup: $($backup.Root)"
    }
    return $transaction
}

Export-ModuleMember -Function Invoke-AgentArtifactRemediation, Restore-AgentArtifactRemediation, Test-IsReservedAgentArtifactPath
