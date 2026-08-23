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
    [string] $SourceArchivePath,
    [string] $ExpectedCurrentCommit,
    [string] $ExpectedUpdateMode,
    [string] $ExpectedUpdateChannel,
    [string] $ExpectedUpdateRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapSection = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(
    'IyMgUmVwb3NpdG9yeSBJbnN0cnVjdGlvbnMgQm9vdHN0cmFwCgotIOWPquacieaWsOWinuaIluabtOaWsCBwcm9kdWN0aW9uIGNvZGUg55qE5a+m5L2c6KiI55Wr5pmC77yM5omN5Z+36KGMIGAkY29kZXhIb21lID0gaWYgKC1ub3QgW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkZW52OkNPREVYX0hPTUUpKSB7ICRlbnY6Q09ERVhfSE9NRSB9IGVsc2UgeyBKb2luLVBhdGggJEhPTUUgJy5jb2RleCcgfTsgJiAoSm9pbi1QYXRoICRjb2RleEhvbWUgJ2hvb2tzXGJvb3RzdHJhcC1haS1pbnN0cnVjdGlvbnMucHMxJylg77yb5Zau57SU5ZWP5ZWP6aGM44CB6YeQ5riF6ZyA5rGC44CB56K66KqN5oiW6Kej6YeL5ZWP6aGM77yM5Lul5Y+K5YW25LuW5bCa5pyq6ZaL5aeL6KaP5YqDIGNvZGUg55qE5bel5L2c5LiN5b6X5Z+36KGMIGJvb3RzdHJhcOOAggotIOWQjOatpeWujOaIkOW+jO+8jOWFiOiugOWPliBSZXBvc2l0b3J5IOaWsOWinuaIluabtOaWsOeahCBgQUdFTlRTLm1kYCDoiIfnm67liY3ku7vli5npgannlKjnmoTopo/liYfmqKHntYTvvJvkvb/nlKjogIXmmI7norrmjIflrpogU2tpbGwg5oiW5Lu75YuZ56ym5ZCIIGAuYWdlbnRzL3NraWxscy9gIOS4reeahCBTa2lsbCBkZXNjcmlwdGlvbiDmmYLvvIzlho3oroDlj5blsI3mh4kgYFNLSUxMLm1kYOOAggotIOS7pSBgLmNvZGV4L2FpLWluc3RydWN0aW9ucy5tYW5pZmVzdC5qc29uYCDnrqHnkIblhbHkuqsgSW5zdHJ1Y3Rpb25zIOiIhyBBZ2VudCBTa2lsbHPvvJvlj6rmm7TmlrDmnKrooqvlgIvkurrkv67mlLnnmoTlj5fnrqHnkIbmqpTmoYjvvIzkuI3opoblr6sgY3VzdG9taXplZCBvciB1bm1hbmFnZWQgSW5zdHJ1Y3Rpb25zIG9yIEFnZW50IFNraWxsc+OAggotIFJlcG9zaXRvcnkg55qEIG9yaWdpbiDoi6XliJflnKggYH4vLmNvZGV4L2FpLWluc3RydWN0aW9ucy1zeW5jLmpzb25gIOeahCBgZXhjbHVkZWRSZXBvc2l0b3J5VXJsc2DvvIzmiJYgdGFzayDllZ/li5Xnm67pjITkvY3mlrwgYGV4Y2x1ZGVkUmVwb3NpdG9yeVBhdGhzYO+8jOebtOaOpeeVpemBjuWQjOatpeOAggotIFJlcG9zaXRvcnktbG9jYWwgSW5zdHJ1Y3Rpb25z44CBU2tpbGxzIOiIhyBtYW5pZmVzdCDmmK/miYDmnIkgYnJhbmNoIOWFseeUqOeahOWAi+S6uiBydW50aW1lIGFydGlmYWN0c++8jOW/hemgiOS/neaMgSBsb2NhbCBpZ25vcmVkIOS4lOS4jeW+lyBjb21taXQg5Yiw55Si5ZOBIFJlcG9zaXRvcnnvvJvoi6Xlj5fnrqHot6/lvpHlt7LooqsgR2l0IHRyYWNrZWTvvIxib290c3RyYXAg5b+F6aCIIGZhaWwgY2xvc2VkIOS4puWbnuWgseaxoeafk+i3r+W+ke+8jOS4jeW+l+iHquWLlSBzdGFnZeOAgWNvbW1pdCDmiJYgcHVzaOOAgg=='
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

function Assert-InstallerMutationPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('File','Directory')][string] $ExpectedType
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -Force -LiteralPath $Path
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $hasExpectedType = if ($ExpectedType -ceq 'Directory') { $item.PSIsContainer } else { -not $item.PSIsContainer }
    if ($isReparsePoint -or -not $hasExpectedType) {
        throw "Unsafe installer mutation path '$Path': expected a non-reparse $($ExpectedType.ToLowerInvariant())."
    }
}

