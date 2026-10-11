[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $BaselineRoot,
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $BaselineGeneralArchive,
    [Parameter(Mandatory = $true)][string] $CandidateGeneralArchive,
    [Parameter(Mandatory = $true)][string] $BaselineCodeCollaborationArchive,
    [Parameter(Mandatory = $true)][string] $CandidateCodeCollaborationArchive,
    [Parameter(Mandatory = $true)][string] $EvidenceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Phase
    )
    $global:LASTEXITCODE = $null
    $output = & git -C $RepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = [string]::Join("`n", @($output | ForEach-Object { [string]$_ }))
        throw "$Phase failed with git exit code $exitCode. $details"
    }
    return [string]::Join("`n", @($output | ForEach-Object { [string]$_ })).Trim()
}

function ConvertTo-CanonicalGitHubRepositoryUrl {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)

    $hostName = ''
    $path = ''
    if ($RepositoryUrl -match '^git@(?<host>github\.com):(?<path>[^?#]+)$') {
        $hostName = [string]$Matches.host
        $path = [string]$Matches.path
    }
    elseif ($RepositoryUrl -match '^ssh://git@(?<host>github\.com)/(?<path>[^?#]+)$') {
        $hostName = [string]$Matches.host
        $path = [string]$Matches.path
    }
    else {
        $uri = $null
        if (-not [System.Uri]::TryCreate($RepositoryUrl, [System.UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or $uri.Host -ine 'github.com' -or
            -not [string]::IsNullOrEmpty($uri.UserInfo) -or
            -not [string]::IsNullOrEmpty($uri.Query) -or
            -not [string]::IsNullOrEmpty($uri.Fragment)) {
            throw "Repository origin must be a credential-free GitHub HTTPS or SSH URL: $RepositoryUrl"
        }
        $hostName = $uri.Host
        $path = $uri.AbsolutePath.Trim('/')
    }

    if ($hostName -ine 'github.com') { throw 'Repository origin must use github.com.' }
    $path = $path.Trim('/')
    if ($path.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(0, $path.Length - 4)
    }
    $parts = @($path.Split('/'))
    if ($parts.Count -ne 2 -or
        $parts[0] -notmatch '^[A-Za-z0-9_.-]+$' -or
        $parts[1] -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "Repository origin must identify one GitHub owner/repository pair: $RepositoryUrl"
    }
    return "https://github.com/$($parts[0])/$($parts[1])"
}

function Get-GitRepositoryIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $Name,
        [switch] $RequireClean
    )
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "$Name checkout does not exist: $root" }

    $actualRoot = [System.IO.Path]::GetFullPath((Invoke-GitText -RepositoryRoot $root -Arguments @('rev-parse','--show-toplevel') -Phase "$Name repository root")).TrimEnd([char[]]@('\','/'))
    if (-not [string]::Equals($root, $actualRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name root must be a top-level Git checkout."
    }
    $commit = Invoke-GitText -RepositoryRoot $root -Arguments @('rev-parse','HEAD') -Phase "$Name HEAD"
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw "$Name checkout must resolve to a full lowercase Git commit SHA." }

    $rawOrigin = Invoke-GitText -RepositoryRoot $root -Arguments @('remote','get-url','origin') -Phase "$Name origin"
    if ([string]::IsNullOrWhiteSpace($rawOrigin) -or $rawOrigin.Contains("`n")) {
        throw "$Name checkout must have exactly one origin URL."
    }
    $repositoryUrl = ConvertTo-CanonicalGitHubRepositoryUrl -RepositoryUrl $rawOrigin

    $status = Invoke-GitText -RepositoryRoot $root -Arguments @('status','--porcelain=v1','--untracked-files=all','--ignore-submodules=none') -Phase "$Name working-tree status"
    if ($RequireClean -and -not [string]::IsNullOrWhiteSpace($status)) {
        throw "$Name checkout must be clean before lifecycle evidence is generated."
    }

    return [pscustomobject][ordered]@{
        root = $root
        repositoryUrl = $repositoryUrl
        commit = $commit
        workingTreeClean = [string]::IsNullOrWhiteSpace($status)
    }
}

function Assert-PathOutsideRepository {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $RepositoryRoot)
    $pathValue = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $rootValue = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\','/'))
    $rootPrefix = $rootValue + [System.IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($pathValue, $rootValue, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathValue.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'EvidenceRoot must be outside every repository used by this lifecycle.'
    }
}

function New-RepositorySnapshot {
    param(
        [Parameter(Mandatory = $true)][object] $RepositoryIdentity,
        [Parameter(Mandatory = $true)][string] $EvidenceRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $archivePath = Join-Path $EvidenceRoot "$Name-commit-catalog-runtime.zip"
    [void](Invoke-GitText -RepositoryRoot ([string]$RepositoryIdentity.root) `
        -Arguments @('archive','--format=zip',"--output=$archivePath",[string]$RepositoryIdentity.commit,'--','catalog','scripts') `
        -Phase "$Name committed catalog/runtime archive")
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "$Name committed archive was not created." }

    $snapshotRoot = Join-Path $EvidenceRoot "$Name-commit-snapshot"
    [void](New-Item -ItemType Directory -Path $snapshotRoot -Force)
    Expand-Archive -LiteralPath $archivePath -DestinationPath $snapshotRoot
    foreach ($relative in @('catalog/skills-catalog.json','catalog/skills-catalog.sources.json','catalog/skills-catalog-lock.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $snapshotRoot $relative) -PathType Leaf)) {
            throw "$Name committed snapshot is missing $relative."
        }
    }

    $catalogPath = Join-Path $snapshotRoot 'catalog/skills-catalog.json'
    $lockPath = Join-Path $snapshotRoot 'catalog/skills-catalog-lock.json'
    $catalogSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $catalogPath).Hash.ToLowerInvariant()
    $lock = Get-Content -Raw -Encoding UTF8 -LiteralPath $lockPath | ConvertFrom-Json -Depth 50
    if ([string]$lock.catalogSha256 -cne $catalogSha) {
        throw "$Name committed Catalog lock does not match the committed Catalog bytes."
    }
    return [pscustomobject][ordered]@{
        root = $snapshotRoot
        archiveSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
        catalogSha256 = $catalogSha
        lockSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $lockPath).Hash.ToLowerInvariant()
    }
}

