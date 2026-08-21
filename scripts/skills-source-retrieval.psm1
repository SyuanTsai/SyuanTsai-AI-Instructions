Set-StrictMode -Version 2.0

function Assert-HttpsGitRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $uri = $null
    if (-not [System.Uri]::TryCreate($Repository, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "Skills source repository must be an absolute HTTPS URL: $Repository"
    }
    return $uri
}

function Get-GitHubArchiveUri {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $ResolvedCommit
    )

    $uri = Assert-HttpsGitRepository -Repository $Repository
    if (-not $uri.Host.Equals('github.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "GitHub archive URI requires a github.com repository: $Repository"
    }
    if ($ResolvedCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Skills source resolvedCommit must be a full 40-character SHA: $ResolvedCommit"
    }

    $path = $uri.AbsolutePath.Trim('/')
    if ($path.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(0, $path.Length - 4)
    }
    $parts = @($path.Split('/'))
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "Skills source repository must identify a GitHub owner/repository pair: $Repository"
    }

    $owner = [System.Uri]::EscapeDataString($parts[0])
    $repo = [System.Uri]::EscapeDataString($parts[1])
    return "https://codeload.github.com/$owner/$repo/zip/$ResolvedCommit"
}

function Invoke-RetrievalGit {
    param(
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $WorkingDirectory @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function New-GenericGitArchive {
    param(
        [Parameter(Mandatory = $true)][object] $Source,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $WorkingRoot
    )

    $repository = [string]$Source.repository
    $null = Assert-HttpsGitRepository -Repository $repository
    $resolvedCommit = [string]$Source.resolvedCommit
    if ($resolvedCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Skills source resolvedCommit must be a full 40-character SHA: $resolvedCommit"
    }

    $repositoryRoot = Join-Path $WorkingRoot 'repository'
    New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
    Invoke-RetrievalGit -WorkingDirectory $repositoryRoot -Arguments @('init','--quiet') | Out-Null
    Invoke-RetrievalGit -WorkingDirectory $repositoryRoot -Arguments @('remote','add','origin',$repository) | Out-Null

    $requestedRef = if ($null -ne $Source.PSObject.Properties['requestedRef'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Source.requestedRef)) {
        [string]$Source.requestedRef
    }
    else {
        $resolvedCommit
    }

    Invoke-RetrievalGit -WorkingDirectory $repositoryRoot -Arguments @('fetch','--quiet','--depth','1','origin',$requestedRef) | Out-Null
    $fetchedCommit = ((Invoke-RetrievalGit -WorkingDirectory $repositoryRoot -Arguments @('rev-parse','FETCH_HEAD')) | Select-Object -First 1).Trim()
    if ($fetchedCommit -cne $resolvedCommit) {
        throw "Skills source '$([string]$Source.id)' resolved commit changed: expected $resolvedCommit, fetched $fetchedCommit."
    }

    Invoke-RetrievalGit -WorkingDirectory $repositoryRoot -Arguments @(
        'archive','--format=zip','--prefix=repository/','--output',([System.IO.Path]::GetFullPath($ArchivePath)),'FETCH_HEAD'
    ) | Out-Null
    return $ArchivePath
}

function Get-SkillsSourceArchives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [hashtable] $LocalArchiveOverrides = @{}
    )

    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not (Test-Path -LiteralPath $destination)) {
        New-Item -ItemType Directory -Path $destination | Out-Null
    }

    $result = @{}
    foreach ($source in @($Plan.Sources)) {
        $sourceId = [string]$source.id
        if ($sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "Unsafe source ID for retrieval: $sourceId"
        }

        if ($LocalArchiveOverrides.ContainsKey($sourceId)) {
            $override = [System.IO.Path]::GetFullPath([string]$LocalArchiveOverrides[$sourceId])
            if (-not (Test-Path -LiteralPath $override -PathType Leaf)) {
                throw "Local archive override for source '$sourceId' does not exist: $override"
            }
            $result[$sourceId] = $override
            continue
        }

        $archivePath = Join-Path $destination "$sourceId.zip"
        $repositoryUri = Assert-HttpsGitRepository -Repository ([string]$source.repository)
        if ($repositoryUri.Host.Equals('github.com', [System.StringComparison]::OrdinalIgnoreCase)) {
            $archiveUri = Get-GitHubArchiveUri -Repository ([string]$source.repository) -ResolvedCommit ([string]$source.resolvedCommit)
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{ 'User-Agent'='Codex-Agent-Skills-Bootstrap' } -OutFile $archivePath
        }
        else {
            $genericRoot = Join-Path $destination ("$sourceId-git")
            New-GenericGitArchive -Source $source -ArchivePath $archivePath -WorkingRoot $genericRoot | Out-Null
        }
        $result[$sourceId] = $archivePath
    }

    return $result
}

Export-ModuleMember -Function Get-GitHubArchiveUri, Get-SkillsSourceArchives
