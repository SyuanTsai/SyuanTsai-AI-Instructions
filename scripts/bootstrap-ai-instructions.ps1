[CmdletBinding()]
param(
    [string] $SourceRepository = 'SyuanTsai/SyuanTsai-AI-Instructions',
    [string] $SourceRef = 'main',
    [string] $SourceArchivePath,
    [string] $TargetRoot,
    [string] $ConfigurationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$manifestRelativePath = '.codex/ai-instructions.manifest.json'
$initialCommitMessage = 'chore: add shared AI instructions'
$syncCommitMessage = 'chore: sync shared AI instructions'

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Get-GitExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & git -C $Repository @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-FullPathWithoutTrailingSeparator {
    param([Parameter(Mandatory = $true)][string] $Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Get-NormalizedRepositoryLocation {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)

    $trimmedUrl = $RepositoryUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedUrl)) {
        throw 'Repository URL cannot be empty.'
    }

    $hostName = $null
    $repositoryPath = $null
    $absoluteUri = $null
    if ([System.Uri]::TryCreate($trimmedUrl, [System.UriKind]::Absolute, [ref] $absoluteUri) -and
        -not [string]::IsNullOrWhiteSpace($absoluteUri.Host)) {
        $hostName = $absoluteUri.Host
        $repositoryPath = $absoluteUri.AbsolutePath
    }
    elseif ($trimmedUrl -match '^(?:[^@/]+@)?(?<Host>[^:/]+):(?<Path>.+)$') {
        $hostName = $Matches.Host
        $repositoryPath = $Matches.Path
    }
    else {
        throw "Repository URL must identify a remote Git repository: $RepositoryUrl"
    }

    $normalizedPath = $repositoryPath.Trim([char[]]@('/', '\'))
    if ($normalizedPath.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedPath = $normalizedPath.Substring(0, $normalizedPath.Length - 4)
    }

    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        throw "Repository URL does not contain a repository path: $RepositoryUrl"
    }

    return "$($hostName.ToLowerInvariant())/$normalizedPath"
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $FullPath
    )

    return $FullPath.Substring($RepositoryRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
}

function Get-NormalizedContentHash {
    param([Parameter(Mandatory = $true)][string] $Path)

    $content = [System.IO.File]::ReadAllText($Path)
    $normalizedContent = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $contentBytes = $utf8WithoutBom.GetBytes($normalizedContent)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($contentBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-IsAllowedManagedPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return $Path -eq 'AGENTS.md' -or
        $Path -eq '.github/copilot-instructions.md' -or
        $Path -match '^\.codex/AI-Rules/[^/\\]+\.en\.md$' -or
        $Path -match '^\.github/AI-Rules/[^/\\]+\.en\.md$'
}

function Test-GitPathHasChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $workingTreeExitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--quiet', '--', $Path)
    $indexExitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path)

    if ($workingTreeExitCode -gt 1 -or $indexExitCode -gt 1) {
        throw "Unable to inspect local changes for managed path: $Path"
    }

    return $workingTreeExitCode -eq 1 -or $indexExitCode -eq 1
}

function Test-GitPathHasStagedChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect staged changes for managed path: $Path"
    }

    return $exitCode -eq 1
}

function Test-GitPathIsTracked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('ls-files', '--error-unmatch', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect tracked managed path: $Path"
    }

    return $exitCode -eq 0
}

function Test-GitPathNeedsCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (Test-GitPathHasStagedChanges -Repository $Repository -Path $Path) {
        return $false
    }

    if (-not (Test-GitPathIsTracked -Repository $Repository -Path $Path)) {
        return Test-Path -LiteralPath (Join-Path $Repository $Path.Replace('/', '\'))
    }

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--quiet', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect pending managed path: $Path"
    }

    return $exitCode -eq 1
}

