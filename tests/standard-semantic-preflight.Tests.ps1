Describe 'Standard semantic scan preflight' {
    BeforeAll {
        $script:Producer = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Prepare-StandardSemanticScanEvidence.ps1'

        function Write-PreflightJson {
            param([string] $Path, [object] $Value)
            [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        }

        function New-CompleteSemanticResult {
            [ordered]@{
                schemaVersion = 1
                resultType = 'standard-semantic-scan-result-v1'
                candidateId = ('b' * 64)
                inputInventorySha256 = ('a' * 64)
                provider = 'fixture-provider'
                purpose = 'validate alpha and beta skills'
                scope = 'fixture packages only'
                activeSkills = @('alpha-skill', 'beta-skill')
                analyzers = @(
                    [ordered]@{
                        identity = 'semantic-intent'
                        status = 'passed'
                        completeness = 'complete'
                        coveredSkills = @('alpha-skill', 'beta-skill')
                        findings = @([ordered]@{
                            severity = 'low'
                            fingerprint = 'finding-1'
                            ruleId = 'intent-context'
                            message = 'Review a fixture instruction.'
                            path = 'skills/alpha-skill/SKILL.md'
                        })
                    },
                    [ordered]@{
                        identity = 'semantic-security'
                        status = 'passed'
                        completeness = 'complete'
                        coveredSkills = @('alpha-skill', 'beta-skill')
                        findings = @()
                    }
                )
            }
        }
    }

    # Scenario: Two required semantic analyzers each cover every active package and one reports a low finding.
    # Purpose: Preserve every finding and bind the unsigned preflight to the exact candidate and scanner inventory.
    It 'UnitT10_preserves_complete_analyzer_findings_as_unsigned_candidate_bound_preflight' {
        $resultPath = Join-Path $TestDrive 'complete-scan.json'
        $outputPath = Join-Path $TestDrive 'complete-preflight.json'
        Write-PreflightJson -Path $resultPath -Value (New-CompleteSemanticResult)

        & $script:Producer `
            -ScannerResultPath $resultPath `
            -OutputPath $outputPath `
            -CandidateId ('b' * 64) `
            -InputInventorySha256 ('a' * 64) `
            -Provider 'fixture-provider' `
            -Purpose 'validate alpha and beta skills' `
            -Scope 'fixture packages only' `
            -ExpectedActiveSkills @('alpha-skill', 'beta-skill') `
            -ExpectedAnalyzerIds @('semantic-intent', 'semantic-security') | Out-Null

        $preflight = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
        $preflight.candidateId | Should -Be ('b' * 64)
        $preflight.preflightType | Should -Be 'semantic-scan-preflight-v1'
        $preflight.analyzerCompleteness | Should -Be 'declared-set-complete'
        $preflight.analyzerInventoryVerified | Should -BeFalse
        $preflight.consentStatus | Should -Be 'pending'
        $preflight.signed | Should -BeFalse
        $preflight.releaseEligible | Should -BeFalse
        @($preflight.analyzerIdentity).Count | Should -Be 2
        @($preflight.findings).Count | Should -Be 1
        $preflight.findings[0].fingerprint | Should -Be 'finding-1'

        $expectedFinding = [pscustomobject][ordered]@{
            severity = 'low'
            fingerprint = 'finding-1'
            ruleId = 'intent-context'
            message = 'Review a fixture instruction.'
            path = 'skills/alpha-skill/SKILL.md'
        }
        $expectedJson = ConvertTo-Json -InputObject ([object[]]@($expectedFinding)) -Compress -Depth 20
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $expectedDigest = [Convert]::ToHexString($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($expectedJson))).ToLowerInvariant()
        }
        finally { $sha.Dispose() }
        $preflight.findingsSha256 | Should -Be $expectedDigest
    }

    # Scenario: One analyzer claims complete status but omits a required active package.
    # Purpose: Stop before creating a preflight that could hide an unscanned Skill.
    It 'UnitT20_rejects_incomplete_skill_coverage_without_writing_an_artifact' {
        $result = New-CompleteSemanticResult
        $result.analyzers[1].coveredSkills = @('alpha-skill')
        $resultPath = Join-Path $TestDrive 'incomplete-scan.json'
        $outputPath = Join-Path $TestDrive 'incomplete-preflight.json'
        Write-PreflightJson -Path $resultPath -Value $result

        { & $script:Producer `
            -ScannerResultPath $resultPath `
            -OutputPath $outputPath `
            -CandidateId ('b' * 64) `
            -InputInventorySha256 ('a' * 64) `
            -Provider 'fixture-provider' `
            -Purpose 'validate alpha and beta skills' `
            -Scope 'fixture packages only' `
            -ExpectedActiveSkills @('alpha-skill', 'beta-skill') `
            -ExpectedAnalyzerIds @('semantic-intent', 'semantic-security') | Out-Null } | Should -Throw
        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    # Scenario: A complete analyzer reports a High finding against one Skill.
    # Purpose: Keep the complete finding visible while preventing the unsigned preflight from suggesting release.
    It 'UnitT30_preserves_high_findings_with_a_blocked_severity_gate' {
        $result = New-CompleteSemanticResult
        $result.analyzers[0].findings[0].severity = 'high'
        $resultPath = Join-Path $TestDrive 'high-scan.json'
        $outputPath = Join-Path $TestDrive 'high-preflight.json'
        Write-PreflightJson -Path $resultPath -Value $result

        & $script:Producer -ScannerResultPath $resultPath -OutputPath $outputPath `
            -CandidateId ('b' * 64) -InputInventorySha256 ('a' * 64) `
            -Provider 'fixture-provider' -Purpose 'validate alpha and beta skills' `
            -Scope 'fixture packages only' -ExpectedActiveSkills @('alpha-skill','beta-skill') `
            -ExpectedAnalyzerIds @('semantic-intent','semantic-security') | Out-Null
        $preflight = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
        $preflight.severityGate | Should -Be 'blocked'
        $preflight.findings[0].severity | Should -Be 'high'
        $preflight.releaseEligible | Should -BeFalse
    }

    # Scenario: A scanner result is bound to a different immutable candidate than the supervisor request.
    # Purpose: Prevent an earlier candidate's findings from being rebadged as current evidence.
    It 'UnitT40_rejects_a_different_candidate_without_writing_an_artifact' {
        $result = New-CompleteSemanticResult
        $result.candidateId = ('c' * 64)
        $resultPath = Join-Path $TestDrive 'wrong-candidate.json'
        $outputPath = Join-Path $TestDrive 'wrong-candidate-preflight.json'
        Write-PreflightJson -Path $resultPath -Value $result

        { & $script:Producer -ScannerResultPath $resultPath -OutputPath $outputPath `
            -CandidateId ('b' * 64) -InputInventorySha256 ('a' * 64) `
            -Provider 'fixture-provider' -Purpose 'validate alpha and beta skills' `
            -Scope 'fixture packages only' -ExpectedActiveSkills @('alpha-skill','beta-skill') `
            -ExpectedAnalyzerIds @('semantic-intent','semantic-security') | Out-Null } | Should -Throw
        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    # Scenario: The machine-readable scanner document repeats candidateId with a different value.
    # Purpose: Reject ambiguous JSON rather than trusting a parser's last-key interpretation.
    It 'UnitT50_rejects_duplicate_json_keys_before_parsing_analyzer_claims' {
        $resultPath = Join-Path $TestDrive 'duplicate-key-scan.json'
        $outputPath = Join-Path $TestDrive 'duplicate-key-preflight.json'
        $json = (New-CompleteSemanticResult | ConvertTo-Json -Depth 30)
        if ($json -notmatch '"candidateId"') { throw 'Fixture has no candidateId key.' }
        $json = $json -replace '("schemaVersion"\s*:\s*1\s*,)', '$1 "candidateId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",'
        [IO.File]::WriteAllText($resultPath, $json, (New-Object Text.UTF8Encoding($false)))

        { & $script:Producer -ScannerResultPath $resultPath -OutputPath $outputPath `
            -CandidateId ('b' * 64) -InputInventorySha256 ('a' * 64) `
            -Provider 'fixture-provider' -Purpose 'validate alpha and beta skills' `
            -Scope 'fixture packages only' -ExpectedActiveSkills @('alpha-skill','beta-skill') `
            -ExpectedAnalyzerIds @('semantic-intent','semantic-security') | Out-Null } | Should -Throw '*duplicate property*'
        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    # Scenario: A caller points the preflight artifact at the authority repository's tracked tests directory.
    # Purpose: Keep scanner intermediates outside source so local validation cannot dirty a production checkout.
    It 'UnitT60_rejects_an_output_path_inside_the_authority_source_tree' {
        $resultPath = Join-Path $TestDrive 'outside-scan.json'
        $sourceRoot = Split-Path -Parent $PSScriptRoot
        $outputPath = Join-Path $sourceRoot 'tests\semantic-preflight-must-not-write.json'
        Write-PreflightJson -Path $resultPath -Value (New-CompleteSemanticResult)
        try {
            { & $script:Producer -ScannerResultPath $resultPath -OutputPath $outputPath `
                -CandidateId ('b' * 64) -InputInventorySha256 ('a' * 64) `
                -Provider 'fixture-provider' -Purpose 'validate alpha and beta skills' `
                -Scope 'fixture packages only' -ExpectedActiveSkills @('alpha-skill','beta-skill') `
                -ExpectedAnalyzerIds @('semantic-intent','semantic-security') | Out-Null } | Should -Throw '*outside*authority*'
            Test-Path -LiteralPath $outputPath | Should -BeFalse
        }
        finally {
            if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
        }
    }

    # Scenario: A complete unsigned preflight is supplied to the canonical semantic receipt verifier.
    # Purpose: Prove the preparation artifact cannot substitute for typed consent or supervisor signature.
    It 'UnitT70_canonical_runner_refuses_unsigned_preflight_as_semantic_receipt' {
        $resultPath = Join-Path $TestDrive 'verifier-scan.json'
        $outputPath = Join-Path $TestDrive 'verifier-preflight.json'
        Write-PreflightJson -Path $resultPath -Value (New-CompleteSemanticResult)
        & $script:Producer -ScannerResultPath $resultPath -OutputPath $outputPath `
            -CandidateId ('b' * 64) -InputInventorySha256 ('a' * 64) `
            -Provider 'fixture-provider' -Purpose 'validate alpha and beta skills' `
            -Scope 'fixture packages only' -ExpectedActiveSkills @('alpha-skill','beta-skill') `
            -ExpectedAnalyzerIds @('semantic-intent','semantic-security') | Out-Null
        $preflight = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json

        $runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-StandardValidation.ps1'
        . $runner -CandidateRoot $TestDrive -AdapterPath $resultPath -ArtifactsRoot $TestDrive `
            -SourceRepository 'https://example.test/skills.git' -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) -EventName 'local' -TrustedToolRoot $TestDrive `
            -DefineFunctionsOnly
        { Assert-StandardValidationSemanticEvidence -Evidence $preflight `
            -CandidateId ('b' * 64) -TrustAnchorRoot $TestDrive `
            -Context 'unsigned preflight probe' | Out-Null } | Should -Throw
    }

    # Scenario: A junction under TestDrive redirects an apparently external output parent into the authority tests directory.
    # Purpose: Prevent a reparse path from bypassing the source-tree artifact boundary.
    It 'UnitT80_rejects_a_junction_output_parent_before_writing_to_source' {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Set-ItResult -Skipped -Because 'Windows junction-specific test'; return }
        $resultPath = Join-Path $TestDrive 'junction-scan.json'
        Write-PreflightJson -Path $resultPath -Value (New-CompleteSemanticResult)
        $sourceRoot = Split-Path -Parent $PSScriptRoot
        $target = Join-Path $sourceRoot 'tests'
        $junction = Join-Path $TestDrive 'redirect-to-authority'
        $targetFile = Join-Path $target 'semantic-preflight-junction-must-not-write.json'
        $outputPath = Join-Path $junction 'semantic-preflight-junction-must-not-write.json'
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        try {
            { & $script:Producer -ScannerResultPath $resultPath -OutputPath $outputPath `
                -CandidateId ('b' * 64) -InputInventorySha256 ('a' * 64) `
                -Provider 'fixture-provider' -Purpose 'validate alpha and beta skills' `
                -Scope 'fixture packages only' -ExpectedActiveSkills @('alpha-skill','beta-skill') `
                -ExpectedAnalyzerIds @('semantic-intent','semantic-security') | Out-Null } | Should -Throw '*reparse*'
            Test-Path -LiteralPath $targetFile | Should -BeFalse
        }
        finally {
            if (Test-Path -LiteralPath $targetFile) { Remove-Item -LiteralPath $targetFile -Force }
            if (Test-Path -LiteralPath $junction) { Remove-Item -LiteralPath $junction -Force }
        }
    }
}
