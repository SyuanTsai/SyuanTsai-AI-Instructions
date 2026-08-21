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

$bootstrapSection = @'
## Repository Instructions Bootstrap

- 只有新增或更新 production code 的實作計畫時，才執行 `$CODEX_HOME/hooks/bootstrap-ai-instructions.ps1`；單純問問題、釐清需求、確認或解釋問題，以及其他尚未開始規劃 code 的工作不得執行 bootstrap。
- 同步完成後，先讀取 Repository 新增或更新的 `AGENTS.md` 與目前任務適用的規則模組；使用者明確指定 Skill 或任務符合 `.agents/skills/` 中的 Skill description 時，再讀取對應 `SKILL.md`。
- 以 `.codex/ai-instructions.manifest.json` 管理共享 Instructions 與 Agent Skills；只更新未被個人修改的受管理檔案，不覆寫 customized or unmanaged Instructions or Agent Skills。
- Repository 的 origin 若列在 `~/.codex/ai-instructions-sync.json` 的 `excludedRepositoryUrls`，或 task 啟動目錄位於 `excludedRepositoryPaths`，直接略過同步。
- Git ignore 只可越過精確的受管理檔案與 manifest，不得把其他 ignored 內容納入同步或 commit。
- 只有 origin 列在 `autoCommitRepositoryUrls` 時才自動 commit；其他 Repository 只同步，不自動 stage、commit 或 push。
'@
# Keep the installed section byte-stable under Windows PowerShell 5.1, which may decode
# UTF-8 source files without a BOM using the active ANSI code page.
$bootstrapSectionBase64 = 'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquacieaWsOWinuaIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkQ09ERVhfSE9NRS9ob29rcy9ib290c3RyYXAtYWktaW5zdHJ1Y3Rpb25zLnBzMWDvvJvllq7ntJTllY/llY/poYzjgIHph5DmuIXpnIDmsYLjgIHnorroqo3miJbop6Pph4vllY/poYzvvIzku6Xlj4rlhbbku5blsJrmnKrplovlp4vopo/lioMgY29kZSDnmoTlt6XkvZzkuI3lvpfln7fooYwgYm9vdHN0cmFw44CCCi0g5ZCM5q2l5a6M5oiQ5b6M77yM5YWI6K6A5Y+WIFJlcG9zaXRvcnkg5paw5aKe5oiW5pu05paw55qEIGBBR0VOVFMubWRgIOiIh+ebruWJjeS7u+WLmemBqeeUqOeahOimj+WJh+aooee1hO+8m+S9v+eUqOiAheaYjueiuuaMh+WumiBTa2lsbCDmiJbku7vli5nnrKblkIggYC5hZ2VudHMvc2tpbGxzL2Ag5Lit55qEIFNraWxsIGRlc2NyaXB0aW9uIOaZgu+8jOWGjeiugOWPluWwjeaHiSBgU0tJTEwubWRg44CCCi0g5LulIGAuY29kZXgvYWktaW5zdHJ1Y3Rpb25zLm1hbmlmZXN0Lmpzb25gIOeuoeeQhuWFseS6qyBJbnN0cnVjdGlvbnMg6IiHIEFnZW50IFNraWxsc++8m+WPquabtOaWsOacquiiq+WAi+S6uuS/ruaUueeahOWPl+euoeeQhuaqlOahiO+8jOS4jeimhuWvqyBjdXN0b21pemVkIG9yIHVubWFuYWdlZCBJbnN0cnVjdGlvbnMgb3IgQWdlbnQgU2tpbGxz44CCCi0gUmVwb3NpdG9yeSDnmoQgb3JpZ2luIOiLpeWIl+WcqCBgfi8uY29kZXgvYWktaW5zdHJ1Y3Rpb25zLXN5bmMuanNvbmAg55qEIGBleGNsdWRlZFJlcG9zaXRvcnlVcmxzYO+8jOaIliB0YXNrIOWVn+WLleebrumMhOS9jeaWvCBgZXhjbHVkZWRSZXBvc2l0b3J5UGF0aHNg77yM55u05o6l55Wl6YGO5ZCM5q2l44CCCi0gR2l0IGlnbm9yZSDlj6rlj6/otorpgY7nsr7norrnmoTlj5fnrqHnkIbmqpTmoYjoiIcgbWFuaWZlc3TvvIzkuI3lvpfmiorlhbbku5YgaWdub3JlZCDlhaflrrnntI3lhaXlkIzmraXmiJYgY29tbWl044CCCi0g5Y+q5pyJIG9yaWdpbiDliJflnKggYGF1dG9Db21taXRSZXBvc2l0b3J5VXJsc2Ag5pmC5omN6Ieq5YuVIGNvbW1pdO+8m+WFtuS7liBSZXBvc2l0b3J5IOWPquWQjOatpe+8jOS4jeiHquWLlSBzdGFnZeOAgWNvbW1pdCDmiJYgcHVzaOOAggo='
$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bootstrapSectionBase64))

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]] $Arguments
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
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-IsRepositoryUrl {
    param([Parameter(Mandatory = $true)][string] $Value)

    $trimmedValue = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) { return $false }

    $absoluteUri = $null
    if ([System.Uri]::TryCreate($trimmedValue, [System.UriKind]::Absolute, [ref]$absoluteUri) -and
        -not [string]::IsNullOrWhiteSpace($absoluteUri.Host)) {
        return $absoluteUri.Scheme -in @('https','http','ssh','git')
    }
    return $trimmedValue -match '^(?:[^@/\\]+@)?[^:/\\]+:.+'
}

