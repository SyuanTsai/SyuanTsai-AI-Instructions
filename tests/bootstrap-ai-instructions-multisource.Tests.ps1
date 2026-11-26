$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BootstrapScript = Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions-multisource.ps1'
$script:TestRepositoryUrl = 'git@example.com:team/multisource-bootstrap-test.git'
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-acquisition.psm1') -Force

function Invoke-TestGit {
    param([string]$Repository,[string[]]$Arguments)
    $output=& git -c core.autocrlf=false -C $Repository @Arguments 2>&1
    if($LASTEXITCODE-ne0){throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"}
    return $output
}
function Set-TestUtf8Text {
    param([string]$Path,[string]$Value)
    [System.IO.File]::WriteAllText($Path,$Value,(New-Object System.Text.UTF8Encoding($false)))
}
function Copy-TestPlatformRuntimeClosure {
    param([Parameter(Mandatory=$true)][string]$Destination)
    $runtimeRoot=Join-Path $script:RepositoryRoot 'scripts'
    $manifestPath=Join-Path $runtimeRoot 'platform-runtime.psd1'
    $manifest=Import-PowerShellDataFile -LiteralPath $manifestPath
    foreach($relativePath in @($manifest.FileList)){
        $source=Join-Path $runtimeRoot ([string]$relativePath)
        $target=Join-Path $Destination ([string]$relativePath)
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target))|Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}
function Get-TestFileSha256 {
    param([string]$Path)
    $stream=[System.IO.File]::OpenRead($Path);try{$sha=[System.Security.Cryptography.SHA256]::Create();try{return([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}finally{$stream.Dispose()}
}
function Assert-ThrowsMessage {
    param([scriptblock]$Action,[string]$Pattern)
    $thrown=$false;$message=$null
    try{& $Action}catch{$thrown=$true;$message=$_.Exception.Message}
    $thrown|Should Be $true
    $message|Should Match $Pattern
}
function Compress-TestDirectory {
    param([string]$SourceRoot,[string]$ArchivePath)
    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression
    $resolvedSource=[System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\','/'))
    $stream=[System.IO.File]::Open([System.IO.Path]::GetFullPath($ArchivePath),[System.IO.FileMode]::CreateNew)
    try{
        $archive=New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            $rootName=Split-Path -Leaf $resolvedSource
            foreach($file in @(Get-ChildItem -LiteralPath $resolvedSource -Recurse -Force -File|Sort-Object FullName)){
                $relativePath=$file.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry=$archive.CreateEntry("$rootName/$relativePath",[System.IO.Compression.CompressionLevel]::Optimal)
                $input=[System.IO.File]::OpenRead($file.FullName);$output=$entry.Open()
                try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
}
function New-TestInstructionArchive {
    param([string]$Root,[string]$ArchivePath)
    $repositoryRoot=Join-Path $Root 'SyuanTsai-AI-Instructions-main'
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $repositoryRoot '.codex\AI-Rules'),(Join-Path $repositoryRoot '.github\AI-Rules'),(Join-Path $repositoryRoot '.claude\AI-Rules'),(Join-Path $repositoryRoot '.agents\skills\legacy-skill'),(Join-Path $repositoryRoot 'scripts')|Out-Null
    Set-TestUtf8Text (Join-Path $repositoryRoot '.codex\AGENTS.en.md') "# Codex Base`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.codex\AI-Rules\core.en.md') "# Codex Rule`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.github\copilot-instructions.en.md') "# Copilot Base`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.github\AI-Rules\core.en.md') "# Copilot Rule`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.claude\CLAUDE.en.md') "# Claude Base`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.claude\AI-Rules\core.en.md') "# Claude Rule`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.agents\skills\legacy-skill\SKILL.md') "---`nname: legacy-skill`ndescription: Legacy fixture skill.`n---`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot 'scripts\Build-AiInstructions.ps1') "param([switch]`$Check)`n"
    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $ArchivePath
}
function New-TestSkillArchive {
    param(
        [string]$Root,
        [string]$ArchivePath,
        [string]$Marker = 'Selected external fixture skill.',
        [string]$LicenseText
    )
    $repositoryRoot=Join-Path $Root 'external-skills-aaaaaaaa'
    $skillRoot=Join-Path $repositoryRoot '.agents\skills\skill-a'
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $skillRoot|Out-Null
    Set-TestUtf8Text (Join-Path $skillRoot 'SKILL.md') "---`nname: skill-a`ndescription: $Marker`n---`n`n# Skill A`n"
    if ($LicenseText) {
        Set-TestUtf8Text (Join-Path $repositoryRoot 'LICENSE') $LicenseText
        Set-TestUtf8Text (Join-Path $skillRoot 'NOTICE') 'Skill-local attribution'
    }
    $contentHash=Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot
    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $ArchivePath
    return [pscustomobject]@{ArchivePath=$ArchivePath;ArchiveSha256=(Get-TestFileSha256 $ArchivePath);ContentSha256=$contentHash}
}

function New-TestDatadogSkillArchive {
    param([string]$Root,[string]$ArchivePath)
    $repositoryRoot=Join-Path $Root 'Skill-General-aaaaaaaa'
    $skillRoot=Join-Path $repositoryRoot 'skills\investigate-datadog-logs'
    $baselineSkillRoot=Join-Path $repositoryRoot 'skills\plan-production-change'
    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $skillRoot,$baselineSkillRoot|Out-Null
    Set-TestUtf8Text (Join-Path $skillRoot 'SKILL.md') "---`nname: investigate-datadog-logs`ndescription: Isolated launcher evidence fixture.`n---`n`n# Datadog fixture`n"
    Set-TestUtf8Text (Join-Path $baselineSkillRoot 'SKILL.md') "---`nname: plan-production-change`ndescription: Isolated ungated launcher fixture.`n---`n`n# Baseline fixture`n"
    $datadogContentHash=Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot
    $baselineContentHash=Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $baselineSkillRoot
    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $ArchivePath
    return [pscustomobject]@{ArchivePath=$ArchivePath;ArchiveSha256=(Get-TestFileSha256 $ArchivePath);DatadogContentSha256=$datadogContentHash;BaselineContentSha256=$baselineContentHash}
}

function New-TestV5RuntimeBundle {
    param([string]$RuntimeRoot,[string]$Commit)
    $platformModule=Import-Module (Join-Path $RuntimeRoot 'platform-runtime.psd1') -Force -PassThru
    $receipt=&$platformModule {Get-PlatformCapabilities -Required @()}
    $contractModule=Import-Module (Join-Path $RuntimeRoot 'ai-instructions-runtime-contract.psm1') -Force -PassThru
    $arguments=@{
        RuntimeRoot=$RuntimeRoot
        Repository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        Commit=$Commit
        Acquisition='git-checkout'
        CapabilityReceipt=$receipt
    }
    $bundle=&$contractModule {param($Arguments) New-AiInstructionsRuntimeBundleV3 @Arguments} $arguments
    Set-TestUtf8Text (Join-Path $RuntimeRoot 'runtime-bundle.json') (($bundle|ConvertTo-Json -Depth 30).Replace("`r`n","`n")+"`n")
}
function New-TestTargetRepository {
    param([string]$Path)
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Path|Out-Null
    Invoke-TestGit $Path @('init','--quiet')|Out-Null;Invoke-TestGit $Path @('config','user.name','Multisource Bootstrap Test')|Out-Null;Invoke-TestGit $Path @('config','user.email','multisource@example.test')|Out-Null;Invoke-TestGit $Path @('remote','add','origin',$script:TestRepositoryUrl)|Out-Null
    Set-TestUtf8Text (Join-Path $Path 'README.md') "# Test Repository`n";Invoke-TestGit $Path @('add','--','README.md')|Out-Null;Invoke-TestGit $Path @('commit','--quiet','-m','initial commit')|Out-Null
}
function New-TestDocuments {
    param([string]$CatalogPath,[string]$LockPath,[string]$ConfigurationPath,[object]$SkillArchive,[switch]$MissingSelectionArrays)
    $catalog=[ordered]@{
        schemaVersion=1;catalogId='multisource-smoke'
        sources=@([ordered]@{id='source-a';repository='https://github.com/example/source-a.git'})
        profiles=@([ordered]@{id='core';description='Core fixture profile.';default=$false;includes=@('skill-a');excludes=@()})
        skills=@([ordered]@{id='skill-a';group='fixture';source=[ordered]@{sourceId='source-a';path='.agents/skills/skill-a'};profiles=@('core');compatibility=[ordered]@{platforms=@('any');shells=@();requiredCapabilities=@();anyOfCapabilities=@()};dependencies=@();lifecycle=[ordered]@{status='active';aliases=@()}})
    }
    Set-TestUtf8Text $CatalogPath (($catalog|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")
    $lock=[ordered]@{
        schemaVersion=1;catalogId='multisource-smoke';catalogSha256=(Get-TestFileSha256 $CatalogPath)
        sources=@([ordered]@{id='source-a';repository='https://github.com/example/source-a.git';requestedRef='main';requestedRefType='branch';resolvedCommit=('a'*40);resolvedVersion='test';archiveSha256=$SkillArchive.ArchiveSha256})
        skills=@([ordered]@{id='skill-a';sourceId='source-a';sourcePath='.agents/skills/skill-a';contentSha256=$SkillArchive.ContentSha256})
    }
    Set-TestUtf8Text $LockPath (($lock|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")
    if($MissingSelectionArrays){$catalogSelection=[ordered]@{repository='https://github.com/example/catalog.git';ref=('c'*40);profiles=@()}}
    else{$catalogSelection=[ordered]@{repository='https://github.com/example/catalog.git';ref=('c'*40);profiles=@();includeSkills=@('skill-a');excludeSkills=@()}}
    $catalogSelection.repository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    $configuration=[ordered]@{
        schemaVersion=4
        excludedRepositoryUrls=@()
        excludedRepositoryPaths=@()
        catalog=$catalogSelection
        updates=[ordered]@{mode='notify-only';channel='protected-branch';ref='main';minimumCheckIntervalMinutes=1440}
    }
    Set-TestUtf8Text $ConfigurationPath (($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")
}

function Convert-TestTargetManifestToV1 {
    param([string]$TargetRoot)
    $manifestPath=Join-Path $TargetRoot '.codex\ai-instructions.manifest.json'
    $manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
    $legacy=[ordered]@{
        schemaVersion=1
        sourceRepository='https://github.com/example/catalog.git'
        sourceRef='main'
        files=@(
            foreach($entry in @($manifest.files)){
                [ordered]@{sourcePath=[string]$entry.sourcePath;targetPath=[string]$entry.targetPath;sha256=[string]$entry.sha256}
            }
        )
    }
    Set-TestUtf8Text $manifestPath ($legacy|ConvertTo-Json -Depth 20)
}

Describe 'bootstrap-ai-instructions-multisource' {
    # Scenario: A v5 sync configuration is paired with the legacy Catalog/Lock fixture.
    # Purpose: Enforce the P7e gate before acquisition or target mutation instead of treating v5 alone as trusted.
    It 'InterT04_rejects_sync_v5_with_a_legacy_catalog_pair_without_mutation' {
        $catalogPath=Join-Path $TestDrive 'v5-catalog.json';$lockPath=Join-Path $TestDrive 'v5-lock.json';$configurationPath=Join-Path $TestDrive 'v5-config.json'
        $instructionArchive=Join-Path $TestDrive 'v5-instructions.zip';$skillArchivePath=Join-Path $TestDrive 'v5-source.zip';$targetRoot=Join-Path $TestDrive 'v5-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'v5-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'v5-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        $configuration=Get-Content -Raw -LiteralPath $configurationPath|ConvertFrom-Json
        $configuration.schemaVersion=5
        $configuration|Add-Member -NotePropertyName projections -NotePropertyValue ([pscustomobject]@{user=@('user-agents');project=@()})
        Set-TestUtf8Text $configurationPath (($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")
        New-TestTargetRepository $targetRoot
        $readmePath=Join-Path $targetRoot 'README.md';$before=[IO.File]::ReadAllBytes($readmePath)

        $message=$null
        try { & $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath -InstructionSourceArchivePath $instructionArchive -InstructionSourceCommit ('c'*40) -SourceArchivePaths @{'source-a'=$skillArchivePath} -TargetRoot $targetRoot }
        catch { $message=$_.Exception.Message }

        $message | Should Match 'consistent Catalog/Lock v3 pair'
        $message | Should Match 'ai-instructions-refusal-code=projection-runtime-unavailable'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($readmePath))|Should Be ([Convert]::ToBase64String($before))
        Test-Path -LiteralPath (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|Should Be $false
        Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md')|Should Be $false
    }

    # Scenario: A licensed external Skill is selected for consumer Instructions synchronization.
    # Purpose: Keep Instructions license delivery while shared Skill grants remain in USER composition/reconciliation.
    It 'InterT05_keeps_licensed_external_Skills_out_of_REPO' {
        # Given
        $catalogPath=Join-Path $TestDrive 'licensed-catalog.json';$lockPath=Join-Path $TestDrive 'licensed-lock.json';$configurationPath=Join-Path $TestDrive 'licensed-config.json'
        $instructionArchive=Join-Path $TestDrive 'licensed-instructions.zip';$skillArchivePath=Join-Path $TestDrive 'licensed-source.zip';$targetRoot=Join-Path $TestDrive 'licensed-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'licensed-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'licensed-skill-root') $skillArchivePath -LicenseText 'Source grant'
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot
        # When
        & $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath -InstructionSourceArchivePath $instructionArchive -InstructionSourceCommit ('c'*40) -SourceArchivePaths @{'source-a'=$skillArchivePath} -TargetRoot $targetRoot
        # Then
        Test-Path (Join-Path $targetRoot '.agents/skills/skill-a') | Should Be $false
        Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
    }

    # Scenario: The user-level updater installs, repeats, upgrades, rolls back, and removes a licensed Skill.
    # Purpose: Exercise real acquisition and desired-state generation with file ownership and recovery evidence.
    It 'InterT06_reconciles_user_skill_license_lifecycle_and_rolls_back_failures' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/agent-environment-reconciler.psm1') -Force
        $runtime=Join-Path $TestDrive 'runtime'; New-Item -ItemType Directory -Force -Path (Join-Path $runtime 'catalog') | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Filter '*.psm1' | Copy-Item -Destination $runtime
        Copy-TestPlatformRuntimeClosure -Destination $runtime
        try {
        $catalogPath=Join-Path $runtime 'catalog/skills-catalog.json'; $lockPath=Join-Path $runtime 'catalog/skills-catalog-lock.json'; $configurationPath=Join-Path $TestDrive 'config.json'
        $skillArchivePath=Join-Path $TestDrive 'skill.zip'; $userHome=Join-Path $TestDrive 'user'
        New-Item -ItemType Directory -Path $userHome | Out-Null
        Set-TestUtf8Text (Join-Path $userHome 'LICENSE') 'Personal license'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'skill-root') $skillArchivePath -LicenseText 'Source license v1'
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        $configuration=Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        $arguments=@{ RuntimeRoot=$runtime; Configuration=$configuration; CatalogRepository='https://github.com/example/catalog.git'; CatalogCommit=('c'*40); LocalArchiveOverrides=@{'source-a'=$skillArchivePath} }
        $desired=Get-UserSkillsDesiredState @arguments -WorkingRoot (Join-Path $TestDrive 'work-one')
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $licensePath=Join-Path $userHome '.agents/skills/skill-a/.ai-instructions-licenses/source/LICENSE'
        [IO.File]::ReadAllText($licensePath) | Should Be 'Source license v1'
        $second=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $second.outcome | Should Be 'current'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'skill-root') $skillArchivePath -LicenseText 'Source license v2'
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        $next=Get-UserSkillsDesiredState @arguments -WorkingRoot (Join-Path $TestDrive 'work-two')
        Set-TestUtf8Text $licensePath 'Customized license'
        (Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply).outcome | Should Be 'failed'
        [IO.File]::ReadAllText($licensePath) | Should Be 'Customized license'
        Set-TestUtf8Text $licensePath 'Source license v1'
        $manifestPath=Join-Path $userHome '.agents/catalog-skills.manifest.json'
        $manifestBefore=[IO.File]::ReadAllText($manifestPath)
        $failed=Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1
        $failed.outcome | Should Be 'failed'
        $failed.rollbackState | Should Be 'completed'
        @($failed.failureDetails | Where-Object { $_.code -eq 'mutation-failure' }).Count | Should Be 1
        [IO.File]::ReadAllText($licensePath) | Should Be 'Source license v1'
        [IO.File]::ReadAllText($manifestPath) | Should Be $manifestBefore
        (Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        [IO.File]::ReadAllText($licensePath) | Should Be 'Source license v2'
        $configuration.catalog.includeSkills=@()
        $removed=Get-UserSkillsDesiredState @arguments -WorkingRoot (Join-Path $TestDrive 'work-empty')
        (Invoke-UserSkillsReconciliation -DesiredState $removed -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        Test-Path -LiteralPath $licensePath | Should Be $false
        [IO.File]::ReadAllText((Join-Path $userHome 'LICENSE')) | Should Be 'Personal license'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        $configuration.catalog.includeSkills=@('skill-a')
        $legacyOutput=@(Get-UserSkillsDesiredState @arguments -WorkingRoot (Join-Path $TestDrive 'work-legacy') 3>&1)
        $legacyOutput.Count | Should Be 1
        $legacy=$legacyOutput[0]
        $legacyResult=Invoke-UserSkillsReconciliation -DesiredState $legacy -UserHome $userHome -Mode WhatIf
        ($legacyResult.licenseWarnings -join ' ') | Should Match 'skill-a.*missing'
        }
        finally {
            Get-Module -All | Where-Object { $_.Path -and $_.Path.StartsWith($runtime + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) } | Remove-Module -Force
        }
    }

    # Scenario: Schema v4 selects one locally pinned Skill source and targets a disposable Git repository.
    # Purpose: Exercise validation, routing, acquisition, composition, schema-v2 handoff, and branch-independent local artifacts without network access.
    It 'InterT10_executes_a_selected_skill_local_source_end_to_end' {
        $catalogPath=Join-Path $TestDrive 'catalog.json';$lockPath=Join-Path $TestDrive 'catalog.lock.json';$configurationPath=Join-Path $TestDrive 'sync-config.json';$instructionArchive=Join-Path $TestDrive 'instruction-source.zip';$skillArchivePath=Join-Path $TestDrive 'source-a.zip';$targetRoot=Join-Path $TestDrive 'target'
        New-TestInstructionArchive (Join-Path $TestDrive 'instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot

        & $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath -InstructionSourceArchivePath $instructionArchive -InstructionSourceCommit ('c'*40) -SourceArchivePaths @{'source-a'=$skillArchivePath} -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim()|Should Be '# Codex Base'
        Test-Path (Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md')|Should Be $false
        Test-Path (Join-Path $targetRoot '.agents\skills\legacy-skill')|Should Be $false
        Test-Path (Join-Path $targetRoot '.agents/skills') | Should Be $false
        Test-Path (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|Should Be $true
        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|ConvertFrom-Json
        $manifest.schemaVersion|Should Be 2
        [string]$manifest.catalogId|Should Be 'multisource-smoke'
        [string]$manifest.lockSha256|Should Be (Get-TestFileSha256 $lockPath)
        @($manifest.files|Where-Object {$_.artifactType -eq 'skill'}).Count|Should Be 0
        $instructionEntry=@($manifest.files|Where-Object {$_.targetPath -eq 'AGENTS.md'})[0]
        [string]$instructionEntry.artifactType|Should Be 'instruction'
        [string]$instructionEntry.artifactId|Should Be 'codex-base'
        [string]$instructionEntry.sourceCommit|Should Be ('c'*40)
        (@(Invoke-TestGit $targetRoot @('log','-1','--pretty=%s')) -join '').Trim()|Should Be 'initial commit'
        @(Invoke-TestGit $targetRoot @('status','--porcelain')).Count|Should Be 0
        (@(Invoke-TestGit $targetRoot @('stash','list','--format=%s')) -join "`n")|Should Match 'PersonalAgent'
    }

    # Scenario: The Lock declares a catalogId different from the validated Catalog document.
    # Purpose: Bind every source and Skill pin to the intended Catalog identity before acquisition begins.
    It 'InterT12_rejects_a_Catalog_Lock_identity_mismatch' {
        $catalogPath=Join-Path $TestDrive 'identity-catalog.json';$lockPath=Join-Path $TestDrive 'identity-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'identity-sync-config.json';$skillArchivePath=Join-Path $TestDrive 'identity-source-a.zip'
        $missingInstructionArchive=Join-Path $TestDrive 'identity-missing-instructions.zip'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'identity-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        $lock=Get-Content -Raw -Encoding UTF8 -LiteralPath $lockPath|ConvertFrom-Json
        $lock.catalogId='different-catalog'
        Set-TestUtf8Text $lockPath (($lock|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")

        Assert-ThrowsMessage {
            & $script:BootstrapScript `
                -CatalogPath $catalogPath `
                -LockPath $lockPath `
                -ConfigurationPath $configurationPath `
                -SourceArchivePaths @{'source-a'=$skillArchivePath} `
                -InstructionSourceArchivePath $missingInstructionArchive
        } 'catalogId does not match'
    }

    # Scenario: The Catalog bytes change after the immutable Lock records catalogSha256.
    # Purpose: Reject a Lock routed against different Catalog content before source retrieval or target mutation.
    It 'InterT14_rejects_a_Catalog_hash_mismatch' {
        $catalogPath=Join-Path $TestDrive 'hash-catalog.json';$lockPath=Join-Path $TestDrive 'hash-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'hash-sync-config.json';$skillArchivePath=Join-Path $TestDrive 'hash-source-a.zip'
        $missingInstructionArchive=Join-Path $TestDrive 'hash-missing-instructions.zip'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'hash-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        [System.IO.File]::AppendAllText($catalogPath,' ',(New-Object System.Text.UTF8Encoding($false)))

        Assert-ThrowsMessage {
            & $script:BootstrapScript `
                -CatalogPath $catalogPath `
                -LockPath $lockPath `
                -ConfigurationPath $configurationPath `
                -SourceArchivePaths @{'source-a'=$skillArchivePath} `
                -InstructionSourceArchivePath $missingInstructionArchive
        } 'catalogSha256 does not match'
    }

    # Scenario: Schema v4 personal configuration omits required includeSkills and excludeSkills arrays.
    # Purpose: Fail before acquisition with an actionable configuration message instead of a strict-mode property error.
    It 'InterT20_rejects_missing_selection_arrays_with_an_actionable_error' {
        $catalogPath=Join-Path $TestDrive 'bad-catalog.json';$lockPath=Join-Path $TestDrive 'bad-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'bad-sync-config.json';$skillArchivePath=Join-Path $TestDrive 'bad-source-a.zip'
        $missingInstructionArchive=Join-Path $TestDrive 'bad-missing-instructions.zip'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'bad-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive -MissingSelectionArrays
        $thrown=$false;$message=$null
        try{& $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath -SourceArchivePaths @{'source-a'=$skillArchivePath} -InstructionSourceArchivePath $missingInstructionArchive}catch{$thrown=$true;$message=$_.Exception.Message}
        $thrown|Should Be $true
        $message|Should Match "catalog is missing 'includeSkills'"
    }

    # Scenario: A schema-v4 selection differs from a stable Catalog ID only by casing.
    # Purpose: Keep the runtime entry point as strict as the authoring contract before acquisition begins.
    It 'InterT22_rejects_case_variant_selection_ids_before_acquisition' {
        $skillArchivePath=Join-Path $TestDrive 'case-source-a.zip'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'case-skill-root') $skillArchivePath
        $missingInstructionArchive=Join-Path $TestDrive 'case-missing-instructions.zip'
        $cases=@(
            @{Name='profile';Property='profiles';Values=@('CORE');Expected='item must be a lowercase stable ID'},
            @{Name='include';Property='includeSkills';Values=@('Skill-A');Expected='item must be a lowercase stable ID'},
            @{Name='exclude';Property='excludeSkills';Values=@('Skill-A');Expected='item must be a lowercase stable ID'},
            @{Name='duplicate';Property='includeSkills';Values=@('skill-a','skill-a');Expected='contains duplicate (?:value|ID)'}
        )

        foreach($case in $cases){
            $catalogPath=Join-Path $TestDrive "$($case.Name)-catalog.json"
            $lockPath=Join-Path $TestDrive "$($case.Name)-catalog.lock.json"
            $configurationPath=Join-Path $TestDrive "$($case.Name)-sync-config.json"
            New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
            $configuration=Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json
            $configuration.catalog.PSObject.Properties[$case.Property].Value=@($case.Values)
            Set-TestUtf8Text $configurationPath (($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")

            Assert-ThrowsMessage {
                & $script:BootstrapScript `
                    -CatalogPath $catalogPath `
                    -LockPath $lockPath `
                    -ConfigurationPath $configurationPath `
                    -SourceArchivePaths @{'source-a'=$skillArchivePath} `
                    -InstructionSourceArchivePath $missingInstructionArchive
            } "catalog\.$($case.Property) $($case.Expected)"
        }
    }

    # Scenario: A target still has a schema-v1 manifest and every managed byte is unchanged.
    # Purpose: Permit one safe migration to per-file schema-v2 provenance.
    It 'InterT30_migrates_an_unchanged_v1_manifest_to_v2' {
        $catalogPath=Join-Path $TestDrive 'migration-catalog.json';$lockPath=Join-Path $TestDrive 'migration-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'migration-sync-config.json';$instructionArchive=Join-Path $TestDrive 'migration-instructions.zip';$skillArchivePath=Join-Path $TestDrive 'migration-source.zip';$targetRoot=Join-Path $TestDrive 'migration-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'migration-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'migration-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot
        $arguments=@{CatalogPath=$catalogPath;LockPath=$lockPath;ConfigurationPath=$configurationPath;InstructionSourceArchivePath=$instructionArchive;InstructionSourceCommit=('c'*40);SourceArchivePaths=@{'source-a'=$skillArchivePath};TargetRoot=$targetRoot}
        & $script:BootstrapScript @arguments
        Convert-TestTargetManifestToV1 -TargetRoot $targetRoot

        & $script:BootstrapScript @arguments

        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|ConvertFrom-Json
        $manifest.schemaVersion|Should Be 2
        @($manifest.files|Where-Object artifactType -eq 'skill').Count|Should Be 0
        (@(Invoke-TestGit $targetRoot @('log','-1','--pretty=%s')) -join '').Trim()|Should Be 'initial commit'
    }

    # Scenario: A schema-v1 target contains a locally customized managed Skill.
    # Purpose: Stop before migration because v1 cannot prove the historical per-file source commit.
    It 'InterT35_rejects_v1_migration_when_a_managed_file_is_customized' {
        $catalogPath=Join-Path $TestDrive 'custom-catalog.json';$lockPath=Join-Path $TestDrive 'custom-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'custom-sync-config.json';$instructionArchive=Join-Path $TestDrive 'custom-instructions.zip';$skillArchivePath=Join-Path $TestDrive 'custom-source.zip';$targetRoot=Join-Path $TestDrive 'custom-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'custom-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'custom-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot
        $arguments=@{CatalogPath=$catalogPath;LockPath=$lockPath;ConfigurationPath=$configurationPath;InstructionSourceArchivePath=$instructionArchive;InstructionSourceCommit=('c'*40);SourceArchivePaths=@{'source-a'=$skillArchivePath};TargetRoot=$targetRoot}
        & $script:BootstrapScript @arguments
        Convert-TestTargetManifestToV1 -TargetRoot $targetRoot
        $instructionPath=Join-Path $targetRoot 'AGENTS.md'
        Set-TestUtf8Text $instructionPath 'locally customized'
        $headBefore=(@(Invoke-TestGit $targetRoot @('rev-parse','HEAD')) -join '').Trim()
        $manifestBefore=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')

        Assert-ThrowsMessage { & $script:BootstrapScript @arguments } 'Cannot migrate managed manifest v1.*customized'

        (Get-Content -Raw $instructionPath)|Should Be 'locally customized'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json'))|Should Be $manifestBefore
        (@(Invoke-TestGit $targetRoot @('rev-parse','HEAD')) -join '').Trim()|Should Be $headBefore
    }

    # Scenario: An existing schema-v2 target selects a new immutable source commit and content lock.
    # Purpose: Use historical per-file provenance for customization checks, then safely advance the file and root lock provenance.
    It 'InterT40_advances_Catalog_lock_without_REPO_Skill_projection' {
        $catalogPath=Join-Path $TestDrive 'pin-catalog.json';$lockPath=Join-Path $TestDrive 'pin-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'pin-sync-config.json';$instructionArchive=Join-Path $TestDrive 'pin-instructions.zip';$skillArchivePath=Join-Path $TestDrive 'pin-source-v1.zip';$targetRoot=Join-Path $TestDrive 'pin-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'pin-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'pin-skill-root-v1') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot
        $arguments=@{CatalogPath=$catalogPath;LockPath=$lockPath;ConfigurationPath=$configurationPath;InstructionSourceArchivePath=$instructionArchive;InstructionSourceCommit=('c'*40);SourceArchivePaths=@{'source-a'=$skillArchivePath};TargetRoot=$targetRoot}
        & $script:BootstrapScript @arguments

        $newArchivePath=Join-Path $TestDrive 'pin-source-v2.zip'
        $newArchive=New-TestSkillArchive (Join-Path $TestDrive 'pin-skill-root-v2') $newArchivePath -Marker 'Selected external fixture skill v2.'
        $lock=Get-Content -Raw -LiteralPath $lockPath|ConvertFrom-Json
        @($lock.sources)[0].resolvedCommit=('b'*40)
        @($lock.sources)[0].resolvedVersion='test-v2'
        @($lock.sources)[0].archiveSha256=$newArchive.ArchiveSha256
        @($lock.skills)[0].contentSha256=$newArchive.ContentSha256
        Set-TestUtf8Text $lockPath ($lock|ConvertTo-Json -Depth 20)
        $arguments.SourceArchivePaths=@{'source-a'=$newArchivePath}

        & $script:BootstrapScript @arguments

        Test-Path (Join-Path $targetRoot '.agents/skills/skill-a/SKILL.md') | Should Be $false
        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|ConvertFrom-Json
        [string]$manifest.lockSha256|Should Be (Get-TestFileSha256 $lockPath)
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
        (@(Invoke-TestGit $targetRoot @('log','-1','--pretty=%s')) -join '').Trim()|Should Be 'initial commit'
    }

    # Scenario: A source pin advances while a project owns a same-name Skill outside the manifest.
    # Purpose: Preserve the project file, its lack of shared ownership and all unrelated sources.
    It 'InterT45_preserves_a_project_Skill_across_a_pin_update' {
        # Given
        $catalogPath=Join-Path $TestDrive 'custom-pin-catalog.json'; $lockPath=Join-Path $TestDrive 'custom-pin-lock.json'
        $configurationPath=Join-Path $TestDrive 'custom-pin-config.json'; $instructionArchive=Join-Path $TestDrive 'custom-pin-instructions.zip'
        $skillArchivePath=Join-Path $TestDrive 'custom-pin-source.zip'; $targetRoot=Join-Path $TestDrive 'custom-pin-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'custom-pin-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'custom-pin-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot
        $skillPath=Join-Path $targetRoot '.agents/skills/skill-a/SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillPath) | Out-Null
        Set-TestUtf8Text $skillPath 'project-specific Skill'
        Invoke-TestGit $targetRoot @('add','--','.agents/skills/skill-a/SKILL.md') | Out-Null
        Invoke-TestGit $targetRoot @('commit','-qm','project Skill') | Out-Null
        $arguments=@{CatalogPath=$catalogPath;LockPath=$lockPath;ConfigurationPath=$configurationPath;InstructionSourceArchivePath=$instructionArchive;InstructionSourceCommit=('c'*40);SourceArchivePaths=@{'source-a'=$skillArchivePath};TargetRoot=$targetRoot}
        # When
        & $script:BootstrapScript @arguments
        $nextArchivePath=Join-Path $TestDrive 'project-pin-next.zip'
        $nextArchive=New-TestSkillArchive (Join-Path $TestDrive 'project-pin-next') $nextArchivePath -Marker 'shared v2'
        $lock=Get-Content -Raw $lockPath | ConvertFrom-Json
        $lock.sources[0].resolvedCommit=('b'*40)
        $lock.sources[0].resolvedVersion='test-v2'
        $lock.sources[0].archiveSha256=$nextArchive.ArchiveSha256
        $lock.skills[0].contentSha256=$nextArchive.ContentSha256
        Set-TestUtf8Text $lockPath ($lock | ConvertTo-Json -Depth 20)
        $arguments.SourceArchivePaths=@{'source-a'=$nextArchivePath}
        & $script:BootstrapScript @arguments
        # Then
        [IO.File]::ReadAllText($skillPath) | Should Be 'project-specific Skill'
        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex/ai-instructions.manifest.json') | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
        (@(Invoke-TestGit $targetRoot @('log','-1','--pretty=%s')) -join '').Trim() | Should Be 'project Skill'
    }
}

Describe 'SYP-511 launcher capability evidence fan-out' {
    BeforeEach { Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue }
    AfterEach { Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue }

    # Scenario: Config v5 selects the production observability profile with stored Datadog evidence, no evidence, or an environment absent override.
    # Purpose: Reuse persisted evidence for provenance and project candidates while preserving environment precedence and fresh-install filtering.
    It 'InterT50_fans_out_stored_capability_evidence_with_environment_precedence' {
        $runtime=Join-Path $TestDrive 'runtime';New-Item -ItemType Directory -Force -Path (Join-Path $runtime 'catalog')|Out-Null
        Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Filter '*.psm1'|Copy-Item -Destination $runtime
        Copy-TestPlatformRuntimeClosure -Destination $runtime
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'instructions/common/bootstrap-section.md') -Destination (Join-Path $runtime 'bootstrap-section.md')
        $catalogPath=Join-Path $runtime 'catalog/skills-catalog.json';$lockPath=Join-Path $runtime 'catalog/skills-catalog-lock.json'
        $catalog=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json')|ConvertFrom-Json
        $catalog.projections=@($catalog.projections)+@([pscustomobject][ordered]@{id='project-agents';scope='project';root='.agents/skills'})
        Set-TestUtf8Text $catalogPath (($catalog|ConvertTo-Json -Depth 30).Replace("`r`n","`n")+"`n")
        $lock=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog-lock.json')|ConvertFrom-Json
        $skillId='investigate-datadog-logs';$source=@($lock.sources|Where-Object id -ceq 'general')[0]
        $skillArchive=New-TestDatadogSkillArchive -Root (Join-Path $TestDrive 'datadog-source') -ArchivePath (Join-Path $TestDrive 'datadog-source.zip')
        $source.archiveSha256=$skillArchive.ArchiveSha256
        @($lock.skills|Where-Object id -ceq $skillId)[0].contentSha256=$skillArchive.DatadogContentSha256
        @($lock.skills|Where-Object id -ceq 'plan-production-change')[0].contentSha256=$skillArchive.BaselineContentSha256
        $lock.catalogSha256=Get-TestFileSha256 $catalogPath
        $contractModule=Import-Module (Join-Path $runtime 'ai-instructions-runtime-contract.psm1') -Force -PassThru
        $lock.projectionContractSha256=&$contractModule {param($Projections) Get-AiInstructionsProjectionContractSha256 -Projections $Projections} $catalog.projections
        Set-TestUtf8Text $lockPath (($lock|ConvertTo-Json -Depth 30).Replace("`r`n","`n")+"`n")
        $commit='c'*40
        New-TestV5RuntimeBundle -RuntimeRoot $runtime -Commit $commit
        $instructionArchive=Join-Path $TestDrive 'instructions.zip'
        New-TestInstructionArchive (Join-Path $TestDrive 'instruction-root') $instructionArchive
        $userHome=Join-Path $TestDrive 'user';New-Item -ItemType Directory -Force -Path $userHome|Out-Null

        foreach($case in @(
            [pscustomobject]@{Name='stored';Stored=$true;Environment=$null;Expected=$true},
            [pscustomobject]@{Name='unknown';Stored=$false;Environment=$null;Expected=$false},
            [pscustomobject]@{Name='environment-absent';Stored=$true;Environment='[{"kind":"connector","id":"datadog","state":"absent"}]';Expected=$false}
        )){
            $configurationPath=Join-Path $TestDrive "$($case.Name)-config.json"
            $configuration=[ordered]@{
                schemaVersion=5;excludedRepositoryUrls=@();excludedRepositoryPaths=@()
                catalog=[ordered]@{repository='https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git';ref=$commit;profiles=@('observability');includeSkills=@('plan-production-change');excludeSkills=@()}
                updates=[ordered]@{mode='notify-only';channel='protected-branch';ref='main';minimumCheckIntervalMinutes=1440}
                projections=[ordered]@{user=@('user-agents');project=@('project-agents')}
            }
            if($case.Stored){$configuration.capabilityEvidence=@([ordered]@{kind='connector';id='datadog';state='configured'})}
            Set-TestUtf8Text $configurationPath (($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")
            if($null-ne$case.Environment){$env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE=[string]$case.Environment}else{Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue}
            $targetRoot=Join-Path $TestDrive "$($case.Name)-target";New-TestTargetRepository $targetRoot

            & $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath `
                -InstructionSourceArchivePath $instructionArchive -InstructionSourceCommit $commit `
                -SourceArchivePaths @{'general'=$skillArchive.ArchivePath} -TargetRoot $targetRoot -UserHome $userHome -RuntimeRoot $runtime

            $skillPath=Join-Path $targetRoot ".agents/skills/$skillId/SKILL.md"
            (Test-Path -LiteralPath $skillPath -PathType Leaf)|Should Be $case.Expected
            $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $targetRoot '.codex/ai-instructions.manifest.json')|ConvertFrom-Json
            (@($manifest.files|Where-Object artifactId -ceq $skillId).Count -gt 0)|Should Be $case.Expected
        }
    }
}

Describe 'Installed bootstrap source cache and disposition' {
    BeforeAll {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1') -Force
        $script:SourceCacheTestRoot=$TestDrive
        if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
            # Resolve the trusted test anchor, including macOS /var -> /private/var.
            $physical='/'
            foreach($part in ([IO.Path]::GetFullPath($TestDrive)).Trim('/').Split('/')){
                $item=[IO.DirectoryInfo]::new((Join-Path $physical $part));$target=$item.ResolveLinkTarget($true)
                $physical=if($null -eq $target){$item.FullName}else{$target.FullName}
            }
            $script:SourceCacheTestRoot=$physical
        }
        $launcher=Join-Path $script:RepositoryRoot 'scripts/bootstrap-ai-instructions-installed.ps1'
        $text=[IO.File]::ReadAllText($launcher)
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        $parser=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-InstalledAiInstructionsFailureDisposition'},$true)
        . ([scriptblock]::Create($parser.Extent.Text))
        # Exercise the real final launcher block with a parameter-recording
        # multisource fixture. Its earlier inventory gate is covered by installer
        # tests; CloudT1b additionally runs the complete verified launcher.
        $script:CacheLauncherTail=$text.Substring($text.LastIndexOf('$runtimeReadLock = Open-InstalledRuntimeReadLock',[StringComparison]::Ordinal))

        function New-SourceCacheLauncherFixture {
            param([string]$Name,[switch]$WithoutCache)
            $fixtureHome=Join-Path $script:SourceCacheTestRoot $Name;[void][IO.Directory]::CreateDirectory($fixtureHome)
            $runtime=Join-Path $fixtureHome 'hooks/ai-instructions-runtime';[void][IO.Directory]::CreateDirectory((Join-Path $runtime 'catalog'))
            Copy-Item (Join-Path $script:RepositoryRoot 'scripts/skills-source-retrieval.psm1') (Join-Path $runtime 'skills-source-retrieval.psm1')
            $commit='c'*40;$repository='https://github.com/example/instructions.git'
            $configuration=@{catalog=@{ref=$commit;repository=$repository}}
            $instruction=[Text.Encoding]::UTF8.GetBytes('instruction archive');$source=[Text.Encoding]::UTF8.GetBytes('source archive')
            $ih=Get-TestFileSha256Bytes $instruction;$sh=Get-TestFileSha256Bytes $source
            $lockPath=Join-Path $runtime 'catalog/skills-catalog-lock.json'
            [IO.File]::WriteAllText($lockPath,(@{sources=@(@{id='source-a';resolvedCommit=('a'*40);archiveSha256=$sh})}|ConvertTo-Json -Depth 6))
            $manifest=@{schemaVersion=1;commit=$commit;repository=$repository;lockSha256=(Get-TestFileSha256 $lockPath);instruction=@{fileName="$ih.zip";sha256=$ih};sources=@(@{id='source-a';resolvedCommit=('a'*40);archiveSha256=$sh;fileName="$sh.zip"})}
            $cache=Join-Path $fixtureHome 'ai-instructions-source-cache'
            if(-not$WithoutCache){
                $lease=Open-PlatformDirectory -Root $fixtureHome -RelativePath 'ai-instructions-source-cache' -CreatePrivate
                try{
                    foreach($pair in @(@{Name="$ih.zip";Bytes=$instruction},@{Name="$sh.zip";Bytes=$source},@{Name='manifest.json';Bytes=([Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 8)))})){
                        $file=Open-PlatformFile -ParentLease $lease -Leaf $pair.Name -Access ReadWrite -CreateMode CreateNew
                        try{$file.WriteNewBytes($pair.Bytes)}finally{$file.Dispose()}
                    }
                }finally{$lease.Dispose()}
            }
            $record=Join-Path $fixtureHome 'record.json'
            $fanout=@'
param($CatalogPath,$LockPath,$ConfigurationPath,$RuntimeRoot,$UserHome,$TargetRoot,[switch]$WhatIf,$InstructionSourceArchivePath,$InstructionSourceCommit,[hashtable]$SourceArchivePaths)
$record=@{overrides=$PSBoundParameters.ContainsKey('InstructionSourceArchivePath');commit=$InstructionSourceCommit;instruction=$null;source=$null}
if($record.overrides){$record.instruction=[IO.File]::ReadAllText($InstructionSourceArchivePath);$record.source=[IO.File]::ReadAllText($SourceArchivePaths['source-a'])}
[IO.File]::WriteAllText((Join-Path $UserHome 'record.json'),($record|ConvertTo-Json))
'@
            $fanoutPath=Join-Path $fixtureHome 'fanout.ps1';[IO.File]::WriteAllText($fanoutPath,$fanout)
            $harness=Join-Path $fixtureHome 'launcher.ps1'
            $header=@'
param($FixtureHome,$PlatformManifest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$codexHome=$FixtureHome;$runtimeRoot=Join-Path $codexHome 'hooks/ai-instructions-runtime'
$catalogPath=Join-Path $runtimeRoot 'catalog/skills-catalog.json';$lockPath=Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json'
$configurationPath=Join-Path $codexHome 'configuration.json';$platformRuntimeManifestPath=$PlatformManifest
$UserHome=$FixtureHome;$TargetRoot=$FixtureHome;$WhatIf=$false;$bootstrapPath=Join-Path $FixtureHome 'fanout.ps1'
function Open-InstalledRuntimeReadLock {return [IO.MemoryStream]::new()}
function Assert-NoLauncherInterruptedInstallResidue {}
function Assert-VerifiedInstalledRuntime {return [pscustomobject]@{Configuration=(Get-Content -Raw $configurationPath|ConvertFrom-Json);Bundle=[pscustomobject]@{commit=('c'*40)}}}
'@
            [IO.File]::WriteAllText((Join-Path $fixtureHome 'configuration.json'),($configuration|ConvertTo-Json -Depth 6))
            [IO.File]::WriteAllText($harness,$header+"`n"+$script:CacheLauncherTail)
            return [pscustomobject]@{Home=$fixtureHome;Runtime=$runtime;Cache=$cache;Manifest=$manifest;Harness=$harness;Record=$record}
        }
        function Get-TestFileSha256Bytes {
            param([byte[]]$Bytes)
            $sha=[Security.Cryptography.SHA256]::Create()
            try{return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        }
        function Invoke-SourceCacheLauncherFixture {
            param($Fixture)
            $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach($arg in @('-NoProfile','-NonInteractive','-File',$Fixture.Harness,'-FixtureHome',$Fixture.Home,'-PlatformManifest',(Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1'))){$start.ArgumentList.Add($arg)}
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.Environment['HOME']=$Fixture.Home;$start.Environment['USERPROFILE']=$Fixture.Home;$start.Environment['CODEX_HOME']=$Fixture.Home
            $process=[Diagnostics.Process]::Start($start)
            try{
                $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                if(-not$process.WaitForExit(60000)){$process.Kill($true);throw 'Cache launcher fixture timed out.'}
                $process.WaitForExit()
                return [pscustomobject]@{ExitCode=$process.ExitCode;Text=($stdout.Result+$stderr.Result)}
            }finally{$process.Dispose()}
        }
    }

    # Scenario: Child output contains ANSI and interpolated source text before its final updater disposition.
    # Purpose: Ignore the garbage-producing source marker and prefer the last well-formed updater marker.
    It 'UnitT00_parses_the_real_updater_disposition_after_ANSI_source_lines' {
        $message=([string][char]27)+'[31mAt update-ai-instructions.ps1:123'+"`n"+'[classification=$($disposition.classification); retryable=$retryable]'+"`n"+'AI instructions updater stopped [classification=operational; installationState=not-installed; retryable=false].'+([string][char]27)+'[0m'+"`n"+'[classification=sandbox; retryable=true]'
        $result=Get-InstalledAiInstructionsFailureDisposition -Message $message
        $result.classification|Should BeExactly operational;$result.retryable|Should Be $false
        (Get-InstalledAiInstructionsFailureDisposition -Message '[classification=integrity; retryable=false] [classification=configuration; retryable=false]').classification|Should BeExactly configuration
    }

    # Scenario: No cache was written (the default Windows installation path).
    # Purpose: Preserve multisource invocation without archive overrides.
    It 'UnitT10_calls_multisource_without_overrides_when_cache_is_absent' {
        foreach($kind in @('root','manifest')){
            $fixture=New-SourceCacheLauncherFixture "no-cache-$kind" -WithoutCache:($kind -ceq 'root')
            if($kind -ceq 'manifest'){[IO.File]::Delete((Join-Path $fixture.Cache 'manifest.json'))}
            $run=Invoke-SourceCacheLauncherFixture $fixture
            $run.ExitCode|Should Be 0
            (Get-Content -Raw $fixture.Record|ConvertFrom-Json).overrides|Should Be $false
        }
    }

    # Scenario: The cached commit or raw lock hash belongs to a previous runtime generation.
    # Purpose: Report staleness once and retain the normal download path.
    It 'UnitT20_ignores_stale_commit_or_lock_with_an_information_line' {
        foreach($kind in @('commit','lock')){
            $fixture=New-SourceCacheLauncherFixture "stale-$kind"
            if($kind -ceq 'commit'){$fixture.Manifest.commit='d'*40}else{$fixture.Manifest.lockSha256='e'*64}
            [IO.File]::WriteAllText((Join-Path $fixture.Cache 'manifest.json'),($fixture.Manifest|ConvertTo-Json -Depth 8))
            $run=Invoke-SourceCacheLauncherFixture $fixture
            $run.ExitCode|Should Be 0;$run.Text|Should Match 'cache is stale'
            (Get-Content -Raw $fixture.Record|ConvertFrom-Json).overrides|Should Be $false
        }
    }

    # Scenario: Matching cache metadata refers to tampered instruction/source bytes, missing files or malformed metadata.
    # Purpose: Fail with an integrity disposition before multisource, without falling back to downloads.
    It 'UnitT30_refuses_matching_corrupt_or_incomplete_cache' {
        foreach($kind in @('instruction','source','missing','malformed','malformed-metadata')){
            $fixture=New-SourceCacheLauncherFixture "corrupt-$kind"
            switch($kind){
                instruction {[IO.File]::WriteAllText((Join-Path $fixture.Cache $fixture.Manifest.instruction.fileName),'tampered')}
                source {[IO.File]::WriteAllText((Join-Path $fixture.Cache $fixture.Manifest.sources[0].fileName),'tampered')}
                missing {[IO.File]::Delete((Join-Path $fixture.Cache $fixture.Manifest.instruction.fileName))}
                malformed {[IO.File]::WriteAllText((Join-Path $fixture.Cache 'manifest.json'),'{')}
                malformed-metadata {$fixture.Manifest.instruction.fileName=@($fixture.Manifest.instruction.fileName);[IO.File]::WriteAllText((Join-Path $fixture.Cache 'manifest.json'),($fixture.Manifest|ConvertTo-Json -Depth 8))}
            }
            $run=Invoke-SourceCacheLauncherFixture $fixture
            $run.ExitCode|Should Not Be 0;$run.Text|Should Match 'classification=integrity'
            Test-Path $fixture.Record|Should Be $false
        }
    }

    # Scenario: Every cached archive matches the manifest and active runtime lock.
    # Purpose: Pass verified private snapshots and exact commit to multisource, then remove the snapshots.
    It 'UnitT40_passes_matching_verified_cache_overrides' {
        $fixture=New-SourceCacheLauncherFixture 'valid-cache'
        $run=Invoke-SourceCacheLauncherFixture $fixture
        if($run.ExitCode -ne 0){throw $run.Text}
        $record=Get-Content -Raw $fixture.Record|ConvertFrom-Json
        $record.overrides|Should Be $true;$record.commit|Should BeExactly ('c'*40)
        $record.instruction|Should BeExactly 'instruction archive';$record.source|Should BeExactly 'source archive'
        # The shared store persists so another reader can create its snapshot.
        Test-Path (Join-Path $fixture.Cache '.ai-instructions-txn')|Should Be $true
        @(Get-ChildItem -Force (Join-Path $fixture.Cache '.ai-instructions-txn')).Count|Should Be 0
    }

    # Scenario: Retrieval writes a umask-mode archive, then the next source download fails.
    # Purpose: Clean incomplete downloads without requiring published-file modes and permit a later publication.
    It 'UnitT50_retries_publication_after_a_partial_source_download_failure' {
        $fixture=New-SourceCacheLauncherFixture 'partial-download' -WithoutCache
        Copy-Item (Join-Path $fixture.Home 'configuration.json') (Join-Path $fixture.Home 'ai-instructions-sync.json')
        [IO.File]::WriteAllText((Join-Path $fixture.Runtime 'runtime-bundle.json'),('{"commit":"'+('c'*40)+'"}'))
        $lockPath=Join-Path $fixture.Runtime 'catalog/skills-catalog-lock.json'
        $document=Get-Content -Raw $lockPath|ConvertFrom-Json
        $document.sources+=@([pscustomobject]@{id='source-b';resolvedCommit=('b'*40);archiveSha256=$document.sources[0].archiveSha256})
        [IO.File]::WriteAllText($lockPath,($document|ConvertTo-Json -Depth 6))
        $retrieval=Import-Module (Join-Path $fixture.Runtime 'skills-source-retrieval.psm1') -Force -PassThru
        & $retrieval {
            $script:FailSecondDownload=$true
            function script:Get-SkillsSourceArchives {
                param($Plan,[string]$DestinationRoot)
                $result=@{}
                foreach($source in $Plan.Sources){
                    if($script:FailSecondDownload -and $source.id -ceq 'source-b'){throw 'Fixture source download failed.'}
                    $path=Join-Path $DestinationRoot ($source.id+'.zip')
                    [IO.File]::WriteAllText($path,'source archive')
                    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){[IO.File]::SetUnixFileMode($path,[IO.UnixFileMode]420)}
                    $result[[string]$source.id]=$path
                }
                return $result
            }
        }
        $publish=@{CodexHome=$fixture.Home;RuntimeRoot=$fixture.Runtime;ExpectedCommit=('c'*40);InstructionArchiveBytes=[Text.Encoding]::UTF8.GetBytes('instruction archive')}
        try {
            {Publish-AiInstructionsSourceCache @publish}|Should Throw 'Fixture source download failed.'
            Test-Path (Join-Path $fixture.Cache 'manifest.json')|Should Be $false
            @(Get-ChildItem -Force (Join-Path $fixture.Cache '.ai-instructions-txn')).Count|Should Be 0
            & $retrieval {$script:FailSecondDownload=$false}
            Publish-AiInstructionsSourceCache @publish
            $configuration=Get-Content -Raw (Join-Path $fixture.Home 'ai-instructions-sync.json')|ConvertFrom-Json
            $opened=Open-AiInstructionsSourceCache -CodexHome $fixture.Home -RuntimeRoot $fixture.Runtime -Configuration $configuration -Bundle ([pscustomobject]@{commit=('c'*40)})
            try {
                $opened.Arguments.SourceArchivePaths.Count|Should Be 2
                foreach($path in $opened.Arguments.SourceArchivePaths.Values){[IO.File]::ReadAllText($path)|Should BeExactly 'source archive'}
            } finally {Remove-AiSourceCacheSnapshot $opened.Snapshot}
        } finally {Remove-Module $retrieval -Force}
    }

    # Scenario: An aborted process leaves an owned 0644 download inside its private transaction directory.
    # Purpose: Accept owned abandoned staging while preserving strict modes for published entries.
    It 'UnitT60_publishes_with_an_abandoned_umask_mode_download' {
        $fixture=New-SourceCacheLauncherFixture 'abandoned-download'
        Copy-Item (Join-Path $fixture.Home 'configuration.json') (Join-Path $fixture.Home 'ai-instructions-sync.json')
        [IO.File]::WriteAllText((Join-Path $fixture.Runtime 'runtime-bundle.json'),('{"commit":"'+('c'*40)+'"}'))
        $stage=Open-PlatformDirectory -Root $fixture.Cache -RelativePath ('.ai-instructions-txn/'+('a'*32)) -CreatePrivate
        try {
            $path=Join-Path $fixture.Cache ('.ai-instructions-txn/'+('a'*32)+'/source-a.zip')
            [IO.File]::WriteAllText($path,'incomplete download')
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){[IO.File]::SetUnixFileMode($path,[IO.UnixFileMode]420)}
        } finally {$stage.Dispose()}
        $retrieval=Import-Module (Join-Path $fixture.Runtime 'skills-source-retrieval.psm1') -Force -PassThru
        & $retrieval {
            function script:Get-SkillsSourceArchives {
                param($Plan,[string]$DestinationRoot)
                $path=Join-Path $DestinationRoot 'source-a.zip';[IO.File]::WriteAllText($path,'source archive')
                return @{'source-a'=$path}
            }
        }
        try {
            $publish=@{CodexHome=$fixture.Home;RuntimeRoot=$fixture.Runtime;ExpectedCommit=('c'*40);InstructionArchiveBytes=[Text.Encoding]::UTF8.GetBytes('instruction archive')}
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
                $manifestPath=Join-Path $fixture.Cache 'manifest.json'
                [IO.File]::SetUnixFileMode($manifestPath,[IO.UnixFileMode]420)
                try{{Publish-AiInstructionsSourceCache @publish}|Should Throw 'private 0700/0600 modes'}
                finally{[IO.File]::SetUnixFileMode($manifestPath,[IO.UnixFileMode]384)}
            }
            Publish-AiInstructionsSourceCache @publish
            (Get-Content -Raw (Join-Path $fixture.Cache 'manifest.json')|ConvertFrom-Json).commit|Should BeExactly ('c'*40)
            [IO.File]::ReadAllText($path)|Should BeExactly 'incomplete download'
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
                foreach($entry in Get-ChildItem -LiteralPath $fixture.Cache -File){[int][IO.File]::GetUnixFileMode($entry.FullName)|Should Be 384}
            }
        } finally {Remove-Module $retrieval -Force}
    }

    # Scenario: One reader finishes while another has opened the store but has not created a snapshot.
    # Purpose: Keep the shared directory alive through both readers' cleanup and subsequent cache reads.
    It 'UnitT70_keeps_the_snapshot_store_between_interleaved_readers' {
        $fixture=New-SourceCacheLauncherFixture 'interleaved-readers'
        $retrieval=Import-Module (Join-Path $fixture.Runtime 'skills-source-retrieval.psm1') -Force -PassThru
        $configuration=Get-Content -Raw (Join-Path $fixture.Home 'configuration.json')|ConvertFrom-Json
        $arguments=@{CodexHome=$fixture.Home;RuntimeRoot=$fixture.Runtime;Configuration=$configuration;Bundle=[pscustomobject]@{commit=('c'*40)}}
        $first=$null;$second=$null;$store=$null
        try {
            $first=Open-AiInstructionsSourceCache @arguments
            $store=Open-PlatformDirectory -Root $fixture.Cache -RelativePath '.ai-instructions-txn'
            Remove-AiSourceCacheSnapshot $first.Snapshot;$first=$null
            Test-Path (Join-Path $fixture.Cache '.ai-instructions-txn')|Should Be $true
            $second=Open-AiInstructionsSourceCache @arguments
            [IO.File]::ReadAllText($second.Arguments.InstructionSourceArchivePath)|Should BeExactly 'instruction archive'
            $store.Dispose();$store=$null
            Remove-AiSourceCacheSnapshot $second.Snapshot;$second=$null
            Test-Path (Join-Path $fixture.Cache '.ai-instructions-txn')|Should Be $true
            @(Get-ChildItem -Force (Join-Path $fixture.Cache '.ai-instructions-txn')).Count|Should Be 0
        } finally {
            if($null -ne $store){$store.Dispose()}
            if($null -ne $first){Remove-AiSourceCacheSnapshot $first.Snapshot}
            if($null -ne $second){Remove-AiSourceCacheSnapshot $second.Snapshot}
            Remove-Module $retrieval -Force
        }
    }
}