function New-RuntimeProjection {
    param([string] $RepositorySnapshot, [string] $Destination)
    [void](New-Item -ItemType Directory -Path (Join-Path $Destination 'catalog') -Force)
    Copy-Item -LiteralPath (Join-Path $RepositorySnapshot 'catalog/skills-catalog.json') -Destination (Join-Path $Destination 'catalog/skills-catalog.json')
    Copy-Item -LiteralPath (Join-Path $RepositorySnapshot 'catalog/skills-catalog-lock.json') -Destination (Join-Path $Destination 'catalog/skills-catalog-lock.json')
    Get-ChildItem -LiteralPath (Join-Path $RepositorySnapshot 'scripts') -Filter '*.psm1' -File |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Destination $_.Name) }
}

function New-LocalArchiveOverrides {
    param([string] $GeneralArchive, [string] $CodeCollaborationArchive)
    return @{
        general = [System.IO.Path]::GetFullPath($GeneralArchive)
        'code-collaboration' = [System.IO.Path]::GetFullPath($CodeCollaborationArchive)
    }
}

function Assert-SkillIds {
    param([string[]] $Actual, [string[]] $Expected, [string] $Phase)
    $actualSorted = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $expectedSorted = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if (($actualSorted -join ',') -cne ($expectedSorted -join ',')) {
        throw "$Phase expected Skill IDs '$($expectedSorted -join ',')', got '$($actualSorted -join ',')'."
    }
}

function Assert-Result {
    param([object] $Result, [string] $Expected, [string] $Phase)
    if ([string]$Result.outcome -cne $Expected -or [int]$Result.exitCode -ne 0) {
        throw "$Phase expected $Expected/0, got $($Result.outcome)/$($Result.exitCode)."
    }
}

