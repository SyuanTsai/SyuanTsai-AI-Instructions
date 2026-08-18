$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-composition.psm1') -Force

function New-TestSkill {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Marker
    )

    $skillRoot = Join-Path $Root $Id
    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Value "# $Id`n$Marker" -Encoding UTF8
    return [pscustomobject]@{ id = $Id; skillRootPath = $skillRoot }
}

Describe 'Skills source composition' {
    It 'MultiT10_composes_skills_from_two_independent_sources_into_one_desired_set' {
        $instructionRoot = Join-Path $TestDrive 'instructions'
        New-Item -ItemType Directory -Force -Path (Join-Path $instructionRoot '.codex\AI-Rules'), (Join-Path $instructionRoot '.github\AI-Rules'), (Join-Path $instructionRoot '.agents\skills\legacy-skill') | Out-Null
        Set-Content -LiteralPath (Join-Path $instructionRoot '.codex\AGENTS.en.md') -Value 'codex base'
        Set-Content -LiteralPath (Join-Path $instructionRoot '.github\copilot-instructions.en.md') -Value 'copilot base'
        Set-Content -LiteralPath (Join-Path $instructionRoot '.codex\AI-Rules\core.en.md') -Value 'codex rule'
        Set-Content -LiteralPath (Join-Path $instructionRoot '.github\AI-Rules\core.en.md') -Value 'copilot rule'
        Set-Content -LiteralPath (Join-Path $instructionRoot '.agents\skills\legacy-skill\SKILL.md') -Value '# legacy'

        $sourceA = Join-Path $TestDrive 'source-a'
        $sourceB = Join-Path $TestDrive 'source-b'
        $skills = @(
            New-TestSkill -Root $sourceA -Id 'skill-a' -Marker 'from source A'
            New-TestSkill -Root $sourceB -Id 'skill-b' -Marker 'from source B'
        )

        $destination = Join-Path $TestDrive 'composed'
        $result = New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills $skills -DestinationRoot $destination

        @($result.SkillIds).Count | Should Be 2
        Test-Path -LiteralPath (Join-Path $destination '.codex\AGENTS.en.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $destination '.agents\skills\skill-a\SKILL.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $destination '.agents\skills\skill-b\SKILL.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $destination '.agents\skills\legacy-skill') | Should Be $false
        (Get-Content -Raw -LiteralPath (Join-Path $destination '.agents\skills\skill-a\SKILL.md')) | Should Match 'from source A'
        (Get-Content -Raw -LiteralPath (Join-Path $destination '.agents\skills\skill-b\SKILL.md')) | Should Match 'from source B'
    }

    It 'MultiT20_allows_instruction_only_composition_with_no_selected_skills' {
        $instructionRoot = Join-Path $TestDrive 'instruction-only'
        New-Item -ItemType Directory -Force -Path (Join-Path $instructionRoot '.agents\skills\old') | Out-Null
        Set-Content -LiteralPath (Join-Path $instructionRoot '.agents\skills\old\SKILL.md') -Value '# old'

        $destination = Join-Path $TestDrive 'instruction-only-composed'
        $result = New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills @() -DestinationRoot $destination

        @($result.SkillIds).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $destination '.agents\skills') -Directory).Count | Should Be 0
    }

    It 'MultiT30_rejects_duplicate_selected_skill_ids_before_target_mutation' {
        $instructionRoot = Join-Path $TestDrive 'duplicate-instructions'
        New-Item -ItemType Directory -Force -Path $instructionRoot | Out-Null
        $sourceA = Join-Path $TestDrive 'duplicate-a'
        $sourceB = Join-Path $TestDrive 'duplicate-b'
        $skills = @(
            New-TestSkill -Root $sourceA -Id 'same-skill' -Marker 'A'
            New-TestSkill -Root $sourceB -Id 'same-skill' -Marker 'B'
        )

        { New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills $skills -DestinationRoot (Join-Path $TestDrive 'duplicate-composed') } |
            Should Throw '*Duplicate selected Skill during composition*'
    }
}
