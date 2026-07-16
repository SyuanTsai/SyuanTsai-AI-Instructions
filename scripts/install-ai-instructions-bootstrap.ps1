[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $CodexHome,
    [string[]] $AutoCommitRepositoryUrls = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapSectionBase64 = 'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOmWi+Wni+iZleeQhiBHaXQgUmVwb3NpdG9yeSDmmYLvvIznlLEgYFNlc3Npb25TdGFydGAgaG9vayDlvp4gYFN5dWFuVHNhaS9TeXVhblRzYWktQUktSW5zdHJ1Y3Rpb25zYCDnmoQgR2l0SHViIGBtYWluYCBicmFuY2gg5LiL6LyJ5Lim5ZCM5q2l6Iux5paHIENvZGV4IOiIhyBHaXRIdWIgQ29waWxvdCBJbnN0cnVjdGlvbnPjgIIKLSDoi6UgaG9vayDmnKrln7fooYzvvIzlhYjln7fooYzvvJpgJENPREVYX0hPTUUvaG9va3MvYm9vdHN0cmFwLWFpLWluc3RydWN0aW9ucy5wczFg77yb5pyq6Kit5a6aIGBDT0RFWF9IT01FYCDmmYLkvb/nlKggYH4vLmNvZGV4L2hvb2tzL2Jvb3RzdHJhcC1haS1pbnN0cnVjdGlvbnMucHMxYOOAggotIOS7pSBgLmNvZGV4L2FpLWluc3RydWN0aW9ucy5tYW5pZmVzdC5qc29uYCDnrqHnkIblhbHkuqvmqpTmoYjvvJvlj6rmm7TmlrDmnKrooqvlsIjmoYjkv67mlLnnmoTlj5fnrqHnkIbmqpTmoYjvvIzkuI3lvpfopoblr6sgY3VzdG9taXplZCDmiJYgdW5tYW5hZ2VkIEluc3RydWN0aW9uc+OAggotIOWPquaciSBSZXBvc2l0b3J5IOeahCBgb3JpZ2luYCDlr6bpmpvkvY3nva7liJflnKggYH4vLmNvZGV4L2FpLWluc3RydWN0aW9ucy1zeW5jLmpzb25gIOeahCBgYXV0b0NvbW1pdFJlcG9zaXRvcnlVcmxzYCDmmYLmiY3oh6rli5UgY29tbWl077yb5LiN5b6X5L2/55So5pys5qmf6LOH5paZ5aS+5L2N572u5Yik5pa344CC6Z2eIGFsbG93bGlzdCBSZXBvc2l0b3J5IOS7jeWQjOatpeaqlOahiO+8jOS9huS4jeW+lyBzdGFnZSDmiJYgY29tbWl077yM5Lim5LulIGBQZXJzb25hbEFnZW50YCBzdGFzaCDkv53lrZjlvoznq4vljbMgYXBwbHkg5ZueIHdvcmtpbmcgdHJlZeOAggotIOabtOaWsOmdniBhbGxvd2xpc3QgUmVwb3NpdG9yeSDmmYLvvIzlj6rog73lnKjmlrDniYggYFBlcnNvbmFsQWdlbnRgIHN0YXNoIOaIkOWKn+W7uueri+S4puWll+eUqOW+jOWIqumZpOiIiueahOWQjOWQjSBzdGFzaO+8m+S4jeW+l+WIqumZpOWFtuS7liBzdGFzaOOAggotIGFsbG93bGlzdCBSZXBvc2l0b3J5IOWPqiBjb21taXQgYm9vdHN0cmFwIOaWsOWinuOAgeabtOaWsOOAgeenu+mZpOeahOWPl+euoeeQhuaqlOahiOiIhyBtYW5pZmVzdO+8m+mmluasoeS9v+eUqCBgY2hvcmU6IGFkZCBzaGFyZWQgQUkgaW5zdHJ1Y3Rpb25zYO+8jOW+jOe6jOS9v+eUqCBgY2hvcmU6IHN5bmMgc2hhcmVkIEFJIGluc3RydWN0aW9uc2DvvIzmsLjpgaDkuI3lvpfoh6rli5UgcHVzaOOAggotIEdpdEh1YiDnhKHms5XlrZjlj5bjgIHnm67liY3kvY3nva7kuI3mmK8gR2l0IFJlcG9zaXRvcnkg5oiW54Sh5rOV5a6J5YWo6ZqU6ZuiIGNvbW1pdCDmmYLvvIzlgZzmraIgYm9vdHN0cmFwIOS4puWbnuWgseWOn+WboOOAgg=='
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

        [string[]] $AdditionalRepositoryUrls = @()
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

    $repositoryUrls = @(
        $candidateUrls |
            Where-Object { Test-IsRepositoryUrl -Value ([string] $_) } |
            ForEach-Object { ([string] $_).Trim() } |
            Sort-Object -Unique
    )

    $configuration = [ordered]@{
        schemaVersion = 2
        autoCommitRepositoryUrls = @($repositoryUrls)
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

Set-SyncConfiguration -ConfigurationPath $configurationPath -AdditionalRepositoryUrls $AutoCommitRepositoryUrls
Set-BootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
Set-SessionStartHook -HooksPath $hooksPath -HookScriptPath $hookScript

Write-Output "Installed AI instructions bootstrap script: $hookScript"
Write-Output "Updated Codex AGENTS.md bootstrap section: $agentsPath"
Write-Output "Updated Codex SessionStart hook: $hooksPath"
Write-Output "Updated AI instructions sync configuration: $configurationPath"
