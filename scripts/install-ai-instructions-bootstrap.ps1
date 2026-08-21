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

$bootstrapSectionBase64 = 'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquacieaWsOWinuaIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkQ09ERVhfSE9NRS9ob29rcy9ib290c3RyYXAtYWktaW5zdHJ1Y3Rpb25zLnBzMWDvvJvllq7ntJTllY/llY/poYzjgIHph5DmuIXpnIDmsYLjgIHnorroqo3miJbop6Pph4vllY/poYzvvIzku6Xlj4rlhbbku5blsJrmnKrplovlp4vopo/lioMgY29kZSDnmoTlt6XkvZzkuI3lvpfln7fooYwgYm9vdHN0cmFw44CCCi0g5ZCM5q2l5a6M5oiQ5b6M77yM5YWI6K6A5Y+WIFJlcG9zaXRvcnkg5paw5aKe5oiW5pu05paw55qEIGBBR0VOVFMubWRgIOiIh+ebruWJjeS7u+WLmemBqeeUqOeahOimj+WJh+aooee1hO+8m+S9v+eUqOiAheaYjueiuuaMh+WumiBTa2lsbCDmiJbku7vli5nnrKblkIggYC5hZ2VudHMvc2tpbGxzL2Ag5Lit55qEIFNraWxsIGRlc2NyaXB0aW9uIOaZgu+8jOWGjeiugOWPluWwjeaHiSBgU0tJTEwubWRg44CCCi0g5LulIGAuY29kZXgvYWktaW5zdHJ1Y3Rpb25zLm1hbmlmZXN0Lmpzb25gIOeuoeeQhuWFseS6qyBJbnN0cnVjdGlvbnMg6IiHIEFnZW50IFNraWxsc++8m+WPquabtOaWsOacquiiq+WAi+S6uuS/ruaUueeahOWPl+euoeeQhuaqlOahiO+8jOS4jeimhuWvqyBjdXN0b21pemVkIG9yIHVubWFuYWdlZCBJbnN0cnVjdGlvbnMgb3IgQWdlbnQgU2tpbGxz44CCCi0gUmVwb3NpdG9yeSDnmoQgb3JpZ2luIOiLpeWIl+WcqCBgfi8uY29kZXgvYWktaW5zdHJ1Y3Rpb25zLXN5bmMuanNvbmAg55qEIGBleGNsdWRlZFJlcG9zaXRvcnlVcmxzYO+8jOaIliB0YXNrIOWVn+WLleebrumMhOS9jeaWvCBgZXhjbHVkZWRSZXBvc2l0b3J5UGF0aHNg77yM55u05o6l55Wl6YGO5ZCM5q2l44CCCi0gR2l0IGlnbm9yZSDlj6rlj6/otorpgY7nsr7norrnmoTlj5fnrqHnkIbmqpTmoYjoiIcgbWFuaWZlc3TvvIzkuI3lvpfmiorlhbbku5YgaWdub3JlZCDlhaflrrnntI3lhaXlkIzmraXmiJYgY29tbWl044CCCi0g5Y+q5pyJIG9yaWdpbiDliJflnKggYGF1dG9Db21taXRSZXBvc2l0b3J5VXJsc2Ag5pmC5omN6Ieq5YuVIGNvbW1pdO+8m+WFtuS7liBSZXBvc2l0b3J5IOWPquWQjOatpe+8jOS4jeiHquWLlSBzdGFnZeOAgWNvbW1pdCDmiJYgcHVzaOOAggo='
$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bootstrapSectionBase64))

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string] $WorkingDirectory,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $WorkingDirectory @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Write-Utf8NoBomFile {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-IsRepositoryUrl {
    param([Parameter(Mandatory = $true)][string] $Value)
    $trimmedValue = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) { return $false }
    $absoluteUri = $null
    if ([System.Uri]::TryCreate($trimmedValue,[System.UriKind]::Absolute,[ref]$absoluteUri) -and -not [string]::IsNullOrWhiteSpace($absoluteUri.Host)) {
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
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $PropertyName)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$PropertyName]
}

function Get-StringArrayProperty {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $PropertyName)
    if (-not (Test-ObjectHasProperty -Object $Object -PropertyName $PropertyName)) { return @() }
    return @($Object.$PropertyName | ForEach-Object { if ($null -ne $_) { [string]$_ } })
}