function Assert-BlockedResult {
    param([object] $Result, [string] $ExpectedCode, [string] $ExpectedPath, [string] $Phase)
    if ([string]$Result.outcome -cne 'failed' -or [int]$Result.exitCode -ne 1) {
        throw "$Phase expected failed/1, got $($Result.outcome)/$($Result.exitCode)."
    }
    $details = @($Result.failureDetails | Where-Object { [string]$_.code -ceq $ExpectedCode })
    if ($details.Count -ne 1) { throw "$Phase expected one '$ExpectedCode' failure detail." }
    if ([string]$details[0].path -cne $ExpectedPath -or [bool]$details[0].destructiveChangeAllowed -or [bool]$details[0].backupCreated) {
        throw "$Phase returned unexpected path or destructive ownership evidence."
    }
    return $details[0]
}

function Assert-SkillState {
    param([string] $UserRoot, [string[]] $Expected, [string] $Phase)
    $manifestPath = Join-Path $UserRoot '.agents/catalog-skills.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "${Phase}: manifest missing." }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $actual = @($manifest.files | ForEach-Object { [string]$_.skillId } | Sort-Object -Unique)
    $wanted = @($Expected | Sort-Object -Unique)
    if (($actual -join ',') -cne ($wanted -join ',')) {
        throw "${Phase}: expected Skills '$($wanted -join ',')', got '$($actual -join ',')'."
    }
    foreach ($skillId in $wanted) {
        $skillPath = Join-Path $UserRoot ".agents/skills/$skillId/SKILL.md"
        if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { throw "${Phase}: $skillId is missing." }
    }
    foreach ($skillId in @('manage-ai-memory','manage-notion-ai-memory')) {
        if ($wanted -cnotcontains $skillId -and (Test-Path -LiteralPath (Join-Path $UserRoot ".agents/skills/$skillId"))) {
            throw "${Phase}: inactive $skillId remains in the isolated user root."
        }
    }
}

function Get-BackupEntryCount {
    param([string] $UserRoot)
    $backupRoot = Join-Path $UserRoot '.agents/backups'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { return 0 }
    return @([System.IO.Directory]::GetFileSystemEntries($backupRoot)).Count
}