function Test-WasCreatedByPreviousBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (Test-GitPathHasChanges -Repository $Repository -Path $Path) {
        return $false
    }

    $addCommits = @(Invoke-Git -Repository $Repository -Arguments @('log', '--diff-filter=A', '--format=%H', '--', $Path))
    if ($addCommits.Count -eq 0) {
        return $false
    }

    $addCommit = ($addCommits | Select-Object -First 1).Trim()
    $subject = (Invoke-Git -Repository $Repository -Arguments @('show', '-s', '--format=%s', $addCommit) | Select-Object -First 1).Trim()
    if ($subject -ne $initialCommitMessage) {
        return $false
    }

    $createdBlob = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', "$addCommit`:$Path") | Select-Object -First 1).Trim()
    $currentBlob = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', "HEAD`:$Path") | Select-Object -First 1).Trim()
    return $createdBlob -eq $currentBlob
}

function New-ManifestEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

    return [pscustomobject][ordered]@{
        sourcePath = $SourcePath
        targetPath = $TargetPath
        sha256 = $Sha256
    }
}

function Get-PersonalAgentStashes {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $stashes = New-Object System.Collections.Generic.List[object]
    $stashLines = @(Invoke-Git -Repository $Repository -Arguments @('stash', 'list', '--format=%gd%x09%H%x09%gs'))
    foreach ($stashLine in $stashLines) {
        $parts = ([string] $stashLine).Split(@("`t"), 3, [System.StringSplitOptions]::None)
        if ($parts.Count -ne 3 -or $parts[2] -notmatch '(^|: )PersonalAgent$') {
            continue
        }

        $indexMatch = [System.Text.RegularExpressions.Regex]::Match($parts[0], '^stash@\{([0-9]+)\}$')
        if (-not $indexMatch.Success) {
            throw "Unexpected PersonalAgent stash reference: $($parts[0])"
        }

        $stashes.Add([pscustomobject]@{
            Reference = $parts[0]
            Hash = $parts[1]
            Index = [int] $indexMatch.Groups[1].Value
        })
    }

    return $stashes
}

function Update-PersonalAgentStash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Paths
    )

    if ($Paths.Count -eq 0) {
        throw 'Cannot create PersonalAgent stash without managed changes.'
    }

    Invoke-Git -Repository $Repository -Arguments (@(
        'stash', 'push', '--include-untracked', '--quiet', '-m', 'PersonalAgent', '--'
    ) + $Paths) | Out-Null

    $newStashHash = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', 'stash@{0}') | Select-Object -First 1).Trim()
    $newStash = @(Get-PersonalAgentStashes -Repository $Repository | Where-Object { $_.Hash -eq $newStashHash })
    if ($newStash.Count -ne 1) {
        throw 'PersonalAgent stash was not created as the latest stash.'
    }

    Invoke-Git -Repository $Repository -Arguments @('stash', 'apply', '--quiet', 'stash@{0}') | Out-Null

    $obsoleteStashes = @(
        Get-PersonalAgentStashes -Repository $Repository |
            Where-Object { $_.Hash -ne $newStashHash } |
            Sort-Object Index -Descending
    )
    foreach ($obsoleteStash in $obsoleteStashes) {
        Invoke-Git -Repository $Repository -Arguments @('stash', 'drop', '--quiet', $obsoleteStash.Reference) | Out-Null
    }

    return $newStashHash
}

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $resolvedRoot = & git -C (Get-Location).Path rev-parse --show-toplevel 2>$null
        $resolveExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($resolveExitCode -ne 0) {
        Write-Output 'AI instruction sync skipped: the current directory is not inside a Git repository.'
        return
    }

    $TargetRoot = ($resolvedRoot | Select-Object -First 1).Trim()
}

$targetRootPath = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
$insideWorkTree = Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', '--is-inside-work-tree')
if (($insideWorkTree | Select-Object -First 1).Trim() -ne 'true') {
    Write-Output "AI instruction sync skipped: target is not a Git work tree: $targetRootPath"
    return
}

