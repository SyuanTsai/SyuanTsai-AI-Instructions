$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:AggregateScript = Join-Path $script:RepositoryRoot 'scripts/Assert-UnixCoreAggregate.ps1'
. $script:AggregateScript -AggregateRoot '.' -Platform linux -ExpectedPlanSha256 ('0' * 64) `
    -ExpectedPlanRunAttempt 1 -PlanResult success -AuthorityResult success -PesterResult success -DefineFunctionsOnly

function Write-UnixAggregateTestJson {
    param([string] $Path, $Value, [switch] $Compress)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) | Out-Null
    $json = if ($Compress) { $Value | ConvertTo-Json -Depth 12 -Compress } else { $Value | ConvertTo-Json -Depth 12 }
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function New-UnixAggregateTestTree {
    param(
        [string] $Root,
        [int] $PlanAttempt = 1,
        [int] $AuthorityAttempt = $PlanAttempt,
        [int] $Shard01Attempt = $PlanAttempt,
        [int] $Shard02Attempt = $PlanAttempt
    )

    $plan = [pscustomobject][ordered]@{
        schemaVersion=2; runId='run-574'; runAttempt=$PlanAttempt; windowsPlanSha256=('a' * 64)
        authorityTestFiles=[string[]]@('authority.Tests.ps1')
        selectedTestFiles=[string[]]@('alpha.Tests.ps1','beta.Tests.ps1','gamma.Tests.ps1')
        platforms=[object[]]@([pscustomobject][ordered]@{id='linux';display='Linux';runner='ubuntu-latest';asset='asset';sha256=('b' * 64);partitionCount=2})
        shards=[object[]]@(
            [pscustomobject][ordered]@{id='01';platform='linux';files=[string[]]@('alpha.Tests.ps1','beta.Tests.ps1');expectedSkippedTests=[string[]]@('beta.Tests.ps1::UnitT10_skip');weight=2},
            [pscustomobject][ordered]@{id='02';platform='linux';files=[string[]]@('gamma.Tests.ps1');expectedSkippedTests=[string[]]@();weight=1}
        )
    }
    $canonical = $plan | ConvertTo-Json -Depth 12 -Compress
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $planSha = ([BitConverter]::ToString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($canonical)))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    [IO.Directory]::CreateDirectory((Join-Path $Root 'plan')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root 'plan/plan.json'), $canonical + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'plan/plan.sha256'), $planSha + "`n", [Text.UTF8Encoding]::new($false))

    $shardSpecs = @(
        [pscustomobject]@{ Id='01'; Attempt=$Shard01Attempt; Files=@('alpha.Tests.ps1','beta.Tests.ps1') },
        [pscustomobject]@{ Id='02'; Attempt=$Shard02Attempt; Files=@('gamma.Tests.ps1') }
    )
    foreach ($spec in $shardSpecs) {
        $shardRoot = Join-Path $Root "shards/artifact-$($spec.Id)"
        $fileRows = [Collections.Generic.List[object]]::new()
        for ($index=0; $index -lt $spec.Files.Count; $index++) {
            $file = $spec.Files[$index]
            $skips = if ($file -ceq 'beta.Tests.ps1') { [string[]]@('beta.Tests.ps1::UnitT10_skip') } else { [string[]]@() }
            $counts = if ($file -ceq 'beta.Tests.ps1') {
                [pscustomobject][ordered]@{total=3;passed=2;failed=0;skipped=1;pending=0;inconclusive=0}
            } else { [pscustomobject][ordered]@{total=2;passed=2;failed=0;skipped=0;pending=0;inconclusive=0} }
            $summary = [pscustomobject][ordered]@{
                schemaVersion=2;platform='linux';shard=$spec.Id;planSha256=$planSha;file=$file
                runId='run-574';runAttempt=$spec.Attempt;status='passed';executorOutcome='success'
                counts=$counts;expectedSkippedTests=$skips;skippedTests=$skips;failedTests=[string[]]@()
            }
            $fileRoot = Join-Path $shardRoot ('files/{0:D2}' -f ($index + 1))
            Write-UnixAggregateTestJson -Path (Join-Path $fileRoot 'summary.json') -Value $summary
            $fileRows.Add([pscustomobject][ordered]@{index=$index+1;file=$file;status='passed';passed=$counts.passed;failed=0;skipped=$counts.skipped})
        }
        $shardSummary = [pscustomobject][ordered]@{
            schemaVersion=2;platform='linux';shard=$spec.Id;planSha256=$planSha;runId='run-574'
            runAttempt=$spec.Attempt;status='passed';files=[object[]]$fileRows.ToArray()
        }
        Write-UnixAggregateTestJson -Path (Join-Path $shardRoot 'shard-summary.json') -Value $shardSummary
    }

    $authorityPath = Join-Path $Root 'authority/artifact/authority-result.json'
    Write-UnixAggregateTestJson -Path $authorityPath -Value ([pscustomobject][ordered]@{schemaVersion=1;status='passed';executed=$true})
    $authoritySha = (Get-FileHash -LiteralPath $authorityPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-UnixAggregateTestJson -Path (Join-Path $Root 'authority/artifact/authority-identity.json') -Value `
        ([pscustomobject][ordered]@{schemaVersion=1;runId='run-574';runAttempt=$AuthorityAttempt;authoritySha256=$authoritySha})
    return [pscustomobject]@{ Root=$Root; PlanSha=$planSha; PlanAttempt=$PlanAttempt }
}

function Invoke-UnixAggregateTest {
    param($Fixture, [int] $CurrentAttempt, [int] $ExpectedPlanAttempt=$Fixture.PlanAttempt, [string] $PesterResult='success')
    Invoke-UnixCoreAggregateAssertion -Root $Fixture.Root -PlatformId linux -PlanSha256 $Fixture.PlanSha `
        -PlanRunAttempt $ExpectedPlanAttempt -PlanJobResult success -AuthorityJobResult success -PesterJobResult $PesterResult `
        -WorkflowRunId 'run-574' -WorkflowRunAttempt $CurrentAttempt -SummaryPath (Join-Path $Fixture.Root 'step-summary.md')
}

function Read-UnixAggregateTestJson { param([string]$Path) Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json }
function Set-UnixAggregateTestJson { param([string]$Path, $Value) Write-UnixAggregateTestJson -Path $Path -Value $Value }

Describe 'Assert-UnixCoreAggregate' {
    It 'UnitT01_accepts_complete_attempt_one_evidence_and_reports_counts' {
        $fixture = New-UnixAggregateTestTree -Root (Join-Path $TestDrive 'UnitT01')
        Invoke-UnixAggregateTest -Fixture $fixture -CurrentAttempt 1 | Out-Null
        $result = Read-UnixAggregateTestJson (Join-Path $fixture.Root 'aggregate-result.json')
        $result.status | Should Be 'passed'
        $result.shardCount | Should Be 2
        $result.fileCount | Should Be 3
        $result.passed | Should Be 6
        $result.failed | Should Be 0
        $result.skipped | Should Be 1
    }

    It 'UnitT02_accepts_reused_successful_evidence_when_only_failed_jobs_are_rerun' {
        $fixture = New-UnixAggregateTestTree -Root (Join-Path $TestDrive 'UnitT02') -Shard02Attempt 2
        Invoke-UnixAggregateTest -Fixture $fixture -CurrentAttempt 2 | Out-Null
        $result = Read-UnixAggregateTestJson (Join-Path $fixture.Root 'aggregate-result.json')
        $result.status | Should Be 'passed'
        $result.planRunAttempt | Should Be 1
        $result.runAttempt | Should Be 2
    }

    # Scenario: the plan job fails before producing plan outputs. Purpose: preserve aggregate failure evidence for the workflow upload step.
    It 'UnitT04_writes_failed_result_when_plan_job_fails_without_plan_outputs' {
        $fixture = New-UnixAggregateTestTree -Root (Join-Path $TestDrive 'UnitT04')
        $caught = $null
        try {
            & $script:AggregateScript -AggregateRoot $fixture.Root -Platform linux -ExpectedPlanSha256 '' `
                -ExpectedPlanRunAttempt 0 -PlanResult failure -AuthorityResult success -PesterResult success `
                -RunId 'run-574' -CurrentRunAttempt 1 -StepSummaryPath ''
        }
        catch { $caught = $_ }
        $caught | Should Not BeNullOrEmpty
        $caught.Exception.Message | Should Match "upstream 'plan' result must be success"
        $failure = Read-UnixAggregateTestJson (Join-Path $fixture.Root 'aggregate-result.json')
        $failure.status | Should Be 'failed'
        $failure.error | Should Match "upstream 'plan' result must be success"
    }

    # Scenario: all upstream jobs pass but the plan SHA output is empty. Purpose: record an invalid plan-output failure rather than failing parameter binding.
    It 'UnitT05_writes_failed_result_when_successful_plan_job_has_empty_sha' {
        $fixture = New-UnixAggregateTestTree -Root (Join-Path $TestDrive 'UnitT05')
        $caught = $null
        try {
            & $script:AggregateScript -AggregateRoot $fixture.Root -Platform linux -ExpectedPlanSha256 '' `
                -ExpectedPlanRunAttempt $fixture.PlanAttempt -PlanResult success -AuthorityResult success -PesterResult success `
                -RunId 'run-574' -CurrentRunAttempt 1 -StepSummaryPath ''
        }
        catch { $caught = $_ }
        $caught | Should Not BeNullOrEmpty
        $caught.Exception.Message | Should Match "expected plan SHA-256 '' must be 64 lowercase hexadecimal characters"
        $failure = Read-UnixAggregateTestJson (Join-Path $fixture.Root 'aggregate-result.json')
        $failure.status | Should Be 'failed'
        $failure.error | Should Match "expected plan SHA-256 '' must be 64 lowercase hexadecimal characters"
    }

    It 'UnitT03_rejects_invalid_evidence_<Case>' -TestCases @(
        @{Case='plan_hash_mismatch'; Message='plan SHA-256 evidence differs'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) Set-Content -NoNewline -Encoding UTF8 (Join-Path $f.Root 'plan/plan.sha256') ('f' * 64)}},
        @{Case='plan_attempt_mismatch'; Message='runAttempt must equal expected plan attempt'; PlanAttempt=1; Current=2; Expected=2; Pester='success'; Mutate={param($f)}},
        @{Case='stale_shard_plan'; Message='Shard summary.*identity and status'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-01/shard-summary.json';$j=Read-UnixAggregateTestJson $p;$j.planSha256='f'*64;Set-UnixAggregateTestJson $p $j}},
        @{Case='attempt_above_current'; Message='Shard summary.*runAttempt must be an integer'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-02/shard-summary.json';$j=Read-UnixAggregateTestJson $p;$j.runAttempt=2;Set-UnixAggregateTestJson $p $j}},
        @{Case='attempt_below_plan'; Message='Shard summary.*runAttempt must be an integer'; PlanAttempt=2; Current=2; Expected=2; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-01/shard-summary.json';$j=Read-UnixAggregateTestJson $p;$j.runAttempt=1;Set-UnixAggregateTestJson $p $j}},
        @{Case='missing_file'; Message="Missing per-file summary.json for planned file 'gamma.Tests.ps1'"; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) Remove-Item -LiteralPath (Join-Path $f.Root 'shards/artifact-02/files/01/summary.json')}},
        @{Case='duplicate_file'; Message='is unexpected or duplicates file'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $src=Join-Path $f.Root 'shards/artifact-01/files/01/summary.json';$dst=Join-Path $f.Root 'shards/artifact-02/files/01/summary.json';Copy-Item -LiteralPath $src -Destination $dst -Force}},
        @{Case='file_attempt_differs'; Message='runAttempt differs from shard summary'; PlanAttempt=1; Current=2; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-01/files/01/summary.json';$j=Read-UnixAggregateTestJson $p;$j.runAttempt=2;Set-UnixAggregateTestJson $p $j}},
        @{Case='failed_file_status'; Message='Per-file summary.*identity and status'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-01/files/01/summary.json';$j=Read-UnixAggregateTestJson $p;$j.status='failed';Set-UnixAggregateTestJson $p $j}},
        @{Case='skip_mismatch'; Message='skip evidence differs'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-01/files/02/summary.json';$j=Read-UnixAggregateTestJson $p;$j.skippedTests=@();Set-UnixAggregateTestJson $p $j}},
        @{Case='shard_file_list'; Message='file list differs from planned shard'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'shards/artifact-01/shard-summary.json';$j=Read-UnixAggregateTestJson $p;$j.files[0].file='gamma.Tests.ps1';Set-UnixAggregateTestJson $p $j}},
        @{Case='missing_shard'; Message="Missing shard-summary.json for planned shard '02'"; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) Remove-Item -LiteralPath (Join-Path $f.Root 'shards/artifact-02/shard-summary.json')}},
        @{Case='upstream_pester_failure'; Message="upstream 'pester' result must be success"; PlanAttempt=1; Current=1; Expected=1; Pester='failure'; Mutate={param($f)}},
        @{Case='authority_attempt_out_of_range'; Message='Authority identity.*runAttempt must be an integer'; PlanAttempt=1; Current=1; Expected=1; Pester='success'; Mutate={param($f) $p=Join-Path $f.Root 'authority/artifact/authority-identity.json';$j=Read-UnixAggregateTestJson $p;$j.runAttempt=2;Set-UnixAggregateTestJson $p $j}}
    ) {
        param($Case,$Message,$PlanAttempt,$Current,$Expected,$Pester,$Mutate)
        $fixture = New-UnixAggregateTestTree -Root (Join-Path $TestDrive "UnitT03_$Case") -PlanAttempt $PlanAttempt
        & $Mutate $fixture
        $caught = $null
        try { Invoke-UnixAggregateTest -Fixture $fixture -CurrentAttempt $Current -ExpectedPlanAttempt $Expected -PesterResult $Pester | Out-Null }
        catch { $caught = $_ }
        $caught | Should Not BeNullOrEmpty
        $caught.Exception.Message | Should Match $Message
        $failure = Read-UnixAggregateTestJson (Join-Path $fixture.Root 'aggregate-result.json')
        $failure.status | Should Be 'failed'
        $failure.error | Should Match $Message
    }
}
