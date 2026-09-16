Describe 'Unsigned raw SkillSpector graph normalization' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'standard-semantic-assertions.ps1')
        $pythonApplications = @(Get-Command -Name python -CommandType Application -ErrorAction Stop)
        $script:Python = [string]$pythonApplications[0].Source
        $script:Fixture = Join-Path $PSScriptRoot 'semantic-raw-graph-normalizer-unit.py'
        $script:Preflight = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Prepare-StandardSemanticScanEvidence.ps1'
    }

    # Scenario: One synthetic raw graph per peer Skill contains completed semantic ledger rows and a High finding.
    # Purpose: Confirm the version-specific normalizer's exact JSON can enter the existing unsigned preflight without losing that finding.
    It 'InterT10_passes_complete_synthetic_raw_graph_through_unsigned_preflight' {
        $scannerPath = Join-Path $TestDrive 'semantic-normalized.json'
        $preflightPath = Join-Path $TestDrive 'semantic-preflight.json'
        & $script:Python -B $script:Fixture --emit-fixture $scannerPath | Out-Null
        $LASTEXITCODE | Assert-SemanticEqual -Expected 0
        Test-Path -LiteralPath $scannerPath | Assert-SemanticTrue

        & $script:Preflight -ScannerResultPath $scannerPath -OutputPath $preflightPath `
            -CandidateId ('a' * 64) -InputInventorySha256 ('b' * 64) `
            -Provider 'fixture-provider' -Purpose 'fixture semantic review' `
            -Scope 'fixture active skill files' `
            -ExpectedActiveSkills @('alpha-skill', 'beta-skill') `
            -ExpectedAnalyzerIds @('semantic_alpha', 'semantic_beta') | Out-Null

        $result = Get-Content -LiteralPath $preflightPath -Raw | ConvertFrom-Json
        [string]$result.providerTextInventorySha256 | Assert-SemanticMatch -Pattern '^[0-9a-f]{64}$'
        $result.findings.Count | Assert-SemanticEqual -Expected 1
        $result.findings[0].severity | Assert-SemanticEqual -Expected 'high'
        $result.severityGate | Assert-SemanticEqual -Expected 'blocked'
        $result.signed | Assert-SemanticFalse
        $result.releaseEligible | Assert-SemanticFalse
        $result.analyzerInventoryVerified | Assert-SemanticFalse
    }
}
