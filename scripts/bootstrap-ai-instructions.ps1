[CmdletBinding()]
param(
    [string] $SourceRepository = 'SyuanTsai/SyuanTsai-AI-Instructions',
    [string] $SourceRef = 'main',
    [string] $SourceArchivePath,
    [string] $TargetRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

function Get-FullPathWithoutTrailingSeparator {
    param([Parameter(Mandatory = $true)][string] $Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
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

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $resolvedRoot = & git -C (Get-Location).Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'AI instruction bootstrap skipped: the current directory is not inside a Git repository.'
        return
    }

    $TargetRoot = ($resolvedRoot | Select-Object -First 1).Trim()
}

$targetRootPath = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
$insideWorkTree = Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', '--is-inside-work-tree')
if (($insideWorkTree | Select-Object -First 1).Trim() -ne 'true') {
    Write-Output "AI instruction bootstrap skipped: target is not a Git work tree: $targetRootPath"
    return
}

$families = @(
    @{
        Name = 'Codex'
        SourceBase = '.codex\AGENTS.en.md'
        TargetBase = 'AGENTS.md'
        SourceRules = '.codex\AI-Rules'
        TargetRules = '.codex\AI-Rules'
    },
    @{
        Name = 'GitHub Copilot'
        SourceBase = '.github\copilot-instructions.en.md'
        TargetBase = '.github\copilot-instructions.md'
        SourceRules = '.github\AI-Rules'
        TargetRules = '.github\AI-Rules'
    }
)

$missingFamilies = @($families | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $targetRootPath $_.TargetBase))
})

if ($missingFamilies.Count -eq 0) {
    Write-Output 'AI instruction bootstrap: all instruction families already exist; no download or commit was required.'
    return
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
    $familiesToCreate = New-Object System.Collections.Generic.List[object]

    foreach ($family in $missingFamilies) {
        $sourceBasePath = Join-Path $sourceRootPath $family.SourceBase
        $sourceRulesPath = Join-Path $sourceRootPath $family.SourceRules

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

        $familiesToCreate.Add(@{
            Family = $family
            SourceBasePath = $sourceBasePath
            TargetBasePath = Join-Path $targetRootPath $family.TargetBase
            EnglishRules = $englishRules
        })
    }

    $createdPaths = New-Object System.Collections.Generic.List[string]

    foreach ($item in $familiesToCreate) {
        $targetBaseDirectory = Split-Path -Parent $item.TargetBasePath
        if (-not [string]::IsNullOrWhiteSpace($targetBaseDirectory)) {
            New-Item -ItemType Directory -Force -Path $targetBaseDirectory | Out-Null
        }

        Copy-Item -LiteralPath $item.SourceBasePath -Destination $item.TargetBasePath
        $createdPaths.Add((Get-RepositoryRelativePath -RepositoryRoot $targetRootPath -FullPath $item.TargetBasePath))

        $targetRulesPath = Join-Path $targetRootPath $item.Family.TargetRules
        New-Item -ItemType Directory -Force -Path $targetRulesPath | Out-Null

        foreach ($sourceRule in $item.EnglishRules) {
            $targetRulePath = Join-Path $targetRulesPath $sourceRule.Name
            if (Test-Path -LiteralPath $targetRulePath) {
                continue
            }

            Copy-Item -LiteralPath $sourceRule.FullName -Destination $targetRulePath
            $createdPaths.Add((Get-RepositoryRelativePath -RepositoryRoot $targetRootPath -FullPath $targetRulePath))
        }
    }

    $pathArguments = @($createdPaths.ToArray())
    Invoke-Git -Repository $targetRootPath -Arguments (@('add', '--') + $pathArguments) | Out-Null
    Invoke-Git -Repository $targetRootPath -Arguments (@('diff', '--cached', '--check', '--') + $pathArguments) | Out-Null
    Invoke-Git -Repository $targetRootPath -Arguments (@('commit', '--only', '--quiet', '-m', 'chore: add shared AI instructions', '--') + $pathArguments) | Out-Null

    $committedPaths = @(Invoke-Git -Repository $targetRootPath -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'))
    $unexpectedPaths = @($committedPaths | Where-Object { $_ -notin $pathArguments })
    $missingPaths = @($pathArguments | Where-Object { $_ -notin $committedPaths })

    if ($unexpectedPaths.Count -gt 0 -or $missingPaths.Count -gt 0) {
        throw "Bootstrap commit verification failed. Unexpected: $($unexpectedPaths -join ', '); Missing: $($missingPaths -join ', ')"
    }

    Write-Output "AI instructions downloaded from GitHub and committed: $($pathArguments -join ', ')"
}
finally {
    $resolvedWorkingPath = [System.IO.Path]::GetFullPath($workingPath)
    $expectedPrefix = $tempRootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe temporary cleanup path: $resolvedWorkingPath"
    }

    Remove-Item -LiteralPath $resolvedWorkingPath -Recurse -Force -ErrorAction SilentlyContinue
}
