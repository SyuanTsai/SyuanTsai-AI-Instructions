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

function Get-SmokeFileInventory {
    param([string]$Root,[string[]]$RelativePaths)
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    foreach ($relative in @($RelativePaths | Sort-Object -Unique)) {
        $normalized = ([string]$relative).Replace('\','/')
        $path = Join-Path $resolvedRoot $normalized.Replace('/', [string][System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -Force -LiteralPath $path
            if ($item.PSIsContainer) {
                [ordered]@{ relativePath = $normalized; type = 'directory'; length = $null; sha256 = $null }
            } else {
                [ordered]@{ relativePath = $normalized; type = 'file'; length = [long]$item.Length; sha256 = Get-RawSha256 -Path $path }
            }
        } else {
            [ordered]@{ relativePath = $normalized; type = 'missing'; length = $null; sha256 = $null }
        }
    }
}

function Get-ManagedSnapshot {
    param([string]$TargetRoot,[object]$Manifest)
    $relativePaths = @(@($Manifest.files | ForEach-Object { [string]$_.targetPath }) + @('.codex/ai-instructions.manifest.json'))
    $rows = @(Get-SmokeFileInventory -Root $TargetRoot -RelativePaths $relativePaths)
    $missing = @($rows | Where-Object { $_.type -ne 'file' })
    if ($missing.Count -ne 0) { throw "Managed smoke files are missing or not regular files: $(($missing.relativePath) -join ', ')" }
    return $rows
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
$candidateTree = ((Invoke-SmokeGit $repositoryRootPath @('rev-parse','HEAD^{tree}')) | Select-Object -First 1).Trim()
$bootstrapRuns = 0

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
    $userRelativePaths=@(@($userManifest.files | ForEach-Object { [string]$_.targetPath }) + @('.agents/catalog-skills.manifest.json'))
    $userBefore=@(Get-SmokeFileInventory -Root $userHome -RelativePaths $userRelativePaths)
    $userManifestBefore=Get-RawSha256 $userManifestPath
    $projectRelative=".agents/skills/$($userManifest.files[0].skillId)/SKILL.md"
    $projectPath=Join-Path $targetRoot $projectRelative
    New-Item -ItemType Directory -Force -Path (Split-Path $projectPath) | Out-Null
    [IO.File]::WriteAllText($projectPath,'project-owned Skill')
    Invoke-SmokeGit $targetRoot @('add','--',$projectRelative) | Out-Null
    Invoke-SmokeGit $targetRoot @('commit','-qm','project Skill') | Out-Null
    $initialHead=((Invoke-SmokeGit $targetRoot @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    $initialIndex=Get-RawSha256 (Join-Path $targetRoot '.git/index')
    $projectBefore=@(Get-SmokeFileInventory -Root $targetRoot -RelativePaths @($projectRelative))
    & $hook -TargetRoot $targetRoot -UserHome $userHome -SkipUpdateCheck
    $bootstrapRuns++

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
    $bootstrapRuns++

    $manifestAfter = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $afterSnapshot = @(Get-ManagedSnapshot -TargetRoot $targetRoot -Manifest $manifestAfter)
    $afterStatus = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('status','--porcelain')))
    $afterStashes = @((Invoke-SmokeGit -Repository $targetRoot -Arguments @('stash','list','--format=%H%x00%gs')))

    Assert-Syp101SmokeRepositoryClean -Repository $targetRoot -Phase 'the second bootstrap'
    $managedBytesStable = (ConvertTo-Json -InputObject @($beforeSnapshot) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($afterSnapshot) -Depth 6 -Compress)
    if (-not $managedBytesStable) { throw 'Second production smoke sync changed managed file bytes.' }
    if (($beforeStatus -join "`n") -cne ($afterStatus -join "`n")) { throw 'Second production smoke sync changed working-tree status.' }
    if (($beforeStashes -join "`n") -cne ($afterStashes -join "`n")) { throw 'Second production smoke sync replaced or added a PersonalAgent stash.' }
    $headAfterSecond = ((Invoke-SmokeGit -Repository $targetRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
    if ($headAfterSecond -cne $initialHead) { throw 'Second branch-independent production smoke unexpectedly committed changes.' }

    $userAfter=@(Get-SmokeFileInventory -Root $userHome -RelativePaths $userRelativePaths)
    $userBytesStable = (ConvertTo-Json -InputObject @($userBefore) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($userAfter) -Depth 6 -Compress)
    $userManifestBytesStable = $userManifestBefore -ceq (Get-RawSha256 $userManifestPath)
    if (-not $userBytesStable -or -not $userManifestBytesStable) { throw 'Bootstrap changed USER installation bytes.' }
    $indexAfterSecond=Get-RawSha256 (Join-Path $targetRoot '.git/index')
    if ($indexAfterSecond -cne $initialIndex) { throw 'Bootstrap changed the project index.' }
    if ([IO.File]::ReadAllText($projectPath) -cne 'project-owned Skill') { throw 'Second bootstrap changed the project Skill.' }
    $projectAfter=@(Get-SmokeFileInventory -Root $targetRoot -RelativePaths @($projectRelative))
    $projectSkillPreserved=(ConvertTo-Json -InputObject @($projectBefore) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($projectAfter) -Depth 6 -Compress)
    if (-not $projectSkillPreserved) { throw 'Second bootstrap changed the project Skill bytes.' }
    $headStable=($headAfterFirst -ceq $initialHead -and $headAfterSecond -ceq $initialHead)
    $statusClean=(@($beforeStatus).Count -eq 0 -and @($afterStatus).Count -eq 0)
    $recoveryEvidenceStable=(($beforeStashes -join "`n") -ceq ($afterStashes -join "`n"))
    if (-not $headStable -or -not $statusClean -or -not $recoveryEvidenceStable) { throw 'Production smoke Git state measurements do not satisfy the preserved-state assertions.' }
    $sourceHeadCommit=[string]$env:SYP101_SOURCE_HEAD_SHA
    $runIdentity=[ordered]@{
        runId=[string]$env:GITHUB_RUN_ID; runAttempt=[string]$env:GITHUB_RUN_ATTEMPT
        workflow=[string]$env:GITHUB_WORKFLOW; event=[string]$env:GITHUB_EVENT_NAME; ref=[string]$env:GITHUB_REF
        sourceHeadCommit=$sourceHeadCommit; checkoutHeadCommit=$candidateCommit; checkoutTree=$candidateTree
    }
    $scriptHashes=[ordered]@{
        smokeScriptSha256=(Get-RawSha256 -Path $PSCommandPath)
        installerSha256=(Get-RawSha256 -Path (Join-Path $repositoryRootPath 'scripts/install-ai-instructions-bootstrap.ps1'))
        bootstrapSha256=(Get-RawSha256 -Path (Join-Path $repositoryRootPath 'scripts/bootstrap-ai-instructions.ps1'))
        environmentHookSha256=(Get-RawSha256 -Path $environmentHook)
        smokeContractSha256=(Get-RawSha256 -Path (Join-Path $PSScriptRoot 'syp101-production-smoke-contract.psm1'))
    }
    $evidence=[ordered]@{
        schemaVersion=2; runIdentity=$runIdentity; candidateCommit=$candidateCommit; candidateTree=$candidateTree; installedRuntimeCommit=$bundle.commit
        scriptHashes=$scriptHashes
        runtimeInventorySha256=$bundle.inventorySha256; catalogLockSha256=(Get-RawSha256 (Join-Path $codexHome 'hooks/ai-instructions-runtime/catalog/skills-catalog-lock.json'))
        updateMode=$configuration.updates.mode; userSkillCount=@($userManifest.files.skillId | Sort-Object -Unique).Count
        userFileCount=@($userManifest.files).Count; consumerSharedSkillEntries=$skillEntries.Count
        bootstrapRuns=$bootstrapRuns; managedBytesStable=$managedBytesStable; userBytesStable=$userBytesStable
        userManifestBytesStable=$userManifestBytesStable; projectSkillPreserved=$projectSkillPreserved
        indexStable=($initialIndex -ceq $indexAfterSecond); headStable=$headStable; statusClean=$statusClean; recoveryEvidenceStable=$recoveryEvidenceStable
        observed=[ordered]@{
            managedFilesBefore=@($beforeSnapshot); managedFilesAfter=@($afterSnapshot)
            userFilesBefore=@($userBefore); userFilesAfter=@($userAfter)
            projectSkillBefore=@($projectBefore); projectSkillAfter=@($projectAfter)
            userManifestSha256Before=$userManifestBefore; userManifestSha256After=(Get-RawSha256 $userManifestPath)
            git=[ordered]@{
                headBefore=$initialHead; headAfterFirst=$headAfterFirst; headAfterSecond=$headAfterSecond
                indexSha256Before=$initialIndex; indexSha256AfterSecond=$indexAfterSecond
                statusAfterFirst=@($beforeStatus); statusAfterSecond=@($afterStatus)
                stashesAfterFirst=@($beforeStashes); stashesAfterSecond=@($afterStashes)
            }
        }
        hostPlatform=[Environment]::OSVersion.Platform.ToString(); powershellVersion=$PSVersionTable.PSVersion.ToString()
        powershellExecutable=[IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
        realUserDeployment='not-run-SYP-259'; codexCopilotUiDiscovery='not-run-SYP-259'
    }
    if ($EvidencePath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),($evidence | ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false)) }
    Write-Output "SYP101/SYP214 production smoke passed: USER $($evidence.userSkillCount) Skills / $($evidence.userFileCount) files; consumer shared entries 0; candidate $candidateCommit."

}
finally {
    $resolvedTemp=[IO.Path]::GetFullPath($tempRoot)
    $allowedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($allowedTemp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedTemp) -notlike 'syp101-production-smoke-*') { throw 'Unsafe smoke cleanup path.' }
    if (Test-Path -LiteralPath $resolvedTemp) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue }
}
