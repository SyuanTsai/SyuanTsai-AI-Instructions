$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BootstrapScript = Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions-multisource.ps1'
$script:TestRepositoryUrl = 'git@example.com:team/multisource-bootstrap-test.git'
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-acquisition.psm1') -Force

function Invoke-TestGit {
    param([string]$Repository,[string[]]$Arguments)
    $output=& git -C $Repository @Arguments 2>&1
    if($LASTEXITCODE-ne0){throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"}
    return $output
}
function Set-TestUtf8Text {
    param([string]$Path,[string]$Value)
    [System.IO.File]::WriteAllText($Path,$Value,(New-Object System.Text.UTF8Encoding($false)))
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
    New-Item -ItemType Directory -Force -Path (Join-Path $repositoryRoot '.codex\AI-Rules'),(Join-Path $repositoryRoot '.github\AI-Rules'),(Join-Path $repositoryRoot '.agents\skills\legacy-skill')|Out-Null
    Set-TestUtf8Text (Join-Path $repositoryRoot '.codex\AGENTS.en.md') "# Codex Base`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.codex\AI-Rules\core.en.md') "# Codex Rule`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.github\copilot-instructions.en.md') "# Copilot Base`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.github\AI-Rules\core.en.md') "# Copilot Rule`n"
    Set-TestUtf8Text (Join-Path $repositoryRoot '.agents\skills\legacy-skill\SKILL.md') "---`nname: legacy-skill`ndescription: Legacy fixture skill.`n---`n"
    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $ArchivePath
}
function New-TestSkillArchive {
    param(
        [string]$Root,
        [string]$ArchivePath,
        [string]$Marker = 'Selected external fixture skill.'
    )
    $repositoryRoot=Join-Path $Root 'external-skills-aaaaaaaa'
    $skillRoot=Join-Path $repositoryRoot '.agents\skills\skill-a'
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $skillRoot|Out-Null
    Set-TestUtf8Text (Join-Path $skillRoot 'SKILL.md') "---`nname: skill-a`ndescription: $Marker`n---`n`n# Skill A`n"
    $contentHash=Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot
    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $ArchivePath
    return [pscustomobject]@{ArchivePath=$ArchivePath;ArchiveSha256=(Get-TestFileSha256 $ArchivePath);ContentSha256=$contentHash}
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
        Test-Path (Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md')|Should Be $true
        Test-Path (Join-Path $targetRoot '.agents\skills\legacy-skill')|Should Be $false
        (Get-Content -Raw (Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md'))|Should Match 'Selected external fixture skill'
        Test-Path (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|Should Be $true
        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|ConvertFrom-Json
        $manifest.schemaVersion|Should Be 2
        [string]$manifest.catalogId|Should Be 'multisource-smoke'
        [string]$manifest.lockSha256|Should Be (Get-TestFileSha256 $lockPath)
        @($manifest.files|Where-Object {$_.artifactType -eq 'skill'}).Count|Should Be 1
        $skillEntry=@($manifest.files|Where-Object {$_.targetPath -eq '.agents/skills/skill-a/SKILL.md'})[0]
        [string]$skillEntry.artifactId|Should Be 'skill-a'
        [string]$skillEntry.sourceId|Should Be 'source-a'
        [string]$skillEntry.sourceRepository|Should Be 'https://github.com/example/source-a.git'
        [string]$skillEntry.sourceCommit|Should Be ('a'*40)
        [string]$skillEntry.sourceVersion|Should Be 'test'
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
        @($manifest.files|Where-Object {$_.sourceCommit -eq ('a'*40)}).Count|Should Be 1
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
        $skillPath=Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md'
        Set-TestUtf8Text $skillPath 'locally customized'
        $headBefore=(@(Invoke-TestGit $targetRoot @('rev-parse','HEAD')) -join '').Trim()
        $manifestBefore=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')

        Assert-ThrowsMessage { & $script:BootstrapScript @arguments } 'Cannot migrate managed manifest v1.*customized'

        (Get-Content -Raw $skillPath)|Should Be 'locally customized'
        (Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json'))|Should Be $manifestBefore
        (@(Invoke-TestGit $targetRoot @('rev-parse','HEAD')) -join '').Trim()|Should Be $headBefore
    }

    # Scenario: An existing schema-v2 target selects a new immutable source commit and content lock.
    # Purpose: Use historical per-file provenance for customization checks, then safely advance the file and root lock provenance.
    It 'InterT40_updates_an_unchanged_v2_managed_skill_to_a_new_pin' {
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

        (Get-Content -Raw (Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md'))|Should Match 'fixture skill v2'
        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|ConvertFrom-Json
        [string]$manifest.lockSha256|Should Be (Get-TestFileSha256 $lockPath)
        $entry=@($manifest.files|Where-Object {$_.targetPath -eq '.agents/skills/skill-a/SKILL.md'})[0]
        [string]$entry.sourceCommit|Should Be ('b'*40)
        [string]$entry.sourceVersion|Should Be 'test-v2'
        (@(Invoke-TestGit $targetRoot @('log','-1','--pretty=%s')) -join '').Trim()|Should Be 'initial commit'
    }

    # Scenario: A schema-v2 target has a customized managed Skill when the selected source advances.
    # Purpose: Keep the customized bytes and their historical provenance while advancing the root lock for other managed artifacts.
    It 'InterT45_preserves_a_customized_v2_skill_across_a_pin_update' {
        $catalogPath=Join-Path $TestDrive 'custom-pin-catalog.json';$lockPath=Join-Path $TestDrive 'custom-pin-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'custom-pin-sync-config.json';$instructionArchive=Join-Path $TestDrive 'custom-pin-instructions.zip';$skillArchivePath=Join-Path $TestDrive 'custom-pin-source-v1.zip';$targetRoot=Join-Path $TestDrive 'custom-pin-target'
        New-TestInstructionArchive (Join-Path $TestDrive 'custom-pin-instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'custom-pin-skill-root-v1') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot
        $arguments=@{CatalogPath=$catalogPath;LockPath=$lockPath;ConfigurationPath=$configurationPath;InstructionSourceArchivePath=$instructionArchive;InstructionSourceCommit=('c'*40);SourceArchivePaths=@{'source-a'=$skillArchivePath};TargetRoot=$targetRoot}
        & $script:BootstrapScript @arguments
        $skillPath=Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md'
        Set-TestUtf8Text $skillPath 'locally customized v2 skill'

        $newArchivePath=Join-Path $TestDrive 'custom-pin-source-v2.zip'
        $newArchive=New-TestSkillArchive (Join-Path $TestDrive 'custom-pin-skill-root-v2') $newArchivePath -Marker 'Selected external fixture skill v2.'
        $lock=Get-Content -Raw -LiteralPath $lockPath|ConvertFrom-Json
        @($lock.sources)[0].resolvedCommit=('b'*40)
        @($lock.sources)[0].resolvedVersion='test-v2'
        @($lock.sources)[0].archiveSha256=$newArchive.ArchiveSha256
        @($lock.skills)[0].contentSha256=$newArchive.ContentSha256
        Set-TestUtf8Text $lockPath ($lock|ConvertTo-Json -Depth 20)
        $arguments.SourceArchivePaths=@{'source-a'=$newArchivePath}

        & $script:BootstrapScript @arguments

        (Get-Content -Raw $skillPath)|Should Be 'locally customized v2 skill'
        $manifest=Get-Content -Raw (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|ConvertFrom-Json
        [string]$manifest.lockSha256|Should Be (Get-TestFileSha256 $lockPath)
        $entry=@($manifest.files|Where-Object {$_.targetPath -eq '.agents/skills/skill-a/SKILL.md'})[0]
        [string]$entry.sourceCommit|Should Be ('a'*40)
        [string]$entry.sourceVersion|Should Be 'test'
        (@(Invoke-TestGit $targetRoot @('status','--porcelain','.agents/skills/skill-a/SKILL.md')) -join '')|Should BeNullOrEmpty
        (@(Invoke-TestGit $targetRoot @('stash','list','--format=%s')) -join "`n")|Should Match 'PersonalAgent'
    }
}
