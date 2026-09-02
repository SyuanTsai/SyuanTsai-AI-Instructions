$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:StandardsRoot = Join-Path $script:RepositoryRoot 'docs\standards'
$script:IndexPath = Join-Path $script:StandardsRoot 'README.md'
$script:StandardPath = Join-Path $script:StandardsRoot 'skill-repository-standard.md'
$script:MatrixPath = Join-Path $script:StandardsRoot 'skill-repository-review-matrix.md'
$script:ToolchainPath = Join-Path $script:StandardsRoot 'validation-toolchain.json'

Describe 'Agent Skill Repository Standard v1 contract' {
    It 'UnitT10_keeps_the_normative_standard_evidence_and_toolchain_documents_together' {
        Test-Path -LiteralPath $script:IndexPath -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $script:StandardPath -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $script:MatrixPath -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $script:ToolchainPath -PathType Leaf | Should Be $true

        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        $index | Should Match 'skill-repository-standard\.md'
        $index | Should Match 'skill-repository-review-matrix\.md'
        $index | Should Match 'validation-toolchain\.json'
    }

    It 'UnitT20_requires_latest_stable_validation_tools_and_freezes_each_resolved_run' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json

        $toolchain.schemaVersion | Should Be 1
        $toolchain.policy | Should Be 'latest-stable-per-validation-run'
        $toolchain.resolution.resolveAtRunStart | Should Be $true
        $toolchain.resolution.freezeForRun | Should Be $true
        $toolchain.resolution.recordResolvedVersion | Should Be $true
        $toolchain.resolution.allowPrerelease | Should Be $false

        $toolNames = @('skillspector', 'skill-validator', 'skill-tools', 'pester')
        foreach ($toolName in $toolNames) {
            $toolchain.tools.$toolName.channel | Should Be 'latest-stable'
        }

        $toolchain.compatibilityLane.mayPinOlderVersion | Should Be $true
        $toolchain.compatibilityLane.requiresExplicitPurpose | Should Be $true
        $toolchain.compatibilityLane.mayBeCanonicalReleaseGate | Should Be $false
    }

    It 'UnitT30_validates_openai_agent_metadata_beyond_file_presence' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        $standard | Should Match 'agents/openai\.yaml.*MUST.*valid YAML'
        $standard | Should Match 'interface\.display_name'
        $standard | Should Match 'interface\.short_description'
        $standard | Should Match 'interface\.default_prompt'
        $standard | Should Match '\$<skill-id>'
    }

    It 'UnitT40_distinguishes_release_approval_from_installing_an_already_approved_release' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        $standard | Should Match 'Release Approval'
        $standard | Should Match 'Approved Release Installation'
        $standard | Should Match 'MUST NOT.*再次取得 human approval'
    }

    It 'UnitT50_makes_standard_conformance_tests_effective_in_the_same_policy_change' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath

        $standard | Should Match '本 normative authority 的 conformance regression.*MUST.*同一 PR'
        $index | Should Match 'tests/skill-repository-standard\.Tests\.ps1'
    }
}
