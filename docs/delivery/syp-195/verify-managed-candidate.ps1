#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][string]$ReportPath
)
$ErrorActionPreference='Stop'
$central=[IO.Path]::GetFullPath($CentralRoot)
$work=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $work) {throw 'Managed acceptance requires a new, isolated WorkRoot.'}
if(Test-Path -LiteralPath $ReportPath) {throw 'Report must be create-only.'}
$candidate=Join-Path $PSScriptRoot 'candidate'
$descriptor=Get-Content (Join-Path $candidate 'raw-source-descriptor.json') -Raw | ConvertFrom-Json
if($descriptor.reviewState -cne 'candidate' -or $descriptor.licenseReview -cne 'pending') {throw 'This harness is only for an inert pending candidate.'}
if((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $descriptor.archiveSha256) {throw 'Archive identity mismatch.'}
[void][IO.Directory]::CreateDirectory($work)
$runtime=Join-Path $work 'runtime'
[void][IO.Directory]::CreateDirectory((Join-Path $runtime 'catalog'))
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $central 'scripts') -File -Filter '*.psm1')) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtime $file.Name)
}
foreach($name in @('skills-catalog.json','skills-catalog-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $candidate ('catalog/'+$name)) -Destination (Join-Path $runtime ('catalog/'+$name))
}
Import-Module (Join-Path $runtime 'agent-environment-reconciler.psm1') -Force
$configuration=[pscustomobject]@{catalog=[pscustomobject]@{profiles=@('diagram-design');includeSkills=@();excludeSkills=@()}}
$overrides=@{}; $overrides[$descriptor.sourceId]=[IO.Path]::GetFullPath($ArchivePath)
$desired=Get-UserSkillsDesiredState -RuntimeRoot $runtime -Configuration $configuration `
    -CatalogRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
    -CatalogCommit '638a342e0757867558e396e2f7decb79fcf7addb' -WorkingRoot (Join-Path $work 'staging') -LocalArchiveOverrides $overrides
function Assert-Case([bool]$Condition,[string]$Message) {if(-not $Condition) {throw $Message}}
function Hash([string]$Path) {(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function New-Home([string]$Name) {
    $path=Join-Path $work $Name
    [void][IO.Directory]::CreateDirectory($path)
    $path
}
$payload=@($desired.Files | Where-Object {$_.sourcePath.StartsWith('skills/diagram-design/')})
$licenses=@($desired.Files | Where-Object {-not $_.sourcePath.StartsWith('skills/diagram-design/')})
Assert-Case ($payload.Count -eq 279 -and $licenses.Count -eq 3) 'Expected full 279-file raw package plus two legal documents and one receipt.'
Assert-Case (@($desired.Files | Where-Object {$_.sourceCommit -cne $descriptor.resolvedCommit -or $_.sourceRepository -cne $descriptor.repository -or $_.sourceId -cne $descriptor.sourceId}).Count -eq 0) 'Upstream provenance mismatch.'
Assert-Case (@($desired.Files | Where-Object {-not $_.targetPath.StartsWith('.agents/skills/diagram-design/')}).Count -eq 0) 'Unexpected projection outside the selected Skill.'
$fixtureHome=New-Home 'home-clean'
$personal=Join-Path $fixtureHome '.agents/skills/personal/SKILL.md'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $personal))
[IO.File]::WriteAllText($personal,'owned personal content')
$profile=Join-Path $fixtureHome 'diagram-profile.json'
[IO.File]::WriteAllText($profile,'{"brand":"personal"}')
$profileHash=Hash $profile
$first=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $fixtureHome -Mode Apply
Assert-Case ($first.outcome -ceq 'applied') 'Initial installation failed.'
foreach($file in $desired.Files) {Assert-Case ((Hash (Join-Path $fixtureHome $file.targetPath)) -ceq $file.sha256) 'Installed bytes mismatch.'}
$second=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $fixtureHome -Mode Apply
Assert-Case ($second.outcome -ceq 'current' -and @($second.installed).Count -eq 0 -and @($second.updated).Count -eq 0) 'Idempotence failed.'
$verified=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $fixtureHome -Mode VerifyOnly
Assert-Case ($verified.outcome -ceq 'current') 'Post-install verification failed.'
$style=Join-Path $fixtureHome '.agents/skills/diagram-design/references/style-guide.md'
[IO.File]::AppendAllText($style,"`nPersonal styling rule.`n")
$styleHash=Hash $style
$custom=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $fixtureHome -Mode Apply
Assert-Case ($custom.outcome -ceq 'failed' -and $custom.rollbackState -ceq 'not-started' -and (Hash $style) -ceq $styleHash) 'Customized content was not protected.'
Assert-Case (@($custom.failureDetails | Where-Object code -ceq 'managed-local-drift').Count -gt 0) 'Missing customized drift classification.'
# Restore only the owned fixture bytes to test removal separately.
$original=@($desired.Files | Where-Object targetPath -ceq '.agents/skills/diagram-design/references/style-guide.md')[0]
[IO.File]::WriteAllBytes($style,[IO.File]::ReadAllBytes($original.stagedPath))
$emptyManifest=$desired.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$emptyManifest.files=@()
$empty=[pscustomobject]@{RuntimeRoot=$runtime;Catalog=$desired.Catalog;SkillIds=@();Files=@();Manifest=$emptyManifest}
$removed=Invoke-UserSkillsReconciliation -DesiredState $empty -UserHome $fixtureHome -Mode Apply
Assert-Case ($removed.outcome -ceq 'applied' -and @($removed.removed).Count -eq 282) 'Managed deselection failed.'
Assert-Case (([IO.File]::ReadAllText($personal)) -ceq 'owned personal content' -and (Hash $profile) -ceq $profileHash) 'Personal content or profile changed.'
$rollbackHome=New-Home 'home-rollback'
$rollback=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $rollbackHome -Mode Apply -FailureAfterMutationCount 3
Assert-Case ($rollback.outcome -ceq 'failed' -and $rollback.rollbackState -ceq 'completed') 'Injected failure did not roll back.'
Assert-Case (@($desired.Files | Where-Object {Test-Path -LiteralPath (Join-Path $rollbackHome $_.targetPath)}).Count -eq 0) 'Rollback left payload files.'
Assert-Case (-not(Test-Path -LiteralPath (Join-Path $rollbackHome '.agents/catalog-skills.manifest.json'))) 'Rollback left a committed manifest.'
$retry=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $rollbackHome -Mode Apply
Assert-Case ($retry.outcome -ceq 'applied') 'Retry after rollback failed.'
$collisionHome=New-Home 'home-unmanaged'
$collision=Join-Path $collisionHome '.agents/skills/diagram-design/SKILL.md'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $collision))
[IO.File]::WriteAllText($collision,'unmanaged existing Skill')
$collisionHash=Hash $collision
$blocked=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $collisionHome -Mode Apply
Assert-Case ($blocked.outcome -ceq 'failed' -and (Hash $collision) -ceq $collisionHash) 'Unmanaged collision was overwritten.'
$report=[ordered]@{
    schemaVersion=1;validationKind='isolated-managed-candidate-acceptance';status='passed';releaseEligible=$false;realUserScopeUpdated=$false
    candidateState='candidate/pending';runtimeAuthorityCommit='638a342e0757867558e396e2f7decb79fcf7addb';catalogIsDerivedFixture=$true
    catalogSha256=Hash (Join-Path $candidate 'catalog/skills-catalog.json');lockSha256=Hash (Join-Path $candidate 'catalog/skills-catalog-lock.json')
    sourceCommit=$descriptor.resolvedCommit;archiveSha256=$descriptor.archiveSha256;skillContentSha256=$descriptor.skills[0].contentSha256
    payloadFiles=$payload.Count;licenseDocuments=2;licenseReceipts=1;installedFiles=$desired.Files.Count
    cases=@(
        @{id='exact-package-and-provenance';status='passed'},@{id='clean-install';status='passed';outcome=$first.outcome},
        @{id='idempotence';status='passed';outcome=$second.outcome},@{id='verify-only';status='passed';outcome=$verified.outcome},
        @{id='customized-drift';status='passed';outcome=$custom.outcome;rollbackState=$custom.rollbackState},
        @{id='managed-deselection';status='passed';removed=@($removed.removed).Count},@{id='personal-and-profile-preservation';status='passed'},
        @{id='injected-transaction-failure';status='passed';outcome=$rollback.outcome;rollbackState=$rollback.rollbackState},
        @{id='retry-after-rollback';status='passed';outcome=$retry.outcome},@{id='unmanaged-collision';status='passed';outcome=$blocked.outcome}
    )
    managedInventory=@($desired.Manifest.files)
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 35).Replace("`r`n","`n")+"`n",[Text.UTF8Encoding]::new($false))
$report | Select-Object validationKind,status,realUserScopeUpdated,payloadFiles,installedFiles,cases | ConvertTo-Json -Depth 8
