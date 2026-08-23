[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $CodexHome,
    [string[]] $ExcludedRepositoryUrls = @(),
    [string[]] $ExcludedRepositoryPaths = @(),
    [string] $SourceRepository,
    [string] $SourceCommit,
    [ValidateSet('git-checkout','github-codeload')][string] $Acquisition = 'git-checkout',
    [string] $ArchiveSha256,
    [string] $SourceArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(
    'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquacieaWsOWinuaIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkQ09ERVhfSE9NRS9ob29rcy9ib290c3RyYXAtYWktaW5zdHJ1Y3Rpb25zLnBzMWDvvJvllq7ntJTllY/llY/poYzjgIHph5DmuIXpnIDmsYLjgIHnorroqo3miJbop6Pph4vllY/poYzvvIzku6Xlj4rlhbbku5blsJrmnKrplovlp4vopo/lioMgY29kZSDnmoTlt6XkvZzkuI3lvpfln7fooYwgYm9vdHN0cmFw44CCCi0g5ZCM5q2l5a6M5oiQ5b6M77yM5YWI6K6A5Y+WIFJlcG9zaXRvcnkg5paw5aKe5oiW5pu05paw55qEIGBBR0VOVFMubWRgIOiIh+ebruWJjeS7u+WLmemBqeeUqOeahOimj+WJh+aooee1hO+8m+S9v+eUqOiAheaYjueiuuaMh+WumiBTa2lsbCDmiJbku7vli5nnrKblkIggYC5hZ2VudHMvc2tpbGxzL2Ag5Lit55qEIFNraWxsIGRlc2NyaXB0aW9uIOaZgu+8jOWGjeiugOWPluWwjeaHiSBgU0tJTEwubWRg44CCCi0g5LulIGAuY29kZXgvYWktaW5zdHJ1Y3Rpb25zLm1hbmlmZXN0Lmpzb25gIOeuoeeQhuWFseS6qyBJbnN0cnVjdGlvbnMg6IiHIEFnZW50IFNraWxsc++8m+WPquabtOaWsOacquiiq+WAi+S6uuS/ruaUueeahOWPl+euoeeQhuaqlOahiO+8jOS4jeimhuWvqyBjdXN0b21pemVkIG9yIHVubWFuYWdlZCBJbnN0cnVjdGlvbnMgb3IgQWdlbnQgU2tpbGxz44CCCi0gUmVwb3NpdG9yeSDnmoQgb3JpZ2luIOiLpeWIl+WcqCBgfi8uY29kZXgvYWktaW5zdHJ1Y3Rpb25zLXN5bmMuanNvbmAg55qEIGBleGNsdWRlZFJlcG9zaXRvcnlVcmxzYO+8jOaIliB0YXNrIOWVn+WLleebrumMhOS9jeaWvCBgZXhjbHVkZWRSZXBvc2l0b3J5UGF0aHNg77yM55u05o6l55Wl6YGO5ZCM5q2l44CCCi0gUmVwb3NpdG9yeS1sb2NhbCBJbnN0cnVjdGlvbnPjgIFTa2lsbHMg6IiHIG1hbmlmZXN0IOaYr+aJgOaciSBicmFuY2gg5YWx55So55qE5YCL5Lq6IHJ1bnRpbWUgYXJ0aWZhY3Rz77yM5b+F6aCI5L+d5oyBIGxvY2FsIGlnbm9yZWQg5LiU5LiN5b6XIGNvbW1pdCDliLDnlKLlk4EgUmVwb3NpdG9yee+8m+iLpeWPl+euoei3r+W+keW3suiiqyBHaXQgdHJhY2tlZO+8jGJvb3RzdHJhcCDlv4XpoIggZmFpbCBjbG9zZWQg5Lim5Zue5aCx5rGh5p+T6Lev5b6R77yM5LiN5b6X6Ieq5YuVIHN0YWdl44CBY29tbWl0IOaIliBwdXNo44CC'
))

