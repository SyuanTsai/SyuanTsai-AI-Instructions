[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $CodexHome,
    [string[]] $AutoCommitRepositoryUrls = @(),
    [string[]] $ExcludedRepositoryUrls = @(),
    [string[]] $ExcludedRepositoryPaths = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapSectionBase64 = 'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquaciea6luWCmeW7uueri+aIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkQ09ERVhfSE9NRS9ob29rcy9ib290c3RyYXAtYWktaW5zdHJ1Y3Rpb25zLnBzMWDvvJvmnKroqK3lrpogYENPREVYX0hPTUVgIOaZguS9v+eUqCBgfi8uY29kZXgvaG9va3MvYm9vdHN0cmFwLWFpLWluc3RydWN0aW9ucy5wczFg44CCCi0g5Zau57SU5ZWP5ZWP6aGM44CB6YeQ5riF6ZyA5rGC44CB56K66KqN5oiW6Kej6YeL5ZWP6aGM77yM5Lul5Y+K5YW25LuW5bCa5pyq6ZaL5aeL6KaP5YqDIGNvZGUg55qE5bel5L2c77yM5LiN5b6X5Z+36KGMIGJvb3RzdHJhcO+8jOS5n+S4jeW+l+WDheeCuumAmeS6m+W3peS9nOWwh+WFseS6qyBJbnN0cnVjdGlvbnMg5oiWIG1hbmlmZXN0IOWKoOWFpSBSZXBvc2l0b3J544CCCi0g5ZCM5q2l5a6M5oiQ5b6M77yM5YWI6K6A5Y+WIFJlcG9zaXRvcnkg5paw5aKe5oiW5pu05paw55qEIGBBR0VOVFMubWRgIOiIh+ebruWJjeS7u+WLmemBqeeUqOeahOimj+WJh+aooee1hO+8jOWGjeaPkOWHuuWvpuS9nOioiOeVq+OAggotIOS7pSBgLmNvZGV4L2FpLWluc3RydWN0aW9ucy5tYW5pZmVzdC5qc29uYCDnrqHnkIblhbHkuqvmqpTmoYjvvJvlj6rmm7TmlrDmnKrooqvlsIjmoYjkv67mlLnnmoTlj5fnrqHnkIbmqpTmoYjvvIzkuI3lvpfopoblr6sgY3VzdG9taXplZCDmiJYgdW5tYW5hZ2VkIEluc3RydWN0aW9uc+OAggotIFJlcG9zaXRvcnkg55qEIGBvcmlnaW5gIOWvpumam+S9jee9ruWIl+WcqCBgfi8uY29kZXgvYWktaW5zdHJ1Y3Rpb25zLXN5bmMuanNvbmAg55qEIGBleGNsdWRlZFJlcG9zaXRvcnlVcmxzYO+8jOaIliB0YXNrIOWVn+WLleebrumMhOS9jeaWvCBgZXhjbHVkZWRSZXBvc2l0b3J5UGF0aHNgIOeahCByZXBvLXJlbGF0aXZlIOebrumMhOW6leS4i+aZgu+8jOebtOaOpeeVpemBjuWQjOatpe+8m+S4jeW+l+S9v+eUqOacrOapn+izh+aWmeWkvuS9jee9ruWIpOaWt+OAggotIOWPquaciSBSZXBvc2l0b3J5IOeahCBgb3JpZ2luYCDlr6bpmpvkvY3nva7liJflnKggYGF1dG9Db21taXRSZXBvc2l0b3J5VXJsc2Ag5pmC5omN6Ieq5YuVIGNvbW1pdOOAgumdniBhbGxvd2xpc3Qg5LiU5pyq6KKr5o6S6Zmk55qEIFJlcG9zaXRvcnkg5oiW55uu6YyE5LuN5ZCM5q2l5qqU5qGI77yM5L2G5LiN5b6XIHN0YWdlIOaIliBjb21taXTvvIzkuKbku6UgYFBlcnNvbmFsQWdlbnRgIHN0YXNoIOS/neWtmOW+jOeri+WNsyBhcHBseSDlm54gd29ya2luZyB0cmVl44CCCi0g5pu05paw6Z2eIGFsbG93bGlzdCBSZXBvc2l0b3J5IOaZgu+8jOWPquiDveWcqOaWsOeJiCBgUGVyc29uYWxBZ2VudGAgc3Rhc2gg5oiQ5Yqf5bu656uL5Lim5aWX55So5b6M5Yiq6Zmk6IiK55qE5ZCM5ZCNIHN0YXNo77yb5LiN5b6X5Yiq6Zmk5YW25LuWIHN0YXNo44CCCi0gYWxsb3dsaXN0IFJlcG9zaXRvcnkg5Y+qIGNvbW1pdCBib290c3RyYXAg5paw5aKe44CB5pu05paw44CB56e76Zmk55qE5Y+X566h55CG5qqU5qGI6IiHIG1hbmlmZXN077yb6aaW5qyh5L2/55SoIGBjaG9yZTogYWRkIHNoYXJlZCBBSSBpbnN0cnVjdGlvbnNg77yM5b6M57qM5L2/55SoIGBjaG9yZTogc3luYyBzaGFyZWQgQUkgaW5zdHJ1Y3Rpb25zYO+8jOawuOmBoOS4jeW+l+iHquWLlSBwdXNo44CCCi0gR2l0SHViIOeEoeazleWtmOWPluOAgeebruWJjeS9jee9ruS4jeaYryBHaXQgUmVwb3NpdG9yeSDmiJbnhKHms5XlronlhajpmpTpm6IgY29tbWl0IOaZgu+8jOWBnOatoiBib290c3RyYXAg5Lim5Zue5aCx5Y6f5Zug44CC'
$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bootstrapSectionBase64))

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $WorkingDirectory @Arguments 2>&1
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

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8WithoutBom)
}

