# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Static parser coverage and finding preservation' {
    BeforeAll {
        Set-StrictMode -Version Latest
        $ErrorActionPreference='Stop'
        $parserRepositoryRoot=Split-Path -Parent $PSScriptRoot
        . (Join-Path $parserRepositoryRoot 'scripts/Invoke-StandardValidation.ps1') -DefineFunctionsOnly -CandidateRoot $parserRepositoryRoot -AdapterPath 'unused' -ArtifactsRoot $TestDrive -SourceRepository 'https://example.test/tests/parser.git' -SourceRevision ('a'*40) -BaseRevision ('b'*40)
        $parserWrapperPath=Join-Path $parserRepositoryRoot 'scripts/Invoke-StandardStaticScan.ps1'
        $parserTokens=$null;$parserErrors=$null
        $parserAst=[Management.Automation.Language.Parser]::ParseFile($parserWrapperPath,[ref]$parserTokens,[ref]$parserErrors)
        if($parserErrors.Count){throw 'Static wrapper does not parse.'}
        foreach($name in @('Assert-StaticCoverageDelta','Assert-StaticPreservedFindings','Read-StaticFrozenReceipt','Assert-StaticOutputLocation','Convert-StaticFindingComparisonKey')){
            $definition=$parserAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
            if($null -eq $definition){throw "Required central static verifier is missing: $name"}
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function Assert-ParserCase([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
        function Assert-ParserRejected([scriptblock]$Action){
            $rejected=$false
            try{&$Action}catch{$rejected=$true}
            Assert-ParserCase $rejected 'Malformed static correction evidence was accepted.'
        }
        function New-ParserCoverageFixture {
            $issue=[pscustomobject]@{id='E1';finding_id=('finding-'+('a'*32));match_fingerprint=('c'*64);severity='MEDIUM';finding='https://example.test/';location=@{file='SKILL.md';start_line=1}}
            $derived=[pscustomobject]@{id='AE1';finding_id=('finding-'+('b'*32));match_fingerprint=('d'*64);pattern='Incomplete referenced artifact analysis';severity='HIGH';evidence=@{
                target_path='scripts/example.ps1';target_disposition='partial'
                reasons=@(@{reason_code='static_parse_limit';phase='static';analyzers=@('static_patterns_tool_misuse')})
            }}
            $components=@(@{path='SKILL.md'},@{path='scripts/example.ps1'})
            return [pscustomobject]@{
                original=[pscustomobject]@{components=$components;issues=@($issue,$derived);analysis_completeness=@{ledger_exceptions=@(@{path='scripts/example.ps1';reason_code='static_parse_limit';analyzers=@('static_patterns_tool_misuse');phase='static';outcome='partial';fatal=$false})}}
                corrected=[pscustomobject]@{components=$components;issues=@(($issue | ConvertTo-Json -Depth 10 | ConvertFrom-Json))}
                execution=[pscustomobject]@{candidateInventory=@(@{path='SKILL.md'},@{path='scripts/example.ps1'});correctedComponents=@(@{candidatePaths=@('scripts/example.ps1');partialAfterActualParserRun=$false})}
            }
        }
    }

    # Scenario: actual coverage removes only the previously incomplete referenced-artifact finding.
    # Purpose: preserve the remaining Medium finding and avoid assigning authorization to parser evidence.
    It 'UnitT10_accepts_exact_parser_delta_and_preserves_all_other_findings' {
        $fixture=New-ParserCoverageFixture
        $fixture.corrected.issues[0].finding_id='finding-'+('f'*32)
        $before=$fixture.corrected | ConvertTo-Json -Depth 12 -Compress
        Assert-StaticCoverageDelta $fixture.original $fixture.corrected $fixture.execution
        Assert-StaticPreservedFindings $fixture.original $fixture.corrected $fixture.execution
        Assert-ParserCase (($fixture.corrected | ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'The verifier mutated findings.'
    }

    # Scenario: the corrected report loses, downgrades or deduplicates an original non-derived finding.
    # Purpose: forbid arbitrary finding suppression even when component coverage is complete.
    It 'UnitT20_rejects_lost_changed_or_reduced_non_derived_findings' {
        foreach($drift in @('missing','severity','duplicate','unknown-derived-reason','fingerprint','invalid-run-id','new-run-id-with-changed-evidence')){
            $fixture=New-ParserCoverageFixture
            switch($drift){
                'missing' {$fixture.corrected.issues=@()}
                'fingerprint' {$fixture.corrected.issues[0].match_fingerprint='e'*64}
                'invalid-run-id' {$fixture.corrected.issues[0].finding_id='caller-identity'}
                'new-run-id-with-changed-evidence' {$fixture.corrected.issues[0].finding_id='finding-'+('f'*32);$fixture.corrected.issues[0].finding='changed evidence'}
                'severity' {$fixture.corrected.issues=@($fixture.corrected.issues | ConvertTo-Json -Depth 12 | ConvertFrom-Json);$fixture.corrected.issues[0].severity='LOW'}
                'duplicate' {$fixture.original.issues=@($fixture.original.issues[0],$fixture.original.issues[0],$fixture.original.issues[1])}
                'unknown-derived-reason' {$fixture.original.issues[1].evidence.reasons[0].reason_code='reference_missing'}
            }
            Assert-ParserRejected {Assert-StaticPreservedFindings $fixture.original $fixture.corrected $fixture.execution}
        }
    }

    # Scenario: native exceptions or report inventories no longer match the actual correction records.
    # Purpose: reject unknown analyzers, incomplete coverage, duplicate proofs and omitted components.
    It 'UnitT30_rejects_missing_unknown_or_duplicate_analyzer_coverage' {
        foreach($drift in @('component','duplicate-component','reason','analyzer','partial','missing-proof','duplicate-proof','wrong-phase','wrong-outcome','fatal')){
            $fixture=New-ParserCoverageFixture
            switch($drift){
                'component' {$fixture.corrected.components=@($fixture.corrected.components[0])}
                'duplicate-component' {$fixture.corrected.components+=@($fixture.corrected.components[0])}
                'reason' {$fixture.original.analysis_completeness.ledger_exceptions[0].reason_code='resource_limit'}
                'analyzer' {$fixture.original.analysis_completeness.ledger_exceptions[0].analyzers=@('unknown-analyzer')}
                'wrong-phase' {$fixture.original.analysis_completeness.ledger_exceptions[0].phase='metadata'}
                'wrong-outcome' {$fixture.original.analysis_completeness.ledger_exceptions[0].outcome='failed'}
                'fatal' {$fixture.original.analysis_completeness.ledger_exceptions[0].fatal=$true}
                'partial' {$fixture.execution.correctedComponents[0].partialAfterActualParserRun=$true}
                'missing-proof' {$fixture.execution.correctedComponents=@()}
                'duplicate-proof' {$fixture.execution.correctedComponents+=@($fixture.execution.correctedComponents[0])}
            }
            Assert-ParserRejected {Assert-StaticCoverageDelta $fixture.original $fixture.corrected $fixture.execution}
        }
    }

    # Scenario: central policy is changed to permit mutations, authorization or larger parser budgets.
    # Purpose: require exact reviewed policy bytes and typed no-authorization boundaries.
    It 'UnitT40_rejects_profile_identity_budget_and_authorization_drift' {
        $policyPath=Join-Path $parserRepositoryRoot 'docs/standards/static-parser-host-ownership.json'
        $schemaPath=Join-Path $parserRepositoryRoot 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json'
        $json=Get-Content -LiteralPath $policyPath -Raw
        Assert-ParserCase ($json | Test-Json -SchemaFile $schemaPath) 'Reviewed parser policy does not match its schema.'
        foreach($drift in @('hash','budget','mutation','authorization')){
            $policy=$json | ConvertFrom-Json
            switch($drift){
                'hash' {$policy.officialAnalyzerSha256='0'*64}
                'budget' {$policy.maximumSourceBytes=2097152}
                'mutation' {$policy.mutatesInstalledTool=$true}
                'authorization' {$policy.standaloneProofGrantsAuthorization=$true}
            }
            $valid=($policy | ConvertTo-Json -Depth 8) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
            Assert-ParserCase (-not $valid) "Policy drift was accepted: $drift"
        }
    }

    # Scenario: latest-stable resolves SkillSpector 2.13.0 after the prior 2.12.0 profile was reviewed.
    # Purpose: bind the replacement profile to the exact release commit, wheel, analyzer module, schemas and runtime gates.
    It 'UnitT42_binds_exact_2_13_release_identity_across_profile_surfaces' {
        $expectedVersion='2.13.0'
        $expectedCommit='091a509b3d6ba8ff5be528966e1f43c2e68cf214'
        $expectedAsset='41e097b4127c0aa0732ad31cc909f8aee0b907d97816c866a55b8e782a6ca6dc'
        $expectedAnalyzer='c799169f9ad716f8dbbbec5892ef76affd0f9974433709ed0c1cfc3bcd0b66a4'
        $policy=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/static-parser-host-ownership.json') | ConvertFrom-Json
        $policySchema=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json') | ConvertFrom-Json
        $executionSchema=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json') | ConvertFrom-Json
        $wrapper=Get-Content -Raw (Join-Path $parserRepositoryRoot 'scripts/Invoke-StandardStaticScan.ps1')
        $bridge=Get-Content -Raw (Join-Path $parserRepositoryRoot 'scripts/standard_static_powershell.py')

        Assert-ParserCase ($policy.officialScannerVersion -ceq $expectedVersion) 'Profile policy does not bind SkillSpector 2.13.0.'
        Assert-ParserCase ($policy.officialScannerReleaseCommit -ceq $expectedCommit) 'Profile policy does not bind the reviewed release commit.'
        Assert-ParserCase ($policy.officialScannerReleaseAssetSha256 -ceq $expectedAsset) 'Profile policy does not bind the reviewed release wheel.'
        Assert-ParserCase ($policy.officialAnalyzerSha256 -ceq $expectedAnalyzer) 'Profile policy does not bind the reviewed analyzer bytes.'
        Assert-ParserCase ($policySchema.properties.officialScannerVersion.const -ceq $expectedVersion -and
            $policySchema.properties.officialScannerReleaseCommit.const -ceq $expectedCommit -and
            $policySchema.properties.officialScannerReleaseAssetSha256.const -ceq $expectedAsset -and
            $policySchema.properties.officialAnalyzerSha256.const -ceq $expectedAnalyzer) 'Profile policy schema has a different release identity.'
        Assert-ParserCase ($executionSchema.properties.officialScannerVersion.const -ceq $expectedVersion -and
            $executionSchema.properties.officialScannerReleaseCommit.const -ceq $expectedCommit -and
            $executionSchema.properties.officialScannerReleaseAssetSha256.const -ceq $expectedAsset -and
            $executionSchema.properties.officialAnalyzerSha256.const -ceq $expectedAnalyzer) 'Profile execution schema has a different release identity.'
        foreach($value in @($expectedVersion,$expectedCommit,$expectedAsset)){
            Assert-ParserCase ($wrapper.Contains($value)) "Static wrapper omits reviewed identity '$value'."
        }
        Assert-ParserCase ($wrapper -match '\$receipt\.dependencyClosure -isnot \[array\]') 'Static wrapper does not require an explicit frozen dependency closure array.'
        foreach($value in @($expectedVersion,$expectedCommit,$expectedAsset,$expectedAnalyzer)){
            Assert-ParserCase ($bridge.Contains($value)) "Python bridge omits reviewed identity '$value'."
        }
    }

    # Scenario: a scan output is outside its Skill but still inside another part of the frozen candidate.
    # Purpose: forbid writes to the entire bound source and both tooling roots while accepting a separate artifact sibling.
    It 'UnitT46_forbids_outputs_inside_any_bound_source_or_tool_root' {
        $roots=@((Join-Path $TestDrive 'candidate'),(Join-Path $TestDrive 'scanner'),(Join-Path $TestDrive 'authority'))
        foreach($root in $roots){
            Assert-ParserRejected {Assert-StaticOutputLocation -Output (Join-Path $root 'elsewhere/report.json') -ForbiddenRoots $roots}
        }
        Assert-StaticOutputLocation -Output (Join-Path $TestDrive 'candidate-extra/report.json') -ForbiddenRoots $roots
        Assert-StaticOutputLocation -Output (Join-Path $TestDrive 'artifacts/report.json') -ForbiddenRoots $roots
    }

    # Scenario: a resolver receipt changes between trusted handoff and child consumption.
    # Purpose: authenticate the exact bytes that are parsed, rejecting hash/encoding/content drift.
    It 'UnitT45_reads_one_hash_bound_receipt_snapshot' {
        $receipt=Join-Path $TestDrive 'frozen-scanner-receipt.json'
        [IO.File]::WriteAllText($receipt,'{"toolName":"skillspector","resolvedVersion":"2.13.0"}',[Text.UTF8Encoding]::new($false))
        $digest=(Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash.ToLowerInvariant()
        $snapshot=Read-StaticFrozenReceipt $receipt $digest
        Assert-ParserCase ($snapshot.toolName -ceq 'skillspector') 'Hash-bound receipt snapshot did not parse.'
        [IO.File]::WriteAllText($receipt,'{"toolName":"substituted"}',[Text.UTF8Encoding]::new($false))
        Assert-ParserRejected {Read-StaticFrozenReceipt $receipt $digest}
        Assert-ParserCase ($snapshot.toolName -ceq 'skillspector') 'Parsed receipt changed after its source path was replaced.'
    }

    # Scenario: a consumer snapshots the central parser profile but omits an executable dependency.
    # Purpose: require all reviewed grammar and policy bytes in the authenticated authority inventory.
    It 'UnitT50_binds_every_static_parser_dependency_to_the_authority_snapshot' {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $parserRepositoryRoot 'scripts/Invoke-StandardValidation.ps1'),[ref]$tokens,[ref]$errors)
        Assert-ParserCase ($errors.Count -eq 0) 'The central runner does not parse.'
        $definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-StandardValidationAuthoritySnapshot'},$true)
        Assert-ParserCase ($null -ne $definition) 'Authority snapshot validation is missing.'
        foreach($path in @(
            'docs/standards/static-parser-host-ownership.json',
            'docs/standards/schemas/static-parser-host-ownership-v1.schema.json',
            'docs/standards/schemas/static-parser-profile-execution-v1.schema.json',
            'scripts/Get-StandardPowerShellSyntaxProof.ps1',
            'scripts/Invoke-StandardStaticScan.ps1',
            'scripts/standard_static_powershell.py'
        )){
            Assert-ParserCase (([regex]::Matches($definition.Extent.Text,[regex]::Escape($path))).Count -eq 1) ('Authority snapshot omitted or duplicated '+$path)
        }
        $expectedAssignment=$definition.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$expectedFiles'},$true)
        $selectedPaths=@($expectedAssignment.Right.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true))
        $evidenceSchema=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') | ConvertFrom-Json
        $admission=$evidenceSchema.allOf[5].then.properties.authority.properties.binding.properties.selectedFiles
        $binding=$evidenceSchema.'$defs'.authorityBinding.allOf[0].then.properties.selectedFiles
        Assert-ParserCase ($selectedPaths.Count -eq 22 -and $admission.minItems -eq 22 -and $admission.maxItems -eq 22 -and $binding.minItems -eq 22 -and $binding.maxItems -eq 22) 'Runtime and both evidence-schema authority inventories disagree.'
        $contract=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/standard-validation-contract-v1.json') | ConvertFrom-Json
        Assert-ParserCase ($contract.evidence.staticParserHostOwnership.executionSchemaPath -ceq 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json') 'The sidecar schema is not part of the source contract.'
    }

    # Scenario: a caller passes a different candidate identity to the public parser wrapper.
    # Purpose: reject before any resolver/scanner or artifact output without granting trust to a sidecar.
    It 'InterT20_rejects_unbound_child_before_tool_or_output_access' {
        $pwsh=(Get-Process -Id $PID).Path
        $record=Join-Path $TestDrive 'unbound-evidence.json'
        $savedCandidate=$env:STANDARD_VALIDATION_CANDIDATE_ID
        $savedRoot=$env:STANDARD_VALIDATION_CANDIDATE_ROOT
        $savedPreference=$ErrorActionPreference
        try{
            $env:STANDARD_VALIDATION_CANDIDATE_ID='0'*64
            $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$TestDrive
            $ErrorActionPreference='Continue'
            $output=& $pwsh -NoLogo -NoProfile -NonInteractive -File $parserWrapperPath -ToolReceiptPath (Join-Path $TestDrive 'missing-receipt.json') -ExpectedToolReceiptSha256 ('a'*64) -ExpectedResolutionRunId ('b'*32) -SkillRoot $TestDrive -SourceRevision ('c'*40) -CandidateIdentity ('d'*64) -ReportPath (Join-Path $TestDrive 'unbound-report.json') -EvidencePath $record 2>&1
            $childExit=$LASTEXITCODE
        }finally{
            $env:STANDARD_VALIDATION_CANDIDATE_ID=$savedCandidate
            $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$savedRoot
            $ErrorActionPreference=$savedPreference
        }
        Assert-ParserCase ($childExit -eq 20 -and ($output -join "`n") -match 'existing candidate-bound source child') 'Unbound wrapper did not fail before tool access.'
        Assert-ParserCase (-not(Test-Path -LiteralPath $record)) 'Unbound wrapper wrote evidence.'
    }

    # Scenario: independent Python contract tests invoke the real native parser with benign/adversarial text.
    # Purpose: exercise source ownership, Unicode, proof shape and shell controls without scanner or network dependencies.
    It 'InterT10_runs_native_parser_contracts_without_skipping_or_scanner_installation' {
        $python=(Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $log=Join-Path $TestDrive 'native-parser-contracts.log'
        $previous=$ErrorActionPreference
        try{
            $ErrorActionPreference='Continue'
            & $python -I -B (Join-Path $parserRepositoryRoot 'tests/test_static_powershell_parser.py') *> $log
            $exit=$LASTEXITCODE
        }finally{$ErrorActionPreference=$previous}
        $output=Get-Content -LiteralPath $log -Raw
        Assert-ParserCase ($exit -eq 0 -and $output -match 'Ran 12 tests' -and $output -match '(?m)^OK\s*$' -and $output -notmatch 'skipped=') $output
    }
}