$baseline = [System.IO.Path]::GetFullPath($BaselineRoot).TrimEnd([char[]]@('\','/'))
$candidate = [System.IO.Path]::GetFullPath($CandidateRoot).TrimEnd([char[]]@('\','/'))
$evidence = [System.IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([char[]]@('\','/'))
$archiveInputs = @(
    $BaselineGeneralArchive, $CandidateGeneralArchive,
    $BaselineCodeCollaborationArchive, $CandidateCodeCollaborationArchive
)
foreach ($path in @($baseline,$candidate) + $archiveInputs) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input is missing: $path" }
}
foreach ($archivePath in $archiveInputs) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "Source archive input must be a file: $archivePath" }
}
if (Test-Path -LiteralPath $evidence) { throw 'EvidenceRoot must be a fresh path.' }

$invocationRepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd([char[]]@('\','/'))
$invocationIdentity = Get-GitRepositoryIdentity -RepositoryRoot $invocationRepositoryRoot -Name 'script repository'
$baselineIdentity = Get-GitRepositoryIdentity -RepositoryRoot $baseline -Name 'baseline' -RequireClean
$candidateIdentity = Get-GitRepositoryIdentity -RepositoryRoot $candidate -Name 'candidate' -RequireClean
if ([string]::Equals($baselineIdentity.root, $candidateIdentity.root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'BaselineRoot and CandidateRoot must be distinct clean checkouts.'
}
if ($baselineIdentity.commit -ceq $candidateIdentity.commit) {
    throw 'Baseline and candidate must resolve to different Git commits.'
}
if ($baselineIdentity.repositoryUrl -cne $candidateIdentity.repositoryUrl -or
    $candidateIdentity.repositoryUrl -cne $invocationIdentity.repositoryUrl) {
    throw 'Baseline, candidate, and script must share the same canonical GitHub origin.'
}
foreach ($repositoryRoot in @($baselineIdentity.root,$candidateIdentity.root,$invocationIdentity.root)) {
    Assert-PathOutsideRepository -Path $evidence -RepositoryRoot $repositoryRoot
}

[void](New-Item -ItemType Directory -Path $evidence -Force)
$baselineSnapshot = New-RepositorySnapshot -RepositoryIdentity $baselineIdentity -EvidenceRoot $evidence -Name 'baseline'
$candidateSnapshot = New-RepositorySnapshot -RepositoryIdentity $candidateIdentity -EvidenceRoot $evidence -Name 'candidate'
$baselineRuntime = Join-Path $evidence 'baseline-runtime'
$candidateRuntime = Join-Path $evidence 'candidate-runtime'
$userRoot = Join-Path $evidence 'isolated-user'
New-RuntimeProjection -RepositorySnapshot $baselineSnapshot.root -Destination $baselineRuntime
New-RuntimeProjection -RepositorySnapshot $candidateSnapshot.root -Destination $candidateRuntime
[void](New-Item -ItemType Directory -Path $userRoot -Force)
Import-Module (Join-Path $candidateRuntime 'agent-environment-reconciler.psm1') -Force
# The reconciliation module imports this module in its own scope. Load it in the
# harness scope as well because the explicit legacy-ID assertions call it directly.
Import-Module (Join-Path $candidateRuntime 'skills-selection.psm1') -Force

$catalogRepository = [string]$candidateIdentity.repositoryUrl
$selection = [pscustomobject]@{ catalog=[pscustomobject]@{
    profiles=@('ai-memory'); includeSkills=@(); excludeSkills=@()
} }
$baselineDesired = Get-UserSkillsDesiredState -RuntimeRoot $baselineRuntime -Configuration $selection `
    -CatalogRepository $catalogRepository -CatalogCommit $baselineIdentity.commit `
    -WorkingRoot (Join-Path $evidence 'baseline-working') `
    -LocalArchiveOverrides (New-LocalArchiveOverrides -GeneralArchive $BaselineGeneralArchive -CodeCollaborationArchive $BaselineCodeCollaborationArchive)
$candidateDesired = Get-UserSkillsDesiredState -RuntimeRoot $candidateRuntime -Configuration $selection `
    -CatalogRepository $catalogRepository -CatalogCommit $candidateIdentity.commit `
    -WorkingRoot (Join-Path $evidence 'candidate-working') `
    -LocalArchiveOverrides (New-LocalArchiveOverrides -GeneralArchive $CandidateGeneralArchive -CodeCollaborationArchive $CandidateCodeCollaborationArchive)

Assert-SkillIds -Actual $baselineDesired.SkillIds -Expected @('manage-notion-ai-memory','manage-task-handoff') -Phase 'baseline ai-memory selection'
Assert-SkillIds -Actual $candidateDesired.SkillIds -Expected @('manage-ai-memory','manage-task-handoff') -Phase 'candidate ai-memory selection'

$candidateCatalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $candidateSnapshot.root 'catalog/skills-catalog.json') | ConvertFrom-Json -Depth 50
$previousCapabilityEvidence = [System.Environment]::GetEnvironmentVariable('AI_INSTRUCTIONS_CAPABILITY_EVIDENCE','Process')
try {
    [System.Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_CAPABILITY_EVIDENCE',$null,'Process')
    $legacyIncludeConfiguration = [pscustomobject]@{
        profiles=@(); includeSkills=@('manage-notion-ai-memory'); excludeSkills=@()
    }
    $legacyIncludeSelection = @(Resolve-SkillsSelection -Catalog $candidateCatalog -Selection $legacyIncludeConfiguration)
    Assert-SkillIds -Actual $legacyIncludeSelection -Expected @('manage-ai-memory','plan-production-change','verify-data-access-performance') -Phase 'explicit legacy include'

    $legacyExcludeConfiguration = [pscustomobject]@{
        profiles=@('ai-memory'); includeSkills=@(); excludeSkills=@('manage-notion-ai-memory')
    }
    $legacyExcludeSelection = @(Resolve-SkillsSelection -Catalog $candidateCatalog -Selection $legacyExcludeConfiguration)
    Assert-SkillIds -Actual $legacyExcludeSelection -Expected @('manage-task-handoff') -Phase 'explicit legacy exclude'
}
finally {
    [System.Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_CAPABILITY_EVIDENCE',$previousCapabilityEvidence,'Process')
}

$personalFile = Join-Path $userRoot '.agents/skills/personal-example/SKILL.md'
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $personalFile) -Force)
[IO.File]::WriteAllText($personalFile, "---`nname: personal-example`ndescription: unmanaged`n---`n",[Text.UTF8Encoding]::new($false))
$personalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $personalFile).Hash

$baselinePlan = Invoke-UserSkillsReconciliation -DesiredState $baselineDesired -UserHome $userRoot -Mode WhatIf
Assert-Result -Result $baselinePlan -Expected 'planned' -Phase 'baseline plan'
if (Test-Path -LiteralPath (Join-Path $userRoot '.agents/catalog-skills.manifest.json')) {
    throw 'Baseline plan changed the isolated user root.'
}
$baselineApply = Invoke-UserSkillsReconciliation -DesiredState $baselineDesired -UserHome $userRoot -Mode Apply
Assert-Result -Result $baselineApply -Expected 'applied' -Phase 'baseline install'
Assert-SkillState -UserRoot $userRoot -Expected @('manage-notion-ai-memory','manage-task-handoff') -Phase 'baseline install'

$candidatePlan = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $userRoot -Mode WhatIf
Assert-Result -Result $candidatePlan -Expected 'planned' -Phase 'candidate plan'
Assert-SkillState -UserRoot $userRoot -Expected @('manage-notion-ai-memory','manage-task-handoff') -Phase 'candidate plan'
$candidateApply = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $userRoot -Mode Apply
Assert-Result -Result $candidateApply -Expected 'applied' -Phase 'candidate install'
Assert-SkillState -UserRoot $userRoot -Expected @('manage-ai-memory','manage-task-handoff') -Phase 'candidate install'
$candidateVerify = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $userRoot -Mode VerifyOnly
Assert-Result -Result $candidateVerify -Expected 'current' -Phase 'candidate verify'
$candidateRepeat = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $userRoot -Mode Apply
Assert-Result -Result $candidateRepeat -Expected 'current' -Phase 'candidate idempotence'

$rollbackPlan = Invoke-UserSkillsReconciliation -DesiredState $baselineDesired -UserHome $userRoot -Mode WhatIf
Assert-Result -Result $rollbackPlan -Expected 'planned' -Phase 'baseline rollback plan'
Assert-SkillState -UserRoot $userRoot -Expected @('manage-ai-memory','manage-task-handoff') -Phase 'baseline rollback plan'
$rollbackApply = Invoke-UserSkillsReconciliation -DesiredState $baselineDesired -UserHome $userRoot -Mode Apply
Assert-Result -Result $rollbackApply -Expected 'applied' -Phase 'baseline rollback'
Assert-SkillState -UserRoot $userRoot -Expected @('manage-notion-ai-memory','manage-task-handoff') -Phase 'baseline rollback'
$rollbackVerify = Invoke-UserSkillsReconciliation -DesiredState $baselineDesired -UserHome $userRoot -Mode VerifyOnly
Assert-Result -Result $rollbackVerify -Expected 'current' -Phase 'baseline rollback verify'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $personalFile).Hash -cne $personalSha) {
    throw 'Unmanaged personal Skill changed during isolated lifecycle.'
}

$customizedRoot = Join-Path $evidence 'isolated-user-customized'
$customizedBaseline = Invoke-UserSkillsReconciliation -DesiredState $baselineDesired -UserHome $customizedRoot -Mode Apply
Assert-Result -Result $customizedBaseline -Expected 'applied' -Phase 'customized baseline install'
$customizedPath = Join-Path $customizedRoot '.agents/skills/manage-notion-ai-memory/SKILL.md'
$customizedManifestPath = Join-Path $customizedRoot '.agents/catalog-skills.manifest.json'
$customizedNewPath = Join-Path $customizedRoot '.agents/skills/manage-ai-memory/SKILL.md'
[IO.File]::AppendAllText($customizedPath,"`n# local customization preserved by lifecycle check`n",[Text.UTF8Encoding]::new($false))
$customizedShaBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $customizedPath).Hash.ToLowerInvariant()
$customizedManifestShaBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $customizedManifestPath).Hash.ToLowerInvariant()
$customizedBackupCountBefore = Get-BackupEntryCount -UserRoot $customizedRoot
$customizedPlan = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $customizedRoot -Mode WhatIf
$customizedPlanDetail = Assert-BlockedResult -Result $customizedPlan -ExpectedCode 'managed-local-drift' `
    -ExpectedPath '.agents/skills/manage-notion-ai-memory/SKILL.md' -Phase 'customized candidate plan'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $customizedPath).Hash.ToLowerInvariant() -cne $customizedShaBefore -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $customizedManifestPath).Hash.ToLowerInvariant() -cne $customizedManifestShaBefore -or
    (Test-Path -LiteralPath $customizedNewPath) -or
    (Get-BackupEntryCount -UserRoot $customizedRoot) -ne $customizedBackupCountBefore) {
    throw 'Customized candidate plan changed user content, manifest, candidate path, or backup state.'
}
$customizedApply = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $customizedRoot -Mode Apply
$customizedApplyDetail = Assert-BlockedResult -Result $customizedApply -ExpectedCode 'managed-local-drift' `
    -ExpectedPath '.agents/skills/manage-notion-ai-memory/SKILL.md' -Phase 'customized candidate apply'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $customizedPath).Hash.ToLowerInvariant() -cne $customizedShaBefore -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $customizedManifestPath).Hash.ToLowerInvariant() -cne $customizedManifestShaBefore -or
    (Test-Path -LiteralPath $customizedNewPath) -or
    (Get-BackupEntryCount -UserRoot $customizedRoot) -ne $customizedBackupCountBefore) {
    throw 'Customized candidate apply changed user content, manifest, candidate path, or backup state.'
}

