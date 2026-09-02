Describe 'Agent Skill Repository Standard v1 contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:StandardsRoot = Join-Path $script:RepositoryRoot 'docs\standards'
        $script:IndexPath = Join-Path $script:StandardsRoot 'README.md'
        $script:StandardPath = Join-Path $script:StandardsRoot 'skill-repository-standard.md'
        $script:MatrixPath = Join-Path $script:StandardsRoot 'skill-repository-review-matrix.md'
        $script:ToolchainPath = Join-Path $script:StandardsRoot 'validation-toolchain.json'
        $script:ResolverPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-StandardValidationTool.ps1'
        $script:WorkflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'

        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
        }

        function Assert-Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Assert-NotMatch {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -match $Pattern) { throw "$Message Pattern='$Pattern'." }
        }
    }

    It 'UnitT10_keeps_the_normative_standard_evidence_toolchain_and_resolver_together' {
        Assert-True (Test-Path -LiteralPath $script:IndexPath -PathType Leaf) 'Missing standards index.'
        Assert-True (Test-Path -LiteralPath $script:StandardPath -PathType Leaf) 'Missing normative Standard.'
        Assert-True (Test-Path -LiteralPath $script:MatrixPath -PathType Leaf) 'Missing cross-repository review matrix.'
        Assert-True (Test-Path -LiteralPath $script:ToolchainPath -PathType Leaf) 'Missing validation toolchain policy.'
        Assert-True (Test-Path -LiteralPath $script:ResolverPath -PathType Leaf) 'Missing central validation tool resolver.'
        Assert-True (Test-Path -LiteralPath $script:WorkflowPath -PathType Leaf) 'Missing Standards Conformance workflow.'

        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        Assert-Match $index 'skill-repository-standard\.md' 'Standards index must link the normative Standard.'
        Assert-Match $index 'skill-repository-review-matrix\.md' 'Standards index must link the review matrix.'
        Assert-Match $index 'validation-toolchain\.json' 'Standards index must link the toolchain policy.'
        Assert-Match $index 'Resolve-StandardValidationTool\.ps1' 'Standards index must name the central validation tool resolver.'
    }

    It 'UnitT20_requires_latest_stable_tools_trusted_sources_and_resolved_identity_evidence' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json

        Assert-Equal $toolchain.schemaVersion 1 'Unexpected toolchain schemaVersion.'
        Assert-Equal $toolchain.policy 'latest-stable-per-validation-run' 'Canonical validation must default to latest stable.'
        Assert-Equal $toolchain.sourceTrust.enforcement 'exact-approved-source' 'Tool sources must use exact approved-source enforcement.'
        Assert-Equal $toolchain.sourceTrust.resolver 'scripts/Resolve-StandardValidationTool.ps1' 'Tool policy must name the central resolver.'
        Assert-True ([bool]$toolchain.sourceTrust.failClosedOnMismatch) 'Tool source mismatch must fail closed.'
        Assert-True ([bool]$toolchain.resolution.resolveAtRunStart) 'Toolchain must resolve at run start.'
        Assert-True ([bool]$toolchain.resolution.freezeForRun) 'Resolved toolchain must freeze for one run.'
        Assert-True ([bool]$toolchain.resolution.recordResolvedVersion) 'Resolved version must be recorded.'
        Assert-True ([bool]$toolchain.resolution.recordResolvedIdentityWhenAvailable) 'Resolved immutable/package identity must be recorded when available.'
        Assert-True (-not [bool]$toolchain.resolution.allowPrerelease) 'Prerelease tools must not be the default.'

        $expectedSources = [ordered]@{
            'skillspector' = 'NVIDIA/SkillSpector'
            'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
            'skill-tools' = 'npm:skill-tools'
            'pester' = 'PowerShellGallery:Pester'
        }

        foreach ($entry in $expectedSources.GetEnumerator()) {
            Assert-Equal $toolchain.tools.($entry.Key).source $entry.Value "$($entry.Key) must use its approved source."
            Assert-Equal $toolchain.tools.($entry.Key).channel 'latest-stable' "$($entry.Key) must use latest-stable."
        }

        Assert-Equal $toolchain.tools.'skill-tools'.registry 'https://registry.npmjs.org/' 'skill-tools must use the approved npm registry.'
        Assert-Equal $toolchain.tools.'skill-validator'.stableVersionRule 'release-semver-only' 'skill-validator must require release SemVer.'
        Assert-True ([bool]$toolchain.compatibilityLane.mayPinOlderVersion) 'Compatibility lanes may pin an older version.'
        Assert-True ([bool]$toolchain.compatibilityLane.requiresExplicitPurpose) 'Compatibility pins require an explicit purpose.'
        Assert-True (-not [bool]$toolchain.compatibilityLane.mayBeCanonicalReleaseGate) 'Compatibility lane must not be the canonical release gate.'
    }

    It 'UnitT25_rejects_an_unapproved_validation_tool_source_before_resolution' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.tools.skillspector.source = 'example.invalid/SkillSpector'
        $unapprovedPath = Join-Path $TestDrive 'unapproved-validation-toolchain.json'
        $json = $toolchain | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($unapprovedPath, $json, (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $unapprovedPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'Untrusted validation tool source.*skillspector' 'Unapproved tool source must fail closed.'
    }

    It 'UnitT26_rejects_an_unapproved_npm_registry_before_skill_tools_resolution' {
        $previousRegistry = $env:NPM_CONFIG_REGISTRY
        $errorMessage = $null
        try {
            $env:NPM_CONFIG_REGISTRY = 'https://registry.example.invalid/'
            & $script:ResolverPath -ToolName skill-tools | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        finally {
            $env:NPM_CONFIG_REGISTRY = $previousRegistry
        }

        Assert-Match $errorMessage 'Untrusted npm registry' 'An npm registry override must fail closed before package resolution.'
    }

    It 'UnitT27_requires_authority_CI_to_use_the_central_tool_resolver' {
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:WorkflowPath

        Assert-Match $workflow 'Resolve-StandardValidationTool\.ps1.*-ValidatePolicyOnly' 'Workflow must validate central tool trust policy.'
        Assert-Match $workflow 'Resolve-StandardValidationTool\.ps1.*-ToolName pester.*-Install' 'Workflow must resolve Pester through the central resolver.'
        Assert-NotMatch $workflow 'Install-Module\s+Pester' 'Workflow must not bypass the central resolver with direct Pester installation.'
    }

    It 'UnitT28_rejects_prerelease_and_pseudo_versions_for_skill_validator' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Assert-True (Test-StableGoModuleVersion -Version 'v1.6.1') 'A normal release version must be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v1.7.0-rc1') 'A prerelease version must not be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v0.0.0-20260902000000-0123456789ab') 'A pseudo-version must not be stable.'
    }

    It 'UnitT30_validates_openai_agent_metadata_against_the_OpenAI_minimum_contract' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $standard 'agents/openai\.yaml.*contract' 'Standard must define an openai.yaml content contract.'
        Assert-Match $standard 'syntactically valid YAML' 'Standard must require valid YAML.'
        Assert-Match $standard 'YAML keys.*MUST.*unquoted' 'Standard must require unquoted YAML keys.'
        Assert-Match $standard 'all string scalar values.*MUST.*quoted' 'Standard must require quoted YAML string values.'
        Assert-Match $standard 'interface\.display_name' 'Standard must require display_name.'
        Assert-Match $standard 'interface\.short_description.*25.*64' 'Standard must require the OpenAI 25-64 character short_description bound.'
        Assert-Match $standard 'interface\.default_prompt' 'Standard must require default_prompt.'
        Assert-Match $standard '\$<skill-id>' 'Standard must bind default_prompt to the Skill ID.'
    }

    It 'UnitT40_distinguishes_release_approval_from_installing_an_already_approved_release' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $standard 'Release Approval' 'Standard must define release approval.'
        Assert-Match $standard 'Approved Release Installation' 'Standard must define approved release installation.'
        Assert-Match $standard 'Human Approved.*MUST NOT.*human approval' 'Installing an approved immutable release must not require repeated release approval.'
    }

    It 'UnitT50_makes_standard_conformance_tests_effective_in_the_same_policy_change' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath

        Assert-Match $standard 'normative authority.*conformance regression.*MUST.*PR' 'Standard changes must update authority regression in the same PR.'
        Assert-Match $index 'tests/skill-repository-standard\.Tests\.ps1' 'Standards index must name the authority regression test.'
    }

    It 'UnitT60_keeps_the_review_matrix_current_with_the_SYP167_authority_deliverables' {
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath

        Assert-Match $matrix 'Validation tool policy' 'Review matrix must record the validation tool policy decision.'
        Assert-Match $matrix 'latest stable' 'Review matrix must record latest-stable validation tooling.'
        Assert-Match $matrix 'authority-level regression' 'Review matrix must record SYP-167 authority regression/CI deliverables.'
        Assert-NotMatch $matrix 'SYP-167 establishes normative Standard v1 only\.' 'Review matrix must not describe the pre-regression SYP-167 scope.'
    }
}
