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
        $envelope=@{suppressedFindings=@(@{skillId='example';ruleId='E1';severity='medium';file='SKILL.md';suppressionReason='approved-example'})}
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
            $value | Add-Member -NotePropertyName suppressedFindings -NotePropertyValue @(@{skillId='alpha';ruleId='E1';severity='medium';file='SKILL.md';suppressionReason='approved-example'})
        }
        Invoke-SourceGateFixture $report | Should -BeTrue

        Set-SourceGateEnvelope $report $staticIndex { param($value) $value.suppressedFindings[0].suppressionReason='unapproved' }
        { Invoke-SourceGateFixture $report } | Should -Throw 'BLOCKED|source report findings suppressed a finding that is not in the approved baseline'
    }
}