function Get-InstallerFullDirectoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($rootPath) -and $fullPath.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase)) { return $rootPath }
    return $fullPath.TrimEnd([char[]]@('\','/'))
}

function Get-InstallerFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Assert-InstallerCanonicalRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)
    $value = $Repository.Trim()
    if ($value -match '^(?:https|ssh|git)://(?:[^@/]+@)?github\.com/(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?/?$' -or
        $value -match '^(?:[^@/]+@)?github\.com:(?<Owner>[^/]+)/(?<Repository>[^/]+?)(?:\.git)?$') {
        $identity = "github.com/$($Matches.Owner)/$($Matches.Repository)".ToLowerInvariant()
        if ($identity -ceq 'github.com/syuantsai/syuantsai-ai-instructions') { return }
    }
    throw "AI-Instructions runtime accepts only the canonical repository; actual: '$Repository'."
}

function Assert-InstallerSafeChildDirectory {
    param([Parameter(Mandatory = $true)][string] $Parent,[Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $LeafPrefix)
    $parentPath = Get-InstallerFullDirectoryPath -Path $Parent
    $childPath = Get-InstallerFullDirectoryPath -Path $Path
    $childParent = Get-InstallerFullDirectoryPath -Path (Split-Path -Parent $childPath)
    if (-not $childParent.Equals($parentPath,[System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $childPath).StartsWith($LeafPrefix,[System.StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $childPath -PathType Container)) {
        throw "Unsafe installer transaction cleanup path: $childPath"
    }
    $item = Get-Item -Force -LiteralPath $childPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unsafe reparse-backed installer transaction cleanup path: $childPath" }
    return $childPath
}

function Test-InstallerOwnedBootstrapHook {
    param(
        [AllowNull()][object] $Hook,
        [Parameter(Mandatory = $true)][string] $BootstrapHookPath
    )
    if ($null -eq $Hook -or -not (Test-InstallerHasProperty -Object $Hook -Name 'type') -or
        [string]$Hook.type -cne 'command') { return $false }

    $ownedPath = [System.IO.Path]::GetFullPath($BootstrapHookPath).Replace('/','\')
    $ownedPathPattern = '(?i)(?<![A-Za-z0-9_.-])' + [regex]::Escape($ownedPath) + '(?![A-Za-z0-9_.-])'
    foreach ($propertyName in @('command','commandWindows')) {
        if ((Test-InstallerHasProperty -Object $Hook -Name $propertyName) -and $Hook.$propertyName -is [string]) {
            $command = ([string]$Hook.$propertyName).Replace('/','\')
            if ([regex]::IsMatch($command,$ownedPathPattern)) { return $true }
        }
    }
    return $false
}

function Remove-InstallerSessionStartHook {
    param(
        [Parameter(Mandatory = $true)][string] $HooksPath,
        [Parameter(Mandatory = $true)][string] $BootstrapHookPath
    )
    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return }
    try { $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $HooksPath | ConvertFrom-Json }
    catch { throw "Codex hooks file is not valid JSON: $HooksPath" }
    if (-not (Test-InstallerHasProperty -Object $document -Name 'hooks') -or $null -eq $document.hooks -or
        -not (Test-InstallerHasProperty -Object $document.hooks -Name 'SessionStart')) { return }
    $retained = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($document.hooks.SessionStart)) {
        if ($null -eq $entry) { continue }
        if (-not (Test-InstallerHasProperty -Object $entry -Name 'hooks')) { $retained.Add($entry); continue }
        $removedBootstrap = $false
        $retainedHooks = New-Object System.Collections.Generic.List[object]
        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) { $retainedHooks.Add($hook); continue }
            $isBootstrap = Test-InstallerOwnedBootstrapHook -Hook $hook -BootstrapHookPath $BootstrapHookPath
            if ($isBootstrap) { $removedBootstrap = $true }
            else { $retainedHooks.Add($hook) }
        }
        if (-not $removedBootstrap) { $retained.Add($entry); continue }
        if ($retainedHooks.Count -gt 0) {
            $entry.PSObject.Properties['hooks'].Value = @($retainedHooks.ToArray())
            $retained.Add($entry)
        }
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

$archiveSourceWorkingRoot = $null
try {
if ($Acquisition -ceq 'git-checkout') {
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = ((Invoke-InstallerGit -WorkingDirectory (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
    }
    $repositoryRootPath = Get-InstallerFullDirectoryPath -Path $RepositoryRoot
    $originUrl = ((Invoke-InstallerGit -WorkingDirectory $repositoryRootPath -Arguments @('remote','get-url','origin')) | Select-Object -First 1).Trim()
    Assert-InstallerCanonicalRepository -Repository $originUrl
    $catalogRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $catalogRef = ((Invoke-InstallerGit -WorkingDirectory $repositoryRootPath -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($SourceRepository)) { Assert-InstallerCanonicalRepository -Repository $SourceRepository }
    if (-not [string]::IsNullOrWhiteSpace($SourceCommit) -and $SourceCommit -cne $catalogRef) { throw 'SourceCommit does not match the git checkout HEAD.' }
    $ArchiveSha256 = $null
}
else {
    if ([string]::IsNullOrWhiteSpace($SourceRepository) -or [string]::IsNullOrWhiteSpace($SourceCommit)) {
        throw 'github-codeload installation requires SourceRepository and SourceCommit.'
    }
    Assert-InstallerCanonicalRepository -Repository $SourceRepository
    if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'SourceCommit must be a full lowercase 40-character commit SHA.' }
    if ($ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'github-codeload installation requires ArchiveSha256.' }
    if ([string]::IsNullOrWhiteSpace($SourceArchivePath) -or -not (Test-Path -LiteralPath $SourceArchivePath -PathType Leaf)) {
        throw 'github-codeload installation requires the downloaded SourceArchivePath.'
    }
    $actualArchiveSha256 = Get-InstallerFileSha256 -Path $SourceArchivePath
    if ($actualArchiveSha256 -cne $ArchiveSha256) {
        throw "github-codeload SourceArchivePath SHA-256 does not match ArchiveSha256: expected $ArchiveSha256; actual $actualArchiveSha256."
    }
    $tempRootPath = Get-InstallerFullDirectoryPath -Path ([System.IO.Path]::GetTempPath())
    $archiveSourceWorkingRoot = Join-Path $tempRootPath ('ai-instructions-installer-source-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $archiveSourceWorkingRoot | Out-Null
    try {
        Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
        $repositoryRootPath = Expand-SafeZipRepository -ArchivePath $SourceArchivePath -DestinationRoot $archiveSourceWorkingRoot
    }
    catch {
        throw "github-codeload archive cannot supply the verified runtime sources: $($_.Exception.Message)"
    }
    $catalogRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $catalogRef = $SourceCommit
}
if ($catalogRef -cnotmatch '^[0-9a-f]{40}$') { throw 'Installer source commit must be a full lowercase 40-character commit SHA.' }
if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit) -and $ExpectedCurrentCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'ExpectedCurrentCommit must be a full lowercase 40-character commit SHA.'
}
$expectedPolicyValues = @(@($ExpectedUpdateMode,$ExpectedUpdateChannel,$ExpectedUpdateRef) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$expectedPolicySpecified = $expectedPolicyValues.Count -gt 0
if ($expectedPolicySpecified -and $expectedPolicyValues.Count -ne 3) {
    throw 'ExpectedUpdateMode, ExpectedUpdateChannel, and ExpectedUpdateRef must be supplied together.'
}
if ($expectedPolicySpecified) {
    if ($ExpectedUpdateMode -cnotin @('notify-only','auto-install-approved')) { throw "Unsupported ExpectedUpdateMode '$ExpectedUpdateMode'." }
    if ($ExpectedUpdateChannel -cnotin @('protected-branch','github-release')) { throw "Unsupported ExpectedUpdateChannel '$ExpectedUpdateChannel'." }
    if (($ExpectedUpdateChannel -ceq 'protected-branch' -and $ExpectedUpdateRef -cne 'main') -or
        ($ExpectedUpdateChannel -ceq 'github-release' -and $ExpectedUpdateRef -cne 'latest')) {
        throw 'Expected update channel/ref combination is invalid.'
    }
}

$runtimeFiles = @(
    'bootstrap-ai-instructions-installed.ps1','bootstrap-ai-instructions-multisource.ps1','bootstrap-ai-instructions.ps1','safe-zip.psm1',
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
        if ($Acquisition -ceq 'github-codeload') { throw "github-codeload archive runtime source was not found: $relativePath" }
        throw "Installer runtime source was not found: $relativePath"
    }
}
if ($Acquisition -ceq 'git-checkout') { Assert-InstallerSourcesMatchHead -Repository $repositoryRootPath -RelativePaths $relativeSourcePaths }

$runtimeContractSource = Join-Path $repositoryRootPath 'scripts\ai-instructions-runtime-contract.psm1'
Import-Module $runtimeContractSource -Force

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$codexHomePath = Get-InstallerFullDirectoryPath -Path $CodexHome
$codexHomeRoot = [System.IO.Path]::GetPathRoot($codexHomePath)
if (-not [string]::IsNullOrWhiteSpace($codexHomeRoot) -and $codexHomePath.Equals($codexHomeRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Codex Home must not be a filesystem root: $codexHomePath"
}
$hookDirectory = Join-Path $codexHomePath 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'
$updateScript = Join-Path $hookDirectory 'update-ai-instructions.ps1'
$cleanupScript = Join-Path $hookDirectory 'cleanup-ai-instructions-pollution.ps1'
$runtimeDirectory = Join-Path $hookDirectory 'ai-instructions-runtime'
$agentsPath = Join-Path $codexHomePath 'AGENTS.md'
$hooksPath = Join-Path $codexHomePath 'hooks.json'
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
Assert-InstallerMutationPath -Path $codexHomePath -ExpectedType Directory
Assert-InstallerMutationPath -Path $hookDirectory -ExpectedType Directory
Assert-InstallerMutationPath -Path $runtimeDirectory -ExpectedType Directory
foreach ($filePath in @($hookScript,$updateScript,$cleanupScript,$agentsPath,$hooksPath,$configurationPath,(Join-Path $codexHomePath 'ai-instructions-install.lock'))) {
    Assert-InstallerMutationPath -Path $filePath -ExpectedType File
}
New-Item -ItemType Directory -Force -Path $codexHomePath,$hookDirectory | Out-Null
$installLockPath = Join-Path $codexHomePath 'ai-instructions-install.lock'
$installLockStream = $null
try {
    try {
        $installLockStream = [System.IO.File]::Open($installLockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw 'Another AI instructions installer is already running for this Codex Home.'
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentCommit)) {
        $installedBundlePath = Join-Path $runtimeDirectory 'runtime-bundle.json'
        try {
            $installedBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $installedBundlePath | ConvertFrom-Json
            $installedConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
            Assert-AiInstructionsRuntimeBundleV2 `
                -Bundle $installedBundle `
                -Configuration $installedConfiguration `
                -RuntimeRoot $runtimeDirectory | Out-Null
        }
        catch {
            throw "The installed runtime changed before installation; the candidate transaction must be resolved again. $($_.Exception.Message)"
        }
        if ([string]$installedBundle.commit -cne $ExpectedCurrentCommit) {
            throw 'The installed runtime changed before installation; the candidate transaction must be resolved again.'
        }
    }

    $existingConfiguration = $null
    if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
        try { $existingConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json }
        catch { throw "AI instruction sync configuration is not valid JSON: $configurationPath" }
    }
    if ($expectedPolicySpecified) {
        try { Assert-AiInstructionsSyncConfigurationV4 -Configuration $existingConfiguration | Out-Null }
        catch { throw 'The active runtime update policy changed before installation; candidate approval must be resolved again.' }
        if ([string]$existingConfiguration.updates.mode -cne $ExpectedUpdateMode -or
            [string]$existingConfiguration.updates.channel -cne $ExpectedUpdateChannel -or
            [string]$existingConfiguration.updates.ref -cne $ExpectedUpdateRef) {
            throw 'The active runtime update policy changed before installation; candidate approval must be resolved again.'
        }
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
    $retainRecoveryBackup = $false
    try {
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
        $runtimeBackedUp=$false; $runtimeInstalled=$false
        try {
            Copy-Item -LiteralPath $stagingLauncher -Destination $hookScript -Force
            Copy-Item -LiteralPath $stagingUpdater -Destination $updateScript -Force
            Copy-Item -LiteralPath $stagingCleanup -Destination $cleanupScript -Force
            if ($hadRuntime) { Move-Item -LiteralPath $runtimeDirectory -Destination $backupRuntime; $runtimeBackedUp=$true }
            Move-Item -LiteralPath $stagingRuntime -Destination $runtimeDirectory; $runtimeInstalled=$true
            Copy-Item -LiteralPath $stagingConfiguration -Destination $configurationPath -Force
            Set-InstallerBootstrapSection -AgentsPath $agentsPath -Section $bootstrapSection
            Remove-InstallerSessionStartHook -HooksPath $hooksPath -BootstrapHookPath $hookScript
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
            }
            catch {
                $retainRecoveryBackup = $true
                throw "AI instructions installation failed and rollback also failed. Recovery backup retained at '$backupRoot'. Original error: $($installError.Exception.Message). Rollback error: $($_.Exception.Message)"
            }
            throw $installError
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            $safeStagingRoot = Assert-InstallerSafeChildDirectory -Parent $codexHomePath -Path $stagingRoot -LeafPrefix '.ai-instructions-install-'
            Remove-Item -LiteralPath $safeStagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not $retainRecoveryBackup -and (Test-Path -LiteralPath $backupRoot)) {
            $safeBackupRoot = Assert-InstallerSafeChildDirectory -Parent $codexHomePath -Path $backupRoot -LeafPrefix '.ai-instructions-backup-'
            Remove-Item -LiteralPath $safeBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($null -ne $installLockStream) { $installLockStream.Dispose() }
}

Write-Output "Installed AI instructions bootstrap launcher: $hookScript"
Write-Output "Installed AI instructions manual updater: $updateScript"
Write-Output "Installed AI instructions pollution cleanup command: $cleanupScript"
Write-Output "Installed immutable runtime bundle: $runtimeDirectory"
Write-Output "Updated AI instructions sync configuration schema v4: $configurationPath"
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($archiveSourceWorkingRoot) -and (Test-Path -LiteralPath $archiveSourceWorkingRoot)) {
        $resolvedTempRoot = Get-InstallerFullDirectoryPath -Path ([System.IO.Path]::GetTempPath())
        $resolvedArchiveSourceRoot = Assert-InstallerSafeChildDirectory -Parent $resolvedTempRoot -Path $archiveSourceWorkingRoot -LeafPrefix 'ai-instructions-installer-source-'
        Remove-Item -LiteralPath $resolvedArchiveSourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
