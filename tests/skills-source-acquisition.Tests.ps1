$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:AcquisitionModule = Join-Path $script:RepositoryRoot 'scripts\skills-source-acquisition.psm1'

Import-Module $script:AcquisitionModule -Force

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

function New-TestSkillSourceArchive {
    param(
        [string] $Name,
        [string] $SkillId,
        [string] $SkillText
    )

    $sourceRoot = Join-Path $TestDrive "$Name-root"
    $repositoryRoot = Join-Path $sourceRoot "$Name-repository"
    $skillRoot = Join-Path $repositoryRoot ".agents\skills\$SkillId"
    New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), $SkillText, (New-Object System.Text.UTF8Encoding($false)))
    $contentHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot

    $archivePath = Join-Path $TestDrive "$Name.zip"
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
            [pscustomobject]@{
                id = 'source-a'
                archiveSha256 = $AlphaArchiveHash
                resolvedCommit = ('a' * 40)
            },
            [pscustomobject]@{
                id = 'source-b'
                archiveSha256 = $BetaArchiveHash
                resolvedCommit = ('b' * 40)
            }
        )
        Skills = @(
            [pscustomobject]@{
                id = 'skill-a'
                sourceId = 'source-a'
                sourcePath = '.agents/skills/skill-a'
                contentSha256 = $AlphaContentHash
            },
            [pscustomobject]@{
                id = 'skill-b'
                sourceId = 'source-b'
                sourcePath = '.agents/skills/skill-b'
                contentSha256 = $BetaContentHash
            }
        )
    }
}

Describe 'Skills source archive acquisition' {
    It 'UnitT10_stages_two_independent_selected_sources_and_validates_skill_content_locks' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan `
            -AlphaArchiveHash (Get-TestFileSha256 -Path $alpha.ArchivePath) `
            -BetaArchiveHash (Get-TestFileSha256 -Path $beta.ArchivePath) `
            -AlphaContentHash $alpha.ContentHash `
            -BetaContentHash $beta.ContentHash

        $result = Expand-ValidatedSkillsSourceArchives `
            -Plan $plan `
            -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } `
            -WorkingRoot (Join-Path $TestDrive 'staging')

        @($result.Sources).Count | Should Be 2
        @($result.Skills).Count | Should Be 2
        @($result.Skills)[0].contentSha256 | Should Be $alpha.ContentHash
        @($result.Skills)[1].contentSha256 | Should Be $beta.ContentHash
    }

    It 'UnitT20_rejects_an_archive_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash ('0' * 64) -BetaArchiveHash (Get-TestFileSha256 -Path $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash

        { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*archive SHA-256 mismatch*'
    }

    It 'UnitT30_rejects_a_missing_selected_source_archive' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 -Path $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 -Path $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash

        { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*has no archive input*'
    }

    It 'UnitT40_rejects_a_missing_skill_in_a_selected_source' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'different-skill' -SkillText '# Other'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 -Path $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 -Path $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash

        { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*is missing from source*'
    }

    It 'UnitT50_rejects_a_skill_content_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 -Path $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 -Path $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash

        { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*content SHA-256 mismatch*'
    }
}
