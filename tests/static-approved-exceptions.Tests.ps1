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

Describe 'Consumer package-adapter Unicode hidden-character check' -Tag 'SYP536' {
    BeforeAll {
        $repositoryRoot=Split-Path -Parent $PSScriptRoot
        $childPath=Join-Path $repositoryRoot 'scripts/consumer/Invoke-ConsumerValidationChild.ps1'
        $pwshPath=(Get-Process -Id $PID).Path
        $utf8NoBom=[Text.UTF8Encoding]::new($false)

        function ConvertFrom-Syp536CodePoint {
            param([Parameter(Mandatory=$true)][int]$Value)
            [char]::ConvertFromUtf32($Value)
        }

        function New-Syp536PackageAdapterFixture {
            param([string[]]$SkillIds=@('example'))
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $skillsRoot=Join-Path $root 'skills'
            [void][IO.Directory]::CreateDirectory($skillsRoot)
            foreach($skillId in $SkillIds){[void][IO.Directory]::CreateDirectory((Join-Path $skillsRoot $skillId))}
            $validatorPath=Join-Path $root 'fake-upstream-adapter-validator.ps1'
            @'
param(
    [string]$PackageRoot,[string]$PolicyPath,[string]$SourceRepository,
    [string]$SourceRevision,[string]$ArchiveSha256,[string]$OutputPath
)
[ordered]@{status='passed';decision='PASS';surfaces=@()}|ConvertTo-Json|Set-Content -LiteralPath $OutputPath -Encoding UTF8
'@ | Set-Content -LiteralPath $validatorPath -Encoding UTF8
            $policyPath=Join-Path $root 'upstream-policy.json'
            [IO.File]::WriteAllText($policyPath,'{}',$utf8NoBom)
            $toolchainPath=Join-Path $root 'toolchain.json'
            [ordered]@{
                upstreamAdapterValidatorPath=$validatorPath
                upstreamAdapterValidatorSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $validatorPath).Hash.ToLowerInvariant()
                upstreamPolicyPath=$policyPath
                upstreamPolicySha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $policyPath).Hash.ToLowerInvariant()
            }|ConvertTo-Json|Set-Content -LiteralPath $toolchainPath -Encoding UTF8
            [pscustomobject]@{Root=$root;SkillsRoot=$skillsRoot;SkillIds=$SkillIds;ToolchainPath=$toolchainPath}
        }

        function Write-Syp536Text {
            param($Fixture,[string]$SkillId,[string]$RelativePath,[string]$Text,[switch]$Bom)
            $path=Join-Path (Join-Path $Fixture.SkillsRoot $SkillId) $RelativePath
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            $bytes=$utf8NoBom.GetBytes($Text)
            if($Bom){$bytes=[byte[]](@(0xEF,0xBB,0xBF)+@($bytes))}
            [IO.File]::WriteAllBytes($path,$bytes)
            $path
        }

        function Invoke-Syp536PackageAdapterFixture {
            param($Fixture)
            $stderrPath=Join-Path $Fixture.Root 'child.stderr'
            $saved=@{
                CandidateRoot=$env:STANDARD_VALIDATION_CANDIDATE_ROOT
                CandidateId=$env:STANDARD_VALIDATION_CANDIDATE_ID
                ActiveSkills=$env:STANDARD_VALIDATION_ACTIVE_SKILLS
                SkillsRoot=$env:STANDARD_VALIDATION_SKILLS_ROOT
            }
            try{
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$Fixture.Root
                $env:STANDARD_VALIDATION_CANDIDATE_ID='syp536-fixture-candidate'
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS=$Fixture.SkillIds -join ';'
                $env:STANDARD_VALIDATION_SKILLS_ROOT=$Fixture.SkillsRoot
                Push-Location $Fixture.Root
                try{
                    $stdout=@(& $pwshPath -NoProfile -NonInteractive -File $childPath -Mode package-adapter `
                        -ToolchainPath $Fixture.ToolchainPath `
                        -ToolchainSha256 ((Get-FileHash -Algorithm SHA256 -LiteralPath $Fixture.ToolchainPath).Hash.ToLowerInvariant()) `
                        -SourceRepository 'https://example.test/syp536.git' -SourceRevision ('a'*40) -ArchiveSha256 ('b'*64) 2> $stderrPath)
                    $exitCode=$LASTEXITCODE
                }finally{Pop-Location}
            }finally{
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$saved.CandidateRoot
                $env:STANDARD_VALIDATION_CANDIDATE_ID=$saved.CandidateId
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS=$saved.ActiveSkills
                $env:STANDARD_VALIDATION_SKILLS_ROOT=$saved.SkillsRoot
            }
            $stderr=if(Test-Path -LiteralPath $stderrPath){Get-Content -Raw -LiteralPath $stderrPath}else{''}
            $envelope=if($exitCode-eq 0){($stdout -join "`n")|ConvertFrom-Json -Depth 100}else{$null}
            [pscustomobject]@{ExitCode=$exitCode;Stderr=$stderr;Envelope=$envelope}
        }
    }

    # Scenario: normal Chinese, full-width space, emoji sequences, a leading BOM, and a valid PNG are present.
    # Purpose: preserve legitimate text and emoji while ignoring a known binary file with matching magic.
    It 'UnitT10_returns_no_findings_for_allowed_text_emoji_BOM_and_binary_NUL' {
        $fixture=New-Syp536PackageAdapterFixture
        $fullWidthSpace=ConvertFrom-Syp536CodePoint 0x3000
        $man=ConvertFrom-Syp536CodePoint 0x1F468
        $woman=ConvertFrom-Syp536CodePoint 0x1F469
        $girl=ConvertFrom-Syp536CodePoint 0x1F467
        $zwj=ConvertFrom-Syp536CodePoint 0x200D
        $variation=ConvertFrom-Syp536CodePoint 0xFE0F
        $skinTone=ConvertFrom-Syp536CodePoint 0x1F3FB
        [void](Write-Syp536Text $fixture example 'SKILL.md' "一般中文${fullWidthSpace}內容`n${man}${zwj}${woman}${zwj}${girl}`n${man}${variation}${skinTone}${zwj}${woman}`n" -Bom)
        [void](Write-Syp536Text $fixture example 'empty.txt' '')
        [IO.File]::WriteAllBytes((Join-Path $fixture.SkillsRoot 'example/image.png'),[byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00))

        $result=Invoke-Syp536PackageAdapterFixture $fixture

        $result.ExitCode|Should -Be 0
        $result.Stderr|Should -BeNullOrEmpty
        @($result.Envelope.findings).Count|Should -Be 0
    }

    # Scenario: an unknown NUL-bearing payload, a spoofed PNG, and a valid PNG are scanned together.
    # Purpose: reject unknown binary bypasses, scan mismatched known-binary extensions as text, and skip only verified binary magic.
    It 'UnitT15_rejects_unknown_NUL_payloads_and_scans_spoofed_binary_extensions' {
        $fixture=New-Syp536PackageAdapterFixture
        $tagBytes=$utf8NoBom.GetBytes((ConvertFrom-Syp536CodePoint 0xE0041))
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.SkillsRoot 'example/references'))
        [IO.File]::WriteAllBytes(
            (Join-Path $fixture.SkillsRoot 'example/references/payload.bin'),
            [byte[]](@(0x00)+@($tagBytes)))
        [void](Write-Syp536Text $fixture example 'spoofed.png' ('text'+(ConvertFrom-Syp536CodePoint 0x202E)))
        [IO.File]::WriteAllBytes(
            (Join-Path $fixture.SkillsRoot 'example/valid.png'),
            [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00))

        $findings=@((Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings)

        @($findings).Count|Should -Be 2
        @($findings|Where-Object path -CEQ 'references/payload.bin').ruleId|Should -BeExactly 'unicode-unrecognized-binary'
        @($findings|Where-Object path -CEQ 'spoofed.png').ruleId|Should -BeExactly 'unicode-hidden-character'
        @($findings|Where-Object path -CEQ 'valid.png').Count|Should -Be 0
    }

    # Scenario: one representative from every blocked category appears at line 2, column 2 in separate files.
    # Purpose: project deterministic high findings with the canonical path and location for every category.
    It 'UnitT20_reports_each_hidden_character_category_with_exact_location' {
        $fixture=New-Syp536PackageAdapterFixture
        $cases=[ordered]@{
            'nested/tag.txt'=@(0xE0041,'tag')
            'bidi.txt'=@(0x202E,'bidi')
            'deprecated.txt'=@(0x206A,'deprecated-format')
            'operator.txt'=@(0x2062,'invisible-operator')
            'zero-width.txt'=@(0x200B,'zero-width')
            'bom.txt'=@(0xFEFF,'bom-not-at-start')
            'zwj.txt'=@(0x200D,'zero-width')
        }
        foreach($entry in $cases.GetEnumerator()){
            [void](Write-Syp536Text $fixture example $entry.Key ("first`nA"+(ConvertFrom-Syp536CodePoint $entry.Value[0])+'B'))
        }

        $result=Invoke-Syp536PackageAdapterFixture $fixture

        $result.ExitCode|Should -Be 0
        @($result.Envelope.findings).Count|Should -Be $cases.Count
        foreach($entry in $cases.GetEnumerator()){
            $finding=@($result.Envelope.findings|Where-Object path -CEQ $entry.Key)
            $finding.Count|Should -Be 1
            $finding[0].severity|Should -BeExactly 'high'
            $finding[0].ruleId|Should -BeExactly 'unicode-hidden-character'
            $hex='U+{0:X4}' -f $entry.Value[0]
            $finding[0].message|Should -BeExactly "Hidden or control character $hex ($($entry.Value[1])) at line 2, column 2."
            $finding[0].fingerprint|Should -Match '^[a-f0-9]{64}$'
            $finding[0].skillId|Should -BeExactly 'example'
        }
    }

    # Scenario: every owned range endpoint and each requested neighboring scalar are scanned.
    # Purpose: lock the exact inclusive range boundaries without expanding the zero-tolerance set.
    It 'UnitT25_matches_all_range_boundaries_without_matching_neighbors' {
        $fixture=New-Syp536PackageAdapterFixture
        $blocked=@(
            0xE0000,0xE007F,
            0x061C,0x200E,0x200F,0x202A,0x202E,0x2066,0x2069,
            0x206A,0x206F,0x2061,0x2064,
            0x200B,0x200D,0x2060,0x180E,0x034F)
        for($index=0;$index-lt $blocked.Count;$index++){
            [void](Write-Syp536Text $fixture example ("blocked-$index.txt") (ConvertFrom-Syp536CodePoint $blocked[$index]))
        }
        $allowed=0xE0080,0x2065,0x2070,0x200A,0x2029,0x180D,0x034E
        [void](Write-Syp536Text $fixture example 'allowed-neighbors.txt' (($allowed|ForEach-Object { ConvertFrom-Syp536CodePoint $_ })-join ''))

        $findings=@((Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings)

        @($findings).Count|Should -Be $blocked.Count
        @($findings|Where-Object path -CEQ 'allowed-neighbors.txt').Count|Should -Be 0
        for($index=0;$index-lt $blocked.Count;$index++){
            $finding=@($findings|Where-Object path -CEQ "blocked-$index.txt")
            $finding.Count|Should -Be 1
            $finding[0].message|Should -Match ([regex]::Escape(('U+{0:X4}' -f $blocked[$index])))
        }
    }

    # Scenario: a bidi control is embedded between visible sentinel text.
    # Purpose: keep the blocked character and surrounding source text out of log-safe messages.
    It 'UnitT30_does_not_echo_the_hidden_character_or_source_context' {
        $fixture=New-Syp536PackageAdapterFixture
        $hidden=ConvertFrom-Syp536CodePoint 0x202E
        [void](Write-Syp536Text $fixture example 'leak.txt' ("before${hidden}after"))

        $finding=(Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings[0]

        $finding.message.Contains($hidden)|Should -BeFalse
        $finding.message|Should -Not -Match 'before|after'
    }

    # Scenario: known and inferred text files contain invalid UTF-8, while a known text file contains NUL.
    # Purpose: fail closed on malformed text without treating an unknown non-NUL file as binary.
    It 'UnitT40_reports_invalid_UTF8_and_NUL_in_known_text' {
        $fixture=New-Syp536PackageAdapterFixture
        [IO.File]::WriteAllBytes((Join-Path $fixture.SkillsRoot 'example/known.md'),[byte[]]@(0xC3,0x28))
        [IO.File]::WriteAllBytes((Join-Path $fixture.SkillsRoot 'example/inferred.bin'),[byte[]]@(0xC3,0x28))
        [IO.File]::WriteAllBytes((Join-Path $fixture.SkillsRoot 'example/nul.md'),[byte[]]@(0x41,0x00,0x42))

        $findings=@((Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings)

        @($findings|Where-Object ruleId -CEQ 'unicode-invalid-utf8').Count|Should -Be 2
        @($findings|Where-Object ruleId -CEQ 'unicode-nul-in-text').Count|Should -Be 1
        @($findings|Where-Object path -CEQ 'known.md').ruleId|Should -BeExactly 'unicode-invalid-utf8'
        @($findings|Where-Object path -CEQ 'inferred.bin').ruleId|Should -BeExactly 'unicode-invalid-utf8'
        @($findings|Where-Object path -CEQ 'nul.md').ruleId|Should -BeExactly 'unicode-nul-in-text'
    }

    # Scenario: one file contains more than fifty blocked scalar values.
    # Purpose: bound detailed findings while preserving an explicit total-count truncation signal.
    It 'UnitT50_caps_details_at_fifty_and_adds_one_truncation_finding' {
        $fixture=New-Syp536PackageAdapterFixture
        $hidden=ConvertFrom-Syp536CodePoint 0x200B
        [void](Write-Syp536Text $fixture example 'many.txt' ($hidden*55))

        $findings=@((Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings)

        @($findings|Where-Object ruleId -CEQ 'unicode-hidden-character').Count|Should -Be 50
        @($findings|Where-Object ruleId -CEQ 'unicode-hidden-character-truncated').Count|Should -Be 1
        @($findings|Where-Object ruleId -CEQ 'unicode-hidden-character-truncated')[0].message|Should -Match '55'
    }

    # Scenario: a supplementary emoji precedes a supplementary tag character on the same line.
    # Purpose: count Unicode scalar values rather than UTF-16 code units when calculating columns.
    It 'UnitT60_counts_surrogate_pairs_as_one_column' {
        $fixture=New-Syp536PackageAdapterFixture
        $emoji=ConvertFrom-Syp536CodePoint 0x1F600
        $tag=ConvertFrom-Syp536CodePoint 0xE0041
        [void](Write-Syp536Text $fixture example 'scalar.txt' ("${emoji}${tag}"))

        $finding=(Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings[0]

        $finding.message|Should -Match 'U\+E0041 \(tag\) at line 1, column 2\.'
    }

    # Scenario: a blocked zero-width character appears after two CRLF line endings and one visible scalar.
    # Purpose: keep one-based line and code-point column reporting correct for Windows line endings.
    It 'UnitT65_reports_CRLF_location_at_line_three_column_two' {
        $fixture=New-Syp536PackageAdapterFixture
        $hidden=ConvertFrom-Syp536CodePoint 0x200B
        [void](Write-Syp536Text $fixture example 'crlf.txt' ("first`r`nsecond`r`nA${hidden}"))

        $finding=(Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings[0]

        $finding.message|Should -Match 'at line 3, column 2\.'
    }

    # Scenario: two active Skills each contain a blocked zero-width character.
    # Purpose: scan every active package instead of only the first active Skill.
    It 'UnitT70_scans_every_active_skill' {
        $fixture=New-Syp536PackageAdapterFixture -SkillIds @('alpha','beta')
        $hidden=ConvertFrom-Syp536CodePoint 0x200B
        [void](Write-Syp536Text $fixture alpha 'SKILL.md' ("alpha${hidden}"))
        [void](Write-Syp536Text $fixture beta 'SKILL.md' ("beta${hidden}"))

        $findings=@((Invoke-Syp536PackageAdapterFixture $fixture).Envelope.findings)

        @($findings).Count|Should -Be 2
        (@($findings.skillId|Sort-Object)-join '|')|Should -BeExactly 'alpha|beta'
    }

    # Scenario: roughly two MiB of valid emoji ZWJ sequences precede one blocked scalar.
    # Purpose: require a bounded-memory streaming scalar walk with a generous subprocess time ceiling.
    It 'UnitT80_scans_two_MiB_of_emoji_ZWJ_text_within_sixty_seconds' {
        $fixture=New-Syp536PackageAdapterFixture
        $man=ConvertFrom-Syp536CodePoint 0x1F468
        $woman=ConvertFrom-Syp536CodePoint 0x1F469
        $zwj=ConvertFrom-Syp536CodePoint 0x200D
        $hidden=ConvertFrom-Syp536CodePoint 0x200B
        $sequence="${man}${zwj}${woman}"
        $chunk=($sequence*1000)-join ''
        $text=(($chunk*191)-join '')+$hidden
        [void](Write-Syp536Text $fixture example 'large.txt' $text)

        $result=$null
        $duration=Measure-Command { $result=Invoke-Syp536PackageAdapterFixture $fixture }

        @($result.Envelope.findings).Count|Should -Be 1
        $result.Envelope.findings[0].ruleId|Should -BeExactly 'unicode-hidden-character'
        $duration.TotalSeconds|Should -BeLessThan 60
    }
}