function Test-IsRepositoryRelativePath {
    param([Parameter(Mandatory = $true)][string] $Value)

    $trimmedValue = $Value.Trim().Replace('\','/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Value) -or $trimmedValue -match '^[A-Za-z]:') { return $false }
    foreach ($part in @($trimmedValue -split '/+')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') { return $false }
    }
    return $true
}

function Test-ObjectHasProperty {
    param(
        [AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $PropertyName
    )
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$PropertyName]
}

function Get-StringArrayProperty {
    param(
        [AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $PropertyName
    )

    if (-not (Test-ObjectHasProperty -Object $Object -PropertyName $PropertyName)) { return @() }
    return @($Object.$PropertyName | ForEach-Object { if ($null -ne $_) { [string]$_ } })
}

function Set-BootstrapSection {
    param(
        [Parameter(Mandatory = $true)][string] $AgentsPath,
        [Parameter(Mandatory = $true)][string] $Section
    )

    $normalizedSection = $Section.Trim() + "`n"
    $content = if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($AgentsPath).Replace("`r`n","`n").Replace("`r","`n")
    }
    else { '' }

    $pattern = '(?ms)^## Repository Instructions Bootstrap\s*\n.*?(?=^##\s|\z)'
    if ([regex]::IsMatch($content, $pattern)) {
        $updatedContent = [regex]::Replace($content, $pattern, $normalizedSection)
    }
    elseif ([string]::IsNullOrWhiteSpace($content)) {
        $updatedContent = $normalizedSection
    }
    else {
        $updatedContent = $content.TrimEnd() + "`n`n" + $normalizedSection
    }
    Write-Utf8NoBomFile -Path $AgentsPath -Content $updatedContent
}

function Get-CanonicalGitHubRepositoryUrl {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)

    $value = $RepositoryUrl.Trim()
    if ($value -match '^(?:https|ssh|git)://(?:[^@/]+@)?github\.com/(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?/?$') {
        return "https://github.com/$($Matches.Owner)/$($Matches.Repository).git"
    }
    if ($value -match '^(?:[^@/]+@)?github\.com:(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?$') {
        return "https://github.com/$($Matches.Owner)/$($Matches.Repository).git"
    }
    throw "The installer repository origin must be hosted on GitHub: $RepositoryUrl"
}

function Get-GitHubRepositoryIdentity {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)

    try {
        return (Get-CanonicalGitHubRepositoryUrl -RepositoryUrl $RepositoryUrl).ToLowerInvariant()
    }
    catch {
        return $null
    }
}

