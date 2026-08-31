Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RolloutAuthorityRepositoryUrls = @(
    'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git',
    'https://github.com/SyuanTsai/Skill-General.git'
)
$script:RolloutExcludedDirectoryNames = @(
    '$RECYCLE.BIN','.agents','.cache','.codex','.git','.gradle','.hg','.m2','.npm','.nuget','.svn',
    'AppData','bin','node_modules','obj','packages','Program Files','Program Files (x86)','ProgramData',
    'System Volume Information','Temp','TestResults','tmp','Windows'
)

function Get-RolloutFullPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($root,[System.StringComparison]::OrdinalIgnoreCase)) { return $root }
    return $fullPath.TrimEnd([char[]]@('\','/'))
}

function ConvertTo-RolloutRepositoryUrl {
    param([AllowNull()][string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $normalized = $Url.Trim().Replace('\','/').ToLowerInvariant()
    if ($normalized.StartsWith('git@github.com:')) {
        $normalized = 'https://github.com/' + $normalized.Substring('git@github.com:'.Length)
    }
    elseif ($normalized.StartsWith('ssh://git@github.com/')) {
        $normalized = 'https://github.com/' + $normalized.Substring('ssh://git@github.com/'.Length)
    }
    $normalized = $normalized.TrimEnd('/')
    if ($normalized.EndsWith('.git')) { $normalized = $normalized.Substring(0,$normalized.Length - 4) }
    return $normalized
}

function Invoke-RolloutGit {
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
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Get-RolloutGitExitCode {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $GitExecutable,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $GitExecutable -C $Repository @Arguments 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
}

function Get-AiInstructionsFixedSearchRoots {
    return @(
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.IsReady -and $drive.DriveType -eq [System.IO.DriveType]::Fixed) {
                Get-RolloutFullPath -Path $drive.RootDirectory.FullName
            }
        }
    )
}

function Test-RolloutPathWithin {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Parent)
    if ($Path.Equals($Parent,[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $Parent.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)
}

function Test-RolloutDirectoryExcluded {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $SearchRoots,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ExcludedPaths
    )
    $fullPath = Get-RolloutFullPath -Path $Path
    foreach ($excludedPath in $ExcludedPaths) {
        if (Test-RolloutPathWithin -Path $fullPath -Parent $excludedPath) { return $true }
    }
    foreach ($searchRoot in $SearchRoots) {
        if ($fullPath.Equals($searchRoot,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $leaf = Split-Path -Leaf $fullPath
    return @($script:RolloutExcludedDirectoryNames | Where-Object { $_.Equals($leaf,[System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
}

function Resolve-RolloutRepositoryIdentity {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $GitExecutable)
    if ((Get-RolloutGitExitCode -Repository $Path -GitExecutable $GitExecutable -Arguments @('rev-parse','--is-inside-work-tree')) -ne 0) {
        return $null
    }
    $inside = ((Invoke-RolloutGit -Repository $Path -GitExecutable $GitExecutable -Arguments @('rev-parse','--is-inside-work-tree')) | Select-Object -First 1).Trim()
    if ($inside -cne 'true') { return $null }
    $topLevel = Get-RolloutFullPath -Path (((Invoke-RolloutGit -Repository $Path -GitExecutable $GitExecutable -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim())
    $commonDirectory = ((Invoke-RolloutGit -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonDirectory)) { $commonDirectory = Join-Path $topLevel $commonDirectory }
    $commonDirectory = Get-RolloutFullPath -Path $commonDirectory
    $branch = ''
    if ((Get-RolloutGitExitCode -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('symbolic-ref','-q','--short','HEAD')) -eq 0) {
        $branch = ((Invoke-RolloutGit -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('symbolic-ref','-q','--short','HEAD')) | Select-Object -First 1).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $head = if ((Get-RolloutGitExitCode -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('rev-parse','--verify','HEAD')) -eq 0) {
            ((Invoke-RolloutGit -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('rev-parse','--verify','HEAD')) | Select-Object -First 1).Trim()
        }
        else { 'unborn' }
        $branch = "DETACHED:$head"
    }
    $origin = ''
    if ((Get-RolloutGitExitCode -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('remote','get-url','origin')) -eq 0) {
        $origin = ((Invoke-RolloutGit -Repository $topLevel -GitExecutable $GitExecutable -Arguments @('remote','get-url','origin')) | Select-Object -First 1).Trim()
    }
    return [pscustomobject][ordered]@{
        Repository=$topLevel
        CommonGitDirectory=$commonDirectory
        Branch=$branch
        Origin=$origin
        Identity=($commonDirectory.ToLowerInvariant() + '|' + $topLevel.ToLowerInvariant() + '|' + $branch.ToLowerInvariant())
    }
}

function Get-AiInstructionsRepositoryRoots {
    [CmdletBinding()]
    param(
        [string[]] $SearchRoots,
        [string[]] $ExcludedRepositoryPaths=@(),
        [string] $GitExecutable='git'
    )
    if ($null -eq $SearchRoots -or $SearchRoots.Count -eq 0) { $SearchRoots = @(Get-AiInstructionsFixedSearchRoots) }
    $normalizedRoots = New-Object 'System.Collections.Generic.List[string]'
    $rootSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($SearchRoots)) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
        $fullRoot = Get-RolloutFullPath -Path ([string]$root)
        if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "Rollout search root does not exist: $fullRoot" }
        $rootItem = Get-Item -Force -LiteralPath $fullRoot
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Rollout search root must not be a reparse point: $fullRoot" }
        if ($rootSet.Add($fullRoot)) { $normalizedRoots.Add($fullRoot) }
    }
    if ($normalizedRoots.Count -eq 0) { throw 'No eligible fixed local search roots were found.' }
    $normalizedExcluded = @(
        foreach ($path in @($ExcludedRepositoryPaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) { Get-RolloutFullPath -Path ([string]$path) }
        }
    )
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($root in $normalizedRoots) { $queue.Enqueue($root) }
    $visitedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $repositoryIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $repositories = New-Object 'System.Collections.Generic.List[object]'
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $visitedDirectories.Add($current)) { continue }
        if (Test-RolloutDirectoryExcluded -Path $current -SearchRoots @($normalizedRoots) -ExcludedPaths $normalizedExcluded) { continue }
        try {
            $currentItem = Get-Item -Force -LiteralPath $current
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        }
        catch { continue }
        $gitMarker = Join-Path $current '.git'
        if (Test-Path -LiteralPath $gitMarker) {
            try {
                $identity = Resolve-RolloutRepositoryIdentity -Path $current -GitExecutable $GitExecutable
                if ($null -ne $identity -and $repositoryIdentities.Add([string]$identity.Identity)) { $repositories.Add($identity) }
            }
            catch { }
        }
        try { $children = @([System.IO.Directory]::EnumerateDirectories($current)) }
        catch { continue }
        foreach ($child in $children) {
            try {
                $childPath = Get-RolloutFullPath -Path $child
                $childItem = Get-Item -Force -LiteralPath $childPath
                if (($childItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
                    -not (Test-RolloutDirectoryExcluded -Path $childPath -SearchRoots @($normalizedRoots) -ExcludedPaths $normalizedExcluded)) {
                    $queue.Enqueue($childPath)
                }
            }
            catch { }
        }
    }
    return @($repositories | Sort-Object Repository,Branch)
}

function ConvertFrom-RolloutGitPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $value = $Path.Trim()
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
        $value = $value.Substring(1,$value.Length - 2)
        $value = $value.Replace('\\','\').Replace('\"','"').Replace('\t',"`t").Replace('\n',"`n")
    }
    return $value.Replace('\','/')
}

function Test-RolloutReservedAgentPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $normalized = (ConvertFrom-RolloutGitPath -Path $Path).TrimStart('/')
    if ($normalized -cin @(
        'AGENTS.md','AGENTS.en.md','.codex/ai-instructions.manifest.json','.codex/AGENTS.md','.codex/AGENTS.en.md',
        '.github/copilot-instructions.md','.github/copilot-instructions.en.md'
    )) { return $true }
    foreach ($prefix in @('.agents/','.codex/skills/','.github/AI-Rules/','.github/agents/','.github/instructions/','.github/prompts/')) {
        if ($normalized.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-RolloutNonAgentGitStatus {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $GitExecutable)
    $status = @(Invoke-RolloutGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('-c','core.quotePath=true','status','--porcelain=v1','--untracked-files=all'))
    return @(
        foreach ($line in $status) {
            $text = [string]$line
            if ($text.Length -lt 4) { $text; continue }
            $pathText = $text.Substring(3)
            $paths = if ($pathText -match ' -> ') { @($pathText -split ' -> ',2) } else { @($pathText) }
            $agentOnly = $true
            foreach ($path in $paths) {
                if (-not (Test-RolloutReservedAgentPath -Path $path)) { $agentOnly = $false; break }
            }
            if (-not $agentOnly) { $text }
        }
    ) | Sort-Object
}

function Get-RolloutTrackedReservedPaths {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string] $GitExecutable)
    $trackedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Invoke-RolloutGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('-c','core.quotePath=true','ls-files'))) {
        [void]$trackedPaths.Add((ConvertFrom-RolloutGitPath -Path ([string]$line)))
    }
    if ((Get-RolloutGitExitCode -Repository $Repository -GitExecutable $GitExecutable -Arguments @('rev-parse','--verify','HEAD')) -eq 0) {
        foreach ($line in @(Invoke-RolloutGit -Repository $Repository -GitExecutable $GitExecutable -Arguments @('-c','core.quotePath=true','ls-tree','-r','--name-only','HEAD'))) {
            [void]$trackedPaths.Add((ConvertFrom-RolloutGitPath -Path ([string]$line)))
        }
    }
    return @(
        foreach ($path in $trackedPaths) {
            if (Test-RolloutReservedAgentPath -Path $path) { $path }
        }
    ) | Sort-Object -Unique
}

function Get-RolloutCustomFeloArtifacts {
    param([Parameter(Mandatory = $true)][string] $Repository)
    $remaining = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relativeRoot in @('.agents/skills/search-with-felo','.codex/skills/search-with-felo')) {
        $fullRoot = Join-Path $Repository $relativeRoot.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -File -Force -Recurse -ErrorAction SilentlyContinue)) {
            $remaining.Add(($file.FullName.Substring($Repository.Length).TrimStart([char[]]@('\','/')).Replace('\','/')))
        }
    }
    return @($remaining | Sort-Object -Unique)
}

function Get-RolloutOldFeloRoutes {
    param([Parameter(Mandatory = $true)][string] $Repository)
    $remaining = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relativePath in @('AGENTS.md','AGENTS.en.md','.codex/AGENTS.md','.codex/AGENTS.en.md','.github/copilot-instructions.md','.github/copilot-instructions.en.md')) {
        $fullPath = Join-Path $Repository $relativePath.Replace('/','\')
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $content = [System.IO.File]::ReadAllText($fullPath)
            if ($content -match '(?i)(?:^|[/\\])search-with-felo(?:[/\\]|\b)') { $remaining.Add($relativePath) }
        }
    }
    return @($remaining | Sort-Object -Unique)
}

function Test-RolloutManifestCurrent {
    param([Parameter(Mandatory = $true)][string] $Repository,[AllowNull()][string] $ExpectedLockSha256)
    $manifestPath = Join-Path $Repository '.codex\ai-instructions.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $true }
    try { $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json }
    catch { return $false }
    if ($null -eq $manifest.PSObject.Properties['schemaVersion'] -or [int]$manifest.schemaVersion -ne 2) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLockSha256)) {
        if ($null -eq $manifest.PSObject.Properties['lockSha256'] -or [string]$manifest.lockSha256 -cne $ExpectedLockSha256) { return $false }
    }
    return $true
}

function Get-RolloutExpectedLockSha256 {
    $candidates = @(
        (Join-Path $PSScriptRoot 'catalog\skills-catalog-lock.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog\skills-catalog-lock.json')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    return $null
}

function Get-RolloutOfficialFeloInventory {
    param([string[]] $Roots)
    $inventory = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace([string]$root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $rootPath = Get-RolloutFullPath -Path $root
        foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -File -Force -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $relativePath = $file.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $inventory.Add($rootPath.ToLowerInvariant() + '|' + $relativePath + '|' + $hash)
        }
    }
    return @($inventory)
}

function Test-RolloutStringArraysEqual {
    param([object[]] $Left,[object[]] $Right)
    $leftValues = @($Left | ForEach-Object { [string]$_ } | Sort-Object)
    $rightValues = @($Right | ForEach-Object { [string]$_ } | Sort-Object)
    if ($leftValues.Count -ne $rightValues.Count) { return $false }
    for ($index=0; $index -lt $leftValues.Count; $index++) {
        if ($leftValues[$index] -cne $rightValues[$index]) { return $false }
    }
    return $true
}

function Invoke-AiInstructionsRollout {
    [CmdletBinding()]
    param(
        [string[]] $SearchRoots,
        [Parameter(Mandatory = $true)][string] $BootstrapPath,
        [string[]] $ExcludedRepositoryPaths=@(),
        [string[]] $AuthorityRepositoryUrls=$script:RolloutAuthorityRepositoryUrls,
        [string[]] $OfficialFeloSkillRoots,
        [string] $ExpectedLockSha256,
        [string] $ReportPath,
        [string] $GitExecutable='git'
    )
    $bootstrapFullPath = [System.IO.Path]::GetFullPath($BootstrapPath)
    if (-not (Test-Path -LiteralPath $bootstrapFullPath -PathType Leaf)) { throw "Installed bootstrap does not exist: $bootstrapFullPath" }
    if ($null -eq $SearchRoots -or $SearchRoots.Count -eq 0) { $SearchRoots = @(Get-AiInstructionsFixedSearchRoots) }
    if ($null -eq $OfficialFeloSkillRoots) {
        $userRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        $OfficialFeloSkillRoots = @(
            'felo-search','felo-slides','felo-x-search','felo-landingpage' |
                ForEach-Object { Join-Path $userRoot ('.agents\skills\' + $_) }
        )
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedLockSha256)) { $ExpectedLockSha256 = Get-RolloutExpectedLockSha256 }
    $officialBefore = @(Get-RolloutOfficialFeloInventory -Roots $OfficialFeloSkillRoots)
    $authoritySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($url in @($AuthorityRepositoryUrls)) { [void]$authoritySet.Add((ConvertTo-RolloutRepositoryUrl -Url ([string]$url))) }
    $repositories = @(Get-AiInstructionsRepositoryRoots -SearchRoots $SearchRoots -ExcludedRepositoryPaths $ExcludedRepositoryPaths -GitExecutable $GitExecutable)
    $repositoryResults = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $failed = New-Object 'System.Collections.Generic.List[object]'
    $backups = New-Object 'System.Collections.Generic.List[object]'
    $remediationCommits = New-Object 'System.Collections.Generic.List[object]'
    $customFeloRemaining = New-Object 'System.Collections.Generic.List[object]'
    $oldRoutesRemaining = New-Object 'System.Collections.Generic.List[object]'
    $oldManifestsRemaining = New-Object 'System.Collections.Generic.List[object]'
    $trackedRemaining = New-Object 'System.Collections.Generic.List[object]'
    $nonAgentDrift = New-Object 'System.Collections.Generic.List[object]'
    $trackedDetected = 0
    $trackedRemediated = 0
    $synchronized = 0
    foreach ($repository in $repositories) {
        $repositoryRoot = [string]$repository.Repository
        $normalizedOrigin = ConvertTo-RolloutRepositoryUrl -Url ([string]$repository.Origin)
        if (-not [string]::IsNullOrWhiteSpace($normalizedOrigin) -and $authoritySet.Contains($normalizedOrigin)) {
            $skipped.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Reason='authority repository'})
            continue
        }
        $beforeStatus = @(Get-RolloutNonAgentGitStatus -Repository $repositoryRoot -GitExecutable $GitExecutable)
        $outputLines = @()
        $bootstrapFailure = $null
        try {
            $outputLines = @(& $bootstrapFullPath -TargetRoot $repositoryRoot -SkipUpdateCheck 2>&1 | ForEach-Object { [string]$_ })
        }
        catch {
            $bootstrapFailure = $_.Exception.Message
        }
        $outputText = $outputLines -join [Environment]::NewLine
        if ($null -eq $bootstrapFailure -and $outputText -match '(?im)^AI instruction sync skipped:') {
            $reason = (($outputLines | Where-Object { $_ -match '^AI instruction sync skipped:' }) | Select-Object -First 1)
            $skipped.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Reason=$reason})
            $repositoryResults.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Status='skipped';Output=$outputLines;Reason=$reason})
            continue
        }
        foreach ($line in $outputLines) {
            $backupMatch = [regex]::Match($line,'^Backed up and migrated tracked Agent artifacts: (?<Paths>.+?)\. Backup: (?<Backup>.+)$')
            if ($backupMatch.Success) {
                $paths = @($backupMatch.Groups['Paths'].Value -split ',\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $trackedDetected += $paths.Count
                $trackedRemediated += $paths.Count
                $backups.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Path=$backupMatch.Groups['Backup'].Value;Artifacts=$paths})
            }
            $retiredBackupMatch = [regex]::Match($line,'^Backed up and removed retired custom FELO artifacts: (?<Paths>.+?)\. Backup: (?<Backup>.+)$')
            if ($retiredBackupMatch.Success) {
                $paths = @($retiredBackupMatch.Groups['Paths'].Value -split ',\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $backups.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Path=$retiredBackupMatch.Groups['Backup'].Value;Artifacts=$paths})
            }
            $commitMatch = [regex]::Match($line,'^Agent artifact remediation commit created: (?<Commit>[0-9a-f]{40})$')
            if ($commitMatch.Success) {
                $remediationCommits.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Commit=$commitMatch.Groups['Commit'].Value})
            }
        }
        $verificationReasons = New-Object 'System.Collections.Generic.List[string]'
        $afterStatus = @(Get-RolloutNonAgentGitStatus -Repository $repositoryRoot -GitExecutable $GitExecutable)
        if (-not (Test-RolloutStringArraysEqual -Left $beforeStatus -Right $afterStatus)) {
            $nonAgentDrift.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Before=$beforeStatus;After=$afterStatus})
            $verificationReasons.Add('non-Agent Git state changed')
        }
        $repositoryCustomFelo = @(Get-RolloutCustomFeloArtifacts -Repository $repositoryRoot)
        foreach ($path in $repositoryCustomFelo) { $customFeloRemaining.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Path=$path}) }
        if ($repositoryCustomFelo.Count -gt 0) { $verificationReasons.Add('custom FELO active artifacts remain') }
        $repositoryOldRoutes = @(Get-RolloutOldFeloRoutes -Repository $repositoryRoot)
        foreach ($path in $repositoryOldRoutes) { $oldRoutesRemaining.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Path=$path}) }
        if ($repositoryOldRoutes.Count -gt 0) { $verificationReasons.Add('old custom FELO routes remain') }
        if (-not (Test-RolloutManifestCurrent -Repository $repositoryRoot -ExpectedLockSha256 $ExpectedLockSha256)) {
            $oldManifestsRemaining.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Path='.codex/ai-instructions.manifest.json'})
            $verificationReasons.Add('manifest is not current')
        }
        $repositoryTracked = @(Get-RolloutTrackedReservedPaths -Repository $repositoryRoot -GitExecutable $GitExecutable)
        foreach ($path in $repositoryTracked) { $trackedRemaining.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Path=$path}) }
        if ($repositoryTracked.Count -gt 0) { $verificationReasons.Add('tracked reserved Agent artifacts remain') }
        if ($null -ne $bootstrapFailure -or $verificationReasons.Count -gt 0) {
            $reasonParts = New-Object 'System.Collections.Generic.List[string]'
            if ($null -ne $bootstrapFailure) { $reasonParts.Add([string]$bootstrapFailure) }
            if ($verificationReasons.Count -gt 0) {
                $reasonParts.Add('post-rollout verification failed: ' + ($verificationReasons -join '; '))
            }
            $reason = $reasonParts -join '; '
            $failed.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Reason=$reason})
            $repositoryResults.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Status='failed';Output=$outputLines;Reason=$reason})
            continue
        }
        $synchronized++
        $repositoryResults.Add([pscustomobject][ordered]@{Repository=$repositoryRoot;Status='synchronized';Output=$outputLines;Reason=$null})
    }
    $officialAfter = @(Get-RolloutOfficialFeloInventory -Roots $OfficialFeloSkillRoots)
    $officialPreserved = Test-RolloutStringArraysEqual -Left $officialBefore -Right $officialAfter
    if (-not $officialPreserved) {
        $failed.Add([pscustomobject][ordered]@{Repository='<official-felo-system>';Reason='official Felo Skill inventory changed during rollout'})
    }
    $result = [pscustomobject][ordered]@{
        SchemaVersion=1
        SearchRoots=@($SearchRoots)
        RepositoriesDiscovered=$repositories.Count
        RepositoriesSynchronized=$synchronized
        TrackedArtifactsDetected=$trackedDetected
        TrackedArtifactsRemediated=$trackedRemediated
        RemediationCommitsCreated=$remediationCommits.Count
        RemediationCommits=$remediationCommits.ToArray()
        Backups=$backups.ToArray()
        Skipped=$skipped.ToArray()
        Failed=$failed.ToArray()
        CustomFeloActiveArtifactsRemaining=$customFeloRemaining.ToArray()
        OldRuntimeRoutesRemaining=$oldRoutesRemaining.ToArray()
        OldManifestsRemaining=$oldManifestsRemaining.ToArray()
        TrackedReservedArtifactsRemaining=$trackedRemaining.ToArray()
        NonAgentGitDrift=$nonAgentDrift.ToArray()
        OfficialFeloSkillsPreserved=$officialPreserved
        RestartRequired=($synchronized -gt 0 -or $trackedRemediated -gt 0)
        RepositoryResults=$repositoryResults.ToArray()
    }
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $reportFullPath = [System.IO.Path]::GetFullPath($ReportPath)
        $reportParent = Split-Path -Parent $reportFullPath
        if (-not [string]::IsNullOrWhiteSpace($reportParent)) { New-Item -ItemType Directory -Force -Path $reportParent | Out-Null }
        [System.IO.File]::WriteAllText($reportFullPath,(($result | ConvertTo-Json -Depth 12).Replace("`r`n","`n") + "`n"),(New-Object System.Text.UTF8Encoding($false)))
    }
    return $result
}

Export-ModuleMember -Function Get-AiInstructionsFixedSearchRoots, Get-AiInstructionsRepositoryRoots, Invoke-AiInstructionsRollout
