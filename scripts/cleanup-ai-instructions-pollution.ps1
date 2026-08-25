[CmdletBinding()]
param(
    [Alias('RepositoryRoot')]
    [string] $TargetRoot,
    [switch] $Authorize,
    [string] $GitExecutable = 'git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Test-Path Env:GIT_INDEX_FILE) {
    throw 'Pollution cleanup requires the active worktree Git index; unset GIT_INDEX_FILE before retrying.'
}

$manifestRelativePath = '.codex/ai-instructions.manifest.json'
$excludeBeginMarker = '# BEGIN Codex AI Instructions managed paths'
$excludeEndMarker = '# END Codex AI Instructions managed paths'

$installedRuntimeReadLock = $null
try {
$installedRuntimeRoot = Join-Path $PSScriptRoot 'ai-instructions-runtime'
$entryPointDirectoryName = Split-Path -Leaf ([System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]@('\','/')))
$isInstalledStableEntryPoint = $entryPointDirectoryName -ieq 'hooks'
if ($isInstalledStableEntryPoint -and -not (Test-Path -LiteralPath $installedRuntimeRoot -PathType Container)) {
    throw "Installed runtime directory is missing or invalid: $installedRuntimeRoot"
}
if (Test-Path -LiteralPath $installedRuntimeRoot -PathType Container) {
    $installedLauncher = Join-Path $PSScriptRoot 'bootstrap-ai-instructions.ps1'
    if (-not (Test-Path -LiteralPath $installedLauncher -PathType Leaf)) { throw "Installed AI instructions preflight launcher is missing: $installedLauncher" }
    $installedCodexHome = Split-Path -Parent $PSScriptRoot
    $installedLockPath = Join-Path $installedCodexHome 'ai-instructions-install.lock'
    if (-not (Test-Path -LiteralPath $installedLockPath -PathType Leaf)) { throw 'AI instructions install lock is missing from the installed runtime.' }
    $installedLockItem = Get-Item -Force -LiteralPath $installedLockPath
    if ($installedLockItem.PSIsContainer -or ($installedLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'AI instructions install lock must be a non-reparse file.'
    }
    try {
        $installedRuntimeReadLock = [System.IO.File]::Open(
            $installedLockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
    }
    catch [System.IO.IOException] {
        throw 'AI instructions runtime is being installed; cleanup stopped before reading a mixed runtime.'
    }
    & $installedLauncher -ValidateOnly
}

$manifestContractPath = Join-Path $PSScriptRoot 'ai-instructions-runtime\skills-catalog-contract.psm1'
if (-not (Test-Path -LiteralPath $manifestContractPath -PathType Leaf)) {
    $manifestContractPath = Join-Path $PSScriptRoot 'skills-catalog-contract.psm1'
}
if (-not (Test-Path -LiteralPath $manifestContractPath -PathType Leaf)) {
    throw "Managed manifest contract module was not found: $manifestContractPath"
}
Import-Module $manifestContractPath -Force

$runtimeContractPath = Join-Path $PSScriptRoot 'ai-instructions-runtime\ai-instructions-runtime-contract.psm1'
if (-not (Test-Path -LiteralPath $runtimeContractPath -PathType Leaf)) {
    $runtimeContractPath = Join-Path $PSScriptRoot 'ai-instructions-runtime-contract.psm1'
}
if (-not (Test-Path -LiteralPath $runtimeContractPath -PathType Leaf)) {
    throw "AI instructions runtime contract module was not found: $runtimeContractPath"
}
Import-Module $runtimeContractPath -Force

function Invoke-CleanupGit {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $GitExecutable -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Get-CleanupGitExitCode {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & $GitExecutable -C $Repository @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
}

function ConvertFrom-CleanupGitQuotedPath {
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

function Get-CleanupIndexSnapshot {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $Paths)

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in @(Invoke-CleanupGit -Repository $Repository -Arguments (@('-c','core.quotePath=true','ls-files','--stage','--') + $Paths))) {
        $match = [System.Text.RegularExpressions.Regex]::Match([string]$line,'^(?<Mode>[0-7]{6}) (?<Hash>[0-9a-f]{40,64}) (?<Stage>[0-3])\t(?<Path>.+)$')
        if (-not $match.Success) { throw "Unable to capture an exact Git index entry for rollback: $line" }
        $decodedPath = ConvertFrom-CleanupGitQuotedPath -Path $match.Groups['Path'].Value
        $entries.Add([pscustomobject][ordered]@{
            Line = "$($match.Groups['Mode'].Value) $($match.Groups['Hash'].Value) $($match.Groups['Stage'].Value)`t$decodedPath"
            Path = $decodedPath
            Mode = $match.Groups['Mode'].Value
            Hash = $match.Groups['Hash'].Value
            Stage = [int]$match.Groups['Stage'].Value
        })
    }
    return $entries
}

function Remove-CleanupIndexEntriesAtomically {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $ExpectedSnapshot
    )

    $indexPath = ((Invoke-CleanupGit -Repository $Repository -Arguments @('rev-parse','--git-path','index')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $Repository $indexPath }
    $indexPath = [System.IO.Path]::GetFullPath($indexPath)
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "Git index file is missing: $indexPath" }
    $indexItem = Get-Item -Force -LiteralPath $indexPath
    if (($indexItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Git index file must not be a reparse point: $indexPath" }
    $indexParent = Split-Path -Parent $indexPath
    $indexParentItem = Get-Item -Force -LiteralPath $indexParent
    if (-not $indexParentItem.PSIsContainer -or ($indexParentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Git index parent must be a non-reparse directory: $indexParent"
    }

    $indexLockPath = $indexPath + '.lock'
    $indexLockStream = $null
    $committed = $false
    $temporaryIndexPath = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-cleanup-index-' + [Guid]::NewGuid().ToString('N'))
    $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
    $priorAlternateIndex = $env:GIT_INDEX_FILE
    try {
        try {
            $indexLockStream = [System.IO.File]::Open($indexLockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            throw 'The Git index is being changed by another process; cleanup stopped before mutation.'
        }

        $currentSnapshot = @(Get-CleanupIndexSnapshot -Repository $Repository -Paths $Paths)
        if ((@($currentSnapshot | ForEach-Object { [string]$_.Line }) -join "`n") -cne
            (@($ExpectedSnapshot | ForEach-Object { [string]$_.Line }) -join "`n")) {
            throw 'Tracked managed paths changed in the Git index after cleanup acquired the index lock.'
        }

        [System.IO.File]::Copy($indexPath,$temporaryIndexPath,$false)
        $env:GIT_INDEX_FILE = $temporaryIndexPath
        Invoke-CleanupGit -Repository $Repository -Arguments (@('update-index','--force-remove','--') + $Paths) | Out-Null
        if (@(Get-CleanupIndexSnapshot -Repository $Repository -Paths $Paths).Count -ne 0) {
            throw 'The prepared cleanup index still contains managed paths.'
        }

        $preparedBytes = [System.IO.File]::ReadAllBytes($temporaryIndexPath)
        $indexLockStream.SetLength(0)
        $indexLockStream.Write($preparedBytes,0,$preparedBytes.Length)
        $indexLockStream.Flush($true)
        $indexLockStream.Dispose()
        $indexLockStream = $null
        Move-Item -LiteralPath $indexLockPath -Destination $indexPath -Force
        $committed = $true
    }
    finally {
        if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
        else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        if ($null -ne $indexLockStream) { $indexLockStream.Dispose() }
        if (-not $committed -and (Test-Path -LiteralPath $indexLockPath -PathType Leaf)) {
            Remove-Item -LiteralPath $indexLockPath -Force -ErrorAction SilentlyContinue
        }
        foreach ($temporaryPath in @($temporaryIndexPath,($temporaryIndexPath + '.lock'))) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Restore-CleanupIndexSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Snapshot
    )

    $indexPath = ((Invoke-CleanupGit -Repository $Repository -Arguments @('rev-parse','--git-path','index')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $Repository $indexPath }
    $indexPath = [System.IO.Path]::GetFullPath($indexPath)
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "Git index file is missing during rollback: $indexPath" }
    $indexItem = Get-Item -Force -LiteralPath $indexPath
    if (($indexItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Git index file must not be a reparse point during rollback: $indexPath" }
    $indexParent = Split-Path -Parent $indexPath
    $indexParentItem = Get-Item -Force -LiteralPath $indexParent
    if (-not $indexParentItem.PSIsContainer -or ($indexParentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Git index parent must be a non-reparse directory during rollback: $indexParent"
    }

    $indexLockPath = $indexPath + '.lock'
    $indexLockStream = $null
    $committed = $false
    $temporaryIndexPath = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-cleanup-rollback-index-' + [Guid]::NewGuid().ToString('N'))
    $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
    $priorAlternateIndex = $env:GIT_INDEX_FILE
    $driftedPaths = New-Object System.Collections.Generic.List[string]
    try {
        try {
            $indexLockStream = [System.IO.File]::Open($indexLockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            throw 'The Git index is being changed by another process; cleanup rollback stopped before mutation.'
        }

        $current = @(Get-CleanupIndexSnapshot -Repository $Repository -Paths $Paths)
        $restoreEntries = New-Object System.Collections.Generic.List[object]
        foreach ($snapshotEntry in $Snapshot) {
            $matches = @($current | Where-Object { $_.Path -ceq [string]$snapshotEntry.Path })
            if ($matches.Count -eq 0) {
                if ([int]$snapshotEntry.Stage -ne 0) { throw "Unable to restore a non-stage-zero Git index entry: $($snapshotEntry.Path)" }
                $restoreEntries.Add($snapshotEntry)
                continue
            }
            if ($matches.Count -ne 1 -or [string]$matches[0].Line -cne [string]$snapshotEntry.Line) {
                $driftedPaths.Add([string]$snapshotEntry.Path)
            }
        }
        foreach ($currentEntry in $current) {
            if (@($Snapshot | Where-Object { $_.Path -ceq [string]$currentEntry.Path }).Count -eq 0) {
                $driftedPaths.Add([string]$currentEntry.Path)
            }
        }

        if ($restoreEntries.Count -gt 0) {
            [System.IO.File]::Copy($indexPath,$temporaryIndexPath,$false)
            $env:GIT_INDEX_FILE = $temporaryIndexPath
            foreach ($restoreEntry in $restoreEntries) {
                Invoke-CleanupGit -Repository $Repository -Arguments @(
                    'update-index','--add','--cacheinfo',"$($restoreEntry.Mode),$($restoreEntry.Hash),$($restoreEntry.Path)"
                ) | Out-Null
            }
            $prepared = @(Get-CleanupIndexSnapshot -Repository $Repository -Paths $Paths)
            foreach ($restoreEntry in $restoreEntries) {
                if (@($prepared | Where-Object { [string]$_.Line -ceq [string]$restoreEntry.Line }).Count -ne 1) {
                    throw "The prepared rollback index does not contain the exact original entry: $($restoreEntry.Path)"
                }
            }

            $preparedBytes = [System.IO.File]::ReadAllBytes($temporaryIndexPath)
            $indexLockStream.SetLength(0)
            $indexLockStream.Write($preparedBytes,0,$preparedBytes.Length)
            $indexLockStream.Flush($true)
            $indexLockStream.Dispose()
            $indexLockStream = $null
            Move-Item -LiteralPath $indexLockPath -Destination $indexPath -Force
            $committed = $true
        }
    }
    finally {
        if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
        else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        if ($null -ne $indexLockStream) { $indexLockStream.Dispose() }
        if (-not $committed -and (Test-Path -LiteralPath $indexLockPath -PathType Leaf)) {
            Remove-Item -LiteralPath $indexLockPath -Force -ErrorAction SilentlyContinue
        }
        foreach ($temporaryPath in @($temporaryIndexPath,($temporaryIndexPath + '.lock'))) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($driftedPaths.Count -gt 0) {
        throw "Concurrent Git index changes were preserved and require manual resolution: $(@($driftedPaths | Sort-Object -Unique) -join ', ')"
    }
}

function Get-CleanupGitPathComparer {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $ignoreCase = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ((Get-CleanupGitExitCode -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase')) -eq 0) {
        $configured = ((Invoke-CleanupGit -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase')) | Select-Object -First 1).Trim()
        if ($configured -ceq 'true') { $ignoreCase = $true }
    }
    if ($ignoreCase) { return [System.StringComparer]::OrdinalIgnoreCase }
    return [System.StringComparer]::Ordinal
}

function Open-CleanupRepositoryOperationLock {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $commonGitDirectory = ((Invoke-CleanupGit -Repository $Repository -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $Repository $commonGitDirectory }
    $lockPath = Join-Path ([System.IO.Path]::GetFullPath($commonGitDirectory)) 'codex-ai-instructions.lock'
    try {
        return [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw 'Another AI instruction repository operation is already running; cleanup stopped before index mutation.'
    }
}

function Test-CleanupCanonicalSourceRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)

    if ((Get-CleanupGitExitCode -Repository $Repository -Arguments @('remote','get-url','origin')) -ne 0) { return $false }
    foreach ($originUrl in @(Invoke-CleanupGit -Repository $Repository -Arguments @('remote','get-url','--all','origin'))) {
        try {
            Assert-AiInstructionsCanonicalRepository -Repository ([string]$originUrl)
            return $true
        }
        catch { }
    }
    return $false
}

function Test-CleanupManagedPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    if ($Path -eq 'AGENTS.md' -or $Path -eq '.github/copilot-instructions.md' -or
        $Path -match '^\.codex/AI-Rules/[^/\\]+\.en\.md$' -or
        $Path -match '^\.github/AI-Rules/[^/\\]+\.en\.md$') { return $true }
    if (-not $Path.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) { return $false }
    $parts = @($Path.Substring('.agents/skills/'.Length) -split '/')
    if ($parts.Count -lt 2 -or $parts[0] -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') { return $false }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -in @('.','..') -or $part.Contains('\')) { return $false }
    }
    return $true
}

function Get-CleanupRawHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-CleanupNormalizedHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $content = [System.IO.File]::ReadAllText($Path).Replace("`r`n","`n").Replace("`r","`n")
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($content)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-CleanupManagedHash {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $TargetPath)
    if ($TargetPath.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) { return Get-CleanupRawHash -Path $Path }
    return Get-CleanupNormalizedHash -Path $Path
}

function Get-CleanupIndexManagedHash {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string] $TargetPath
    )

    $blobId = ((Invoke-CleanupGit -Repository $Repository -Arguments @('rev-parse','--verify',":$IndexPath")) | Select-Object -First 1).Trim()
    if ($blobId -cnotmatch '^[0-9a-f]{40,64}$') { throw "Git index path did not resolve to a valid blob: $IndexPath" }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GitExecutable
    $startInfo.Arguments = "cat-file blob $blobId"
    $startInfo.WorkingDirectory = $Repository
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $memory = New-Object System.IO.MemoryStream
    try {
        if (-not $process.Start()) { throw "Unable to read Git index blob: $IndexPath" }
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Unable to read Git index blob '$IndexPath': $errorText" }
        $bytes = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }

    if (-not $TargetPath.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
        $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { 3 } else { 0 }
        $encoding = New-Object System.Text.UTF8Encoding($false,$true)
        try { $content = $encoding.GetString($bytes,$offset,$bytes.Length - $offset) }
        catch { throw "Git index instruction path is not valid UTF-8: $IndexPath" }
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($content.Replace("`r`n","`n").Replace("`r","`n"))
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-CleanupExcludePattern {
    param([Parameter(Mandatory = $true)][string] $Path)
    $escaped = $Path.Replace('\','/')
    foreach ($character in @('\','[',']','*','?')) { $escaped = $escaped.Replace($character,"\$character") }
    if ($escaped.StartsWith('!') -or $escaped.StartsWith('#')) { $escaped = "\$escaped" }
    return "/$escaped"
}

function Assert-CleanupExcludeMutationPath {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $commonGitDirectory = ((Invoke-CleanupGit -Repository $Repository -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $Repository $commonGitDirectory }
    $commonGitDirectory = [System.IO.Path]::GetFullPath($commonGitDirectory).TrimEnd([char[]]@('\','/'))
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $commonGitDirectory 'info\exclude'))
    if (-not $resolvedPath.Equals($expectedPath,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe shared Git exclude mutation path '$resolvedPath': expected '$expectedPath'."
    }

    $inspectionPath = $resolvedPath
    while ($true) {
        if (Test-Path -LiteralPath $inspectionPath) {
            $item = Get-Item -Force -LiteralPath $inspectionPath
            $isLeaf = $inspectionPath.Equals($resolvedPath,[System.StringComparison]::OrdinalIgnoreCase)
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or ($isLeaf -and $item.PSIsContainer) -or (-not $isLeaf -and -not $item.PSIsContainer)) {
                throw "Unsafe shared Git exclude mutation path '$resolvedPath': '$inspectionPath' must be a non-reparse $($(if ($isLeaf) { 'file' } else { 'directory' }))."
            }
        }
        if ($inspectionPath.Equals($commonGitDirectory,[System.StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $inspectionPath
        if ([string]::IsNullOrWhiteSpace($parent) -or -not $parent.StartsWith($commonGitDirectory,[System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe shared Git exclude mutation path '$resolvedPath': parent traversal escaped the common Git directory."
        }
        $inspectionPath = $parent
    }
}

function New-CleanupExcludeMutation {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path
    )

    Assert-CleanupExcludeMutationPath -Repository $Repository -Path $Path
    return [pscustomobject][ordered]@{
        Repository = $Repository
        Path = $Path
        MutationApplied = $false
        Existed = $false
        Bytes = $null
        AppliedBytes = $null
    }
}

function Test-CleanupExcludeBytesEqual {
    param(
        [AllowNull()][byte[]] $Left,
        [AllowNull()][byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Read-CleanupExcludeStreamBytes {
    param([Parameter(Mandatory = $true)][System.IO.FileStream] $Stream)

    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.Position = 0
        $Stream.CopyTo($memory)
        return ,([byte[]]$memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function ConvertFrom-CleanupExcludeBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)

    $memory = New-Object System.IO.MemoryStream
    $reader = $null
    try {
        if ($Bytes.Length -gt 0) { $memory.Write($Bytes,0,$Bytes.Length) }
        $memory.Position = 0
        $reader = New-Object System.IO.StreamReader($memory,[System.Text.Encoding]::UTF8,$true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $memory.Dispose()
    }
}

function Write-CleanupExcludeStreamBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $Stream.Position = 0
    $Stream.SetLength(0)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes,0,$Bytes.Length) }
    $Stream.Flush($true)
}

function Open-CleanupExcludeMutationHandle {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $RequireExisting
    )

    Assert-CleanupExcludeMutationPath -Repository $Repository -Path $Path
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Assert-CleanupExcludeMutationPath -Repository $Repository -Path $Path
    $stream = $null
    $created = $false
    try {
        if ($RequireExisting) {
            $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
        }
        else {
            try {
                $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
                $created = $true
            }
            catch [System.IO.IOException] {
                $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
            }
        }
        return [pscustomobject]@{ Stream=$stream; Created=$created }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw "Unable to acquire the exclusive shared Git exclude mutation handle; another process may be changing '$Path'. $($_.Exception.Message)"
    }
}

function Restore-CleanupExcludeMutation {
    param([Parameter(Mandatory = $true)][object] $Mutation)

    if (-not [bool]$Mutation.MutationApplied) { return }
    $path = [string]$Mutation.Path
    $repository = [string]$Mutation.Repository
    Assert-CleanupExcludeMutationPath -Repository $repository -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if (-not [bool]$Mutation.Existed) {
            $Mutation.MutationApplied = $false
            return
        }
        throw "Shared Git exclude changed concurrently during cleanup rollback; the missing current state was preserved: $path"
    }

    $handle = Open-CleanupExcludeMutationHandle -Repository $repository -Path $path -RequireExisting
    try {
        if ([bool]$handle.Created) { throw "Shared Git exclude changed concurrently during cleanup rollback; the recreated current state was preserved: $path" }
        [byte[]]$currentBytes = Read-CleanupExcludeStreamBytes -Stream $handle.Stream
        if (-not (Test-CleanupExcludeBytesEqual -Left $currentBytes -Right ([byte[]]$Mutation.AppliedBytes))) {
            throw "Shared Git exclude changed concurrently during cleanup rollback; current bytes were preserved: $path"
        }
        $restoreBytes = if ([bool]$Mutation.Existed) { [byte[]]$Mutation.Bytes } else { [byte[]]@() }
        Write-CleanupExcludeStreamBytes -Stream $handle.Stream -Bytes $restoreBytes
        $Mutation.MutationApplied = $false
    }
    finally {
        if ($null -ne $handle -and $null -ne $handle.Stream) { $handle.Stream.Dispose() }
    }
}

function Assert-CleanupManagedFilePath {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $resolvedRoot = Get-AiInstructionsFullDirectoryPath -Path $TargetRoot
    $rootPrefix = $resolvedRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedFile = [System.IO.Path]::GetFullPath($FilePath)
    if (-not $resolvedFile.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context is outside the target Repository: $resolvedFile"
    }
    $inspectionPath = $resolvedFile
    while ($inspectionPath.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $inspectionPath) {
            $item = Get-Item -Force -LiteralPath $inspectionPath
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Context crosses a reparse point: $inspectionPath"
            }
        }
        $inspectionPath = Split-Path -Parent $inspectionPath
    }
    if (-not (Test-Path -LiteralPath $resolvedFile -PathType Leaf)) { throw "$Context must be a file: $resolvedFile" }
}

function Get-CleanupSharedManagedPaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $CurrentManagedPaths
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($currentManagedPath in $CurrentManagedPaths) { [void]$paths.Add($currentManagedPath.Replace('\','/')) }
    foreach ($line in @(Invoke-CleanupGit -Repository $Repository -Arguments @('worktree','list','--porcelain'))) {
        $text = [string]$line
        if (-not $text.StartsWith('worktree ',[System.StringComparison]::Ordinal)) { continue }
        $worktreeRoot = $text.Substring('worktree '.Length)
        $worktreeManifestPath = Join-Path $worktreeRoot $manifestRelativePath.Replace('/','\')
        if (-not (Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf)) { continue }
        Assert-CleanupManagedFilePath -TargetRoot $worktreeRoot -FilePath $worktreeManifestPath -Context 'Linked worktree managed manifest'
        try {
            $worktreeManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $worktreeManifestPath | ConvertFrom-Json
            $worktreeManifestSchemaVersion = $worktreeManifest.schemaVersion
            if ($worktreeManifestSchemaVersion -isnot [int] -and $worktreeManifestSchemaVersion -isnot [long]) {
                throw 'schemaVersion must be an integer.'
            }
            if ($worktreeManifestSchemaVersion -eq 2) { Assert-ManagedManifestV2 -Manifest $worktreeManifest }
            elseif ($worktreeManifestSchemaVersion -eq 1) { Assert-LegacyManagedManifestV1 -Manifest $worktreeManifest }
            else {
                throw "unsupported schemaVersion '$worktreeManifestSchemaVersion'."
            }
        }
        catch {
            throw "Cannot compose shared Git exclusions because a linked worktree manifest is invalid: $worktreeManifestPath. $($_.Exception.Message)"
        }
        [void]$paths.Add($manifestRelativePath)
        foreach ($entry in @($worktreeManifest.files)) {
            $targetPath = [string]$entry.targetPath
            if (-not (Test-CleanupManagedPath -Path $targetPath)) {
                throw "Cannot compose shared Git exclusions because a linked worktree manifest contains an unsafe path: $targetPath"
            }
            [void]$paths.Add($targetPath)
        }
    }
    return @($paths | Sort-Object)
}

function Set-CleanupExcludeBlock {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $ManagedPaths,
        [Parameter(Mandatory = $true)][object] $Mutation
    )
    if ([string]$Mutation.Path -cne $Path -or [string]$Mutation.Repository -cne $Repository) {
        throw 'Shared Git exclude mutation state does not match the requested cleanup target.'
    }
    Assert-CleanupExcludeMutationPath -Repository $Repository -Path $Path
    $sharedManagedPaths = @(Get-CleanupSharedManagedPaths -Repository $Repository -CurrentManagedPaths $ManagedPaths)
    $lines = @($sharedManagedPaths | ForEach-Object { ConvertTo-CleanupExcludePattern -Path $_ })
    $handle = Open-CleanupExcludeMutationHandle -Repository $Repository -Path $Path
    try {
        [byte[]]$beforeBytes = Read-CleanupExcludeStreamBytes -Stream $handle.Stream
        $Mutation.Existed = -not [bool]$handle.Created
        $Mutation.Bytes = if ([bool]$handle.Created) { $null } else { $beforeBytes }
        $Mutation.AppliedBytes = $beforeBytes
        $Mutation.MutationApplied = [bool]$handle.Created

        $content = (ConvertFrom-CleanupExcludeBytes -Bytes $beforeBytes).Replace("`r`n","`n").Replace("`r","`n")
        $pattern = '(?ms)^' + [regex]::Escape($excludeBeginMarker) + '\n.*?^' + [regex]::Escape($excludeEndMarker) + '\n?'
        $beginCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($excludeBeginMarker) + '$').Count
        $endCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($excludeEndMarker) + '$').Count
        if ($beginCount -ne $endCount -or $beginCount -gt 1 -or ($beginCount -eq 1 -and -not [regex]::IsMatch($content,$pattern))) {
            throw "The Codex AI Instructions managed exclude block is malformed: $Path"
        }
        $withoutBlock = [regex]::Replace($content,$pattern,'').TrimEnd("`n")
        $block = $excludeBeginMarker + "`n" + ($lines -join "`n") + "`n" + $excludeEndMarker + "`n"
        $updated = if ([string]::IsNullOrWhiteSpace($withoutBlock)) { $block } else { $withoutBlock + "`n`n" + $block }
        [byte[]]$updatedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($updated)
        if (-not (Test-CleanupExcludeBytesEqual -Left $beforeBytes -Right $updatedBytes)) {
            $Mutation.AppliedBytes = $updatedBytes
            $Mutation.MutationApplied = $true
            try { Write-CleanupExcludeStreamBytes -Stream $handle.Stream -Bytes $updatedBytes }
            catch {
                try { $Mutation.AppliedBytes = [byte[]](Read-CleanupExcludeStreamBytes -Stream $handle.Stream) }
                catch { }
                throw
            }
        }
    }
    finally {
        if ($null -ne $handle -and $null -ne $handle.Stream) { $handle.Stream.Dispose() }
    }
}

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $TargetRoot = ((Invoke-CleanupGit -Repository (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
}
$targetRootPath = Get-AiInstructionsFullDirectoryPath -Path $TargetRoot
if (((Invoke-CleanupGit -Repository $targetRootPath -Arguments @('rev-parse','--is-inside-work-tree')) | Select-Object -First 1).Trim() -ne 'true') {
    throw "Target is not a Git work tree: $targetRootPath"
}
if ((Test-CleanupCanonicalSourceRepository -Repository $targetRootPath) -or
    ((Test-Path -LiteralPath (Join-Path $targetRootPath '.codex\AGENTS.en.md') -PathType Leaf) -and
     (Test-Path -LiteralPath (Join-Path $targetRootPath '.github\copilot-instructions.en.md') -PathType Leaf))) {
    throw 'Tracked AI instructions pollution cleanup refuses the canonical Instructions source repository.'
}

$repositoryOperationLock = Open-CleanupRepositoryOperationLock -Repository $targetRootPath
try {

$manifestPath = Join-Path $targetRootPath $manifestRelativePath.Replace('/','\')
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Managed manifest is required to prove ownership before tracked pollution cleanup.'
}
Assert-CleanupManagedFilePath -TargetRoot $targetRootPath -FilePath $manifestPath -Context 'Managed manifest ownership evidence'
try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json }
catch { throw "Managed manifest is not valid JSON: $($_.Exception.Message)" }
try {
    if ($manifest.schemaVersion -eq 2) { Assert-ManagedManifestV2 -Manifest $manifest }
    elseif ($manifest.schemaVersion -eq 1) { Assert-LegacyManagedManifestV1 -Manifest $manifest }
    else { throw "unsupported schemaVersion '$($manifest.schemaVersion)'." }
}
catch { throw "Managed manifest cannot prove cleanup ownership: $($_.Exception.Message)" }
if (($manifest.schemaVersion -eq 2 -and
     ([string]$manifest.catalogId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or [string]$manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$')) -or
    $manifest.files -isnot [System.Array]) {
    throw 'Managed manifest cannot prove cleanup ownership because its v2 identity is invalid.'
}

$entriesByPath = @{}
foreach ($entry in @($manifest.files)) {
    $targetPath = [string]$entry.targetPath
    if (-not (Test-CleanupManagedPath -Path $targetPath) -or $entriesByPath.ContainsKey($targetPath) -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Managed manifest cannot prove cleanup ownership for '$targetPath'."
    }
    $entriesByPath[$targetPath] = $entry
}

$trackedPaths = @(Invoke-CleanupGit -Repository $targetRootPath -Arguments @('-c','core.quotePath=true','ls-files') | ForEach-Object {
    (ConvertFrom-CleanupGitQuotedPath -Path ([string]$_)).Replace('\','/')
})
$gitPathComparer = Get-CleanupGitPathComparer -Repository $targetRootPath
$trackedManagedEntries = New-Object System.Collections.Generic.List[object]
foreach ($manifestTargetPath in @($manifestRelativePath) + @($entriesByPath.Keys | Sort-Object)) {
    foreach ($actualTrackedPath in $trackedPaths) {
        if ($gitPathComparer.Equals([string]$manifestTargetPath,[string]$actualTrackedPath)) {
            $trackedManagedEntries.Add([pscustomobject]@{ ManifestPath=[string]$manifestTargetPath; IndexPath=[string]$actualTrackedPath })
        }
    }
}
$trackedManagedPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($trackedManagedEntry in $trackedManagedEntries) { [void]$trackedManagedPathSet.Add([string]$trackedManagedEntry.IndexPath) }
$trackedManagedPaths = @($trackedManagedPathSet | Sort-Object)
if ($trackedManagedPaths.Count -eq 0) { throw 'No tracked managed AI instruction pollution was found.' }
foreach ($trackedManagedEntry in $trackedManagedEntries) {
    $indexPath = [string]$trackedManagedEntry.IndexPath
    $manifestTargetPath = [string]$trackedManagedEntry.ManifestPath
    $stagedExitCode = Get-CleanupGitExitCode -Repository $targetRootPath -Arguments @('diff','--cached','--quiet','--',$indexPath)
    if ($stagedExitCode -gt 1) { throw "Unable to inspect staged managed path: $indexPath" }
    if ($stagedExitCode -eq 1) { throw "Tracked managed path already has staged changes; cleanup stopped: $indexPath" }
    $indexHash = Get-CleanupIndexManagedHash -Repository $targetRootPath -IndexPath $indexPath -TargetPath $manifestTargetPath
    if ($manifestTargetPath -ceq $manifestRelativePath) {
        $manifestWorktreeHash = Get-CleanupNormalizedHash -Path $manifestPath
        if ($indexHash -cne $manifestWorktreeHash) {
            throw 'Tracked managed manifest in the Git index does not match the ownership manifest being reviewed.'
        }
        continue
    }
    $fullPath = Join-Path $targetRootPath $manifestTargetPath.Replace('/','\')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Tracked managed path is missing and ownership cannot be verified: $manifestTargetPath" }
    Assert-CleanupManagedFilePath -TargetRoot $targetRootPath -FilePath $fullPath -Context "Tracked managed path '$manifestTargetPath'"
    if ($indexHash -cne [string]$entriesByPath[$manifestTargetPath].sha256) {
        throw "Tracked managed path in the Git index is not manifest-owned or has an ownership hash mismatch: $indexPath"
    }
    $currentHash = Get-CleanupManagedHash -Path $fullPath -TargetPath $manifestTargetPath
    if ($currentHash -cne [string]$entriesByPath[$manifestTargetPath].sha256) {
        throw "Tracked managed path is customized or has an ownership hash mismatch: $manifestTargetPath"
    }
}

Write-Output "Tracked AI instructions pollution detected: $($trackedManagedPaths -join ', ')"
if (-not $Authorize) { throw 'Cleanup requires explicit authorization; re-run with -Authorize after reviewing the pollution paths.' }

$gitExcludePath = ((Invoke-CleanupGit -Repository $targetRootPath -Arguments @('rev-parse','--git-path','info/exclude')) | Select-Object -First 1).Trim()
if (-not [System.IO.Path]::IsPathRooted($gitExcludePath)) { $gitExcludePath = Join-Path $targetRootPath $gitExcludePath }
Assert-CleanupExcludeMutationPath -Repository $targetRootPath -Path $gitExcludePath
$excludeMutation = New-CleanupExcludeMutation -Repository $targetRootPath -Path $gitExcludePath
$cleanupPaths = @($trackedManagedPaths | Sort-Object)
$indexSnapshot = @(Get-CleanupIndexSnapshot -Repository $targetRootPath -Paths $cleanupPaths)
try {
    $indexAtMutation = @(Get-CleanupIndexSnapshot -Repository $targetRootPath -Paths $cleanupPaths)
    if ((@($indexAtMutation | ForEach-Object { [string]$_.Line }) -join "`n") -cne
        (@($indexSnapshot | ForEach-Object { [string]$_.Line }) -join "`n")) {
        throw 'Tracked managed paths changed in the Git index before cleanup mutation.'
    }
    Set-CleanupExcludeBlock -Repository $targetRootPath -Path $gitExcludePath -ManagedPaths @($entriesByPath.Keys + $manifestRelativePath + $cleanupPaths) -Mutation $excludeMutation
    Remove-CleanupIndexEntriesAtomically -Repository $targetRootPath -Paths $cleanupPaths -ExpectedSnapshot $indexSnapshot
    foreach ($cleanupPath in $cleanupPaths) {
        $fullPath = Join-Path $targetRootPath $cleanupPath.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Cleanup failed to preserve local materialization: $cleanupPath" }
        $status = @(Invoke-CleanupGit -Repository $targetRootPath -Arguments @('diff','--cached','--name-status','--',$cleanupPath))
        if ($status.Count -ne 1 -or [string]$status[0] -cnotmatch '^D\s+') { throw "Cleanup did not stage exactly one deletion for '$cleanupPath'." }
    }
}
catch {
    $cleanupError = $_
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    try { Restore-CleanupIndexSnapshot -Repository $targetRootPath -Paths $cleanupPaths -Snapshot $indexSnapshot }
    catch { $rollbackErrors.Add($_.Exception.Message) }
    try { Restore-CleanupExcludeMutation -Mutation $excludeMutation }
    catch { $rollbackErrors.Add($_.Exception.Message) }
    if ($rollbackErrors.Count -gt 0) {
        throw "Pollution cleanup failed and rollback also failed. Original: $($cleanupError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"
    }
    throw $cleanupError
}

Write-Output "Tracked AI instructions pollution cleanup staged deletions only; local files were preserved and ignored: $($cleanupPaths -join ', ')"
}
finally {
    $repositoryOperationLock.Dispose()
}
}
finally {
    if ($null -ne $installedRuntimeReadLock) { $installedRuntimeReadLock.Dispose() }
}