function Test-IsRepositoryUrl {
    param([Parameter(Mandatory = $true)][string] $Value)

    $trimmedValue = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
        return $false
    }

    $absoluteUri = $null
    if ([System.Uri]::TryCreate($trimmedValue, [System.UriKind]::Absolute, [ref] $absoluteUri) -and
        -not [string]::IsNullOrWhiteSpace($absoluteUri.Host)) {
        return $absoluteUri.Scheme -in @('https', 'http', 'ssh', 'git')
    }

    return $trimmedValue -match '^(?:[^@/\\]+@)?[^:/\\]+:.+'
}

function Test-IsRepositoryRelativePath {
    param([Parameter(Mandatory = $true)][string] $Value)

    $trimmedValue = $Value.Trim().Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
        return $false
    }

    if ([System.IO.Path]::IsPathRooted($Value) -or $trimmedValue -match '^[A-Za-z]:') {
        return $false
    }

    foreach ($part in @($trimmedValue -split '/+')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') {
            return $false
        }
    }

    return $true
}

function Test-ObjectHasProperty {
    param(
        [AllowNull()]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $PropertyName
    )

    if ($null -eq $Object) {
        return $false
    }

    return $null -ne $Object.PSObject.Properties[$PropertyName]
}

function Get-StringArrayProperty {
    param(
        [AllowNull()]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $PropertyName
    )

    if (-not (Test-ObjectHasProperty -Object $Object -PropertyName $PropertyName)) {
        return @()
    }

    return @($Object.$PropertyName | ForEach-Object {
        if ($null -ne $_) {
            [string] $_
        }
    })
}

function Set-BootstrapSection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AgentsPath,

        [Parameter(Mandatory = $true)]
        [string] $Section
    )

    $normalizedSection = $Section.Trim() + "`n"
    $content = if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($AgentsPath).Replace("`r`n", "`n").Replace("`r", "`n")
    }
    else {
        ''
    }

    $pattern = '(?ms)^## Repository Instructions Bootstrap\s*\n.*?(?=^##\s|\z)'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($content, $pattern)) {
        $updatedContent = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, $normalizedSection)
    }
    elseif ([string]::IsNullOrWhiteSpace($content)) {
        $updatedContent = $normalizedSection
    }
    else {
        $updatedContent = $content.TrimEnd() + "`n`n" + $normalizedSection
    }

    Write-Utf8NoBomFile -Path $AgentsPath -Content $updatedContent
}