function Invoke-InstallerGit {
    param([Parameter(Mandatory = $true)][string] $WorkingDirectory,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $WorkingDirectory @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Write-InstallerUtf8File {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Set-InstallerBootstrapSection {
    param([Parameter(Mandatory = $true)][string] $AgentsPath,[Parameter(Mandatory = $true)][string] $Section)
    $normalizedSection = $Section.Trim() + "`n"
    $content = if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) { [System.IO.File]::ReadAllText($AgentsPath).Replace("`r`n","`n").Replace("`r","`n") } else { '' }
    $pattern = '(?ms)^## Repository Instructions Bootstrap\s*\n.*?(?=^##\s|\z)'
    $updated = if ([regex]::IsMatch($content,$pattern)) { [regex]::Replace($content,$pattern,$normalizedSection) }
    elseif ([string]::IsNullOrWhiteSpace($content)) { $normalizedSection }
    else { $content.TrimEnd() + "`n`n" + $normalizedSection }
    Write-InstallerUtf8File -Path $AgentsPath -Content $updated
}

function Test-InstallerHasProperty {
    param([AllowNull()][object] $Object,[Parameter(Mandatory = $true)][string] $Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Remove-InstallerSessionStartHook {
    param([Parameter(Mandatory = $true)][string] $HooksPath)
    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return }
    try { $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $HooksPath | ConvertFrom-Json }
    catch { throw "Codex hooks file is not valid JSON: $HooksPath" }
    if (-not (Test-InstallerHasProperty -Object $document -Name 'hooks') -or $null -eq $document.hooks -or
        -not (Test-InstallerHasProperty -Object $document.hooks -Name 'SessionStart')) { return }
    $retained = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($document.hooks.SessionStart)) {
        if ($null -eq $entry) { continue }
        if (-not (Test-InstallerHasProperty -Object $entry -Name 'hooks')) { $retained.Add($entry); continue }
        $containsBootstrap = $false
        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) { continue }
            foreach ($propertyName in @('command','commandWindows')) {
                if ((Test-InstallerHasProperty -Object $hook -Name $propertyName) -and [string]$hook.$propertyName -match 'bootstrap-ai-instructions\.ps1') {
                    $containsBootstrap = $true
                }
            }
        }
        if (-not $containsBootstrap) { $retained.Add($entry) }
    }
    if ($retained.Count -eq 0) { $document.hooks.PSObject.Properties.Remove('SessionStart') }
    else { $document.hooks.PSObject.Properties['SessionStart'].Value = @($retained.ToArray()) }
    Write-InstallerUtf8File -Path $HooksPath -Content (($document | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n")
    Get-Content -Raw -Encoding UTF8 -LiteralPath $HooksPath | ConvertFrom-Json | Out-Null
}

function Assert-InstallerSourcesMatchHead {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $RelativePaths)
    foreach ($relativePath in $RelativePaths) { Invoke-InstallerGit -WorkingDirectory $Repository -Arguments @('ls-files','--error-unmatch','--',$relativePath) | Out-Null }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $changed = & git -C $Repository @(@('diff','--name-only','HEAD','--') + $RelativePaths) 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "Unable to verify installer source files against HEAD: $($changed -join [Environment]::NewLine)" }
    if (@($changed).Count -gt 0) { throw "Installer source files differ from HEAD and cannot be represented by the immutable install pin: $(@($changed) -join ', ')" }
}

function Copy-InstallerBackupFile {
    param([Parameter(Mandatory = $true)][string] $Source,[Parameter(Mandatory = $true)][string] $Destination)
    if (Test-Path -LiteralPath $Source -PathType Leaf) { Copy-Item -LiteralPath $Source -Destination $Destination -Force; return $true }
    return $false
}

