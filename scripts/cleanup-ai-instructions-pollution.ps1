[CmdletBinding()]
param(
    [Alias('RepositoryRoot')]
    [string] $TargetRoot,
    [switch] $Authorize,
    [string] $GitExecutable = 'git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestRelativePath = '.codex/ai-instructions.manifest.json'
$excludeBeginMarker = '# BEGIN Codex AI Instructions managed paths'
$excludeEndMarker = '# END Codex AI Instructions managed paths'

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

function ConvertTo-CleanupExcludePattern {
    param([Parameter(Mandatory = $true)][string] $Path)
    $escaped = $Path.Replace('\','/')
    foreach ($character in @('\','[',']','*','?')) { $escaped = $escaped.Replace($character,"\$character") }
    if ($escaped.StartsWith('!') -or $escaped.StartsWith('#')) { $escaped = "\$escaped" }
    return "/$escaped"
}

function Set-CleanupExcludeBlock {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string[]] $ManagedPaths)
    $content = if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::ReadAllText($Path).Replace("`r`n","`n").Replace("`r","`n") } else { '' }
    $pattern = '(?ms)^' + [regex]::Escape($excludeBeginMarker) + '\n.*?^' + [regex]::Escape($excludeEndMarker) + '\n?'
    $withoutBlock = [regex]::Replace($content,$pattern,'').TrimEnd("`n")
    $lines = @($ManagedPaths | Sort-Object -Unique | ForEach-Object { ConvertTo-CleanupExcludePattern -Path $_ })
    $block = $excludeBeginMarker + "`n" + ($lines -join "`n") + "`n" + $excludeEndMarker + "`n"
    $updated = if ([string]::IsNullOrWhiteSpace($withoutBlock)) { $block } else { $withoutBlock + "`n`n" + $block }
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path,$updated,(New-Object System.Text.UTF8Encoding($false)))
}

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $TargetRoot = ((Invoke-CleanupGit -Repository (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
}
$targetRootPath = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd([char[]]@('\','/'))
if (((Invoke-CleanupGit -Repository $targetRootPath -Arguments @('rev-parse','--is-inside-work-tree')) | Select-Object -First 1).Trim() -ne 'true') {
    throw "Target is not a Git work tree: $targetRootPath"
}
if ((Test-Path -LiteralPath (Join-Path $targetRootPath '.codex\AGENTS.en.md') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $targetRootPath '.github\copilot-instructions.en.md') -PathType Leaf)) {
    throw 'Tracked AI instructions pollution cleanup refuses the canonical Instructions source repository.'
}

$manifestPath = Join-Path $targetRootPath $manifestRelativePath.Replace('/','\')
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Managed manifest is required to prove ownership before tracked pollution cleanup.'
}
try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json }
catch { throw "Managed manifest is not valid JSON: $($_.Exception.Message)" }
if ($manifest.schemaVersion -ne 2 -or [string]$manifest.catalogId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
    [string]$manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$' -or $manifest.files -isnot [System.Array]) {
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

$trackedPaths = @(Invoke-CleanupGit -Repository $targetRootPath -Arguments @('ls-files') | ForEach-Object { ([string]$_).Replace('\','/') })
$trackedManagedPaths = @(
    if ($trackedPaths -ccontains $manifestRelativePath) { $manifestRelativePath }
    foreach ($path in @($entriesByPath.Keys | Sort-Object)) {
        if ($trackedPaths -ccontains [string]$path) { [string]$path }
    }
)
if ($trackedManagedPaths.Count -eq 0) { throw 'No tracked managed AI instruction pollution was found.' }
foreach ($trackedPath in $trackedManagedPaths) {
    $stagedExitCode = Get-CleanupGitExitCode -Repository $targetRootPath -Arguments @('diff','--cached','--quiet','--',$trackedPath)
    if ($stagedExitCode -gt 1) { throw "Unable to inspect staged managed path: $trackedPath" }
    if ($stagedExitCode -eq 1) { throw "Tracked managed path already has staged changes; cleanup stopped: $trackedPath" }
    if ($trackedPath -ceq $manifestRelativePath) { continue }
    $fullPath = Join-Path $targetRootPath $trackedPath.Replace('/','\')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Tracked managed path is missing and ownership cannot be verified: $trackedPath" }
    $currentHash = Get-CleanupManagedHash -Path $fullPath -TargetPath $trackedPath
    if ($currentHash -cne [string]$entriesByPath[$trackedPath].sha256) {
        throw "Tracked managed path is customized or has an ownership hash mismatch: $trackedPath"
    }
}

Write-Output "Tracked AI instructions pollution detected: $($trackedManagedPaths -join ', ')"
if (-not $Authorize) { throw 'Cleanup requires explicit authorization; re-run with -Authorize after reviewing the pollution paths.' }

$gitExcludePath = ((Invoke-CleanupGit -Repository $targetRootPath -Arguments @('rev-parse','--git-path','info/exclude')) | Select-Object -First 1).Trim()
if (-not [System.IO.Path]::IsPathRooted($gitExcludePath)) { $gitExcludePath = Join-Path $targetRootPath $gitExcludePath }
$excludeExisted = Test-Path -LiteralPath $gitExcludePath -PathType Leaf
$excludeBefore = if ($excludeExisted) { [System.IO.File]::ReadAllBytes($gitExcludePath) } else { $null }
$cleanupPaths = @($trackedManagedPaths | Sort-Object -Unique)
try {
    Set-CleanupExcludeBlock -Path $gitExcludePath -ManagedPaths @($entriesByPath.Keys + $manifestRelativePath)
    Invoke-CleanupGit -Repository $targetRootPath -Arguments (@('rm','--cached','--') + $cleanupPaths) | Out-Null
    foreach ($cleanupPath in $cleanupPaths) {
        $fullPath = Join-Path $targetRootPath $cleanupPath.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Cleanup failed to preserve local materialization: $cleanupPath" }
        $status = @(Invoke-CleanupGit -Repository $targetRootPath -Arguments @('diff','--cached','--name-status','--',$cleanupPath))
        if ($status.Count -ne 1 -or [string]$status[0] -cnotmatch '^D\s+') { throw "Cleanup did not stage exactly one deletion for '$cleanupPath'." }
    }
}
catch {
    $cleanupError = $_
    try {
        Invoke-CleanupGit -Repository $targetRootPath -Arguments (@('reset','--quiet','HEAD','--') + $cleanupPaths) | Out-Null
        if ($excludeExisted) { [System.IO.File]::WriteAllBytes($gitExcludePath,$excludeBefore) }
        elseif (Test-Path -LiteralPath $gitExcludePath) { Remove-Item -LiteralPath $gitExcludePath -Force }
    }
    catch { throw "Pollution cleanup failed and rollback also failed. Original: $($cleanupError.Exception.Message). Rollback: $($_.Exception.Message)" }
    throw $cleanupError
}

Write-Output "Tracked AI instructions pollution cleanup staged deletions only; local files were preserved and ignored: $($cleanupPaths -join ', ')"