$sourceCodexBaseInTarget = Join-Path $targetRootPath '.codex\AGENTS.en.md'
$sourceCopilotBaseInTarget = Join-Path $targetRootPath '.github\copilot-instructions.en.md'
if ((Test-Path -LiteralPath $sourceCodexBaseInTarget -PathType Leaf) -and
    (Test-Path -LiteralPath $sourceCopilotBaseInTarget -PathType Leaf)) {
    Write-Output 'AI instruction sync skipped: the current repository is the shared instruction source.'
    return
}

if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path $HOME '.codex'
    }
    $ConfigurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
}

$configurationFullPath = [System.IO.Path]::GetFullPath($ConfigurationPath)
$autoCommitEnabled = $false
if (Test-Path -LiteralPath $configurationFullPath -PathType Leaf) {
    try {
        $configuration = Get-Content -Raw -LiteralPath $configurationFullPath | ConvertFrom-Json
    }
    catch {
        throw "AI instruction sync configuration is not valid JSON: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        $configuration.schemaVersion -ne 2) {
        throw "Unsupported AI instruction sync configuration schema: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -notcontains 'autoCommitRepositoryUrls') {
        throw "AI instruction sync configuration is missing autoCommitRepositoryUrls: $configurationFullPath"
    }

    $configuredRepositoryLocations = @(
        foreach ($configuredRepositoryUrl in @($configuration.autoCommitRepositoryUrls)) {
            try {
                Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $configuredRepositoryUrl)
            }
            catch {
                throw "autoCommitRepositoryUrls contains an invalid repository URL '$configuredRepositoryUrl': $($_.Exception.Message)"
            }
        }
    )

    if ($configuredRepositoryLocations.Count -gt 0 -and
        (Get-GitExitCode -Repository $targetRootPath -Arguments @('remote', 'get-url', 'origin')) -eq 0) {
        $originUrls = @(Invoke-Git -Repository $targetRootPath -Arguments @('remote', 'get-url', '--all', 'origin'))
        foreach ($originUrl in $originUrls) {
            $originLocation = Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $originUrl)
            foreach ($configuredRepositoryLocation in $configuredRepositoryLocations) {
                if ($originLocation.Equals($configuredRepositoryLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $autoCommitEnabled = $true
                    break
                }
            }

            if ($autoCommitEnabled) {
                break
            }
        }
    }
}

$families = @(
    @{
        Name = 'Codex'
        SourceBase = '.codex/AGENTS.en.md'
        TargetBase = 'AGENTS.md'
        SourceRules = '.codex/AI-Rules'
        TargetRules = '.codex/AI-Rules'
    },
    @{
        Name = 'GitHub Copilot'
        SourceBase = '.github/copilot-instructions.en.md'
        TargetBase = '.github/copilot-instructions.md'
        SourceRules = '.github/AI-Rules'
        TargetRules = '.github/AI-Rules'
    }
)

$manifestFullPath = Join-Path $targetRootPath $manifestRelativePath.Replace('/', '\')
$manifestExists = Test-Path -LiteralPath $manifestFullPath -PathType Leaf
$manifestEntriesByTarget = @{}

if ($manifestExists) {
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestFullPath | ConvertFrom-Json
    }
    catch {
        throw "Managed instruction manifest is not valid JSON: $manifestRelativePath"
    }

    if ($manifest.schemaVersion -ne 1) {
        throw "Unsupported managed instruction manifest schema: $($manifest.schemaVersion)"
    }

    if ($manifest.sourceRepository -ne $SourceRepository -or $manifest.sourceRef -ne $SourceRef) {
        throw 'Managed instruction manifest source does not match the configured source repository and ref.'
    }

    foreach ($entry in @($manifest.files)) {
        $targetPath = [string] $entry.targetPath
        if (-not (Test-IsAllowedManagedPath -Path $targetPath)) {
            throw "Unsafe target path in managed instruction manifest: $targetPath"
        }

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            throw "Duplicate target path in managed instruction manifest: $targetPath"
        }

        if ([string]::IsNullOrWhiteSpace([string] $entry.sourcePath) -or
            [string] $entry.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "Invalid managed instruction manifest entry: $targetPath"
        }

        $manifestEntriesByTarget[$targetPath] = $entry
    }
}