function Restore-InstallerBackupFile {
    param([Parameter(Mandatory = $true)][string] $Destination,[Parameter(Mandatory = $true)][string] $Backup,[Parameter(Mandatory = $true)][bool] $OriginallyExisted)
    if ($OriginallyExisted) { Copy-Item -LiteralPath $Backup -Destination $Destination -Force }
    elseif (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = ((Invoke-InstallerGit -WorkingDirectory (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
}
$repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\','/'))
$runtimeContractSource = Join-Path $repositoryRootPath 'scripts\ai-instructions-runtime-contract.psm1'
if (-not (Test-Path -LiteralPath $runtimeContractSource -PathType Leaf)) { throw "Installer runtime contract source was not found: $runtimeContractSource" }
Import-Module $runtimeContractSource -Force

if ($Acquisition -ceq 'git-checkout') {
    $originUrl = ((Invoke-InstallerGit -WorkingDirectory $repositoryRootPath -Arguments @('remote','get-url','origin')) | Select-Object -First 1).Trim()
    Assert-AiInstructionsCanonicalRepository -Repository $originUrl
    $catalogRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $catalogRef = ((Invoke-InstallerGit -WorkingDirectory $repositoryRootPath -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($SourceRepository)) { Assert-AiInstructionsCanonicalRepository -Repository $SourceRepository }
    if (-not [string]::IsNullOrWhiteSpace($SourceCommit) -and $SourceCommit -cne $catalogRef) { throw 'SourceCommit does not match the git checkout HEAD.' }
    $ArchiveSha256 = $null
}
else {
    if ([string]::IsNullOrWhiteSpace($SourceRepository) -or [string]::IsNullOrWhiteSpace($SourceCommit)) {
        throw 'github-codeload installation requires SourceRepository and SourceCommit.'
    }
    Assert-AiInstructionsCanonicalRepository -Repository $SourceRepository
    if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'SourceCommit must be a full lowercase 40-character commit SHA.' }
    if ($ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'github-codeload installation requires ArchiveSha256.' }
    if ([string]::IsNullOrWhiteSpace($SourceArchivePath) -or -not (Test-Path -LiteralPath $SourceArchivePath -PathType Leaf)) {
        throw 'github-codeload installation requires the downloaded SourceArchivePath.'
    }
    $actualArchiveSha256 = Get-AiInstructionsFileSha256 -Path $SourceArchivePath
    if ($actualArchiveSha256 -cne $ArchiveSha256) {
        throw "github-codeload SourceArchivePath SHA-256 does not match ArchiveSha256: expected $ArchiveSha256; actual $actualArchiveSha256."
    }
    $catalogRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $catalogRef = $SourceCommit
}
if ($catalogRef -cnotmatch '^[0-9a-f]{40}$') { throw 'Installer source commit must be a full lowercase 40-character commit SHA.' }

$runtimeFiles = @(
    'bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
    'skills-catalog-contract.psm1','skills-selection.psm1','skills-source-routing.psm1',
    'skills-source-retrieval.psm1','skills-source-acquisition.psm1','skills-source-composition.psm1',
    'ai-instructions-runtime-contract.psm1','ai-instructions-updater.psm1','update-ai-instructions.ps1',
    'cleanup-ai-instructions-pollution.ps1'
)
$stableScripts = @('bootstrap-ai-instructions-installed.ps1','update-ai-instructions.ps1','cleanup-ai-instructions-pollution.ps1')
$relativeSourcePaths = @('scripts/install-ai-instructions-bootstrap.ps1')
foreach ($fileName in @($runtimeFiles + $stableScripts | Sort-Object -Unique)) { $relativeSourcePaths += "scripts/$fileName" }
$relativeSourcePaths += 'catalog/skills-catalog.json','catalog/skills-catalog-lock.json'
foreach ($relativePath in $relativeSourcePaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRootPath $relativePath.Replace('/','\')) -PathType Leaf)) {
        throw "Installer runtime source was not found: $relativePath"
    }
}
if ($Acquisition -ceq 'git-checkout') { Assert-InstallerSourcesMatchHead -Repository $repositoryRootPath -RelativePaths $relativeSourcePaths }

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\','/'))
$hookDirectory = Join-Path $codexHomePath 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'
$updateScript = Join-Path $hookDirectory 'update-ai-instructions.ps1'
$cleanupScript = Join-Path $hookDirectory 'cleanup-ai-instructions-pollution.ps1'
$runtimeDirectory = Join-Path $hookDirectory 'ai-instructions-runtime'
$agentsPath = Join-Path $codexHomePath 'AGENTS.md'
$hooksPath = Join-Path $codexHomePath 'hooks.json'
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
New-Item -ItemType Directory -Force -Path $codexHomePath,$hookDirectory | Out-Null

$existingConfiguration = $null
if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
    try { $existingConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json }
    catch { throw "AI instruction sync configuration is not valid JSON: $configurationPath" }
}
$configuration = ConvertTo-AiInstructionsSyncConfigurationV4 `
    -ExistingConfiguration $existingConfiguration `
    -CatalogRepository $catalogRepository `
    -CatalogRef $catalogRef `
    -AdditionalExcludedRepositoryUrls $ExcludedRepositoryUrls `
    -AdditionalExcludedRepositoryPaths $ExcludedRepositoryPaths

$transactionId = [Guid]::NewGuid().ToString('N')
$stagingRoot = Join-Path $codexHomePath ".ai-instructions-install-$transactionId"
$stagingRuntime = Join-Path $stagingRoot 'runtime'
$stagingLauncher = Join-Path $stagingRoot 'bootstrap-ai-instructions.ps1'
$stagingUpdater = Join-Path $stagingRoot 'update-ai-instructions.ps1'
$stagingCleanup = Join-Path $stagingRoot 'cleanup-ai-instructions-pollution.ps1'
$stagingConfiguration = Join-Path $stagingRoot 'ai-instructions-sync.json'
$backupRoot = Join-Path $codexHomePath ".ai-instructions-backup-$transactionId"
$backupRuntime = Join-Path $backupRoot 'runtime'
New-Item -ItemType Directory -Force -Path $stagingRuntime,(Join-Path $stagingRuntime 'catalog'),$backupRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\bootstrap-ai-instructions-installed.ps1') -Destination $stagingLauncher -Force
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\update-ai-instructions.ps1') -Destination $stagingUpdater -Force
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'scripts\cleanup-ai-instructions-pollution.ps1') -Destination $stagingCleanup -Force
foreach ($fileName in $runtimeFiles) { Copy-Item -LiteralPath (Join-Path $repositoryRootPath "scripts\$fileName") -Destination (Join-Path $stagingRuntime $fileName) -Force }
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog.json') -Force
Copy-Item -LiteralPath (Join-Path $repositoryRootPath 'catalog\skills-catalog-lock.json') -Destination (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -Force
Write-AiInstructionsJsonFile -Path $stagingConfiguration -Document $configuration
Import-Module (Join-Path $stagingRuntime 'ai-instructions-runtime-contract.psm1') -Force
$bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $stagingRuntime -Repository $catalogRepository -Commit $catalogRef -Acquisition $Acquisition -ArchiveSha256 $ArchiveSha256
Write-AiInstructionsJsonFile -Path (Join-Path $stagingRuntime 'runtime-bundle.json') -Document $bundle
$stagedConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $stagingConfiguration | ConvertFrom-Json
$stagedBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stagingRuntime 'runtime-bundle.json') | ConvertFrom-Json
Assert-AiInstructionsRuntimeBundleV2 -Bundle $stagedBundle -Configuration $stagedConfiguration -RuntimeRoot $stagingRuntime | Out-Null
Import-Module (Join-Path $stagingRuntime 'skills-catalog-contract.psm1') -Force
Test-SkillsCatalogLockDocument -LockPath (Join-Path $stagingRuntime 'catalog\skills-catalog-lock.json') -CatalogPath (Join-Path $stagingRuntime 'catalog\skills-catalog.json') | Out-Null
foreach ($scriptPath in @($stagingLauncher,$stagingUpdater,$stagingCleanup) + @(Get-ChildItem -LiteralPath $stagingRuntime -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') } | Select-Object -ExpandProperty FullName)) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) { throw "Staged installer runtime contains a PowerShell parse error in '$scriptPath': $(@($errors)[0].Message)" }
}

$hadRuntime = Test-Path -LiteralPath $runtimeDirectory -PathType Container
$hadHook = Copy-InstallerBackupFile -Source $hookScript -Destination (Join-Path $backupRoot 'bootstrap-ai-instructions.ps1')
$hadUpdater = Copy-InstallerBackupFile -Source $updateScript -Destination (Join-Path $backupRoot 'update-ai-instructions.ps1')
$hadCleanup = Copy-InstallerBackupFile -Source $cleanupScript -Destination (Join-Path $backupRoot 'cleanup-ai-instructions-pollution.ps1')
$hadConfiguration = Copy-InstallerBackupFile -Source $configurationPath -Destination (Join-Path $backupRoot 'ai-instructions-sync.json')
$hadAgents = Copy-InstallerBackupFile -Source $agentsPath -Destination (Join-Path $backupRoot 'AGENTS.md')
$hadHooks = Copy-InstallerBackupFile -Source $hooksPath -Destination (Join-Path $backupRoot 'hooks.json')
$runtimeBackedUp=$false; $runtimeInstalled=$false; $installSucceeded=$false; $rollbackSucceeded=$false
try {
    Copy-Item -LiteralPath $stagingLauncher -Destination $hookScript -Force
    Copy-Item -LiteralPath $stagingUpdater -Destination $updateScript -Force
    Copy-Item -LiteralPath $stagingCleanup -Destination $cleanupScript -Force
    if ($hadRuntime) { Move-Item -LiteralPath $runtimeDirectory -Destination $backupRuntime; $runtimeBackedUp=$true }
    Move-Item -LiteralPath $stagingRuntime -Destination $runtimeDirectory; $runtimeInstalled=$true
    Copy-Item -LiteralPath $stagingConfiguration -Destination $configurationPath -Force
    Set-InstallerBootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
    Remove-InstallerSessionStartHook -HooksPath $hooksPath
    $installSucceeded=$true
}
catch {
    $installError=$_
    try {
        if ($runtimeInstalled -and (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) { Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force }
        if ($runtimeBackedUp -and (Test-Path -LiteralPath $backupRuntime -PathType Container)) { Move-Item -LiteralPath $backupRuntime -Destination $runtimeDirectory }
        Restore-InstallerBackupFile -Destination $hookScript -Backup (Join-Path $backupRoot 'bootstrap-ai-instructions.ps1') -OriginallyExisted $hadHook
        Restore-InstallerBackupFile -Destination $updateScript -Backup (Join-Path $backupRoot 'update-ai-instructions.ps1') -OriginallyExisted $hadUpdater
        Restore-InstallerBackupFile -Destination $cleanupScript -Backup (Join-Path $backupRoot 'cleanup-ai-instructions-pollution.ps1') -OriginallyExisted $hadCleanup
        Restore-InstallerBackupFile -Destination $configurationPath -Backup (Join-Path $backupRoot 'ai-instructions-sync.json') -OriginallyExisted $hadConfiguration
        Restore-InstallerBackupFile -Destination $agentsPath -Backup (Join-Path $backupRoot 'AGENTS.md') -OriginallyExisted $hadAgents
        Restore-InstallerBackupFile -Destination $hooksPath -Backup (Join-Path $backupRoot 'hooks.json') -OriginallyExisted $hadHooks
        $rollbackSucceeded=$true
    }
    catch { throw "AI instructions installation failed and rollback also failed. Recovery backup retained at '$backupRoot'. Original error: $($installError.Exception.Message). Rollback error: $($_.Exception.Message)" }
    throw $installError
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (($installSucceeded -or $rollbackSucceeded) -and (Test-Path -LiteralPath $backupRoot)) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "Installed AI instructions bootstrap launcher: $hookScript"
Write-Output "Installed AI instructions manual updater: $updateScript"
Write-Output "Installed AI instructions pollution cleanup command: $cleanupScript"
Write-Output "Installed immutable runtime bundle: $runtimeDirectory"
Write-Output "Updated AI instructions sync configuration schema v4: $configurationPath"
