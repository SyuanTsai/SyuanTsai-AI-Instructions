# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Human-approved exact static exceptions' {
    BeforeAll {
        $repositoryRoot=Split-Path -Parent $PSScriptRoot
        . (Join-Path $repositoryRoot 'scripts/Invoke-StandardValidation.ps1') -DefineFunctionsOnly -CandidateRoot $repositoryRoot -AdapterPath 'unused' -ArtifactsRoot $TestDrive -SourceRepository 'https://example.test/tests/exceptions.git' -SourceRevision ('a'*40) -BaseRevision ('b'*40)
        . (Join-Path $PSScriptRoot 'Initialize-SourceGateFixture.ps1')
        function Write-ExceptionFixture {
            $registry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $snapshot 'config/skillspector-exceptions.json') -Encoding UTF8
            $baseline | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $snapshot 'config/skillspector-exceptions/example.baseline.json') -Encoding UTF8
        }
        function Invoke-ExceptionCheck {
            Assert-StandardValidationStaticExceptions -Envelope $envelope -SnapshotRoot $snapshot -ActiveSkills @('example') -ScannerVersion '2.13.4' -Context 'Static analyzer'
        }
    }
    BeforeEach {
        $snapshot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $snapshot 'config/skillspector-exceptions'))
        $baseline=@{version=2;scanner_version='2.13.4';rules=@();fingerprints=@(@{hash=('sha256:'+('a'*64));rule_id='E1';file='SKILL.md';reason='approved-example'})}
        $registry=@{
            schemaVersion=1;contract='skillspector-human-approved-exceptions-v1'
            scanner=@{package='skillspector';version='2.13.4';fingerprintSchema='skillspector-finding-fingerprint-v2'}
            approval=@{approver='reviewer';approvedOn='2026-01-01';tracking='SYP-481'}
            review=@{expiresOn=[datetime]::UtcNow.AddDays(30).ToString('yyyy-MM-dd')}
            baselines=@(@{skillId='example';path='config/skillspector-exceptions/example.baseline.json'})
            exceptions=@(@{fingerprint=('sha256:'+('a'*64));skillId='example';ruleId='E1';file='SKILL.md';severity='MEDIUM';exceptionId='example-e1';necessity='documentation';riskAssessment='limited';compensatingControls='exact fingerprint';owner='reviewer';approvedOn='2026-01-01'})
        }
        $envelope=@{suppressedFindings=@(@{skillId='example';ruleId='E1';severity='medium';file='SKILL.md';line=1;suppressionReason='approved-example'})}
    }

    # Scenario: suppression is absent, null or empty. Purpose: preserve the registry-free legacy path.
    It 'UnitT10_returns_zero_without_reading_a_registry' {
        foreach ($value in @(@{},@{suppressedFindings=$null},@{suppressedFindings=@()})) {
            $envelope=$value
            Invoke-ExceptionCheck | Should -Be 0
        }
    }
    # Scenario: all approval bindings match. Purpose: accept suppression without mutating the envelope.
    It 'UnitT20_accepts_the_exact_approved_baseline' {
        Write-ExceptionFixture
        $before=$envelope | ConvertTo-Json -Depth 10 -Compress
        Invoke-ExceptionCheck | Should -Be 1
        ($envelope | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly $before
    }
    # Scenario: suppression has no registry. Purpose: fail closed on missing human approval.
    It 'UnitT30_blocks_a_missing_registry' {
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer reports suppressed findings without a human-approved exception registry'
    }
    # Scenario: approval expired yesterday UTC. Purpose: enforce review expiry.
    It 'UnitT40_blocks_expired_review' {
        $registry.review.expiresOn=[datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-dd')
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer exception registry review.expiresOn is expired'
    }
    # Scenario: the registry names another scanner. Purpose: bind approval to the actual run version.
    It 'UnitT50_blocks_scanner_version_drift' {
        $registry.scanner.version='2.13.0'
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer exception registry scanner.version differs from the frozen scanner'
    }
    # Scenario: baseline suppresses a whole rule. Purpose: permit only exact fingerprints.
    It 'UnitT60_blocks_rule_suppression' {
        $baseline.rules=@('E1')
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer baseline rules must be an empty array'
    }
    # Scenario: scanner suppression reason is unknown. Purpose: reject unapproved suppression.
    It 'UnitT70_blocks_an_unknown_suppression_reason' {
        $envelope.suppressedFindings[0].suppressionReason='unknown'
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer suppressed a finding that is not in the approved baseline'
    }
    # Scenario: a high finding is suppressed. Purpose: keep high risk non-waivable.
    It 'UnitT80_fails_high_severity_suppression' {
        $envelope.suppressedFindings[0].severity='high'
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'FAILED|Static analyzer suppressed a high finding.'
    }
    # Scenario: a fingerprint lacks a registry exception. Purpose: require a bijection.
    It 'UnitT90_blocks_unregistered_fingerprints' {
        $baseline.fingerprints+=@{hash=('sha256:'+('b'*64));rule_id='E1';file='SKILL.md';reason='extra'}
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer registry exceptions and baseline fingerprints must be one-to-one'
    }
    # Scenario: registry redirects a baseline. Purpose: enforce the canonical snapshot path.
    It 'UnitT91_blocks_noncanonical_baseline_paths' {
        $registry.baselines[0].path='../example.baseline.json'
        Write-ExceptionFixture
        { Invoke-ExceptionCheck } | Should -Throw 'BLOCKED|Static analyzer baseline path must match config/skillspector-exceptions/<skillId>.baseline.json'
    }
    # Scenario: a non-array suppression value is provided. Purpose: reject malformed envelopes.
    It 'UnitT92_fails_non_array_suppression' {
        $envelope.suppressedFindings='invalid'
        { Invoke-ExceptionCheck } | Should -Throw 'FAILED|Static analyzer suppressedFindings are not an array'
    }

    # Scenario: a retained static envelope substitutes a suppression outside its candidate's approved baseline.
    # Purpose: revalidate approval against the retained snapshot, scanner receipt and active Skills before accepting findings.
    It 'UnitT93_blocks_retained_source_suppression_outside_the_approved_baseline' {
        $report=New-SourceGateFixture
        $snapshot=$report.artifacts.snapshotRoot
        [void][IO.Directory]::CreateDirectory((Join-Path $snapshot 'config/skillspector-exceptions'))
        $receipt=Get-Content -Raw -Encoding UTF8 $report.sourceValidation.toolReceipts[2].path | ConvertFrom-Json
        $baseline.scanner_version=$receipt.resolvedVersion
        $registry.scanner.version=$receipt.resolvedVersion
        $registry.baselines[0].skillId='alpha'
        $registry.baselines[0].path='config/skillspector-exceptions/alpha.baseline.json'
        $registry.exceptions[0].skillId='alpha'
        Write-SourceGateFixtureJson (Join-Path $snapshot 'config/skillspector-exceptions.json') $registry
        Write-SourceGateFixtureJson (Join-Path $snapshot $registry.baselines[0].path) $baseline

        # Bind the added approval files into the candidate and all retained raw events.
        $inventory=Get-StandardValidationInventory -Root $snapshot -Context 'retained exception fixture'
        $contentHash=Get-StandardValidationInventorySha256 -Inventory $inventory
        $report.candidate.inventory=$inventory
        $report.candidate.contentSha256=$contentHash
        $report.sourceValidation.contentSha256=$contentHash
        $candidateId=Get-StandardValidationTextSha256 -Value "$($report.candidate.sourceRevision)`n$contentHash`n$($report.adapter.sha256)`n$($report.runId)"
        $report.sourceValidation.candidateId=$candidateId
        foreach ($event in $report.sourceValidation.events) {
            $event.candidateId=$candidateId
            $raw=Get-Content -Raw -Encoding UTF8 $event.outputPath | ConvertFrom-Json
            $raw.candidateId=$candidateId
            Write-SourceGateFixtureJson $event.outputPath $raw
        }
        for ($index=0; $index -lt $report.sourceValidation.events.Count; $index++) {
            Set-SourceGateEnvelope $report $index { param($value) $value.candidateIdentity=$candidateId }
        }
        $caseRows=@($inventory | Sort-Object -Property path -CaseSensitive | ForEach-Object { [pscustomobject]@{path=$_.path;sha256=$_.sha256} })
        $caseHash=Get-StandardValidationTextSha256 -Value (ConvertTo-Json -InputObject $caseRows -Depth 3 -Compress)
        Set-SourceGateCases $report { param($cases) $cases.candidateSnapshotSha256=$caseHash }
        $staticIndex=$report.sourceValidation.events.Count-1
        Set-SourceGateEnvelope $report $staticIndex {
            param($value)
            $value | Add-Member -NotePropertyName suppressedFindings -NotePropertyValue @(@{skillId='alpha';ruleId='E1';severity='medium';file='SKILL.md';line=1;suppressionReason='approved-example'})
        }
        Invoke-SourceGateFixture $report | Should -BeTrue

        Set-SourceGateEnvelope $report $staticIndex { param($value) $value.suppressedFindings[0].suppressionReason='unapproved' }
        { Invoke-SourceGateFixture $report } | Should -Throw 'BLOCKED|source report findings suppressed a finding that is not in the approved baseline'
    }
}

Describe 'Consumer static child approved baselines' {
    BeforeAll {
        $repositoryRoot=Split-Path -Parent $PSScriptRoot
        $childPath=Join-Path $repositoryRoot 'scripts/consumer/Invoke-ConsumerValidationChild.ps1'
        $pwshPath=(Get-Process -Id $PID).Path
        . (Join-Path $repositoryRoot 'scripts/Invoke-StandardValidation.ps1') -DefineFunctionsOnly -CandidateRoot $repositoryRoot -AdapterPath 'unused' -ArtifactsRoot $TestDrive -SourceRepository 'https://example.test/tests/static-child.git' -SourceRevision ('c'*40) -BaseRevision ('d'*40)

        function New-StaticChildFixture {
            param([switch]$WithRegistry,[ValidateSet('approved','new-finding','mutate-baseline','none')][string]$Mode='none',[switch]$MissingBaseline)
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $skillRoot=Join-Path $root 'skills/example'
            [void][IO.Directory]::CreateDirectory($skillRoot)
            Set-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Encoding UTF8 -Value "---`nname: example`ndescription: fixture`n---`n"
            $scannerPath=Join-Path $root 'fake-skillspector.ps1'
            @'
$skillRoot=[string]$args[1]
$mode=[string]$env:P11_STATIC_FAKE_MODE
$report=[ordered]@{
    skill=[ordered]@{name='example';source=$skillRoot}
    components=@([ordered]@{path='SKILL.md'})
    issues=@()
    execution_successful=$true
    analysis_completeness=[ordered]@{execution_successful=$true;is_complete=$true;status='complete';coverage_percent=100;ledger_exceptions=@();scope_exclusions=@();limitations=@()}
}
$baselineIndex=[Array]::IndexOf($args,'--baseline')
if($baselineIndex -ge 0){
    $baselinePath=[string]$args[$baselineIndex+1]
    if($mode -ceq 'mutate-baseline'){Add-Content -LiteralPath $baselinePath -Value ''}
    $report.suppressed_count=1
    $report.suppressed=@([ordered]@{
        id='E1';severity='MEDIUM';location=[ordered]@{file='SKILL.md';start_line=1};suppressed=$true
        suppression_reason='approved-example'
    })
}
if($mode -ceq 'new-finding'){
    $report.issues=@([ordered]@{id='NEW1';severity='HIGH';file='SKILL.md';message='new unapproved finding'})
}
$report|ConvertTo-Json -Depth 20
$global:LASTEXITCODE=0
'@ | Set-Content -LiteralPath $scannerPath -Encoding UTF8
            $toolchainPath=Join-Path $root 'toolchain.json'
            [ordered]@{
                skillSpectorPath=$scannerPath
                skillSpectorSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $scannerPath).Hash.ToLowerInvariant()
            }|ConvertTo-Json|Set-Content -LiteralPath $toolchainPath -Encoding UTF8
            if($WithRegistry){
                $configRoot=Join-Path $root 'config/skillspector-exceptions'
                [void][IO.Directory]::CreateDirectory($configRoot)
                $baselinePath=Join-Path $configRoot 'example.baseline.json'
                if(-not $MissingBaseline){
                    [ordered]@{version=2;scanner_version='2.13.4';rules=@();fingerprints=@([ordered]@{hash=('sha256:'+('a'*64));rule_id='E1';file='SKILL.md';reason='approved-example'})}|
                        ConvertTo-Json -Depth 10|Set-Content -LiteralPath $baselinePath -Encoding UTF8
                }
                [ordered]@{
                    schemaVersion=1;contract='skillspector-human-approved-exceptions-v1'
                    scanner=[ordered]@{package='skillspector';version='2.13.4';fingerprintSchema='skillspector-finding-fingerprint-v2'}
                    approval=[ordered]@{approver='fixture-reviewer';approvedOn='2026-01-01';tracking='EXAMPLE-1'}
                    review=[ordered]@{expiresOn='2099-01-01'}
                    baselines=@([ordered]@{skillId='example';path='config/skillspector-exceptions/example.baseline.json'})
                    exceptions=@([ordered]@{fingerprint=('sha256:'+('a'*64));skillId='example';ruleId='E1';file='SKILL.md';severity='MEDIUM';exceptionId='example-e1';necessity='fixture';riskAssessment='limited';compensatingControls='exact fingerprint';owner='fixture-owner';approvedOn='2026-01-01'})
                }|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'config/skillspector-exceptions.json') -Encoding UTF8
            }
            [pscustomobject]@{Root=$root;SkillRoot=$skillRoot;ScannerPath=$scannerPath;ToolchainPath=$toolchainPath;BaselinePath=(Join-Path $root 'config/skillspector-exceptions/example.baseline.json');Mode=$Mode}
        }

        function Invoke-StaticChildFixture {
            param($Fixture)
            $stderrPath=Join-Path $Fixture.Root 'child.stderr'
            $saved=@{
                CandidateRoot=$env:STANDARD_VALIDATION_CANDIDATE_ROOT
                CandidateId=$env:STANDARD_VALIDATION_CANDIDATE_ID
                ActiveSkills=$env:STANDARD_VALIDATION_ACTIVE_SKILLS
                SkillsRoot=$env:STANDARD_VALIDATION_SKILLS_ROOT
                FakeMode=$env:P11_STATIC_FAKE_MODE
            }
            try{
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$Fixture.Root
                $env:STANDARD_VALIDATION_CANDIDATE_ID='fixture-candidate'
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS='example'
                $env:STANDARD_VALIDATION_SKILLS_ROOT=(Join-Path $Fixture.Root 'skills')
                $env:P11_STATIC_FAKE_MODE=$Fixture.Mode
                Push-Location $Fixture.Root
                try{
                    $stdout=@(& $pwshPath -NoProfile -NonInteractive -File $childPath -Mode static -ToolchainPath $Fixture.ToolchainPath `
                        -ToolchainSha256 ((Get-FileHash -Algorithm SHA256 -LiteralPath $Fixture.ToolchainPath).Hash.ToLowerInvariant()) 2> $stderrPath)
                    $exitCode=$LASTEXITCODE
                }finally{Pop-Location}
            }finally{
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$saved.CandidateRoot
                $env:STANDARD_VALIDATION_CANDIDATE_ID=$saved.CandidateId
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS=$saved.ActiveSkills
                $env:STANDARD_VALIDATION_SKILLS_ROOT=$saved.SkillsRoot
                $env:P11_STATIC_FAKE_MODE=$saved.FakeMode
            }
            $stderr=if(Test-Path -LiteralPath $stderrPath){Get-Content -Raw -LiteralPath $stderrPath}else{''}
            $envelope=if($exitCode-eq 0){($stdout -join "`n")|ConvertFrom-Json -Depth 100}else{$null}
            [pscustomobject]@{ExitCode=$exitCode;Stdout=$stdout;Stderr=$stderr;Envelope=$envelope}
        }
    }

    # Scenario: an active Skill has one approved MEDIUM fingerprint in its canonical baseline.
    # Purpose: apply scanner-native suppression, project its evidence, and let central validation accept it.
    It 'UnitT10_applies_the_bound_baseline_and_reports_native_suppression' {
        $fixture=New-StaticChildFixture -WithRegistry -Mode approved
        $result=Invoke-StaticChildFixture $fixture
        $result.Stderr|Should -BeNullOrEmpty
        $result.ExitCode|Should -Be 0
        @($result.Envelope.nativeReports[0].arguments)|Should -Be @('scan',$fixture.SkillRoot,'--no-llm','--format','json','--baseline',$fixture.BaselinePath,'--show-suppressed')
        @($result.Envelope.findings).Count|Should -Be 0
        @($result.Envelope.suppressedFindings).Count|Should -Be 1
        $result.Envelope.suppressedFindings[0].skillId|Should -BeExactly 'example'
        $result.Envelope.suppressedFindings[0].ruleId|Should -BeExactly 'E1'
        $result.Envelope.suppressedFindings[0].severity|Should -BeExactly 'medium'
        $result.Envelope.suppressedFindings[0].file|Should -BeExactly 'SKILL.md'
        $result.Envelope.suppressedFindings[0].line|Should -Be 1
        $result.Envelope.suppressedFindings[0].suppressionReason|Should -BeExactly 'approved-example'
        Assert-StandardValidationStaticExceptions -Envelope $result.Envelope -SnapshotRoot $fixture.Root -ActiveSkills @('example') -ScannerVersion '2.13.4' -Context 'Static analyzer'|Should -Be 1
    }

    # Scenario: the baseline suppresses one approved finding while SkillSpector reports a new HIGH finding.
    # Purpose: keep non-baseline findings in the normal findings path and preserve blocking severity policy.
    It 'UnitT20_keeps_a_new_finding_outside_the_baseline_blocking' {
        $fixture=New-StaticChildFixture -WithRegistry -Mode new-finding
        $result=Invoke-StaticChildFixture $fixture
        $result.Stderr|Should -BeNullOrEmpty
        $result.ExitCode|Should -Be 0
        @($result.Envelope.suppressedFindings).Count|Should -Be 1
        @($result.Envelope.findings).Count|Should -Be 1
        {Assert-StandardValidationFindings -Envelope $result.Envelope -Context 'Static analyzer'}|Should -Throw 'FAILED|Static analyzer contains a high finding.'
    }

    # Scenario: a binding has no regular baseline file, or the scanner changes that file during analysis.
    # Purpose: fail closed before accepting an unbound or mutable exception set.
    It 'UnitT30_fails_closed_for_missing_or_mutated_bound_baselines' {
        $missing=Invoke-StaticChildFixture (New-StaticChildFixture -WithRegistry -Mode approved -MissingBaseline)
        $missing.ExitCode|Should -Not -Be 0
        $missing.Stderr|Should -Match 'baseline.*missing|missing.*baseline'
        $mutated=Invoke-StaticChildFixture (New-StaticChildFixture -WithRegistry -Mode mutate-baseline)
        $mutated.ExitCode|Should -Not -Be 0
        $mutated.Stderr|Should -Match 'Baseline changed during static analysis'
    }

    # Scenario: the candidate snapshot has no exception registry.
    # Purpose: preserve the existing scanner command line and envelope exactly for registry-free repositories.
    It 'UnitT40_preserves_the_registry_free_static_contract' {
        $fixture=New-StaticChildFixture -Mode none
        $result=Invoke-StaticChildFixture $fixture
        $result.Stderr|Should -BeNullOrEmpty
        $result.ExitCode|Should -Be 0
        @($result.Envelope.nativeReports[0].arguments)|Should -Be @('scan',$fixture.SkillRoot,'--no-llm','--format','json')
        $result.Envelope.PSObject.Properties.Name|Should -Not -Contain 'suppressedFindings'
        @($result.Envelope.findings).Count|Should -Be 0
    }
}