function Set-BootstrapSection {
    param([Parameter(Mandatory = $true)][string] $AgentsPath,[Parameter(Mandatory = $true)][string] $Section)
    $normalizedSection = $Section.Trim() + "`n"
    $content = if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) { [System.IO.File]::ReadAllText($AgentsPath).Replace("`r`n","`n").Replace("`r","`n") } else { '' }
    $pattern = '(?ms)^## Repository Instructions Bootstrap\s*\n.*?(?=^##\s|\z)'
    if ([regex]::IsMatch($content,$pattern)) { $updatedContent = [regex]::Replace($content,$pattern,$normalizedSection) }
    elseif ([string]::IsNullOrWhiteSpace($content)) { $updatedContent = $normalizedSection }
    else { $updatedContent = $content.TrimEnd() + "`n`n" + $normalizedSection }
    Write-Utf8NoBomFile -Path $AgentsPath -Content $updatedContent
}

function Get-CanonicalGitHubRepositoryUrl {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)
    $value = $RepositoryUrl.Trim()
    if ($value -match '^(?:https|ssh|git)://(?:[^@/]+@)?github\.com/(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?/?$') { return "https://github.com/$($Matches.Owner)/$($Matches.Repository).git" }
    if ($value -match '^(?:[^@/]+@)?github\.com:(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?$') { return "https://github.com/$($Matches.Owner)/$($Matches.Repository).git" }
    throw "The installer repository origin must be hosted on GitHub: $RepositoryUrl"
}

function Get-GitHubRepositoryIdentity {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)
    try { return (Get-CanonicalGitHubRepositoryUrl -RepositoryUrl $RepositoryUrl).ToLowerInvariant() }
    catch { return $null }
}

function Assert-StableSelectionArray {
    param([Parameter(Mandatory = $true)][object] $Value,[Parameter(Mandatory = $true)][string] $Context)
    if ($Value -isnot [System.Array]) { throw "$Context must be an array." }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]$item -cnotmatch '^[a-z0-9][a-z0-9-]*$') { throw "$Context contains an invalid ID." }
        if (-not $set.Add([string]$item)) { throw "$Context contains a duplicate ID." }
    }
    return ,$set
}