$tempRootPath = Get-FullPathWithoutTrailingSeparator -Path ([System.IO.Path]::GetTempPath())
$workingPath = Join-Path $tempRootPath ('codex-ai-instructions-' + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $workingPath 'source.zip'
$extractPath = Join-Path $workingPath 'source'

try {
    New-Item -ItemType Directory -Path $workingPath, $extractPath | Out-Null

    if ([string]::IsNullOrWhiteSpace($SourceArchivePath)) {
        if ($SourceRepository -notmatch '^[^/]+/[^/]+$') {
            throw "SourceRepository must use owner/repository format: $SourceRepository"
        }

        $repositoryParts = $SourceRepository.Split('/')
        $escapedOwner = [System.Uri]::EscapeDataString($repositoryParts[0])
        $escapedRepository = [System.Uri]::EscapeDataString($repositoryParts[1])
        $escapedRef = [System.Uri]::EscapeDataString($SourceRef)
        $archiveUri = "https://github.com/$escapedOwner/$escapedRepository/archive/refs/heads/$escapedRef.zip"

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{
            'User-Agent' = 'Codex-AI-Instructions-Bootstrap'
        } -OutFile $archivePath
    }
    else {
        $providedArchivePath = Get-FullPathWithoutTrailingSeparator -Path $SourceArchivePath
        if (-not (Test-Path -LiteralPath $providedArchivePath -PathType Leaf)) {
            throw "Source archive does not exist: $providedArchivePath"
        }

        Copy-Item -LiteralPath $providedArchivePath -Destination $archivePath
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
    $archiveRoots = @(Get-ChildItem -LiteralPath $extractPath -Directory)
    if ($archiveRoots.Count -ne 1) {
        throw "Expected one repository root in the source archive, found $($archiveRoots.Count)."
    }

    $sourceRootPath = $archiveRoots[0].FullName
    $desiredEntries = New-Object System.Collections.Generic.List[object]

    foreach ($family in $families) {
        $sourceBasePath = Join-Path $sourceRootPath $family.SourceBase.Replace('/', '\')
        $sourceRulesPath = Join-Path $sourceRootPath $family.SourceRules.Replace('/', '\')

        if (-not (Test-Path -LiteralPath $sourceBasePath -PathType Leaf)) {
            throw "$($family.Name) base instruction is missing from GitHub archive: $($family.SourceBase)"
        }

        if (-not (Test-Path -LiteralPath $sourceRulesPath -PathType Container)) {
            throw "$($family.Name) rule directory is missing from GitHub archive: $($family.SourceRules)"
        }

        $englishRules = @(Get-ChildItem -LiteralPath $sourceRulesPath -File -Filter '*.en.md' | Sort-Object Name)
        if ($englishRules.Count -eq 0) {
            throw "$($family.Name) has no English rule modules in the GitHub archive."
        }

        $desiredEntries.Add([pscustomobject]@{
            FamilyName = $family.Name
            SourcePath = $family.SourceBase
            TargetPath = $family.TargetBase
            SourceFullPath = $sourceBasePath
            Sha256 = Get-NormalizedContentHash -Path $sourceBasePath
        })

        foreach ($sourceRule in $englishRules) {
            $sourceRelativePath = "$($family.SourceRules)/$($sourceRule.Name)"
            $targetRelativePath = "$($family.TargetRules)/$($sourceRule.Name)"
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $family.Name
                SourcePath = $sourceRelativePath
                TargetPath = $targetRelativePath
                SourceFullPath = $sourceRule.FullName
                Sha256 = Get-NormalizedContentHash -Path $sourceRule.FullName
            })
        }
    }

    $desiredEntriesByTarget = @{}
    foreach ($entry in $desiredEntries) {
        if (-not (Test-IsAllowedManagedPath -Path $entry.TargetPath)) {
            throw "Unsafe desired instruction target path: $($entry.TargetPath)"
        }

        if ($desiredEntriesByTarget.ContainsKey($entry.TargetPath)) {
            throw "Duplicate desired instruction target path: $($entry.TargetPath)"
        }

        $desiredEntriesByTarget[$entry.TargetPath] = $entry
    }

    $eligibleFamilies = @{}
    foreach ($family in $families) {
        $baseTargetPath = $family.TargetBase
        $baseTargetFullPath = Join-Path $targetRootPath $baseTargetPath.Replace('/', '\')
        $eligibleFamilies[$family.Name] =
            $manifestEntriesByTarget.ContainsKey($baseTargetPath) -or
            -not (Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -or
            (Test-WasCreatedByPreviousBootstrap -Repository $targetRootPath -Path $baseTargetPath)
    }

    $createdPaths = New-Object System.Collections.Generic.List[string]
    $updatedPaths = New-Object System.Collections.Generic.List[string]
    $removedPaths = New-Object System.Collections.Generic.List[string]
    $adoptedPaths = New-Object System.Collections.Generic.List[string]
    $skippedPaths = New-Object System.Collections.Generic.List[string]
    $nextManifestEntries = New-Object System.Collections.Generic.List[object]

    foreach ($desiredEntry in @($desiredEntries | Sort-Object TargetPath)) {
        $targetPath = $desiredEntry.TargetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        $targetExists = Test-Path -LiteralPath $targetFullPath -PathType Leaf
        $managedEntry = $null

        if (-not $eligibleFamilies[$desiredEntry.FamilyName]) {
            if ($targetExists) {
                $skippedPaths.Add($targetPath)
            }
            continue
        }

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            $managedEntry = $manifestEntriesByTarget[$targetPath]
        }

        if ($null -ne $managedEntry) {
            if (-not $targetExists) {
                if (Test-GitPathHasChanges -Repository $targetRootPath -Path $targetPath) {
                    $skippedPaths.Add($targetPath)
                    $nextManifestEntries.Add((New-ManifestEntry -SourcePath ([string] $managedEntry.sourcePath) -TargetPath $targetPath -Sha256 ([string] $managedEntry.sha256)))
                    continue
                }

                $targetDirectory = Split-Path -Parent $targetFullPath
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
                Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath
                $updatedPaths.Add($targetPath)
                $nextManifestEntries.Add((New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256))
                continue
            }

            if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((New-ManifestEntry -SourcePath ([string] $managedEntry.sourcePath) -TargetPath $targetPath -Sha256 ([string] $managedEntry.sha256)))
                continue
            }

            $currentHash = Get-NormalizedContentHash -Path $targetFullPath
            if ($currentHash -eq [string] $managedEntry.sha256 -or $currentHash -eq $desiredEntry.Sha256) {
                if ($currentHash -ne $desiredEntry.Sha256) {
                    Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath -Force
                    $updatedPaths.Add($targetPath)
                }

                $nextManifestEntries.Add((New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256))
            }
            else {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((New-ManifestEntry -SourcePath ([string] $managedEntry.sourcePath) -TargetPath $targetPath -Sha256 ([string] $managedEntry.sha256)))
            }

            continue
        }

        if (-not $targetExists) {
            $targetDirectory = Split-Path -Parent $targetFullPath
            if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) {
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            }

            Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath
            $createdPaths.Add($targetPath)
            $nextManifestEntries.Add((New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256))
            continue
        }

        if (Test-WasCreatedByPreviousBootstrap -Repository $targetRootPath -Path $targetPath) {
            $currentHash = Get-NormalizedContentHash -Path $targetFullPath
            if ($currentHash -ne $desiredEntry.Sha256) {
                Copy-Item -LiteralPath $desiredEntry.SourceFullPath -Destination $targetFullPath -Force
                $updatedPaths.Add($targetPath)
            }

            $adoptedPaths.Add($targetPath)
            $nextManifestEntries.Add((New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256))
        }
        else {
            $skippedPaths.Add($targetPath)
        }
    }

    foreach ($managedTargetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if ($desiredEntriesByTarget.ContainsKey($managedTargetPath)) {
            continue
        }

        $managedEntry = $manifestEntriesByTarget[$managedTargetPath]
        $targetFullPath = Join-Path $targetRootPath $managedTargetPath.Replace('/', '\')
        if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $managedTargetPath) {
            $skippedPaths.Add($managedTargetPath)
            continue
        }

        if (Test-Path -LiteralPath $targetFullPath -PathType Leaf) {
            $currentHash = Get-NormalizedContentHash -Path $targetFullPath
            if ($currentHash -ne [string] $managedEntry.sha256) {
                $skippedPaths.Add($managedTargetPath)
                continue
            }

            Remove-Item -LiteralPath $targetFullPath -Force
            $removedPaths.Add($managedTargetPath)
        }
    }

    $shouldWriteManifest = $manifestExists -or $nextManifestEntries.Count -gt 0
    $manifestChanged = $false
    if ($shouldWriteManifest) {
        $manifestDirectory = Split-Path -Parent $manifestFullPath
        New-Item -ItemType Directory -Force -Path $manifestDirectory | Out-Null

        $manifestObject = [ordered]@{
            schemaVersion = 1
            sourceRepository = $SourceRepository
            sourceRef = $SourceRef
            files = @($nextManifestEntries | Sort-Object targetPath)
        }
        $manifestJson = ($manifestObject | ConvertTo-Json -Depth 5).Replace("`r`n", "`n") + "`n"
        $existingManifestJson = if ($manifestExists) {
            ([System.IO.File]::ReadAllText($manifestFullPath)).Replace("`r`n", "`n").Replace("`r", "`n")
        }
        else {
            $null
        }

        if ($existingManifestJson -ne $manifestJson) {
            $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($manifestFullPath, $manifestJson, $utf8WithoutBom)
            $manifestChanged = $true
        }
    }

    if ($skippedPaths.Count -gt 0) {
        $uniqueSkippedPaths = @($skippedPaths | Sort-Object -Unique)
        Write-Output "AI instructions customized or unmanaged; not overwritten: $($uniqueSkippedPaths -join ', ')"
    }

    $changedPaths = @(
        @($createdPaths) +
        @($updatedPaths) +
        @($removedPaths) +
        $(if ($manifestChanged) { @($manifestRelativePath) } else { @() }) |
            Sort-Object -Unique
    )

    $manifestHasStagedChanges = $manifestExists -and
        (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $manifestRelativePath)

    if (-not $autoCommitEnabled) {
        $personalAgentStashes = @(Get-PersonalAgentStashes -Repository $targetRootPath)
        $shouldRefreshPersonalAgentStash = $changedPaths.Count -gt 0 -or $personalAgentStashes.Count -eq 0

        if ($manifestHasStagedChanges) {
            Write-Output 'AI instructions synchronized without commit or PersonalAgent stash refresh because the managed manifest has staged changes.'
            return
        }

        if ($shouldRefreshPersonalAgentStash) {
            $stashPaths = New-Object System.Collections.Generic.List[string]
            foreach ($changedPath in $changedPaths) {
                $changedFullPath = Join-Path $targetRootPath $changedPath.Replace('/', '\')
                if ((Test-Path -LiteralPath $changedFullPath) -or
                    (Test-GitPathIsTracked -Repository $targetRootPath -Path $changedPath)) {
                    $stashPaths.Add($changedPath)
                }
            }

            foreach ($manifestEntry in $nextManifestEntries) {
                $targetPath = [string] $manifestEntry.targetPath
                $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
                if ((Test-Path -LiteralPath $targetFullPath -PathType Leaf) -and
                    (Get-NormalizedContentHash -Path $targetFullPath) -eq [string] $manifestEntry.sha256 -and
                    (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $targetPath)) {
                    $stashPaths.Add($targetPath)
                }
            }

            if ((Test-Path -LiteralPath $manifestFullPath -PathType Leaf) -and
                (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $manifestRelativePath)) {
                $stashPaths.Add($manifestRelativePath)
            }

            $stashPathArguments = @($stashPaths | Sort-Object -Unique)
            if ($stashPathArguments.Count -gt 0) {
                $newStashHash = Update-PersonalAgentStash -Repository $targetRootPath -Paths $stashPathArguments
                Write-Output "PersonalAgent stash updated, reapplied, and retained: $newStashHash"
            }
        }

        if ($changedPaths.Count -eq 0) {
            Write-Output 'AI instructions are up to date; this repository is not allowlisted, so no commit was created.'
        }
        else {
            Write-Output "AI instructions synchronized without commit because this repository is not allowlisted: $($changedPaths -join ', ')"
        }
        return
    }

    if ($manifestHasStagedChanges) {
        Write-Output 'AI instructions synchronized without commit because the managed manifest has staged changes.'
        return
    }

    $commitPaths = New-Object System.Collections.Generic.List[string]
    foreach ($changedPath in $changedPaths) {
        $commitPaths.Add($changedPath)
    }

    foreach ($manifestEntry in $nextManifestEntries) {
        $targetPath = [string] $manifestEntry.targetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        if ((Test-Path -LiteralPath $targetFullPath -PathType Leaf) -and
            (Get-NormalizedContentHash -Path $targetFullPath) -eq [string] $manifestEntry.sha256 -and
            (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $targetPath)) {
            $commitPaths.Add($targetPath)
        }
    }

    if ((Test-Path -LiteralPath $manifestFullPath -PathType Leaf) -and
        (Test-GitPathNeedsCommit -Repository $targetRootPath -Path $manifestRelativePath)) {
        $commitPaths.Add($manifestRelativePath)
    }

    $pathArguments = @($commitPaths | Sort-Object -Unique)
    if ($pathArguments.Count -eq 0) {
        Write-Output 'AI instructions are up to date; no commit was required.'
        return
    }

    Invoke-Git -Repository $targetRootPath -Arguments (@('add', '--') + $pathArguments) | Out-Null
    Invoke-Git -Repository $targetRootPath -Arguments (@('diff', '--cached', '--check', '--') + $pathArguments) | Out-Null

    $isInitialBootstrap = -not $manifestExists -and
        $createdPaths.Count -gt 0 -and
        $updatedPaths.Count -eq 0 -and
        $adoptedPaths.Count -eq 0
    $commitMessage = if ($isInitialBootstrap) { $initialCommitMessage } else { $syncCommitMessage }
    Invoke-Git -Repository $targetRootPath -Arguments (@('commit', '--only', '--quiet', '-m', $commitMessage, '--') + $pathArguments) | Out-Null

    $committedPaths = @(Invoke-Git -Repository $targetRootPath -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'))
    $unexpectedPaths = @($committedPaths | Where-Object { $_ -notin $pathArguments })
    $missingPaths = @($pathArguments | Where-Object { $_ -notin $committedPaths })

    if ($unexpectedPaths.Count -gt 0 -or $missingPaths.Count -gt 0) {
        throw "Instruction sync commit verification failed. Unexpected: $($unexpectedPaths -join ', '); Missing: $($missingPaths -join ', ')"
    }

    Write-Output "AI instructions synchronized from GitHub and committed: $($pathArguments -join ', ')"
}
finally {
    $resolvedWorkingPath = [System.IO.Path]::GetFullPath($workingPath)
    $expectedPrefix = $tempRootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe temporary cleanup path: $resolvedWorkingPath"
    }

    Remove-Item -LiteralPath $resolvedWorkingPath -Recurse -Force -ErrorAction SilentlyContinue
}
