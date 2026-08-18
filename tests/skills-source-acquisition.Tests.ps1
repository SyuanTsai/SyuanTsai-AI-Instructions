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

    $archivePath = Join-Path $TestDrive "$Name.zip"
    Compress-Archive -Path $repositoryRoot -DestinationPath $archivePath
    return $archivePath
}

function New-TestAcquisitionPlan {
    param(
        [string] $AlphaHash,
        [string] $BetaHash
    )

    return [pscustomobject]@{
        Sources = @(
            [pscustomobject]@{
                id = 'source-a'
                archiveSha256 = $AlphaHash
                resolvedCommit = ('a' * 40)
            },
            [pscustomobject]@{
                id = 'source-b'
                archiveSha256 = $BetaHash
                resolvedCommit = ('b' * 40)
            }
        )
        Skills = @(
            [pscustomobject]@{
                id = 'skill-a'
                sourceId = 'source-a'
                sourcePath = '.agents/skills/skill-a'
            },
            [pscustomobject]@{
                id = 'skill-b'
                sourceId = 'source-b'
                sourcePath = '.agents/skills/skill-b'
            }
        )
    }
}

Describe 'Skills source archive acquisition' {
    # Scenario: Two selected sources are supplied as independently pinned archives.
    # Purpose: Prove both archives are validated and staged before their Skills are resolved.
    It 'UnitT10_stages_two_independent_selected_sources' {
        $alphaArchive = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $betaArchive = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan `
            -AlphaHash (Get-TestFileSha256 -Path $alphaArchive) `
            -BetaHash (Get-TestFileSha256 -Path $betaArchive)

        $result = Expand-ValidatedSkillsSourceArchives `
            -Plan $plan `
            -SourceArchivePaths @{
                'source-a' = $alphaArchive
                'source-b' = $betaArchive
            } `
            -WorkingRoot (Join-Path $TestDrive 'staging')

        @($result.Sources).Count | Should Be 2
        @($result.Skills).Count | Should Be 2
        (Get-Content -Raw -LiteralPath (Join-Path @($result.Skills)[0].skillRootPath 'SKILL.md')) | Should Be '# Skill A'
        (Get-Content -Raw -LiteralPath (Join-Path @($result.Skills)[1].skillRootPath 'SKILL.md')) | Should Be '# Skill B'
    }

    # Scenario: A source archive does not match its lock pin.
    # Purpose: Fail before the archive can contribute any target mutation input.
    It 'UnitT20_rejects_an_archive_hash_mismatch' {
        $alphaArchive = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $betaArchive = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan -AlphaHash ('0' * 64) -BetaHash (Get-TestFileSha256 -Path $betaArchive)

        { Expand-ValidatedSkillsSourceArchives `
            -Plan $plan `
            -SourceArchivePaths @{ 'source-a' = $alphaArchive; 'source-b' = $betaArchive } `
            -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*archive SHA-256 mismatch*'
    }

    # Scenario: A selected source is absent from the provided archive map.
    # Purpose: Never silently skip a required source.
    It 'UnitT30_rejects_a_missing_selected_source_archive' {
        $alphaArchive = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $betaArchive = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan `
            -AlphaHash (Get-TestFileSha256 -Path $alphaArchive) `
            -BetaHash (Get-TestFileSha256 -Path $betaArchive)

        { Expand-ValidatedSkillsSourceArchives `
            -Plan $plan `
            -SourceArchivePaths @{ 'source-a' = $alphaArchive } `
            -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*has no archive input*'
    }

    # Scenario: A valid archive is pinned but does not contain the selected Skill.
    # Purpose: Fail closed after staging and before any desired-set mutation stage.
    It 'UnitT40_rejects_a_missing_skill_in_a_selected_source' {
        $alphaArchive = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'different-skill' -SkillText '# Other'
        $betaArchive = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText '# Skill B'
        $plan = New-TestAcquisitionPlan `
            -AlphaHash (Get-TestFileSha256 -Path $alphaArchive) `
            -BetaHash (Get-TestFileSha256 -Path $betaArchive)

        { Expand-ValidatedSkillsSourceArchives `
            -Plan $plan `
            -SourceArchivePaths @{ 'source-a' = $alphaArchive; 'source-b' = $betaArchive } `
            -WorkingRoot (Join-Path $TestDrive 'staging') } |
            Should Throw '*is missing from source*'
    }
}
