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

function Compress-TestDirectory {
    param([string] $SourceRoot, [string] $ArchivePath)

    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression
    $resolvedSource = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\','/'))
    $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($ArchivePath), [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $rootName = Split-Path -Leaf $resolvedSource
            foreach ($file in @(Get-ChildItem -LiteralPath $resolvedSource -Recurse -Force -File | Sort-Object FullName)) {
                $relativePath = $file.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                $entry = $archive.CreateEntry("$rootName/$relativePath", [System.IO.Compression.CompressionLevel]::Optimal)
                $input = [System.IO.File]::OpenRead($file.FullName)
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
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

    Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $archivePath
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
    # Scenario: A case-sensitive source repository contains two distinct paths that differ only by letter casing.
    # Purpose: Keep deterministic Skill content hashes bound to each exact repository path on Linux and macOS.
    It 'UnitT05_tracks_inventory_paths_with_ordinal_case_sensitivity' {
        InModuleScope skills-source-acquisition {
            # Given
            $paths = New-SkillInventoryPathMap

            # When
            $paths.Add('.agents/skills/example/A.md', 'upper')
            $paths.Add('.agents/skills/example/a.md', 'lower')

            # Then
            $paths.Count | Should Be 2
            $paths['.agents/skills/example/A.md'] | Should Be 'upper'
            $paths['.agents/skills/example/a.md'] | Should Be 'lower'
        }
    }

    # Scenario: A selected Skill contains a hidden resource whose bytes change while all visible files remain unchanged.
    # Purpose: Bind hidden and dot-prefixed resources to contentSha256 so copied Skill content cannot bypass its lock.
    It 'UnitT07_includes_hidden_resources_in_the_skill_content_hash' {
        # Given
        $repositoryRoot = Join-Path $TestDrive 'hidden-resource-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents\skills\hidden-resource-skill'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Value 'skill definition' -Encoding UTF8
        $hiddenPath = Join-Path $skillRoot '.hidden-resource'
        Set-Content -LiteralPath $hiddenPath -Value 'first value' -Encoding UTF8
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $hiddenItem = Get-Item -LiteralPath $hiddenPath
            $hiddenItem.Attributes = $hiddenItem.Attributes -bor [System.IO.FileAttributes]::Hidden
        }

        # When
        $firstHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot
        Set-Content -LiteralPath $hiddenPath -Value 'second value' -Encoding UTF8 -Force
        $secondHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot

        # Then
        $secondHash | Should Not Be $firstHash
    }

    # Scenario: Two required source archives and their selected Skills match every archive and content lock.
    # Purpose: Prove the normal multi-source staging path preserves independent provenance for each Skill.
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

    # Scenario: A required source archive's bytes do not match its locked archiveSha256.
    # Purpose: Stop before extraction so unpinned source content cannot reach composition.
    It 'UnitT20_rejects_an_archive_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash ('0' * 64) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'archive SHA-256 mismatch'
    }

    # Scenario: A hash-pinned source archive contains an entry that traverses above its assigned staging directory.
    # Purpose: Verify archive extraction fails closed without writing attacker-controlled content outside the source boundary.
    It 'UnitT25_rejects_archive_path_traversal_without_staging_escape' {
        # Given
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'traversal.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new(
                $archiveStream,
                [System.IO.Compression.ZipArchiveMode]::Create,
                $false
            )
            try {
                $entry = $archive.CreateEntry('../escaped.txt')
                $writer = [System.IO.StreamWriter]::new($entry.Open())
                try {
                    $writer.Write('must not escape')
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            $archiveStream.Dispose()
        }
        $workingRoot = Join-Path $TestDrive 'traversal-staging'
        $escapedPath = Join-Path $workingRoot 'escaped.txt'
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{
                id = 'source-a'
                archiveSha256 = Get-TestFileSha256 -Path $archivePath
                resolvedCommit = ('a' * 40)
            })
            Skills = @()
        }

        # When / Then
        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{ 'source-a' = $archivePath } `
                -WorkingRoot $workingRoot
        } '.'
        Test-Path -LiteralPath $escapedPath | Should Be $false
    }

    # Scenario: A ZIP contains two names that collide on a case-insensitive target filesystem.
    # Purpose: Reject ambiguous archives before extraction on every supported operating system.
    It 'UnitT26_rejects_case_insensitive_archive_path_collisions' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'case-collision.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('repository/File.txt','repository/file.txt')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'case-staging')
        } 'case-insensitive path collision'
    }

    # Scenario: ZIP file paths differ only in the casing of an implicit parent directory.
    # Purpose: Prevent two logical trees from merging on a case-insensitive target filesystem.
    It 'UnitT26b_rejects_case_insensitive_parent_directory_collisions' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'parent-case-collision.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('repository/Folder/first.txt','repository/folder/second.txt')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'parent-case-staging')
        } 'case-insensitive path collision'
    }

    # Scenario: A ZIP contains a symbolic-link entry under its repository root.
    # Purpose: Prevent link traversal and reparse-point behavior from escaping staged source boundaries.
    It 'UnitT27_rejects_symbolic_link_archive_entries' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'symbolic-link.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entry = $archive.CreateEntry('repository/link')
                $entry.ExternalAttributes = -1610612736
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write('../outside') } finally { $writer.Dispose() }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'link-staging')
        } 'symbolic link'
    }

    # Scenario: A ZIP contains more than one top-level repository root.
    # Purpose: Make archive root selection deterministic instead of silently choosing one tree.
    It 'UnitT28_rejects_archives_with_multiple_repository_roots' {
        Add-Type -AssemblyName System.IO.Compression
        $archivePath = Join-Path $TestDrive 'multiple-roots.zip'
        $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($name in @('first/a.txt','second/b.txt')) {
                    $entry = $archive.CreateEntry($name)
                    $writer = New-Object System.IO.StreamWriter($entry.Open())
                    try { $writer.Write($name) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{id='source-a';archiveSha256=(Get-TestFileSha256 $archivePath);resolvedCommit=('a'*40)})
            Skills = @()
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{'source-a'=$archivePath} -WorkingRoot (Join-Path $TestDrive 'roots-staging')
        } 'exactly one repository root'
    }

    # Scenario: The routing plan requires two sources but only one archive input is available.
    # Purpose: Reject incomplete acquisition instead of composing a partial desired set.
    It 'UnitT30_rejects_a_missing_selected_source_archive' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'has no archive input'
    }

    # Scenario: A caller bypasses routing validation and supplies a selected Skill path containing parent traversal.
    # Purpose: Preserve defense in depth at the archive-to-filesystem boundary.
    It 'UnitT35_rejects_an_unsafe_selected_skill_path_during_acquisition' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        $plan.Skills[0].sourcePath = '../skill-a'

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } `
                -WorkingRoot (Join-Path $TestDrive 'unsafe-path-staging')
        } 'Unsafe source path'
    }

    # Scenario: A validated source archive does not contain the selected Skill directory at its locked path.
    # Purpose: Prevent a source routing mismatch from being treated as a successful acquisition.
    It 'UnitT40_rejects_a_missing_skill_in_a_selected_source' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'different-skill' -SkillText (New-TestSkillText -SkillId 'different-skill')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'is missing from source'
    }

    # Scenario: The selected Skill directory exists in its source archive but does not contain SKILL.md.
    # Purpose: Reject an incomplete Skill definition before calculating content provenance or composing output.
    It 'UnitT45_rejects_a_selected_skill_directory_without_SKILL_md' {
        $sourceRoot = Join-Path $TestDrive 'missing-definition-root'
        $repositoryRoot = Join-Path $sourceRoot 'missing-definition-repository'
        $skillRoot = Join-Path $repositoryRoot '.agents\skills\skill-a'
        $archivePath = Join-Path $TestDrive 'missing-definition.zip'
        New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $skillRoot 'README.md') -Value 'No SKILL.md is present.' -Encoding UTF8
        Compress-TestDirectory -SourceRoot $repositoryRoot -ArchivePath $archivePath
        $plan = [pscustomobject]@{
            Sources = @([pscustomobject]@{
                id = 'source-a'
                archiveSha256 = Get-TestFileSha256 -Path $archivePath
                resolvedCommit = ('a' * 40)
            })
            Skills = @([pscustomobject]@{
                id = 'skill-a'
                sourceId = 'source-a'
                sourcePath = '.agents/skills/skill-a'
                contentSha256 = ('0' * 64)
            })
        }

        Assert-ThrowsMessage {
            Expand-ValidatedSkillsSourceArchives `
                -Plan $plan `
                -SourceArchivePaths @{ 'source-a' = $archivePath } `
                -WorkingRoot (Join-Path $TestDrive 'missing-definition-staging')
        } 'is missing SKILL.md'
    }

    # Scenario: A selected Skill exists but its deterministic inventory differs from contentSha256.
    # Purpose: Bind every copied Skill file to the immutable Lock before composition.
    It 'UnitT50_rejects_a_skill_content_hash_mismatch' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'skill-a')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash ('0' * 64) -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'content SHA-256 mismatch'
    }

    # Scenario: A selected Skill definition contains Markdown without YAML frontmatter.
    # Purpose: Reject structurally invalid Agent Skills before they enter the composed source.
    It 'UnitT60_rejects_SKILL_md_without_frontmatter' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText '# Skill A'
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'must start with YAML frontmatter'
    }

    # Scenario: SKILL.md declares a valid name that differs from the selected stable Skill ID.
    # Purpose: Keep the directory, Catalog, Lock, and Skill definition identity aligned.
    It 'UnitT70_rejects_SKILL_md_name_that_does_not_match_stable_id' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText (New-TestSkillText -SkillId 'different-skill')
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'does not match its stable Skill ID'
    }

    # Scenario: SKILL.md frontmatter declares a name but omits its required description.
    # Purpose: Enforce the minimum cross-platform Agent Skill discovery contract.
    It 'UnitT80_rejects_SKILL_md_without_description' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`nname: skill-a`n---`n`n# skill-a`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'frontmatter is missing description'
    }

    # Scenario: SKILL.md frontmatter declares a description but omits its required name.
    # Purpose: Reject a Skill whose stable identity cannot be verified.
    It 'UnitT90_rejects_SKILL_md_without_name' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`ndescription: Test skill.`n---`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'frontmatter is missing name'
    }

    # Scenario: A required frontmatter scalar starts an unterminated YAML flow collection.
    # Purpose: Fail closed on malformed YAML instead of accepting a misleading description value.
    It 'UnitT95_rejects_a_malformed_YAML_scalar' {
        $alpha = New-TestSkillSourceArchive -Name 'alpha' -SkillId 'skill-a' -SkillText "---`nname: skill-a`ndescription: [unterminated`n---`n"
        $beta = New-TestSkillSourceArchive -Name 'beta' -SkillId 'skill-b' -SkillText (New-TestSkillText -SkillId 'skill-b')
        $plan = New-TestAcquisitionPlan -AlphaArchiveHash (Get-TestFileSha256 $alpha.ArchivePath) -BetaArchiveHash (Get-TestFileSha256 $beta.ArchivePath) -AlphaContentHash $alpha.ContentHash -BetaContentHash $beta.ContentHash
        Assert-ThrowsMessage { Expand-ValidatedSkillsSourceArchives -Plan $plan -SourceArchivePaths @{ 'source-a'=$alpha.ArchivePath; 'source-b'=$beta.ArchivePath } -WorkingRoot (Join-Path $TestDrive 'staging') } 'malformed YAML flow-sequence syntax'
    }
}
