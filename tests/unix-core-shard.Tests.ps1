$script:UnixCoreRepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:UnixCoreRunnerPath = Join-Path $script:UnixCoreRepositoryRoot 'scripts/Invoke-UnixCoreShard.ps1'
$script:UnixCorePlanHash = 'a' * 64

function Set-UnixCoreTestText {
    param([string] $Path, [string] $Value)

    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-UnixCoreBase64 {
    param([AllowEmptyCollection()][string[]] $Values)

    $json = ConvertTo-Json -InputObject ([string[]]$Values) -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function New-UnixCoreStubFixture {
    param(
        [string] $Root,
        [string[]] $Files,
        [hashtable] $Map
    )

    $testRoot = Join-Path $Root 'tests'
    foreach ($file in $Files) {
        Set-UnixCoreTestText (Join-Path $testRoot $file) "Describe '$file' { It 'UnitT99_fixture' { `$true | Should Be `$true } }`n"
    }
    Set-UnixCoreTestText (Join-Path $Root 'fixture-map.json') ($Map | ConvertTo-Json -Depth 8)
    $stub = @'
[CmdletBinding()]
param(
    [string] $PesterModulePath,
    [string] $PesterVersion,
    [int] $ExpectedSkippedCount,
    [string[]] $ExpectedSkippedTests,
    [string[]] $IsolatedTestFileNames,
    [int] $BulkShardSize,
    [int] $ShardPartitionCount,
    [int] $ShardPartitionIndex,
    [int] $OuterTimeoutSeconds,
    [string] $TestRoot,
    [string] $EvidenceRoot,
    [string[]] $SelectedTestFileNames,
    [string] $SummaryOutputPath,
    [int] $SummarySchemaVersion,
    [string] $SummaryRunId,
    [int] $SummaryRunAttempt,
    [string] $IsolationRequirement
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$file = [string]$SelectedTestFileNames[0]
[IO.File]::WriteAllText((Join-Path $root 'working-directory.json'), ([ordered]@{
    location = (Get-Location).ProviderPath
    currentDirectory = [Environment]::CurrentDirectory
} | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
[IO.File]::AppendAllText((Join-Path $root 'calls.txt'), $file + "`n", [Text.UTF8Encoding]::new($false))
$map = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'fixture-map.json') | ConvertFrom-Json
$entry = $map.PSObject.Properties[$file].Value
if (-not [bool]$entry.missingResult) {
    [IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
    $safeName = $file -replace '[^A-Za-z0-9_.-]', '-'
    $resultPath = Join-Path $EvidenceRoot "pester-shard-$safeName-x.json"
    $cases = [object[]]@($entry.cases)
    $failed = @($cases | Where-Object result -notin @('Passed','Skipped')).Count
    $skipped = @($cases | Where-Object result -ceq 'Skipped').Count
    $passed = @($cases | Where-Object result -ceq 'Passed').Count
    $summary = [ordered]@{
        status = $(if ([string]::IsNullOrWhiteSpace([string]$entry.status)) { 'completed' } else { [string]$entry.status })
        TotalCount = $cases.Count; PassedCount = $passed; FailedCount = $failed; SkippedCount = $skipped
        PendingCount = 0; InconclusiveCount = 0; failurePhase = [string]$entry.failurePhase
    }
    [IO.File]::WriteAllText($resultPath, ($summary | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(($resultPath + '.cases.json'), ([ordered]@{ cases=$cases } | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
}
if ([bool]$entry.throwExecutor) { throw "stub executor failure for $file" }
'@
    $executorPath = Join-Path $Root 'stub-executor.ps1'
    Set-UnixCoreTestText $executorPath $stub
    return [pscustomobject]@{ TestRoot=$testRoot; ExecutorPath=$executorPath; CallsPath=(Join-Path $Root 'calls.txt') }
}

function Invoke-UnixCoreFixture {
    param(
        [string] $FixtureRoot,
        [string[]] $Files,
        [string[]] $Skips = @(),
        [string] $ExecutorPath,
        [string] $TestRoot,
        [string] $PesterModulePath = 'unused/Pester.psd1',
        [string] $StepSummaryPath = ''
    )

    $outputRoot = Join-Path $FixtureRoot 'output'
    $arguments = @{
        PlatformId='linux'; ShardId='07'; FilesBase64=(ConvertTo-UnixCoreBase64 $Files)
        SkipsBase64=(ConvertTo-UnixCoreBase64 $Skips); PlanSha256=$script:UnixCorePlanHash
        PesterModulePath=$PesterModulePath; OutputRoot=$outputRoot; RunId='12345'; RunAttempt=2
        RepositoryRoot=$script:UnixCoreRepositoryRoot; TestRoot=$TestRoot; ExecutorPath=$ExecutorPath
        OuterTimeoutSeconds=300; StepSummaryPath=$StepSummaryPath
    }
    $records = [Collections.Generic.List[object]]::new()
    $hostRecords = [Collections.Generic.List[object]]::new()
    $caught = $null
    try {
        @(& $script:UnixCoreRunnerPath @arguments -InformationVariable +hostRecords 4>&1 3>&1 2>&1) |
            ForEach-Object { $records.Add($_) }
    }
    catch {
        $caught = $_
        $records.Add($_)
    }
    foreach ($record in $hostRecords) {
        if ($records -notcontains $record) { $records.Add($record) }
    }
    return [pscustomobject]@{ OutputRoot=$outputRoot; Records=$records.ToArray(); Error=$caught }
}

Describe 'Unix Core fixed-shard runner' {
    # Scenario: The middle file fails while the files on both sides pass.
    # Purpose: Preserve execution order, evidence publication, annotations, and failure aggregation without fail-fast behavior.
    It 'UnitT01_runs_all_files_and_reports_only_the_middle_failure' {
        $root = Join-Path $TestDrive 'UnitT01_middle-failure'
        $files = @('alpha.Tests.ps1','beta.Tests.ps1','gamma.Tests.ps1')
        $map = @{
            'alpha.Tests.ps1'=@{ cases=@(@{name='alpha passes';result='Passed'}) }
            'beta.Tests.ps1'=@{ cases=@(@{name='beta fails';result='Failed'}); throwExecutor=$true }
            'gamma.Tests.ps1'=@{ cases=@(@{name='gamma passes';result='Passed'}) }
        }
        $fixture = New-UnixCoreStubFixture $root $files $map
        $stepSummary = Join-Path $root 'step-summary.md'
        $run = Invoke-UnixCoreFixture $root $files -ExecutorPath $fixture.ExecutorPath -TestRoot $fixture.TestRoot -StepSummaryPath $stepSummary

        $run.Error | Should Not BeNullOrEmpty
        $run.Error.Exception.Message | Should Be 'Unix Core linux shard 07 failed: beta.Tests.ps1'
        ((Get-Content -Encoding UTF8 $fixture.CallsPath) -join ',') | Should Be ($files -join ',')
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/01/summary.json') | ConvertFrom-Json).status | Should Be 'passed'
        $middle = Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/02/summary.json') | ConvertFrom-Json
        $middle.status | Should Be 'failed'
        @($middle.failedTests) | Should Be @('beta fails')
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/03/summary.json') | ConvertFrom-Json).status | Should Be 'passed'
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'shard-summary.json') | ConvertFrom-Json).status | Should Be 'failed'
        $markdown = Get-Content -Raw -Encoding UTF8 $stepSummary
        $markdown | Should Match '\| # \| File \| Status \| Passed \| Failed \| Skipped \| Failing tests \|'
        $markdown | Should Match '\*\*Failed files:\*\* beta\.Tests\.ps1'
        $annotations = @($run.Records | ForEach-Object { [string]$_ } | Where-Object { $_ -like '::error title=*' })
        $annotations.Count | Should Be 1
        $annotations[0] | Should Match '::error title=Unix Core linux shard 07::beta\.Tests\.ps1 failed:'
    }

    # Scenario: Every file in a shard passes.
    # Purpose: Emit complete per-file identity fields and a passing aggregate without throwing.
    It 'UnitT02_writes_passing_shard_and_bound_identity_fields' {
        $root = Join-Path $TestDrive 'UnitT02_all-pass'
        $files = @('one.Tests.ps1','two.Tests.ps1')
        $map = @{
            'one.Tests.ps1'=@{ cases=@(@{name='one';result='Passed'}) }
            'two.Tests.ps1'=@{ cases=@(@{name='two';result='Passed'}) }
        }
        $fixture = New-UnixCoreStubFixture $root $files $map
        $run = Invoke-UnixCoreFixture $root $files -ExecutorPath $fixture.ExecutorPath -TestRoot $fixture.TestRoot

        $run.Error | Should BeNullOrEmpty
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'shard-summary.json') | ConvertFrom-Json).status | Should Be 'passed'
        foreach ($index in @('01','02')) {
            $summary = Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot "files/$index/summary.json") | ConvertFrom-Json
            $summary.planSha256 | Should Be $script:UnixCorePlanHash
            $summary.shard | Should Be '07'
            $summary.runAttempt | Should Be 2
        }
    }

    # Scenario: One declared skip occurs and another declared skip does not occur.
    # Purpose: Require an exact per-file skip inventory while retaining the valid skipped file as passed.
    It 'UnitT03_enforces_the_expected_skip_inventory_per_file' {
        $root = Join-Path $TestDrive 'UnitT03_skips'
        $files = @('occurs.Tests.ps1','missing.Tests.ps1')
        $map = @{
            'occurs.Tests.ps1'=@{ cases=@(@{name='reviewed skip';result='Skipped'}) }
            'missing.Tests.ps1'=@{ cases=@(@{name='ordinary pass';result='Passed'}) }
        }
        $fixture = New-UnixCoreStubFixture $root $files $map
        $skips = @('occurs.Tests.ps1::reviewed skip','missing.Tests.ps1::reviewed skip')
        $run = Invoke-UnixCoreFixture $root $files $skips $fixture.ExecutorPath $fixture.TestRoot

        $run.Error.Exception.Message | Should Be 'Unix Core linux shard 07 failed: missing.Tests.ps1'
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/01/summary.json') | ConvertFrom-Json).status | Should Be 'passed'
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/02/summary.json') | ConvertFrom-Json).status | Should Be 'failed'
    }

    # Scenario: A successful executor invocation omits its Pester result file.
    # Purpose: Convert missing evidence into a runner failure and continue with later files.
    It 'UnitT04_records_missing_result_evidence_and_continues' {
        $root = Join-Path $TestDrive 'UnitT04_missing-result'
        $files = @('missing.Tests.ps1','later.Tests.ps1')
        $map = @{
            'missing.Tests.ps1'=@{ missingResult=$true; cases=@() }
            'later.Tests.ps1'=@{ cases=@(@{name='later passes';result='Passed'}) }
        }
        $fixture = New-UnixCoreStubFixture $root $files $map
        $run = Invoke-UnixCoreFixture $root $files -ExecutorPath $fixture.ExecutorPath -TestRoot $fixture.TestRoot

        $missing = Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/01/summary.json') | ConvertFrom-Json
        $missing.status | Should Be 'failed'
        @($missing.failedTests) | Should Be @('[runner failure] expected exactly one Pester child result; found 0')
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/02/summary.json') | ConvertFrom-Json).status | Should Be 'passed'
        ((Get-Content -Encoding UTF8 $fixture.CallsPath) -join ',') | Should Be ($files -join ',')
    }

    # Scenario: A matrix payload violates one of the shard trust-boundary checks.
    # Purpose: Reject malformed selection before any executor process is started.
    It 'UnitT05_rejects_invalid_payload_<Case>' -TestCases @(
        @{ Case='empty'; Mutation='empty' },
        @{ Case='duplicate'; Mutation='duplicate' },
        @{ Case='unsafe'; Mutation='unsafe' },
        @{ Case='unknown'; Mutation='unknown' },
        @{ Case='authority'; Mutation='authority' },
        @{ Case='outside-skip'; Mutation='outside-skip' },
        @{ Case='base64'; Mutation='base64' }
    ) {
        param($Case,$Mutation)
        $root = Join-Path $TestDrive "UnitT05_$Case"
        $files = @('valid.Tests.ps1')
        $map = @{ 'valid.Tests.ps1'=@{ cases=@(@{name='valid';result='Passed'}) } }
        $fixture = New-UnixCoreStubFixture $root $files $map
        $selected = [string[]]@('valid.Tests.ps1')
        $skips = [string[]]@()
        switch ($Mutation) {
            'empty' { $selected = [string[]]@() }
            'duplicate' { $selected = [string[]]@('valid.Tests.ps1','valid.Tests.ps1') }
            'unsafe' { $selected = [string[]]@('../x.Tests.ps1') }
            'unknown' { $selected = [string[]]@('unknown.Tests.ps1') }
            'authority' {
                . (Join-Path $script:UnixCoreRepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1') -DefineFunctionsOnly
                $authorityName = [IO.Path]::GetFileName([string]@(Get-AuthorityTestPaths -Root $script:UnixCoreRepositoryRoot)[0])
                Set-UnixCoreTestText (Join-Path $fixture.TestRoot $authorityName) "Describe 'authority' { It 'UnitT99_fixture' { `$true | Should Be `$true } }"
                $selected = [string[]]@($authorityName)
            }
            'outside-skip' { $skips = [string[]]@('other.Tests.ps1::reviewed skip') }
        }
        $outputRoot = Join-Path $root 'output'
        $arguments = @{
            PlatformId='linux'; ShardId='07'; FilesBase64=(ConvertTo-UnixCoreBase64 $selected)
            SkipsBase64=(ConvertTo-UnixCoreBase64 $skips); PlanSha256=$script:UnixCorePlanHash
            PesterModulePath='unused'; OutputRoot=$outputRoot; RunId='12345'; RunAttempt=1
            RepositoryRoot=$script:UnixCoreRepositoryRoot; TestRoot=$fixture.TestRoot; ExecutorPath=$fixture.ExecutorPath
            StepSummaryPath=''
        }
        if ($Mutation -ceq 'base64') { $arguments.FilesBase64 = 'not base64!' }
        { & $script:UnixCoreRunnerPath @arguments } | Should Throw 'The Unix Core shard payload is invalid:'
        Test-Path -LiteralPath $fixture.CallsPath | Should Be $false
    }

    # Scenario: The real bounded executor receives two tiny fixture files through one shard runner invocation.
    # Purpose: Prove the fresh-supervisor loop executes both files and retains independent per-file evidence after one fails.
    It 'UnitT06_runs_two_files_through_the_real_executor' {
        $root = Join-Path $TestDrive 'UnitT06_real-executor'
        $testRoot = Join-Path $root 'tests'
        Set-UnixCoreTestText (Join-Path $testRoot 'real-pass.Tests.ps1') "Describe 'pass' { It 'UnitT01_passes' { `$true | Should Be `$true } }`n"
        Set-UnixCoreTestText (Join-Path $testRoot 'real-fail.Tests.ps1') "Describe 'fail' { It 'UnitT01_fails' { `$true | Should Be `$false } }`n"
        $pester = @(Get-Module Pester | Where-Object Version -EQ ([version]'4.10.1'))[0]
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $files = @('real-pass.Tests.ps1','real-fail.Tests.ps1')
        $run = Invoke-UnixCoreFixture $root $files -ExecutorPath (Join-Path $script:UnixCoreRepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1') `
            -TestRoot $testRoot -PesterModulePath $pesterManifest

        $run.Error.Exception.Message | Should Be 'Unix Core linux shard 07 failed: real-fail.Tests.ps1'
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/01/summary.json') | ConvertFrom-Json).status | Should Be 'passed'
        (Get-Content -Raw -Encoding UTF8 (Join-Path $run.OutputRoot 'files/02/summary.json') | ConvertFrom-Json).status | Should Be 'failed'
        foreach ($index in @('01','02')) {
            $results = @(Get-ChildItem -LiteralPath (Join-Path $run.OutputRoot "files/$index/evidence") -Filter 'pester-shard-*.json' -File |
                Where-Object { $_.Name -notlike '*.process.json' -and $_.Name -notlike '*.cases.json' })
            $results.Count | Should Be 1
        }
    }

    # Scenario: The shard runner is launched after changing PowerShell location and receives a relative test root.
    # Purpose: Keep the fresh child process rooted at the caller location so relative executor paths resolve consistently.
    It 'UnitT07_starts_the_executor_in_the_callers_working_directory' {
        $root = Join-Path $TestDrive 'UnitT07_working-directory'
        $files = @('relative.Tests.ps1')
        $map = @{ 'relative.Tests.ps1'=@{ cases=@(@{name='relative';result='Passed'}) } }
        $fixture = New-UnixCoreStubFixture $root $files $map
        Push-Location $root
        try {
            $run = Invoke-UnixCoreFixture $root $files -ExecutorPath $fixture.ExecutorPath -TestRoot './tests'
        }
        finally { Pop-Location }

        $run.Error | Should BeNullOrEmpty
        $working = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'working-directory.json') | ConvertFrom-Json
        [IO.Path]::GetFullPath([string]$working.location) | Should Be ([IO.Path]::GetFullPath($root))
        [IO.Path]::GetFullPath([string]$working.currentDirectory) | Should Be ([IO.Path]::GetFullPath($root))
    }
}