$collisionRoot = Join-Path $evidence 'isolated-user-name-collision'
$collisionPath = Join-Path $collisionRoot '.agents/skills/manage-ai-memory/SKILL.md'
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $collisionPath) -Force)
[IO.File]::WriteAllText($collisionPath,"---`nname: manage-ai-memory`ndescription: unmanaged collision`n---`nuser-owned bytes`n",[Text.UTF8Encoding]::new($false))
$collisionShaBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $collisionPath).Hash.ToLowerInvariant()
$collisionPlan = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $collisionRoot -Mode WhatIf
$collisionPlanDetail = Assert-BlockedResult -Result $collisionPlan -ExpectedCode 'unmanaged-collision' `
    -ExpectedPath '.agents/skills/manage-ai-memory/SKILL.md' -Phase 'unmanaged name-collision plan'
$collisionApply = Invoke-UserSkillsReconciliation -DesiredState $candidateDesired -UserHome $collisionRoot -Mode Apply
$collisionApplyDetail = Assert-BlockedResult -Result $collisionApply -ExpectedCode 'unmanaged-collision' `
    -ExpectedPath '.agents/skills/manage-ai-memory/SKILL.md' -Phase 'unmanaged name-collision apply'
$collisionManifestPath = Join-Path $collisionRoot '.agents/catalog-skills.manifest.json'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $collisionPath).Hash.ToLowerInvariant() -cne $collisionShaBefore -or
    (Test-Path -LiteralPath $collisionManifestPath) -or
    (Get-BackupEntryCount -UserRoot $collisionRoot) -ne 0) {
    throw 'Unmanaged name-collision evidence shows that user bytes, manifest, or backup state changed.'
}

