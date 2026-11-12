Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'skills-catalog-contract.psm1') -Scope Local -ErrorAction Stop

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
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $output = & $GitExecutable -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
    }
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
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $null = & $GitExecutable -C $Repository @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
    }
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
    $normalized = $Path.Replace('\','/').TrimEnd('/')
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

function Test-IsProtectedClaudeFamilyPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths
    )

    try { $normalizedPath = ConvertTo-RemediationPath -Path $Path }
    catch { return $false }
    $comparison = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else { [StringComparison]::Ordinal }
    foreach ($protectedPath in @($ProtectedPaths)) {
        $normalizedProtectedPath = ConvertTo-RemediationPath -Path ([string]$protectedPath)
        if ($normalizedPath.Equals($normalizedProtectedPath,$comparison) -or
            $normalizedPath.StartsWith($normalizedProtectedPath + '/',$comparison)) {
            return $true
        }
    }
    return $false
}

function Write-ProtectedClaudeFamilyDiagnostic {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Sink)
    Write-Warning "Protected Claude family path skipped at $Sink`: $Path (project-owned Claude family)."
}

function Test-IsReservedAgentArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowNull()][System.Collections.Generic.HashSet[string]] $LegacyManifestPaths
    )

    try { $normalized = ConvertTo-RemediationPath -Path $Path }
    catch { return $false }
    # Skills may be tracked project content. Migration needs whole-Skill ownership evidence.
    if ($normalized.StartsWith('.agents/skills/',[StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith('.codex/skills/',[StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith('.claude/skills/',[StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith('.github/skills/',[StringComparison]::OrdinalIgnoreCase)) { return $false }
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
        '.codex/ai-instructions-licenses/',
        '.claude/AI-Rules/',
        '.claude/ai-instructions-licenses/',
        '.github/ai-instructions-licenses/',
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
        [Parameter(Mandatory = $true)][object] $TrackedSets,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    $manifestPath = Join-Path $Repository '.codex\ai-instructions.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return ,$paths }
    Assert-RemediationPathHasNoReparsePoint -Repository $Repository -RelativePath '.codex/ai-instructions.manifest.json'
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json }
    catch { return ,$paths }
    $inspectionEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($manifest.files)) {
        if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['targetPath'] -and
            (Test-IsProtectedClaudeFamilyPath -Path ([string]$entry.targetPath) -ProtectedPaths $ProtectedPaths)) {
            Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$entry.targetPath) -Sink 'manifest inspection'
            continue
        }
        $inspectionEntries.Add($entry)
    }
    if ($manifest.schemaVersion -eq 4) {
        $manifestForInspection = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $manifestForInspection.files = [object[]]$inspectionEntries.ToArray()
        Assert-ManagedManifestV4 -Manifest $manifestForInspection
    }
    foreach ($entry in [object[]]$inspectionEntries.ToArray()) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['targetPath']) { continue }
        $targetPath = [string]$entry.targetPath
        if ($targetPath.StartsWith('.agents/skills/',[StringComparison]::OrdinalIgnoreCase) -or
            $targetPath.StartsWith('.codex/skills/',[StringComparison]::OrdinalIgnoreCase) -or
            $targetPath.StartsWith('.claude/skills/',[StringComparison]::OrdinalIgnoreCase) -or
            $targetPath.StartsWith('.github/skills/',[StringComparison]::OrdinalIgnoreCase)) { continue }
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
        if (-not $targetPath.StartsWith('.agents/skills/',[StringComparison]::OrdinalIgnoreCase) -and
            -not $targetPath.StartsWith('.codex/skills/',[StringComparison]::OrdinalIgnoreCase) -and
            -not $targetPath.StartsWith('.claude/skills/',[StringComparison]::OrdinalIgnoreCase) -and
            -not $targetPath.StartsWith('.github/skills/',[StringComparison]::OrdinalIgnoreCase)) { [void]$paths.Add((ConvertTo-RemediationPath -Path $targetPath)) }
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
        [Parameter(Mandatory = $true)][System.StringComparer] $Comparer,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    foreach ($trackedPath in $TrackedPaths) {
        if (Test-IsProtectedClaudeFamilyPath -Path ([string]$trackedPath) -ProtectedPaths $ProtectedPaths) {
            Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$trackedPath) -Sink 'remediation mutation set'
            continue
        }
        [void]$paths.Add([string]$trackedPath)
    }
    if (@($TrackedPaths | Where-Object { $Comparer.Equals([string]$_,'.codex/ai-instructions.manifest.json') }).Count -gt 0) {
        foreach ($manifestPath in $LegacyManifestPaths) {
            if (Test-IsProtectedClaudeFamilyPath -Path ([string]$manifestPath) -ProtectedPaths $ProtectedPaths) {
                Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$manifestPath) -Sink 'remediation mutation set'
                continue
            }
            [void]$paths.Add([string]$manifestPath)
        }
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
        [AllowEmptyString()][string] $HeadReference,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths
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
        if (Test-IsProtectedClaudeFamilyPath -Path ([string]$relativePath) -ProtectedPaths $ProtectedPaths) {
            Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$relativePath) -Sink 'remediation recovery backup'
            continue
        }
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

