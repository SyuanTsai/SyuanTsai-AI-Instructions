$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:AcquisitionModule = Join-Path $script:RepositoryRoot 'scripts\skills-source-acquisition.psm1'

Import-Module $script:AcquisitionModule -Force

function Assert-ThrowsMessage {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Pattern
    )

    $thrown = $false
    $message = $null
    try {
        & $Action
    }
    catch {
        $thrown = $true
        $message = $_.Exception.Message
    }
    $thrown | Should Be $true
    $message | Should Match $Pattern
}

function Get-TestFileSha256 {
    param([string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-TestSkillText {
    param(
        [Parameter(Mandatory = $true)][string] $SkillId,
        [string] $Description = 'Test skill description.'
    )

    return "---`nname: $SkillId`ndescription: $Description`n---`n`n# $SkillId`n"
}

function New-TestSkillSourceArchive {
    param(
        [string] $Name,
        [string] $SkillId,
        [string] $SkillText
    )

    $sourceRoot = Join-Path $TestDrive "$Name-root"
    $archivePath = Join-Path $TestDrive "$Name.zip"
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

    $repositoryRoot = Join-Path $sourceRoot "$Name-repository"
    $skillRoot = Join-Path $repositoryRoot ".agents\skills\$SkillId"
    New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), $SkillText, (New-Object System.Text.UTF8Encoding($false)))
    $contentHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot

    Compress-Archive -Path $repositoryRoot -DestinationPath $archivePath
    return [pscustomobject]@{
        ArchivePath = $archivePath
        ContentHash = $contentHash
    }
}

function New-TestAcquisitionPlan {
    param(
        [string] $AlphaArchiveHash,
        [string] $BetaArchiveHash,
        [string] $AlphaContentHash,
        [string] $BetaContentHash
    )

    return [pscustomobject]@{
        Sources = @(
            [pscustomobject]@{ id='source-a'; archiveSha256=$AlphaArchiveHash; resolvedCommit=('a' * 40) },
            [pscustomobject]@{ id='source-b'; archiveSha256=$BetaArchiveHash; resolvedCommit=('b' * 40) }
        )
        Skills = @(
            [pscustomobject]@{ id='skill-a'; sourceId='source-a'; sourcePath='.agents/skills/skill-a'; contentSha256=$AlphaContentHash },
            [pscustomobject]@{ id='skill-b'; sourceId='source-b'; sourcePath='.agents/skills/skill-b'; contentSha256=$BetaContentHash }
        )
    }
}

Describe 'Skills source archive acquisition' {
    It 'UnitT10_stages_two_independent_selected_sources_and_validates_skill_content_locks' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash

        $result = Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging')

        @($result.Sources).Count | Should Be 2
        @($result.Skills).Count | Should Be 2
        @($result.Skills)[0].contentSha256 | Should Be $alpha.ContentHash
        @($result.Skills)[1].contentSha256 | Should Be $beta.ContentHash
    }

    It 'UnitT20_rejects_an_archive_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash ('0' * 64) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'archive SHA-256 mismatch'
    }

    It 'UnitT30_rejects_a_missing_selected_source_archive' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'has no archive input'
    }

    It 'UnitT40_rejects_a_missing_skill_in_a_selected_source' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'different-skill' -SkillText (New-TestSkillText -SkillId 'different-skill')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'is missing from source'
    }

    It 'UnitT50_rejects_a_skill_content_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'content SHA-256 mismatch'
    }

    It 'UnitT60_rejects_SKILL_md_without_frontmatter' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'must start with YAML frontmatter'
    }

    It 'UnitT70_rejects_SKILL_md_name_that_does_not_match_stable_id' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'different-skill')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'does not match its stable Skill ID'
    }

    It 'UnitT80_rejects_SKILL_md_without_description' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`nname: skill-a`n---`n`n# skill-a`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'frontmatter is missing description'
    }

    It 'UnitT90_rejects_SKILL_md_without_name' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`ndescription: Test skill.`n---`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'frontmatter is missing name'
    }

    It 'UnitT100_rejects_malformed_YAML_scalar' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`nname: skill-a`ndescription: [unterminated`n---`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'malformed YAML flow-sequence syntax'
    }
}