$summary = [ordered]@{
    schemaVersion=2
    purpose='SYP-216 isolated user Skill install, legacy-ID selection, customization/name-collision refusal, verification, idempotence, and rollback'
    catalogRepository=$catalogRepository
    baselineCommit=$baselineIdentity.commit
    candidateCommit=$candidateIdentity.commit
    provenance=[ordered]@{
        repository=$catalogRepository
        baselineCommit=$baselineIdentity.commit
        candidateCommit=$candidateIdentity.commit
        baselineWorkingTreeClean=[bool]$baselineIdentity.workingTreeClean
        candidateWorkingTreeClean=[bool]$candidateIdentity.workingTreeClean
        baselineSnapshotSha256=$baselineSnapshot.archiveSha256
        candidateSnapshotSha256=$candidateSnapshot.archiveSha256
    }
    baselineCatalogSha256=$baselineSnapshot.catalogSha256
    candidateCatalogSha256=$candidateSnapshot.catalogSha256
    baselineLockSha256=$baselineSnapshot.lockSha256
    candidateLockSha256=$candidateSnapshot.lockSha256
    baselineGeneralArchiveSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $BaselineGeneralArchive).Hash.ToLowerInvariant()
    candidateGeneralArchiveSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $CandidateGeneralArchive).Hash.ToLowerInvariant()
    baselineCodeCollaborationArchiveSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $BaselineCodeCollaborationArchive).Hash.ToLowerInvariant()
    candidateCodeCollaborationArchiveSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $CandidateCodeCollaborationArchive).Hash.ToLowerInvariant()
    baselineSelection=@($baselineDesired.SkillIds)
    candidateSelection=@($candidateDesired.SkillIds)
    legacyInclude=[ordered]@{
        configuredId='manage-notion-ai-memory'
        resolvedSkillIds=@($legacyIncludeSelection)
        replacementId='manage-ai-memory'
    }
    legacyExclude=[ordered]@{
        configuredId='manage-notion-ai-memory'
        resolvedSkillIds=@($legacyExcludeSelection)
        excludedReplacementId='manage-ai-memory'
    }
    outcomes=[ordered]@{
        baselinePlan=$baselinePlan.outcome
        baseline=$baselineApply.outcome
        candidatePlan=$candidatePlan.outcome
        candidate=$candidateApply.outcome
        verify=$candidateVerify.outcome
        repeat=$candidateRepeat.outcome
        rollbackPlan=$rollbackPlan.outcome
        rollback=$rollbackApply.outcome
        rollbackVerify=$rollbackVerify.outcome
        customizedPlan=$customizedPlan.outcome
        customizedApply=$customizedApply.outcome
        nameCollisionPlan=$collisionPlan.outcome
        nameCollisionApply=$collisionApply.outcome
    }
    unmanagedPreserved=$true
    customizedManagedFile=[ordered]@{
        path='.agents/skills/manage-notion-ai-memory/SKILL.md'
        expectedFailureCode='managed-local-drift'
        planFailureCode=[string]$customizedPlanDetail.code
        applyFailureCode=[string]$customizedApplyDetail.code
        contentSha256Before=$customizedShaBefore
        contentSha256After=(Get-FileHash -Algorithm SHA256 -LiteralPath $customizedPath).Hash.ToLowerInvariant()
        manifestUnchanged=((Get-FileHash -Algorithm SHA256 -LiteralPath $customizedManifestPath).Hash.ToLowerInvariant() -ceq $customizedManifestShaBefore)
        candidateSkillInstalled=(Test-Path -LiteralPath $customizedNewPath)
        backupCountBefore=$customizedBackupCountBefore
        backupCountAfter=(Get-BackupEntryCount -UserRoot $customizedRoot)
    }
    unmanagedNameCollision=[ordered]@{
        path='.agents/skills/manage-ai-memory/SKILL.md'
        expectedFailureCode='unmanaged-collision'
        planFailureCode=[string]$collisionPlanDetail.code
        applyFailureCode=[string]$collisionApplyDetail.code
        contentSha256Before=$collisionShaBefore
        contentSha256After=(Get-FileHash -Algorithm SHA256 -LiteralPath $collisionPath).Hash.ToLowerInvariant()
        manifestCreated=(Test-Path -LiteralPath $collisionManifestPath)
        backupCountAfter=(Get-BackupEntryCount -UserRoot $collisionRoot)
    }
}
$summaryPath = Join-Path $evidence 'summary.json'
[IO.File]::WriteAllText($summaryPath,(($summary | ConvertTo-Json -Depth 12) + "`n"),[Text.UTF8Encoding]::new($false))
Write-Output "SYP-216 isolated lifecycle passed: $summaryPath"