function Assert-StableSelectionArray {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [System.Array]) { throw "$Context must be an array." }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]$item -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "$Context contains an invalid ID."
        }
        if (-not $set.Add([string]$item)) { throw "$Context contains a duplicate ID." }
    }
    return $set
}

function Set-SyncConfiguration {
    param(
        [Parameter(Mandatory = $true)][string] $ConfigurationPath,
        [string[]] $AdditionalRepositoryUrls = @(),
        [string[]] $AdditionalExcludedRepositoryUrls = @(),
        [string[]] $AdditionalExcludedRepositoryPaths = @(),
        [Parameter(Mandatory = $true)][string] $CatalogRepository,
        [Parameter(Mandatory = $true)][string] $CatalogRef
    )

    $existingConfiguration = $null
    if (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf) {
        try { $existingConfiguration = Get-Content -Raw -LiteralPath $ConfigurationPath | ConvertFrom-Json }
        catch { throw "AI instruction sync configuration is not valid JSON: $ConfigurationPath" }
    }

    $existingSchemaVersion = if ($null -eq $existingConfiguration) {
        $null
    }
    elseif (Test-ObjectHasProperty -Object $existingConfiguration -PropertyName 'schemaVersion') {
        [int]$existingConfiguration.schemaVersion
    }
    else {
        throw "AI instruction sync configuration is missing schemaVersion: $ConfigurationPath"
    }
    if ($null -ne $existingSchemaVersion -and $existingSchemaVersion -notin @(1,2,3)) {
        throw "Unsupported AI instruction sync configuration schemaVersion '$existingSchemaVersion': $ConfigurationPath"
    }

    $candidateUrls = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('autoCommitRepositoryUrls','allowedRepositoryUrls','repositoryUrls','autoCommitRepositories')) {
        foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) { $candidateUrls.Add($value) }
    }
    foreach ($value in @($AdditionalRepositoryUrls)) { $candidateUrls.Add([string]$value) }

    $candidateExcludedUrls = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('excludedRepositoryUrls','excludedRepositories')) {
        foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) { $candidateExcludedUrls.Add($value) }
    }
    foreach ($value in @($AdditionalExcludedRepositoryUrls)) { $candidateExcludedUrls.Add([string]$value) }

    $candidateExcludedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('excludedRepositoryPaths','excludedPaths')) {
        foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) { $candidateExcludedPaths.Add($value) }
    }
    foreach ($value in @($AdditionalExcludedRepositoryPaths)) { $candidateExcludedPaths.Add([string]$value) }

    $repositoryUrls = @($candidateUrls | Where-Object { Test-IsRepositoryUrl ([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
    $excludedRepositoryUrls = @($candidateExcludedUrls | Where-Object { Test-IsRepositoryUrl ([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
    $excludedRepositoryPaths = @($candidateExcludedPaths | Where-Object { Test-IsRepositoryRelativePath ([string]$_) } | ForEach-Object { ([string]$_).Trim().Replace('\','/').Trim('/') } | Sort-Object -Unique)

    $catalogSelection = if ($existingSchemaVersion -eq 3) {
        if (-not (Test-ObjectHasProperty -Object $existingConfiguration -PropertyName 'catalog')) {
            throw "AI instruction sync configuration schemaVersion 3 is missing catalog: $ConfigurationPath"
        }
        foreach ($propertyName in @('repository','ref','profiles','includeSkills','excludeSkills')) {
            if (-not (Test-ObjectHasProperty -Object $existingConfiguration.catalog -PropertyName $propertyName)) {
                throw "AI instruction sync configuration catalog is missing '$propertyName': $ConfigurationPath"
            }
        }

        $catalogRepositoryUri = $null
        if (-not [System.Uri]::TryCreate([string]$existingConfiguration.catalog.repository, [System.UriKind]::Absolute, [ref]$catalogRepositoryUri) -or
            $catalogRepositoryUri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($catalogRepositoryUri.Host)) {
            throw "AI instruction sync configuration catalog.repository must be an absolute HTTPS URL: $ConfigurationPath"
        }
        if ([string]$existingConfiguration.catalog.ref -cnotmatch '^[0-9a-f]{40}$') {
            throw "AI instruction sync configuration catalog.ref must be a full lowercase 40-character commit SHA: $ConfigurationPath"
        }

        $profileSet = Assert-StableSelectionArray -Value $existingConfiguration.catalog.profiles -Context 'AI instruction sync configuration catalog.profiles'
        $includeSet = Assert-StableSelectionArray -Value $existingConfiguration.catalog.includeSkills -Context 'AI instruction sync configuration catalog.includeSkills'
        $excludeSet = Assert-StableSelectionArray -Value $existingConfiguration.catalog.excludeSkills -Context 'AI instruction sync configuration catalog.excludeSkills'
        foreach ($skillId in $includeSet) {
            if ($excludeSet.Contains($skillId)) {
                throw "AI instruction sync configuration includes and excludes the same Skill '$skillId': $ConfigurationPath"
            }
        }

        $existingIdentity = Get-GitHubRepositoryIdentity -RepositoryUrl ([string]$existingConfiguration.catalog.repository)
        $installedIdentity = Get-GitHubRepositoryIdentity -RepositoryUrl $CatalogRepository
        $sameInstalledCatalog = $null -ne $existingIdentity -and $existingIdentity -ceq $installedIdentity

        [ordered]@{
            # When reinstalling/upgrading this same AI-Instructions source, runtime, Catalog, Lock,
            # and instruction commit must advance as one version. Preserve only user selection.
            repository = if ($sameInstalledCatalog) { $CatalogRepository } else { [string]$existingConfiguration.catalog.repository }
            ref = if ($sameInstalledCatalog) { $CatalogRef } else { [string]$existingConfiguration.catalog.ref }
            profiles = @(Get-StringArrayProperty -Object $existingConfiguration.catalog -PropertyName 'profiles')
            includeSkills = @(Get-StringArrayProperty -Object $existingConfiguration.catalog -PropertyName 'includeSkills')
            excludeSkills = @(Get-StringArrayProperty -Object $existingConfiguration.catalog -PropertyName 'excludeSkills')
        }
    }
    else {
        [ordered]@{
            repository = $CatalogRepository
            ref = $CatalogRef
            profiles = @('core')
            includeSkills = @()
            excludeSkills = @()
        }
    }

    $configuration = [ordered]@{
        schemaVersion = 3
        autoCommitRepositoryUrls = @($repositoryUrls)
        excludedRepositoryUrls = @($excludedRepositoryUrls)
        excludedRepositoryPaths = @($excludedRepositoryPaths)
        catalog = $catalogSelection
    }
    $configurationJson = ($configuration | ConvertTo-Json -Depth 8).Replace("`r`n","`n") + "`n"
    Write-Utf8NoBomFile -Path $ConfigurationPath -Content $configurationJson
    Get-Content -Raw -LiteralPath $ConfigurationPath | ConvertFrom-Json | Out-Null
}

function Remove-BootstrapSessionStartHook {
    param([Parameter(Mandatory = $true)][string] $HooksPath)

    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return }
    try { $hooksDocument = Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json }
    catch { throw "Codex hooks file is not valid JSON: $HooksPath" }

    if (-not (Test-ObjectHasProperty -Object $hooksDocument -PropertyName 'hooks') -or
        $null -eq $hooksDocument.hooks -or
        -not (Test-ObjectHasProperty -Object $hooksDocument.hooks -PropertyName 'SessionStart')) { return }

    $sessionStartEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($hooksDocument.hooks.SessionStart)) {
        if ($null -eq $entry) { continue }
        if (-not (Test-ObjectHasProperty -Object $entry -PropertyName 'hooks')) {
            $sessionStartEntries.Add($entry)
            continue
        }

        $containsBootstrapCommand = $false
        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) { continue }
            foreach ($propertyName in @('command','commandWindows')) {
                if ((Test-ObjectHasProperty -Object $hook -PropertyName $propertyName) -and
                    [string]$hook.$propertyName -match 'bootstrap-ai-instructions\.ps1') {
                    $containsBootstrapCommand = $true
                }
            }
        }
        if (-not $containsBootstrapCommand) { $sessionStartEntries.Add($entry) }
    }

    if ($sessionStartEntries.Count -eq 0) {
        $hooksDocument.hooks.PSObject.Properties.Remove('SessionStart')
    }
    else {
        $hooksDocument.hooks.PSObject.Properties['SessionStart'].Value = @($sessionStartEntries.ToArray())
    }

    Write-Utf8NoBomFile -Path $HooksPath -Content (($hooksDocument | ConvertTo-Json -Depth 12).Replace("`r`n","`n") + "`n")
    Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json | Out-Null
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = ((Invoke-Git -WorkingDirectory (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
}
$repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\','/'))
$originUrl = ((Invoke-Git -WorkingDirectory $repositoryRootPath -Arguments @('remote','get-url','origin')) | Select-Object -First 1).Trim()
$catalogRepository = Get-CanonicalGitHubRepositoryUrl -RepositoryUrl $originUrl
$catalogRef = ((Invoke-Git -WorkingDirectory $repositoryRootPath -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
if ($catalogRef -cnotmatch '^[0-9a-f]{40}$') { throw "Installer repository HEAD is not a full lowercase commit SHA: $catalogRef" }

$sourceLauncher = Join-Path $repositoryRootPath 'scripts\bootstrap-ai-instructions-installed.ps1'
$runtimeFiles = @(
    'bootstrap-ai-instructions-multisource.ps1',
    'bootstrap-ai-instructions.ps1',
    'safe-zip.psm1',
    'skills-catalog-contract.psm1',
    'skills-selection.psm1',
    'skills-source-routing.psm1',
    'skills-source-retrieval.psm1',
    'skills-source-acquisition.psm1',
    'skills-source-composition.psm1'
)
$requiredSourcePaths = @($sourceLauncher)
foreach ($fileName in $runtimeFiles) { $requiredSourcePaths += Join-Path $repositoryRootPath "scripts\$fileName" }
$requiredSourcePaths += Join-Path $repositoryRootPath 'catalog\skills-catalog.json'
$requiredSourcePaths += Join-Path $repositoryRootPath 'catalog\skills-catalog-lock.json'
foreach ($sourcePath in $requiredSourcePaths) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Installer runtime source was not found: $sourcePath" }
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\','/'))
$hookDirectory = Join-Path $codexHomePath 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'
$runtimeDirectory = Join-Path $hookDirectory 'ai-instructions-runtime'
$agentsPath = Join-Path $codexHomePath 'AGENTS.md'
$hooksPath = Join-Path $codexHomePath 'hooks.json'
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'

# Configuration pin and copied runtime are derived from the same checkout in this invocation.
Set-SyncConfiguration -ConfigurationPath $configurationPath `
    -AdditionalRepositoryUrls $AutoCommitRepositoryUrls `
    -AdditionalExcludedRepositoryUrls $ExcludedRepositoryUrls `
    -AdditionalExcludedRepositoryPaths $ExcludedRepositoryPaths `
    -CatalogRepository $catalogRepository `
    -CatalogRef $catalogRef

New-Item -ItemType Directory -Force -Path $hookDirectory, $runtimeDirectory, (Join-Path $runtimeDirectory 'catalog') | Out-Null
Copy-Item -LiteralPath $sourceLauncher -Destination $hookScript -Force
foreach ($fileName in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $repositoryRootPath "scripts\$fileName") -Destination (Join-Path $runtimeDirectory $fileName) -Force
}
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog.json') -Destination (Join-Path $runtimeDirectory 'catalog\skills-catalog.json') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog-lock.json') -Destination (Join-Path $runtimeDirectory 'catalog\skills-catalog-lock.json') -Force
Set-BootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
Remove-BootstrapSessionStartHook -HooksPath $hooksPath

Write-Output "Installed AI instructions bootstrap script: $hookScript"
Write-Output "Updated Codex AGENTS.md bootstrap section: $agentsPath"
Write-Output "Removed legacy AI instructions bootstrap SessionStart hook when present: $hooksPath"
Write-Output "Updated AI instructions sync configuration: $configurationPath"
