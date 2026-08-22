$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts/skills-source-composition.psm1') -Force

function Assert-ThrowsMessage {
    param([scriptblock] $Action, [string] $Pattern)
    $thrown = $false
    $message = $null
    try { & $Action } catch { $thrown = $true; $message = $_.Exception.Message }
    $thrown | Should Be $true
    $message | Should Match $Pattern
}

function New-TestSkill {
    param([string]$Root,[string]$Id,[string]$Marker)
    $skillRoot=Join-Path $Root $Id
    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Value "# $Id`n$Marker" -Encoding UTF8
    [pscustomobject]@{ id=$Id; skillRootPath=$skillRoot }
}

Describe 'Skills source composition' {
    # Scenario: Two validated Skills originate from independent repositories and the instruction source contains a legacy Skill copy.
    # Purpose: Compose one desired source containing only the selected external Skills alongside the instruction families.
    It 'UnitT10_composes_two_independent_skill_sources_into_one_desired_set' {
        $instructionRoot=Join-Path $TestDrive 'instructions'
        New-Item -ItemType Directory -Force -Path (Join-Path $instructionRoot '.codex/AI-Rules'),(Join-Path $instructionRoot '.github/AI-Rules'),(Join-Path $instructionRoot '.agents/skills/legacy-skill') | Out-Null
        Set-Content (Join-Path $instructionRoot '.codex/AGENTS.en.md') 'codex base'
        Set-Content (Join-Path $instructionRoot '.github/copilot-instructions.en.md') 'copilot base'
        Set-Content (Join-Path $instructionRoot '.codex/AI-Rules/core.en.md') 'codex rule'
        Set-Content (Join-Path $instructionRoot '.github/AI-Rules/core.en.md') 'copilot rule'
        Set-Content (Join-Path $instructionRoot '.agents/skills/legacy-skill/SKILL.md') '# legacy'
        $skills=@((New-TestSkill (Join-Path $TestDrive 'source-a') 'skill-a' 'from source A'),(New-TestSkill (Join-Path $TestDrive 'source-b') 'skill-b' 'from source B'))
        $destination=Join-Path $TestDrive 'composed'
        $result=New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills $skills -DestinationRoot $destination
        @($result.SkillIds).Count | Should Be 2
        Test-Path (Join-Path $destination '.agents/skills/skill-a/SKILL.md') | Should Be $true
        Test-Path (Join-Path $destination '.agents/skills/skill-b/SKILL.md') | Should Be $true
        Test-Path (Join-Path $destination '.agents/skills/legacy-skill') | Should Be $false
    }
    # Scenario: Selection resolves to no Skills while the instruction source still contains an old bundled Skill.
    # Purpose: Produce a valid instruction-only source with an empty .agents/skills directory.
    It 'UnitT20_allows_instruction_only_composition_with_no_selected_skills' {
        $instructionRoot=Join-Path $TestDrive 'instruction-only'
        New-Item -ItemType Directory -Force -Path (Join-Path $instructionRoot '.agents/skills/old') | Out-Null
        Set-Content (Join-Path $instructionRoot '.agents/skills/old/SKILL.md') '# old'
        $destination=Join-Path $TestDrive 'instruction-only-composed'
        $result=New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills @() -DestinationRoot $destination
        @($result.SkillIds).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $destination '.agents/skills') -Directory).Count | Should Be 0
    }

    # Scenario: The composed repository contains hidden dot-directories, matching how .codex, .github, and .agents are treated on Linux and macOS.
    # Purpose: Ensure the handoff archive retains every managed artifact instead of inheriting Compress-Archive's hidden-file exclusion.
    It 'UnitT25_archives_hidden_instruction_and_skill_directories' {
        # Given
        $sourceRoot = Join-Path $TestDrive 'repository'
        $archivePath = Join-Path $TestDrive 'composed-source.zip'
        $extractRoot = Join-Path $TestDrive 'archive-extract'
        $expectedFiles = @(
            '.codex/AGENTS.md',
            '.github/copilot-instructions.md',
            '.agents/skills/skill-a/SKILL.md'
        )
        foreach ($relativePath in $expectedFiles) {
            $path = Join-Path $sourceRoot $relativePath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            Set-Content -LiteralPath $path -Value $relativePath -Encoding UTF8
        }
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            foreach ($directoryName in @('.codex', '.github', '.agents')) {
                $directory = Get-Item -LiteralPath (Join-Path $sourceRoot $directoryName)
                $directory.Attributes = $directory.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
        }

        # When
        New-ComposedBootstrapArchive -SourceRoot $sourceRoot -DestinationPath $archivePath | Out-Null
        Add-Type -AssemblyName System.IO.Compression
        $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            @($archive.Entries | Where-Object { $_.FullName.Contains('\') }).Count | Should Be 0
        }
        finally {
            $archive.Dispose()
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot

        # Then
        foreach ($relativePath in $expectedFiles) {
            Test-Path -LiteralPath (Join-Path (Join-Path $extractRoot 'repository') $relativePath) -PathType Leaf | Should Be $true
        }
    }

    # Scenario: Instruction-only composition produces an empty .agents/skills directory in the handoff source.
    # Purpose: Keep the required shared Skill directory present after ZIP creation and extraction even when no Skill is selected.
    It 'UnitT26_preserves_an_empty_skills_directory_in_the_handoff_archive' {
        # Given
        $sourceRoot = Join-Path $TestDrive 'instruction-only-repository'
        $skillsRoot = Join-Path $sourceRoot '.agents/skills'
        $archivePath = Join-Path $TestDrive 'instruction-only-source.zip'
        $extractRoot = Join-Path $TestDrive 'instruction-only-extract'
        New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null

        # When
        New-ComposedBootstrapArchive -SourceRoot $sourceRoot -DestinationPath $archivePath | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot

        # Then
        Test-Path -LiteralPath (Join-Path (Join-Path $extractRoot 'instruction-only-repository') '.agents/skills') -PathType Container | Should Be $true
    }

    # Scenario: A caller places the destination ZIP underneath the directory being archived.
    # Purpose: Prevent recursive self-inclusion and partial archive creation in the composed source tree.
    It 'UnitT27_rejects_an_archive_destination_inside_its_source' {
        # Given
        $sourceRoot = Join-Path $TestDrive 'unsafe-archive-source'
        New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot 'artifact.md') -Value 'artifact' -Encoding UTF8

        # When / Then
        Assert-ThrowsMessage {
            New-ComposedBootstrapArchive `
                -SourceRoot $sourceRoot `
                -DestinationPath (Join-Path $sourceRoot 'self.zip')
        } 'must be outside its source'
    }

    # Scenario: Resolved inputs contain the same stable Skill ID from two physical source directories.
    # Purpose: Reject an ambiguous desired set before anything reaches the target mutation engine.
    It 'UnitT30_rejects_duplicate_selected_skill_ids_before_target_mutation' {
        $instructionRoot=Join-Path $TestDrive 'duplicate-instructions'; New-Item -ItemType Directory -Force -Path $instructionRoot | Out-Null
        $skills=@((New-TestSkill (Join-Path $TestDrive 'duplicate-a') 'same-skill' 'A'),(New-TestSkill (Join-Path $TestDrive 'duplicate-b') 'same-skill' 'B'))
        Assert-ThrowsMessage { New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills $skills -DestinationRoot (Join-Path $TestDrive 'duplicate-composed') } 'Duplicate selected Skill during composition'
    }
}
