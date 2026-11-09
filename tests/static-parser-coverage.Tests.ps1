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
        foreach($name in @('Assert-StaticCoverageDelta','Assert-StaticPreservedFindings','Read-StaticFrozenReceipt','Assert-StaticOutputLocation','Convert-StaticFindingComparisonKey','Write-StaticNativeReportFromProcess','Get-StaticApprovedSkillSpectorEntry')){
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

    # Scenario: the approved source registry activates 2.13.4 while retaining the reviewed 2.13.0 bridge entry.
    # Purpose: bind native and corrected parser paths to explicit release, wheel and analyzer identities.
    It 'UnitT42_binds_approved_SkillSpector_sources_and_release_specific_parser_corrections' {
        $registry=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/skillspector-approved-sources.json') | ConvertFrom-Json
        $registrySchema=Join-Path $parserRepositoryRoot 'docs/standards/schemas/skillspector-approved-sources-v1.schema.json'
        $policy=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/static-parser-host-ownership.json') | ConvertFrom-Json
        $policySchema=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json') | ConvertFrom-Json
        $bridge=Get-Content -Raw (Join-Path $parserRepositoryRoot 'scripts/standard_static_powershell.py')

        Assert-ParserCase ((Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/skillspector-approved-sources.json')) | Test-Json -SchemaFile $registrySchema) 'Approved source registry violates its strict schema.'
        Assert-ParserCase ($registry.active -ceq '2.13.4' -and $registry.entries.'2.13.4'.parserCorrection -ceq 'none') '2.13.4 must be the active native profile.'
        Assert-ParserCase ($registry.entries.'2.13.0'.parserCorrection -ceq 'powershell-native-command-ownership-v1') '2.13.0 must retain the bridge profile.'
        Assert-ParserCase ($policy.officialScannerVersion -ceq '2.13.0' -and $policy.officialAnalyzerSha256 -ceq $registry.entries.'2.13.0'.analyzerSha256) 'Bridge policy must remain bound to the approved 2.13.0 analyzer.'
        Assert-ParserCase ($policySchema.properties.officialScannerVersion.const -ceq '2.13.0') 'Bridge policy schema must remain release specific.'
        foreach($value in @('2.13.0',$registry.entries.'2.13.0'.releaseCommit,$registry.entries.'2.13.0'.wheelSha256,$registry.entries.'2.13.0'.analyzerSha256)){
            Assert-ParserCase ($bridge.Contains($value)) "Python bridge omits reviewed identity '$value'."
        }
    }

    # Scenario: the active approved source uses the native parser without a correction bridge.
    # Purpose: require portable stdout capture, UTF-8 mode and an explicit none-profile branch without --output.
    It 'UnitT52_captures_native_JSON_from_stdout_and_skips_the_bridge_for_none_profiles' {
        $wrapper=Get-Content -Raw (Join-Path $parserRepositoryRoot 'scripts/Invoke-StandardStaticScan.ps1')
        $bridge=Get-Content -Raw (Join-Path $parserRepositoryRoot 'scripts/standard_static_powershell.py')
        Assert-ParserCase ($wrapper.Contains("@('-I','-B','-X','utf8','-c','from skillspector.cli import app; app()','scan',`$skillFull,'--no-llm','--format','json')")) 'Native scan arguments must use UTF-8 stdout without --output.'
        Assert-ParserCase ($wrapper.Contains("@('-I','-B','-X','utf8',`$bridgePath")) 'The retained bridge scan must also run its Python CLI in UTF-8 mode.'
        Assert-ParserCase (-not $wrapper.Contains("'--output',`$originalReport")) 'Native scan must not use the unsupported output option.'
        Assert-ParserCase ($wrapper.Contains('function Write-StaticNativeReportFromProcess')) 'Native stdout capture must be centralized.'
        $noneBranch=[regex]::Match($wrapper,"(?s)'none' \{(?<body>.*?)\r?\n\s*\}\r?\n\s*'powershell-native-command-ownership-v1'").Groups['body'].Value
        Assert-ParserCase (-not [string]::IsNullOrWhiteSpace($noneBranch) -and $noneBranch -notmatch 'Invoke-StandardValidationProcess|standard_static_powershell\.py') 'The none profile must use only the single common native scanner run.'
        Assert-ParserCase ($wrapper -match "(?s)'none' \{.*FileMode\]::CreateNew") 'The none profile must copy the original report into a new final report.'
        Assert-ParserCase ($wrapper -match "(?s)'powershell-native-command-ownership-v1' \{.*standard_static_powershell\.py") 'The reviewed bridge must remain release-specific.'
        Assert-ParserCase ($bridge -notmatch '"--output"') 'The corrected bridge graph must not use unsupported SkillSpector file output.'
        Assert-ParserCase ($bridge -match 'redirect_stdout' -and $bridge -match 'open\("xb"\)') 'The corrected bridge graph must capture stdout and create its report exactly once.'
        $report=Join-Path $TestDrive 'native-stdout.json'
        Write-StaticNativeReportFromProcess -Process ([pscustomobject]@{status='passed';exitCode=0;cleanedUp=$true;outputTruncated=$false;stdout='{"execution_successful":true}'}) -Path $report
        Assert-ParserCase ((Get-Content -Raw $report | ConvertFrom-Json).execution_successful -eq $true) 'Valid native stdout was not written as the original report.'
        Assert-ParserRejected {Write-StaticNativeReportFromProcess -Process ([pscustomobject]@{status='passed';exitCode=0;cleanedUp=$true;outputTruncated=$false;stdout='{}'}) -Path $report}
        foreach($stdoutCase in @('', 'not-json')) {
            Assert-ParserRejected {Write-StaticNativeReportFromProcess -Process ([pscustomobject]@{status='passed';exitCode=0;cleanedUp=$true;outputTruncated=$false;stdout=$stdoutCase}) -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json'))}
        }
        Assert-ParserRejected {Write-StaticNativeReportFromProcess -Process ([pscustomobject]@{status='passed';exitCode=0;cleanedUp=$true;outputTruncated=$true;stdout='{}'}) -Path (Join-Path $TestDrive 'truncated.json')}
    }

    # Scenario: a frozen receipt omits or changes its approved source binding before the static child consumes it.
    # Purpose: reject missing, unknown, version-drifted and identity-drifted receipts with the established parser-profile error.
    It 'UnitT53_rejects_receipts_not_bound_to_one_approved_SkillSpector_entry' {
        $approved=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/skillspector-approved-sources.json') | ConvertFrom-Json
        $entry=$approved.entries.'2.13.4'
        $runId='b'*32
        $prefix='github:NVIDIA/SkillSpector@'+$entry.releaseTag+'#commit='+$entry.releaseCommit+'#asset=sha256:'+$entry.wheelSha256+'#'
        $valid=[pscustomobject]@{
            toolName='skillspector';source='NVIDIA/SkillSpector';channel='approved-source-registry'
            approvedSourceId='2.13.4';parserCorrection='none';resolvedVersion='2.13.4';frozenForRun=$true
            resolutionRunId=$runId;identityKind='release-commit-asset-metadata-dependency-closure-and-executable'
            offlineResolutionVerified=$true;consoleEntryPoint='skillspector.cli:app';resolvedIdentity=$prefix+'closure=fixture'
            installedClosureSha256='a'*64;dependencyClosure=@([pscustomobject]@{normalizedName='skillspector';version='2.13.4';sha256=$entry.wheelSha256})
        }
        Assert-ParserCase ((Get-StaticApprovedSkillSpectorEntry -Receipt $valid -ApprovedSources $approved -ExpectedResolutionRunId $runId).version -ceq '2.13.4') 'A valid approved receipt was rejected.'
        foreach($mutation in @('missing-approved-source','unknown-approved-source','version','identity')){
            $changed=$valid | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            switch($mutation){
                'missing-approved-source' {$changed.PSObject.Properties.Remove('approvedSourceId')}
                'unknown-approved-source' {$changed.approvedSourceId='9.9.9'}
                'version' {$changed.resolvedVersion='2.13.0'}
                'identity' {$changed.resolvedIdentity=$changed.resolvedIdentity.Replace($entry.releaseCommit,('0'*40))}
            }
            Assert-ParserRejected {Get-StaticApprovedSkillSpectorEntry -Receipt $changed -ApprovedSources $approved -ExpectedResolutionRunId $runId | Out-Null}
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
            'docs/standards/skillspector-approved-sources.json',
            'docs/standards/schemas/static-parser-host-ownership-v1.schema.json',
            'docs/standards/schemas/skillspector-approved-sources-v1.schema.json',
            'docs/standards/schemas/static-native-profile-execution-v1.schema.json',
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
        Assert-ParserCase ($selectedPaths.Count -eq 25 -and $admission.minItems -eq 25 -and $admission.maxItems -eq 25 -and $binding.minItems -eq 25 -and $binding.maxItems -eq 25) 'Runtime and both evidence-schema authority inventories disagree.'
        $contract=Get-Content -Raw (Join-Path $parserRepositoryRoot 'docs/standards/standard-validation-contract-v1.json') | ConvertFrom-Json
        Assert-ParserCase ($contract.evidence.staticParserHostOwnership.executionSchemaPath -ceq 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json') 'The sidecar schema is not part of the source contract.'
        Assert-ParserCase ($contract.evidence.staticParserHostOwnership.nativeExecutionSchemaPath -ceq 'docs/standards/schemas/static-native-profile-execution-v1.schema.json') 'The native none-profile schema is not part of the source contract.'
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
