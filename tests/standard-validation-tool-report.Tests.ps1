# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Central package tool report normalization' {
    BeforeAll {
        $script:runnerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-StandardValidation.ps1'
        . $script:runnerPath -DefineFunctionsOnly -CandidateRoot $PSScriptRoot -AdapterPath $script:runnerPath `
            -ArtifactsRoot $PSScriptRoot -SourceRepository 'https://example.test' -SourceRevision ('0' * 40) -BaseRevision ('0' * 40)
        $script:skillRoot = Join-Path $PSScriptRoot 'fixtures/standard-validation-fixture/skills/standard-validation-fixture'
    }

    # Scenario: the package validator emits a JSON string in its errors count.
    # Purpose: a coercible zero must not become a trusted clean result.
    It 'UnitT10_rejects_a_coercible_string_count' {
        $report = [pscustomobject]@{ skill_dir = $script:skillRoot; passed = $true; errors = '0'; warnings = 0; results = @([pscustomobject]@{ level = 'pass' }) }
        { Assert-StandardValidationSkillValidatorReport -Report $report -SkillRoot $script:skillRoot -SkillId 'standard-validation-fixture' } |
            Should -Throw '*typed nonnegative integer*'
    }

    # Scenario: the package validator emits a typed, candidate-bound clean report.
    # Purpose: the shared rule must preserve the successful package path.
    It 'UnitT20_accepts_typed_zero_counts' {
        $report = [pscustomobject]@{ skill_dir = $script:skillRoot; passed = $true; errors = 0; warnings = 0; results = @([pscustomobject]@{ level = 'pass' }) }
        $results = @(Assert-StandardValidationSkillValidatorReport -Report $report -SkillRoot $script:skillRoot -SkillId 'standard-validation-fixture')
        $results.Count | Should -Be 1
        $results[0].level | Should -Be 'pass'
    }
}