function New-RemediationIndexPlan {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string] $IndexPath,
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths
    )
    [byte[]]$beforeBytes=[IO.File]::ReadAllBytes($IndexPath)
    $temporaryIndex=Join-Path ([IO.Path]::GetTempPath()) ('codex-agent-remediation-plan-index-'+[guid]::NewGuid().ToString('N'))
    $hadAlternateIndex=Test-Path Env:GIT_INDEX_FILE;$priorAlternateIndex=$env:GIT_INDEX_FILE
    try{
        [IO.File]::WriteAllBytes($temporaryIndex,$beforeBytes)
        $env:GIT_INDEX_FILE=$temporaryIndex
        $safePaths=@($Paths|Where-Object{
            if(Test-IsProtectedClaudeFamilyPath -Path ([string]$_) -ProtectedPaths $ProtectedPaths){Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$_) -Sink 'remediation Git index plan';return $false}
            return $true
        })
        if($safePaths.Count-gt0){Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments (@('update-index','--force-remove','--')+$safePaths)|Out-Null}
        [byte[]]$afterBytes=[IO.File]::ReadAllBytes($temporaryIndex)
        $entryLines=@(Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('ls-files','--stage'))|Sort-Object -CaseSensitive
        $entryText=(($entryLines-join"`n")+"`n")
        return [pscustomobject][ordered]@{
            BeforeBytes=$beforeBytes;AfterBytes=$afterBytes
            BeforeSha256=Get-RemediationSha256Bytes -Bytes $beforeBytes
            AfterSha256=Get-RemediationSha256Bytes -Bytes $afterBytes
            AfterEntrySetSha256=Get-RemediationSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($entryText))
        }
    }
    finally{
        if($hadAlternateIndex){$env:GIT_INDEX_FILE=$priorAlternateIndex}else{Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue}
        foreach($path in @($temporaryIndex,($temporaryIndex+'.lock'))){if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
    }
}

