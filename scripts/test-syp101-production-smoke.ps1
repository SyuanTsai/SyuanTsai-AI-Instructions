[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $EvidencePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module (Join-Path $PSScriptRoot 'syp101-production-smoke-contract.psm1') -Force

function Invoke-SmokeGit {
    param([string]$Repository,[string[]]$Arguments)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Get-RawSha256 {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-ManagedSnapshot {
    param([string]$TargetRoot,[object]$Manifest)
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Manifest.files | Sort-Object targetPath)) {
        $relative = [string]$entry.targetPath
        $path = Join-Path $TargetRoot $relative.Replace('/','\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Managed smoke file is missing: $relative" }
        $rows.Add("$relative`t$(Get-RawSha256 -Path $path)")
    }
    $manifestPath = Join-Path $TargetRoot '.codex\ai-instructions.manifest.json'
    $rows.Add(".codex/ai-instructions.manifest.json`t$(Get-RawSha256 -Path $manifestPath)")
    return @($rows.ToArray())
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = ((Invoke-SmokeGit -Repository (Get-Location).Path -Arguments @('rev-parse','--show-toplevel')) | Select-Object -First 1).Trim()
}
$repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('syp101-production-smoke-' + [Guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $tempRoot '.codex'
$targetRoot = Join-Path $tempRoot 'target'
$userHome = Join-Path $tempRoot 'user'
$candidateCommit = ((Invoke-SmokeGit $repositoryRootPath @('rev-parse','HEAD')) | Select-Object -First 1).Trim()

try {
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('init','--quiet') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('config','user.name','SYP101 Production Smoke') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('config','user.email','syp101-smoke@example.test') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('remote','add','origin','https://example.com/smoke/branch-independent-target.git') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $targetRoot 'README.md'),"# SYP101 production smoke`n",(New-Object System.Text.UTF8Encoding($false)))
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('add','--','README.md') | Out-Null
    Invoke-SmokeGit -Repository $targetRoot -Arguments @('commit','--quiet','-m','initial smoke target') | Out-Null

    & (Join-Path $repositoryRootPath 'scripts\install-ai-instructions-bootstrap.ps1') -RepositoryRoot $repositoryRootPath -CodexHome $codexHome
    $hook = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) { throw 'Production smoke installer did not create the installed launcher.' }

    $bundle=Get-Content -Raw (Join-Path $codexHome 'hooks/ai-instructions-runtime/runtime-bundle.json') | ConvertFrom-Json
    if ($bundle.commit -cne $candidateCommit) { throw 'Smoke installed runtime differs from the candidate commit.' }
    $configuration=Get-Content -Raw (Join-Path $codexHome 'ai-instructions-sync.json') | ConvertFrom-Json
    if ($configuration.updates.mode -cne 'notify-only') { throw 'Smoke must retain notify-only.' }
    $environmentHook=Join-Path $codexHome 'hooks/update-agent-environment.ps1'
    $result=@(& $environmentHook -CodexHome $codexHome -UserHome $userHome -Apply -OutputFormat Json)
    $environment=($result -join "`n") | ConvertFrom-Json
    if ($environment.exitCode -ne 0 -or $environment.outcome -cne 'applied') { throw 'Smoke USER reconciliation failed.' }
    $userManifestPath=Join-Path $userHome '.agents/catalog-skills.manifest.json'
    $userManifest=Get-Content -Raw $userManifestPath | ConvertFrom-Json
    if (@($userManifest.files).Count -lt 1) { throw 'Smoke installed no real USER Skills.' }
    $userBefore=@($userManifest.files | Sort-Object targetPath | ForEach-Object { "$($_.targetPath)`t$(Get-RawSha256 (Join-Path $userHome $_.targetPath))" })
    $userManifestBefore=Get-RawSha256 $userManifestPath
    $projectRelative=".agents/skills/$($userManifest.files[0].skillId)/SKILL.md"
    $projectPath=Join-Path $targetRoot $projectRelative
    New-Item -ItemType Directory -Force -Path (Split-Path $projectPath) | Out-Null
    [IO.File]::WriteAllText($projectPath,'project-owned Skill')
    Invoke-SmokeGit $targetRoot @('add','--',$projectRelative) | Out-Null
    Invoke-SmokeGit $targetRoot @('commit','-qm','project Skill') | Out-Null
    $initialHead=((Invoke-SmokeGit $targetRoot @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    $initialIndex=Get-RawSha256 (Join-Path $targetRoot '.git/index')
    & $hook -TargetRoot $targetRoot -UserHome $userHome -SkipUpdateCheck

    $manifestPath = Join-Path $targetRoot '.codex\ai-instructions.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Production smoke did not create manifest v2.' }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2) { throw "Production smoke expected manifest schemaVersion 2; actual: $($manifest.schemaVersion)" }
    $skillEntries = @($manifest.files | Where-Object { $_.artifactType -eq 'skill' })
    if ($skillEntries.Count -ne 0) { throw 'Production smoke found forbidden consumer shared Skill entries.' }
    if (@(Get-ChildItem (Join-Path $targetRoot '.agents/skills') -Recurse -File -Force).Count -ne 1 -or
        [IO.File]::ReadAllText($projectPath) -cne 'project-owned Skill') { throw 'Consumer Skills differ from the protected project Skill.' }

    $beforeSnapshot = @(Get-ManagedSnapshot -TargetRoot $targetRoot -Manifest $manifest)
    Assert-Syp101SmokeRepositoryClean -Repository $targetRoot -Phase 'the first bootstrap'
    $beforeStatus = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('status','--porcelain')))
    $beforeStashes = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('stash','list','--format=%H%x00%gs')))
    if (@($beforeStashes | Where-Object { $_ -match 'PersonalAgent' }).Count -ne 1) {
        throw 'Production smoke expected exactly one retained PersonalAgent recovery stash after the first sync.'
    }
    $headAfterFirst = ((Invoke-SmokeGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if ($headAfterFirst -cne $initialHead) { throw 'Branch-independent production smoke unexpectedly committed the bootstrap.' }

    Invoke-SmokeGit -Repository $targetRoot -Arguments @('config','core.autocrlf','true') | Out-Null
    & $hook -TargetRoot $targetRoot -UserHome $userHome -SkipUpdateCheck

    $manifestAfter = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $afterSnapshot = @(Get-ManagedSnapshot -TargetRoot $targetRoot -Manifest $manifestAfter)
    $afterStatus = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('status','--porcelain')))
    $afterStashes = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('stash','list','--format=%H%x00%gs')))

    Assert-Syp101SmokeRepositoryClean -Repository $targetRoot -Phase 'the second bootstrap'
    if (($beforeSnapshot -join "`n") -cne ($afterSnapshot -join "`n")) { throw 'Second production smoke sync changed managed file bytes.' }
    if (($beforeStatus -join "`n") -cne ($afterStatus -join "`n")) { throw 'Second production smoke sync changed working-tree status.' }
    if (($beforeStashes -join "`n") -cne ($afterStashes -join "`n")) { throw 'Second production smoke sync replaced or added a PersonalAgent stash.' }
    $headAfterSecond = ((Invoke-SmokeGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if ($headAfterSecond -cne $initialHead) { throw 'Second branch-independent production smoke unexpectedly committed changes.' }

    $userAfter=@($userManifest.files | Sort-Object targetPath | ForEach-Object { "$($_.targetPath)`t$(Get-RawSha256 (Join-Path $userHome $_.targetPath))" })
    if (($userBefore -join "`n") -cne ($userAfter -join "`n") -or $userManifestBefore -cne (Get-RawSha256 $userManifestPath)) { throw 'Bootstrap changed USER installation bytes.' }
    if ((Get-RawSha256 (Join-Path $targetRoot '.git/index')) -cne $initialIndex) { throw 'Bootstrap changed the project index.' }
    if ([IO.File]::ReadAllText($projectPath) -cne 'project-owned Skill') { throw 'Second bootstrap changed the project Skill.' }
    $evidence=[ordered]@{
        schemaVersion=1; candidateCommit=$candidateCommit; installedRuntimeCommit=$bundle.commit
        runtimeInventorySha256=$bundle.inventorySha256; catalogLockSha256=(Get-RawSha256 (Join-Path $codexHome 'hooks/ai-instructions-runtime/catalog/skills-catalog-lock.json'))
        updateMode=$configuration.updates.mode; userSkillCount=@($userManifest.files.skillId | Sort-Object -Unique).Count
        userFileCount=@($userManifest.files).Count; consumerSharedSkillEntries=$skillEntries.Count
        bootstrapRuns=2; managedBytesStable=$true; userBytesStable=$true; projectSkillPreserved=$true
        indexStable=$true; headStable=$true; statusClean=$true; recoveryEvidenceStable=$true
        hostPlatform=[Environment]::OSVersion.Platform.ToString(); powershellVersion=$PSVersionTable.PSVersion.ToString()
        realUserDeployment='not-run-SYP-259'; codexCopilotUiDiscovery='not-run-SYP-259'
    }
    if ($EvidencePath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),($evidence | ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false)) }
    Write-Output "SYP101/SYP214 production smoke passed: USER $($evidence.userSkillCount) Skills / $($evidence.userFileCount) files; consumer shared entries 0; candidate $candidateCommit."

}
finally {
    $resolvedTemp=[IO.Path]::GetFullPath($tempRoot)
    $allowedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($allowedTemp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedTemp) -notlike 'syp101-production-smoke-*') { throw 'Unsafe smoke cleanup path.' }
    if (Test-Path -LiteralPath $resolvedTemp) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue }
}
