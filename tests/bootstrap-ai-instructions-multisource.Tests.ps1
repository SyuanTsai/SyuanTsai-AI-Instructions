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
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        [System.IO.Path]::GetFullPath($SourceRoot),
        [System.IO.Path]::GetFullPath($ArchivePath),
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )
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
    param([string]$Root,[string]$ArchivePath)
    $repositoryRoot=Join-Path $Root 'external-skills-aaaaaaaa'
    $skillRoot=Join-Path $repositoryRoot '.agents\skills\skill-a'
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $skillRoot|Out-Null
    Set-TestUtf8Text (Join-Path $skillRoot 'SKILL.md') "---`nname: skill-a`ndescription: Selected external fixture skill.`n---`n`n# Skill A`n"
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
    if($MissingSelectionArrays){$catalogSelection=[ordered]@{repository='https://github.com/example/catalog.git';ref='main';profiles=@()}}
    else{$catalogSelection=[ordered]@{repository='https://github.com/example/catalog.git';ref='main';profiles=@();includeSkills=@('skill-a');excludeSkills=@()}}
    $configuration=[ordered]@{schemaVersion=3;autoCommitRepositoryUrls=@($script:TestRepositoryUrl);excludedRepositoryUrls=@();excludedRepositoryPaths=@();catalog=$catalogSelection}
    Set-TestUtf8Text $ConfigurationPath (($configuration|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n")
}

Describe 'bootstrap-ai-instructions-multisource' {
    # Scenario: Schema v3 selects one locally pinned Skill source and targets a disposable allowlisted Git repository.
    # Purpose: Exercise validation, routing, acquisition, composition, schema-v2 handoff, and legacy mutation end to end without network access.
    It 'InterT10_executes_a_selected_skill_local_source_end_to_end' {
        $catalogPath=Join-Path $TestDrive 'catalog.json';$lockPath=Join-Path $TestDrive 'catalog.lock.json';$configurationPath=Join-Path $TestDrive 'sync-config.json';$instructionArchive=Join-Path $TestDrive 'instruction-source.zip';$skillArchivePath=Join-Path $TestDrive 'source-a.zip';$targetRoot=Join-Path $TestDrive 'target'
        New-TestInstructionArchive (Join-Path $TestDrive 'instruction-root') $instructionArchive
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive
        New-TestTargetRepository $targetRoot

        & $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath -InstructionSourceArchivePath $instructionArchive -SourceArchivePaths @{'source-a'=$skillArchivePath} -TargetRoot $targetRoot

        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim()|Should Be '# Codex Base'
        Test-Path (Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md')|Should Be $true
        Test-Path (Join-Path $targetRoot '.agents\skills\legacy-skill')|Should Be $false
        (Get-Content -Raw (Join-Path $targetRoot '.agents\skills\skill-a\SKILL.md'))|Should Match 'Selected external fixture skill'
        Test-Path (Join-Path $targetRoot '.codex\ai-instructions.manifest.json')|Should Be $true
        (@(Invoke-TestGit $targetRoot @('log','-1','--pretty=%s')) -join '').Trim()|Should Be 'chore: add shared AI instructions'
        @(Invoke-TestGit $targetRoot @('status','--porcelain')).Count|Should Be 0
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

    # Scenario: Schema v3 personal configuration omits required includeSkills and excludeSkills arrays.
    # Purpose: Fail before acquisition with an actionable configuration message instead of a strict-mode property error.
    It 'InterT20_rejects_missing_selection_arrays_with_an_actionable_error' {
        $catalogPath=Join-Path $TestDrive 'bad-catalog.json';$lockPath=Join-Path $TestDrive 'bad-catalog.lock.json';$configurationPath=Join-Path $TestDrive 'bad-sync-config.json';$skillArchivePath=Join-Path $TestDrive 'bad-source-a.zip'
        $missingInstructionArchive=Join-Path $TestDrive 'bad-missing-instructions.zip'
        $skillArchive=New-TestSkillArchive (Join-Path $TestDrive 'bad-skill-root') $skillArchivePath
        New-TestDocuments $catalogPath $lockPath $configurationPath $skillArchive -MissingSelectionArrays
        $thrown=$false;$message=$null
        try{& $script:BootstrapScript -CatalogPath $catalogPath -LockPath $lockPath -ConfigurationPath $configurationPath -SourceArchivePaths @{'source-a'=$skillArchivePath} -InstructionSourceArchivePath $missingInstructionArchive}catch{$thrown=$true;$message=$_.Exception.Message}
        $thrown|Should Be $true
        $message|Should Match "missing required property 'includeSkills'"
    }
}