function New-RemediationCommitObject {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string] $Head,
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths
    )

    $safePaths = @($Paths | Where-Object {
        if (Test-IsProtectedClaudeFamilyPath -Path ([string]$_) -ProtectedPaths $ProtectedPaths) {
            Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$_) -Sink 'remediation commit'
            return $false
        }
        return $true
    })
    if ($safePaths.Count -eq 0) { return $null }
    $temporaryIndex = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-agent-remediation-commit-index-' + [Guid]::NewGuid().ToString('N'))
    $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
    $priorAlternateIndex = $env:GIT_INDEX_FILE
    $hadAuthorDate = Test-Path Env:GIT_AUTHOR_DATE
    $priorAuthorDate = $env:GIT_AUTHOR_DATE
    $hadCommitterDate = Test-Path Env:GIT_COMMITTER_DATE
    $priorCommitterDate = $env:GIT_COMMITTER_DATE
    try {
        $env:GIT_INDEX_FILE = $temporaryIndex
        Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('read-tree',$Head) | Out-Null
        Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments (@('update-index','--force-remove','--') + $safePaths) | Out-Null
        $tree = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('write-tree')) | Select-Object -First 1).Trim()
        $headTree = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('rev-parse',"$Head^{tree}")) | Select-Object -First 1).Trim()
        if ($tree -ceq $headTree) { return $null }
        $env:GIT_AUTHOR_DATE = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('show','-s','--format=%aI',$Head)) | Select-Object -First 1).Trim()
        $env:GIT_COMMITTER_DATE = ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('show','-s','--format=%cI',$Head)) | Select-Object -First 1).Trim()
        return ((Invoke-RemediationGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @(
            '-c',"user.name=$script:RemediationUserName",
            '-c',"user.email=$script:RemediationUserEmail",
            'commit-tree',$tree,'-p',$Head,'-m',$script:RemediationMessage
        )) | Select-Object -First 1).Trim()
    }
    finally {
        if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
        else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        if ($hadAuthorDate) { $env:GIT_AUTHOR_DATE = $priorAuthorDate }
        else { Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue }
        if ($hadCommitterDate) { $env:GIT_COMMITTER_DATE = $priorCommitterDate }
        else { Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
        foreach ($temporaryPath in @($temporaryIndex,($temporaryIndex + '.lock'))) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function New-AgentArtifactRemediationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [string] $GitExecutable = 'git',
        [AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPathPrefixes = @(),
        [AllowEmptyCollection()][ValidateNotNull()][string[]] $SharedExcludeProtectedPathPrefixes
    )

    if (-not $PSBoundParameters.ContainsKey('SharedExcludeProtectedPathPrefixes')) {
        $SharedExcludeProtectedPathPrefixes = @($ProtectedPathPrefixes)
    }

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
    $legacyManifestPaths = Get-RemediationLegacyManifestPaths -Repository $repositoryRoot -Comparer $comparer -TrackedSets $trackedSets -ProtectedPaths $ProtectedPathPrefixes
    $trackedReserved = New-Object 'System.Collections.Generic.HashSet[string]' $comparer
    foreach ($trackedPath in @(@($trackedSets.Index) + @($trackedSets.Head))) {
        if (Test-IsReservedAgentArtifactPath -Path ([string]$trackedPath) -LegacyManifestPaths $legacyManifestPaths) {
            if (Test-IsProtectedClaudeFamilyPath -Path ([string]$trackedPath) -ProtectedPaths $ProtectedPathPrefixes) {
                Write-ProtectedClaudeFamilyDiagnostic -Path ([string]$trackedPath) -Sink 'tracked remediation inventory'
                continue
            }
            [void]$trackedReserved.Add([string]$trackedPath)
        }
    }
    $trackedPaths = @($trackedReserved | Sort-Object)
    $mutationPaths = @(Get-RemediationMutationPaths -Repository $repositoryRoot -TrackedPaths $trackedPaths `
        -LegacyManifestPaths $legacyManifestPaths -Comparer $comparer -ProtectedPaths $ProtectedPathPrefixes)
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
        -Head $head -HeadReference $headReference -ProtectedPaths $ProtectedPathPrefixes
    $excludePath = Get-RemediationGitInfoExcludePath -Repository $repositoryRoot -GitExecutable $GitExecutable -CommonGitDirectory $commonGitDirectory
    $excludePatterns = @($mutationPaths | Sort-Object -Unique)
    $transaction = [pscustomobject][ordered]@{
        Repository=$repositoryRoot
        GitExecutable=$GitExecutable
        CommonGitDirectory=$commonGitDirectory
        GitDirectory=$gitDirectory
        IndexPath=$indexPath
        OriginalHead=$head
        OriginalHeadReference=$headReference
        NewHeadReference=''
        NewCommit=$null
        Paths=$trackedPaths
        MutationPaths=$mutationPaths
        Backup=$backup
        ProtectedPaths=@($ProtectedPathPrefixes)
        ObjectFormat=((Invoke-RemediationGit -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('rev-parse','--show-object-format')|Select-Object -First 1).Trim())
        IndexPlan=$null
        HeadMode=$(if([string]::IsNullOrWhiteSpace($head)){'unborn'}elseif([string]::IsNullOrWhiteSpace($headReference)){'detached'}else{'symbolic'})
    }

    if ($trackedPaths.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($head)) {
        $transaction.NewCommit=New-RemediationCommitObject -Repository $repositoryRoot -GitExecutable $GitExecutable -Head $head -Paths $trackedPaths -ProtectedPaths $ProtectedPathPrefixes
    }
    if ($trackedPaths.Count -gt 0) {
        $transaction.IndexPlan=New-RemediationIndexPlan -Repository $repositoryRoot -GitExecutable $GitExecutable -IndexPath $indexPath -Paths $trackedPaths -ProtectedPaths $ProtectedPathPrefixes
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$transaction.NewCommit) -and [string]::IsNullOrWhiteSpace($headReference)) {
        $baseName='refs/heads/codex/ai-instructions-remediation-'+$head.Substring(0,12);$candidate=$baseName;$suffix=1
        while ((Get-RemediationGitExitCode -Repository $repositoryRoot -GitExecutable $GitExecutable -Arguments @('show-ref','--verify','--quiet',$candidate)) -eq 0) {$candidate=$baseName+'-'+$suffix;$suffix++}
        $transaction.NewHeadReference=$candidate
    }
    return $transaction
        }
Export-ModuleMember -Function New-AgentArtifactRemediationPlan, Test-IsReservedAgentArtifactPath, Test-IsProtectedClaudeFamilyPath