function Get-SyncConfigurationJson {
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
    $existingSchemaVersion = if ($null -eq $existingConfiguration) { $null }
    elseif (Test-ObjectHasProperty -Object $existingConfiguration -PropertyName 'schemaVersion') { [int]$existingConfiguration.schemaVersion }
    else { throw "AI instruction sync configuration is missing schemaVersion: $ConfigurationPath" }
    if ($null -ne $existingSchemaVersion -and $existingSchemaVersion -notin @(1,2,3)) { throw "Unsupported AI instruction sync configuration schemaVersion '$existingSchemaVersion': $ConfigurationPath" }

    $candidateUrls = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('autoCommitRepositoryUrls','allowedRepositoryUrls','repositoryUrls','autoCommitRepositories')) { foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) { $candidateUrls.Add($value) } }
    foreach ($value in @($AdditionalRepositoryUrls)) { $candidateUrls.Add([string]$value) }
    $candidateExcludedUrls = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('excludedRepositoryUrls','excludedRepositories')) { foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) { $candidateExcludedUrls.Add($value) } }
    foreach ($value in @($AdditionalExcludedRepositoryUrls)) { $candidateExcludedUrls.Add([string]$value) }
    $candidateExcludedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('excludedRepositoryPaths','excludedPaths')) { foreach ($value in @(Get-StringArrayProperty -Object $existingConfiguration -PropertyName $propertyName)) { $candidateExcludedPaths.Add($value) } }
    foreach ($value in @($AdditionalExcludedRepositoryPaths)) { $candidateExcludedPaths.Add([string]$value) }

    $repositoryUrls = @($candidateUrls | Where-Object { Test-IsRepositoryUrl ([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
    $excludedRepositoryUrls = @($candidateExcludedUrls | Where-Object { Test-IsRepositoryUrl ([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
    $excludedRepositoryPaths = @($candidateExcludedPaths | Where-Object { Test-IsRepositoryRelativePath ([string]$_) } | ForEach-Object { ([string]$_).Trim().Replace('\','/').Trim('/') } | Sort-Object -Unique)

    $profiles = @('core'); $includeSkills = @(); $excludeSkills = @()
    if ($existingSchemaVersion -eq 3) {
        if (-not (Test-ObjectHasProperty -Object $existingConfiguration -PropertyName 'catalog')) { throw "AI instruction sync configuration schemaVersion 3 is missing catalog: $ConfigurationPath" }
        foreach ($propertyName in @('repository','ref','profiles','includeSkills','excludeSkills')) {
            if (-not (Test-ObjectHasProperty -Object $existingConfiguration.catalog -PropertyName $propertyName)) { throw "AI instruction sync configuration catalog is missing '$propertyName': $ConfigurationPath" }
        }
        $existingIdentity = Get-GitHubRepositoryIdentity -RepositoryUrl ([string]$existingConfiguration.catalog.repository)
        $installedIdentity = Get-GitHubRepositoryIdentity -RepositoryUrl $CatalogRepository
        if ($null -eq $existingIdentity -or $existingIdentity -cne $installedIdentity) { throw 'AI instruction sync configuration catalog.repository must identify the same GitHub AI-Instructions repository as the installed runtime bundle.' }
        if ([string]$existingConfiguration.catalog.ref -cnotmatch '^[0-9a-f]{40}$') { throw "AI instruction sync configuration catalog.ref must be a full lowercase 40-character commit SHA: $ConfigurationPath" }
        $null = Assert-StableSelectionArray -Value $existingConfiguration.catalog.profiles -Context 'AI instruction sync configuration catalog.profiles'
        $includeSet = Assert-StableSelectionArray -Value $existingConfiguration.catalog.includeSkills -Context 'AI instruction sync configuration catalog.includeSkills'
        $excludeSet = Assert-StableSelectionArray -Value $existingConfiguration.catalog.excludeSkills -Context 'AI instruction sync configuration catalog.excludeSkills'
        foreach ($skillId in $includeSet) { if ($excludeSet.Contains($skillId)) { throw "AI instruction sync configuration includes and excludes the same Skill '$skillId': $ConfigurationPath" } }
        $profiles = @(Get-StringArrayProperty -Object $existingConfiguration.catalog -PropertyName 'profiles')
        $includeSkills = @(Get-StringArrayProperty -Object $existingConfiguration.catalog -PropertyName 'includeSkills')
        $excludeSkills = @(Get-StringArrayProperty -Object $existingConfiguration.catalog -PropertyName 'excludeSkills')
    }

    $configuration = [ordered]@{
        schemaVersion = 3
        autoCommitRepositoryUrls = @($repositoryUrls)
        excludedRepositoryUrls = @($excludedRepositoryUrls)
        excludedRepositoryPaths = @($excludedRepositoryPaths)
        catalog = [ordered]@{ repository=$CatalogRepository; ref=$CatalogRef; profiles=@($profiles); includeSkills=@($includeSkills); excludeSkills=@($excludeSkills) }
    }
    return (($configuration | ConvertTo-Json -Depth 8).Replace("`r`n","`n") + "`n")
}

function Remove-BootstrapSessionStartHook {
    param([Parameter(Mandatory = $true)][string] $HooksPath)
    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return }
    try { $hooksDocument = Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json }
    catch { throw "Codex hooks file is not valid JSON: $HooksPath" }
    if (-not (Test-ObjectHasProperty -Object $hooksDocument -PropertyName 'hooks') -or $null -eq $hooksDocument.hooks -or -not (Test-ObjectHasProperty -Object $hooksDocument.hooks -PropertyName 'SessionStart')) { return }
    $sessionStartEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($hooksDocument.hooks.SessionStart)) {
        if ($null -eq $entry) { continue }
        if (-not (Test-ObjectHasProperty -Object $entry -PropertyName 'hooks')) { $sessionStartEntries.Add($entry); continue }
        $containsBootstrapCommand = $false
        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) { continue }
            foreach ($propertyName in @('command','commandWindows')) { if ((Test-ObjectHasProperty -Object $hook -PropertyName $propertyName) -and [string]$hook.$propertyName -match 'bootstrap-ai-instructions\.ps1') { $containsBootstrapCommand = $true } }
        }
        if (-not $containsBootstrapCommand) { $sessionStartEntries.Add($entry) }
    }
    if ($sessionStartEntries.Count -eq 0) { $hooksDocument.hooks.PSObject.Properties.Remove('SessionStart') }
    else { $hooksDocument.hooks.PSObject.Properties['SessionStart'].Value = @($sessionStartEntries.ToArray()) }
    Write-Utf8NoBomFile -Path $HooksPath -Content (($hooksDocument | ConvertTo-Json -Depth 12).Replace("`r`n","`n") + "`n")
    Get-Content -Raw -LiteralPath $HooksPath | ConvertFrom-Json | Out-Null
}

function Assert-InstallerSourcesMatchHead {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $RelativePaths)
    foreach ($relativePath in $RelativePaths) { Invoke-Git -WorkingDirectory $Repository -Arguments @('ls-files','--error-unmatch','--',$relativePath) | Out-Null }
    $arguments = @('diff','--name-only','HEAD','--') + @($RelativePaths)
    $previousErrorActionPreference = $ErrorActionPreference
    try { $ErrorActionPreference='Continue'; $changed=& git -C $Repository @arguments 2>&1; $exitCode=$LASTEXITCODE }
    finally { $ErrorActionPreference=$previousErrorActionPreference }
    if ($exitCode -ne 0) { throw "Unable to verify installer source files against HEAD: $($changed -join [Environment]::NewLine)" }
    if (@($changed).Count -gt 0) { throw "Installer source files differ from HEAD and cannot be represented by the immutable install pin: $(@($changed) -join ', ')" }
}

function Copy-BackupFileIfPresent {
    param([Parameter(Mandatory = $true)][string] $Source,[Parameter(Mandatory = $true)][string] $Destination)
    if (Test-Path -LiteralPath $Source -PathType Leaf) { Copy-Item -LiteralPath $Source -Destination $Destination -Force; return $true }
    return $false
}

function Restore-BackupFile {
    param([Parameter(Mandatory = $true)][string] $Destination,[Parameter(Mandatory = $true)][string] $Backup,[Parameter(Mandatory = $true)][bool] $OriginallyExisted)
    if ($OriginallyExisted) { Copy-Item -LiteralPath $Backup -Destination $Destination -Force }
    else { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot=((Invoke-Git -WorkingDirectory (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim() }
$repositoryRootPath=[System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\','/'))
$originUrl=((Invoke-Git -WorkingDirectory $repositoryRootPath -Arguments @('remote','get-url','origin')) | Select-Object -First 1).Trim()
$catalogRepository=Get-CanonicalGitHubRepositoryUrl -RepositoryUrl $originUrl
$catalogRef=((Invoke-Git -WorkingDirectory $repositoryRootPath -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
if ($catalogRef -cnotmatch '^[0-9a-f]{40}$') { throw "Installer repository HEAD is not a full lowercase commit SHA: $catalogRef" }

$runtimeFiles=@('bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1','skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1','skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1')
$relativeSourcePaths=@('scripts/install-ai-instructions-bootstrap.ps1','scripts/bootstrap-ai-instructions-installed.ps1')
foreach ($fileName in $runtimeFiles) { $relativeSourcePaths += "scripts/$fileName" }
$relativeSourcePaths += 'catalog/skills-catalog.json'; $relativeSourcePaths += 'catalog/skills-catalog-lock.json'
foreach ($relativePath in $relativeSourcePaths) {
    $sourcePath=Join-Path $repositoryRootPath $relativePath.Replace('/','\')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Installer runtime source was not found: $sourcePath" }
}
Assert-InstallerSourcesMatchHead -Repository $repositoryRootPath -RelativePaths $relativeSourcePaths

if ([string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome=if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' } }
$codexHomePath=[System.IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\','/'))
$hookDirectory=Join-Path $codexHomePath 'hooks'; $hookScript=Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'; $runtimeDirectory=Join-Path $hookDirectory 'ai-instructions-runtime'; $agentsPath=Join-Path $codexHomePath 'AGENTS.md'; $hooksPath=Join-Path $codexHomePath 'hooks.json'; $configurationPath=Join-Path $codexHomePath 'ai-instructions-sync.json'
New-Item -ItemType Directory -Force -Path $codexHomePath,$hookDirectory | Out-Null
$transactionId=[Guid]::NewGuid().ToString('N'); $stagingRoot=Join-Path $codexHomePath ".ai-instructions-install-$transactionId"; $stagingRuntime=Join-Path $stagingRoot 'runtime'; $stagingLauncher=Join-Path $stagingRoot 'bootstrap-ai-instructions.ps1'; $stagingConfiguration=Join-Path $stagingRoot 'ai-instructions-sync.json'; $backupRoot=Join-Path $codexHomePath ".ai-instructions-backup-$transactionId"; $backupRuntime=Join-Path $backupRoot 'runtime'
New-Item -ItemType Directory -Force -Path $stagingRuntime,(Join-Path $stagingRuntime 'catalog'),$backupRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\bootstrap-ai-instructions-installed.ps1') -Destination $stagingLauncher -Force
foreach ($fileName in $runtimeFiles) { Copy-Item -LiteralPath (Join-Path $repositoryRootPath "scripts\$fileName") -Destination (Join-Path $stagingRuntime $fileName) -Force }
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog.json') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog-lock.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -Force
$bundleJson=([ordered]@{schemaVersion=1;repository=$catalogRepository;commit=$catalogRef}|ConvertTo-Json -Depth 4).Replace("`r`n","`n")+"`n"; Write-Utf8NoBomFile -Path (Join-Path $stagingRuntime 'runtime-bundle.json') -Content $bundleJson
$configurationJson=Get-SyncConfigurationJson -ConfigurationPath $configurationPath -AdditionalRepositoryUrls $AutoCommitRepositoryUrls -AdditionalExcludedRepositoryUrls $ExcludedRepositoryUrls -AdditionalExcludedRepositoryPaths $ExcludedRepositoryPaths -CatalogRepository $catalogRepository -CatalogRef $catalogRef; Write-Utf8NoBomFile -Path $stagingConfiguration -Content $configurationJson
$stagedConfig=Get-Content -Raw -Encoding UTF8 -LiteralPath $stagingConfiguration|ConvertFrom-Json; $stagedBundle=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stagingRuntime 'runtime-bundle.json')|ConvertFrom-Json
if ([string]$stagedConfig.catalog.repository -cne [string]$stagedBundle.repository -or [string]$stagedConfig.catalog.ref -cne [string]$stagedBundle.commit) { throw 'Staged runtime bundle identity does not match staged configuration.' }
Import-Module (Join-Path $stagingRuntime 'skills-catalog-contract.psm1') -Force; Test-SkillsCatalogLockDocument -LockPath (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -CatalogPath (Join-Path $stagingRuntime 'catalog\skills-catalog.json') | Out-Null
foreach ($scriptPath in @($stagingLauncher)+@(Get-ChildItem -LiteralPath $stagingRuntime -File -Filter '*.ps*'|Select-Object -ExpandProperty FullName)) { $tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors); if (@($errors).Count -gt 0) { throw "Staged installer runtime contains a PowerShell parse error in '$scriptPath': $(@($errors)[0].Message)" } }

$hadRuntime=Test-Path -LiteralPath $runtimeDirectory -PathType Container
$hadHook=Copy-BackupFileIfPresent -Source $hookScript -Destination (Join-Path $backupRoot 'bootstrap-ai-instructions.ps1'); $hadConfiguration=Copy-BackupFileIfPresent -Source $configurationPath -Destination (Join-Path $backupRoot 'ai-instructions-sync.json'); $hadAgents=Copy-BackupFileIfPresent -Source $agentsPath -Destination (Join-Path $backupRoot 'AGENTS.md'); $hadHooks=Copy-BackupFileIfPresent -Source $hooksPath -Destination (Join-Path $backupRoot 'hooks.json')
$runtimeBackedUp=$false; $runtimeInstalled=$false; $installSucceeded=$false; $rollbackSucceeded=$false

try {
    Copy-Item -LiteralPath $stagingLauncher -Destination $hookScript -Force
    if ($hadRuntime) { Move-Item -LiteralPath $runtimeDirectory -Destination $backupRuntime; $runtimeBackedUp=$true }
    Move-Item -LiteralPath $stagingRuntime -Destination $runtimeDirectory; $runtimeInstalled=$true
    Copy-Item -LiteralPath $stagingConfiguration -Destination $configurationPath -Force
    Set-BootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
    Remove-BootstrapSessionStartHook -HooksPath $hooksPath
    $installSucceeded=$true
}
catch {
    $installError=$_
    try {
        if ($runtimeInstalled -and (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) { Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force }
        if ($runtimeBackedUp -and (Test-Path -LiteralPath $backupRuntime -PathType Container)) { Move-Item -LiteralPath $backupRuntime -Destination $runtimeDirectory }
        Restore-BackupFile -Destination $hookScript -Backup (Join-Path $backupRoot 'bootstrap-ai-instructions.ps1') -OriginallyExisted $hadHook
        Restore-BackupFile -Destination $configurationPath -Backup (Join-Path $backupRoot 'ai-instructions-sync.json') -OriginallyExisted $hadConfiguration
        Restore-BackupFile -Destination $agentsPath -Backup (Join-Path $backupRoot 'AGENTS.md') -OriginallyExisted $hadAgents
        Restore-BackupFile -Destination $hooksPath -Backup (Join-Path $backupRoot 'hooks.json') -OriginallyExisted $hadHooks
        $rollbackSucceeded=$true
    }
    catch {
        throw "AI instructions installation failed and rollback also failed. Recovery backup retained at '$backupRoot'. Original error: $($installError.Exception.Message). Rollback error: $($_.Exception.Message)"
    }
    throw $installError
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (($installSucceeded -or $rollbackSucceeded) -and (Test-Path -LiteralPath $backupRoot)) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "Installed AI instructions bootstrap script: $hookScript"
Write-Output "Installed immutable runtime bundle: $runtimeDirectory"
Write-Output "Updated Codex AGENTS.md bootstrap section: $agentsPath"
Write-Output "Removed legacy AI instructions bootstrap SessionStart hook when present: $hooksPath"
Write-Output "Updated AI instructions sync configuration: $configurationPath"
