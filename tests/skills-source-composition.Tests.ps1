$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-composition.psm1') -Force

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
    It 'MultiT10_composes_skills_from_two_independent_sources_into_one_desired_set' {
        $instructionRoot=Join-Path $TestDrive 'instructions'
        New-Item -ItemType Directory -Force -Path (Join-Path $instructionRoot '.codex\AI-Rules'),(Join-Path $instructionRoot '.github\AI-Rules'),(Join-Path $instructionRoot '.agents\skills\legacy-skill') | Out-Null
        Set-Content (Join-Path $instructionRoot '.codex\AGENTS.en.md') 'codex base'
        Set-Content (Join-Path $instructionRoot '.github\copilot-instructions.en.md') 'copilot base'
        Set-Content (Join-Path $instructionRoot '.codex\AI-Rules\core.en.md') 'codex rule'
        Set-Content (Join-Path $instructionRoot '.github\AI-Rules\core.en.md') 'copilot rule'
        Set-Content (Join-Path $instructionRoot '.agents\skills\legacy-skill\SKILL.md') '# legacy'
        $skills=@((New-TestSkill (Join-Path $TestDrive 'source-a') 'skill-a' 'from source A'),(New-TestSkill (Join-Path $TestDrive 'source-b') 'skill-b' 'from source B'))
        $destination=Join-Path $TestDrive 'composed'
        $result=New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills $skills -DestinationRoot $destination
        @($result.SkillIds).Count | Should Be 2
        Test-Path (Join-Path $destination '.agents\skills\skill-a\SKILL.md') | Should Be $true
        Test-Path (Join-Path $destination '.agents\skills\skill-b\SKILL.md') | Should Be $true
        Test-Path (Join-Path $destination '.agents\skills\legacy-skill') | Should Be $false
    }
    It 'MultiT20_allows_instruction_only_composition_with_no_selected_skills' {
        $instructionRoot=Join-Path $TestDrive 'instruction-only'
        New-Item -ItemType Directory -Force -Path (Join-Path $instructionRoot '.agents\skills\old') | Out-Null
        Set-Content (Join-Path $instructionRoot '.agents\skills\old\SKILL.md') '# old'
        $destination=Join-Path $TestDrive 'instruction-only-composed'
        $result=New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills @() -DestinationRoot $destination
        @($result.SkillIds).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $destination '.agents\skills') -Directory).Count | Should Be 0
    }
    It 'MultiT30_rejects_duplicate_selected_skill_ids_before_target_mutation' {
        $instructionRoot=Join-Path $TestDrive 'duplicate-instructions'; New-Item -ItemType Directory -Force -Path $instructionRoot | Out-Null
        $skills=@((New-TestSkill (Join-Path $TestDrive 'duplicate-a') 'same-skill' 'A'),(New-TestSkill (Join-Path $TestDrive 'duplicate-b') 'same-skill' 'B'))
        Assert-ThrowsMessage { New-ComposedBootstrapSource -InstructionSourceRoot $instructionRoot -ResolvedSkills $skills -DestinationRoot (Join-Path $TestDrive 'duplicate-composed') } 'Duplicate selected Skill during composition'
    }
}