function Set-SyncConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigurationPath,

        [string[]] $AdditionalRepositoryUrls = @(),

        [string[]] $AdditionalExcludedRepositoryUrls = @(),

        [string[]] $AdditionalExcludedRepositoryPaths = @()
    )

    $existingConfiguration = $null
    if (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf) {
        try {
            $existingConfiguration = Get-Content -Raw -LiteralPath $ConfigurationPath | ConvertFrom-Json
        }
        catch {
            throw "AI instruction sync configuration is not valid JSON: $ConfigurationPath"
        }
    }

    $candidateUrls = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('autoCommitRepositoryUrls', 'allowedRepositoryUrls', 'repositoryUrls', 'autoCommitRepositories')) {
        foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) {
            $candidateUrls.Add($value)
        }
    }

    foreach ($value in @($AdditionalRepositoryUrls)) {
        $candidateUrls.Add([string] $value)
    }

    $candidateExcludedUrls = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('excludedRepositoryUrls', 'excludedRepositories')) {
        foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) {
            $candidateExcludedUrls.Add($value)
        }
    }

    foreach ($value in @($AdditionalExcludedRepositoryUrls)) {
        $candidateExcludedUrls.Add([string] $value)
    }

    $candidateExcludedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('excludedRepositoryPaths', 'excludedPaths')) {
        foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) {
            $candidateExcludedPaths.Add($value)
        }
    }

    foreach ($value in @($AdditionalExcludedRepositoryPaths)) {
        $candidateExcludedPaths.Add([string] $value)
    }

    $repositoryUrls = @(
        $candidateUrls |
            Where-Object { Test-IsRepositoryUrl -Value ([string] $_) } |
            ForEach-Object { ([string] $_).Trim() } |
            Sort-Object -Unique
    )

    $excludedRepositoryUrls = @(
        $candidateExcludedUrls |
            Where-Object { Test-IsRepositoryUrl -Value ([string] $_) } |
            ForEach-Object { ([string] $_).Trim() } |
            Sort-Object -Unique
    )

    $excludedRepositoryPaths = @(
        $candidateExcludedPaths |
            Where-Object { Test-IsRepositoryRelativePath -Value ([string] $_) } |
            ForEach-Object { ([string] $_).Trim().Replace('\', '/').Trim('/') } |
            Sort-Object -Unique
    )

    $configuration = [ordered]@{
        schemaVersion = 2
        autoCommitRepositoryUrls = @($repositoryUrls)
        excludedRepositoryUrls = @($excludedRepositoryUrls)
        excludedRepositoryPaths = @($excludedRepositoryPaths)
    }
    $configurationJson = ($configuration | ConvertTo-Json -Depth 4).Replace("`r`n", "`n") + "`n"
    Write-Utf8NoBomFile -Path $ConfigurationPath -Content $configurationJson

    Get-Content -Raw -LiteralPath $ConfigurationPath | ConvertFrom-Json | Out-Null
}

function Remove-BootstrapSessionStartHook {
    param(
        [Parameter(Mandatory = $true)]
        [string] $HooksPath
    )

    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) {
        return
    }

    try {
        $hooksDocument = Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json
    }
    catch {
        throw "Codex hooks file is not valid JSON: $HooksPath"
    }

    if (-not (Test-ObjectHasProperty -Object $hooksDocument -PropertyName 'hooks') -or
        $null -eq $hooksDocument.hooks -or
        -not (Test-ObjectHasProperty -Object $hooksDocument.hooks -PropertyName 'SessionStart')) {
        return
    }

    $sessionStartEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($hooksDocument.hooks.SessionStart)) {
        if ($null -eq $entry) {
            continue
        }

        if (-not (Test-ObjectHasProperty -Object $entry -PropertyName 'hooks')) {
            $sessionStartEntries.Add($entry)
            continue
        }

        $containsBootstrapCommand = $false
        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) {
                continue
            }

            foreach ($propertyName in @('command', 'commandWindows')) {
                if ((Test-ObjectHasProperty -Object $hook -PropertyName $propertyName) -and
                    [string] $hook.$propertyName -match 'bootstrap-ai-instructions\.ps1') {
                    $containsBootstrapCommand = $true
                }
            }
        }

        if (-not $containsBootstrapCommand) {
            $sessionStartEntries.Add($entry)
        }
    }

    if ($sessionStartEntries.Count -eq 0) {
        $hooksDocument.hooks.PSObject.Properties.Remove('SessionStart')
    }
    else {
        $hooksDocument.hooks.PSObject.Properties['SessionStart'].Value = @($sessionStartEntries.ToArray())
    }

    $hooksJson = ($hooksDocument | ConvertTo-Json -Depth 12).Replace("`r`n", "`n") + "`n"
    Write-Utf8NoBomFile -Path $HooksPath -Content $hooksJson

    Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json | Out-Null
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $resolvedRoot = Invoke-Git -WorkingDirectory (Get-Location).Path -Arguments @('rev-parse', '--show-toplevel')
    $RepositoryRoot = ($resolvedRoot | Select-Object -First 1).Trim()
}

$repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\', '/'))
$sourceBootstrapScript = Join-Path $repositoryRootPath 'scripts\bootstrap-ai-instructions.ps1'
if (-not (Test-Path -LiteralPath $sourceBootstrapScript -PathType Leaf)) {
    throw "Bootstrap script was not found: $sourceBootstrapScript"
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path $HOME '.codex'
    }
}

$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\', '/'))
$hookDirectory = Join-Path $codexHomePath 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'
$agentsPath = Join-Path $codexHomePath 'AGENTS.md'
$hooksPath = Join-Path $codexHomePath 'hooks.json'
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'

New-Item -ItemType Directory -Force -Path $hookDirectory | Out-Null
Copy-Item -LiteralPath $sourceBootstrapScript -Destination $hookScript -Force

Set-SyncConfiguration -ConfigurationPath $configurationPath `
    -AdditionalRepositoryUrls $AutoCommitRepositoryUrls `
    -AdditionalExcludedRepositoryUrls $ExcludedRepositoryUrls `
    -AdditionalExcludedRepositoryPaths $ExcludedRepositoryPaths
Set-BootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
Remove-BootstrapSessionStartHook -HooksPath $hooksPath

Write-Output "Installed AI instructions bootstrap script: $hookScript"
Write-Output "Updated Codex AGENTS.md bootstrap section: $agentsPath"
Write-Output "Removed legacy AI instructions bootstrap SessionStart hook when present: $hooksPath"
Write-Output "Updated AI instructions sync configuration: $configurationPath"
