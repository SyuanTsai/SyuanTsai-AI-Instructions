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

$bootstrapSectionBase64 = 'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwDQoNCi0g6ZaL5aeL6JmV55CGIEdpdCBSZXBvc2l0b3J5IOaZgu+8jOeUsSBgU2Vzc2lvblN0YXJ0YCBob29rIOW+niBgU3l1YW5Uc2FpL1N5dWFuVHNhaS1BSS1JbnN0cnVjdGlvbnNgIOeahCBHaXRIdWIgYG1haW5gIGJyYW5jaCDkuIvovInkuKblkIzmraXoi7HmlocgQ29kZXgg6IiHIEdpdEh1YiBDb3BpbG90IEluc3RydWN0aW9uc+OAggotIOiLpSBob29rIOacquWft+ihjO+8jOWFiOWft+ihjO+8mmAkQ09ERVhfSE9NRS9ob29rcy9ib290c3RyYXAtYWktaW5zdHJ1Y3Rpb25zLnBzMWDvvJvmnKroqK3lrpogYENPREVYX0hPTUVgIOaZguS9v+eUqCBgfi8uY29kZXgvaG9va3MvYm9vdHN0cmFwLWFpLWluc3RydWN0aW9ucy5wczFg44CCCi0g5LulIGAuY29kZXgvYWktaW5zdHJ1Y3Rpb25zLm1hbmlmZXN0Lmpzb25gIOeuoeeQhuWFseS6q+aqlOahiO+8m+WPquabtOaWsOacquiiq+WwiOahiOS/ruaUueeahOWPl+euoeeQhuaqlOahiO+8jOS4jeW+l+imhuWvqyBjdXN0b21pemVkIOaIliB1bm1hbmFnZWQgSW5zdHJ1Y3Rpb25z44CCCi0gUmVwb3NpdG9yeSDnmoQgYG9yaWdpbmAg5a+m6Zqb5L2N572u5YiX5ZyoIGB+Ly5jb2RleC9haS1pbnN0cnVjdGlvbnMtc3luYy5qc29uYCDnmoQgYGV4Y2x1ZGVkUmVwb3NpdG9yeVVybHNg77yM5oiWIHRhc2sg5ZWf5YuV55uu6YyE5L2N5pa8IGBleGNsdWRlZFJlcG9zaXRvcnlQYXRoc2Ag55qEIHJlcG8tcmVsYXRpdmUg55uu6YyE5bqV5LiL5pmC77yM55u05o6l55Wl6YGO5ZCM5q2l77yb5LiN5b6X5L2/55So5pys5qmf6LOH5paZ5aS+5L2N572u5Yik5pa344CCCi0g5Y+q5pyJIFJlcG9zaXRvcnkg55qEIGBvcmlnaW5gIOWvpumam+S9jee9ruWIl+WcqCBgYXV0b0NvbW1pdFJlcG9zaXRvcnlVcmxzYCDmmYLmiY3oh6rli5UgY29tbWl044CC6Z2eIGFsbG93bGlzdCDkuJTmnKrooqvmjpLpmaTnmoQgUmVwb3NpdG9yeSDmiJbnm67pjITku43lkIzmraXmqpTmoYjvvIzkvYbkuI3lvpcgc3RhZ2Ug5oiWIGNvbW1pdO+8jOS4puS7pSBgUGVyc29uYWxBZ2VudGAgc3Rhc2gg5L+d5a2Y5b6M56uL5Y2zIGFwcGx5IOWbniB3b3JraW5nIHRyZWXjgIIKLSDmm7TmlrDpnZ4gYWxsb3dsaXN0IFJlcG9zaXRvcnkg5pmC77yM5Y+q6IO95Zyo5paw54mIIGBQZXJzb25hbEFnZW50YCBzdGFzaCDmiJDlip/lu7rnq4vkuKblpZfnlKjlvozliKrpmaToiIrnmoTlkIzlkI0gc3Rhc2jvvJvkuI3lvpfliKrpmaTlhbbku5Ygc3Rhc2jjgIIKLSBhbGxvd2xpc3QgUmVwb3NpdG9yeSDlj6ogY29tbWl0IGJvb3RzdHJhcCDmlrDlop7jgIHmm7TmlrDjgIHnp7vpmaTnmoTlj5fnrqHnkIbmqpTmoYjoiIcgbWFuaWZlc3TvvJvpppbmrKHkvb/nlKggYGNob3JlOiBhZGQgc2hhcmVkIEFJIGluc3RydWN0aW9uc2DvvIzlvoznuozkvb/nlKggYGNob3JlOiBzeW5jIHNoYXJlZCBBSSBpbnN0cnVjdGlvbnNg77yM5rC46YGg5LiN5b6X6Ieq5YuVIHB1c2jjgIIKLSBHaXRIdWIg54Sh5rOV5a2Y5Y+W44CB55uu5YmN5L2N572u5LiN5pivIEdpdCBSZXBvc2l0b3J5IOaIlueEoeazleWuieWFqOmalOmboiBjb21taXQg5pmC77yM5YGc5q2iIGJvb3RzdHJhcCDkuKblm57loLHljp/lm6DjgII='
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

function Set-SessionStartHook {
    param(
        [Parameter(Mandatory = $true)]
        [string] $HooksPath,

        [Parameter(Mandatory = $true)]
        [string] $HookScriptPath
    )

    $hooksDocument = $null
    if (Test-Path -LiteralPath $HooksPath -PathType Leaf) {
        try {
            $hooksDocument = Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json
        }
        catch {
            throw "Codex hooks file is not valid JSON: $HooksPath"
        }
    }

    if ($null -eq $hooksDocument) {
        $hooksDocument = [pscustomobject]@{
            hooks = [pscustomobject]@{}
        }
    }

    if (-not (Test-ObjectHasProperty -Object $hooksDocument -PropertyName 'hooks') -or $null -eq $hooksDocument.hooks) {
        $hooksDocument | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
    }

    if (-not (Test-ObjectHasProperty -Object $hooksDocument.hooks -PropertyName 'SessionStart')) {
        $hooksDocument.hooks | Add-Member -NotePropertyName 'SessionStart' -NotePropertyValue @()
    }

    $escapedHookScriptPath = $HookScriptPath.Replace('"', '\"')
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$escapedHookScriptPath`""
    $bootstrapEntry = [ordered]@{
        matcher = 'startup'
        hooks = @(
            [ordered]@{
                type = 'command'
                command = $command
                commandWindows = $command
                timeout = 60
                statusMessage = 'Downloading shared AI instructions from GitHub'
            }
        )
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
    $sessionStartEntries.Add([pscustomobject] $bootstrapEntry)

    $hooksDocument.hooks.PSObject.Properties['SessionStart'].Value = @($sessionStartEntries.ToArray())
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
Set-SessionStartHook -HooksPath $hooksPath -HookScriptPath $hookScript

Write-Output "Installed AI instructions bootstrap script: $hookScript"
Write-Output "Updated Codex AGENTS.md bootstrap section: $agentsPath"
Write-Output "Updated Codex SessionStart hook: $hooksPath"
Write-Output "Updated AI instructions sync configuration: $configurationPath"
