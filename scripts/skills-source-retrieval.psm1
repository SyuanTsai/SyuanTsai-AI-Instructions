Set-StrictMode -Version 2.0

function Get-GitHubArchiveUri {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $ResolvedCommit
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Repository, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw "Skills source repository must be an absolute HTTPS URL: $Repository"
    }
    if (-not $uri.Host.Equals('github.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Remote Skills source retrieval currently supports github.com repositories only: $Repository"
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
        $archiveUri = Get-GitHubArchiveUri -Repository ([string]$source.repository) -ResolvedCommit ([string]$source.resolvedCommit)
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{ 'User-Agent'='Codex-Agent-Skills-Bootstrap' } -OutFile $archivePath
        $result[$sourceId] = $archivePath
    }

    return $result
}

Export-ModuleMember -Function Get-GitHubArchiveUri, Get-SkillsSourceArchives
