Describe 'Standard validation development harness contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:HarnessPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidationDevelopmentHarness.ps1'
        $script:PowerShellPath = $null
        foreach ($pwshCommand in @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($null -eq $pwshCommand -or [string]::IsNullOrWhiteSpace([string]$pwshCommand.Source)) { continue }
            $pwshItem = Get-Item -Force -LiteralPath ([string]$pwshCommand.Source) -ErrorAction SilentlyContinue
            if ($null -ne $pwshItem -and $pwshItem.PSIsContainer -eq $false -and
                ($pwshItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $script:PowerShellPath = [string]$pwshItem.FullName
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($script:PowerShellPath)) {
            $script:PowerShellPath = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                Join-Path $PSHOME 'powershell.exe'
            }
            else {
                Join-Path $PSHOME 'pwsh'
            }
        }

        function Assert-Ci1True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-Ci1False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
        }

        function Assert-Ci1Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) {
                throw "$Message Expected='$Expected' Actual='$Actual'."
            }
        }

        function Assert-Ci1Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) {
                throw "$Message Pattern='$Pattern'."
            }
        }

        function Write-Ci1Utf8File {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $Text
            )

            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and
                -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($fullPath, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-Ci1HarnessFixture {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [ValidateSet('pass', 'static-fail', 'mutate', 'timeout', 'exit-fail', 'barrier-tamper', 'cancel-after-start')]
                [string] $Behavior = 'pass'
            )

            $candidate = Join-Path $Root 'candidate'
            $tools = Join-Path $Root 'trusted-tools'
            $artifacts = Join-Path $Root 'artifacts'
            $adapterPath = Join-Path $Root 'adapter.json'
            $outputPath = Join-Path $artifacts 'ci1-evidence.json'
            $logPath = Join-Path $Root 'trusted-tool-events.log'
            [void](New-Item -ItemType Directory -Path (Join-Path $candidate 'skills/fixture') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $candidate 'scripts') -Force)
            [void](New-Item -ItemType Directory -Path $tools -Force)
            [void](New-Item -ItemType Directory -Path $artifacts -Force)

            Write-Ci1Utf8File -Path (Join-Path $candidate 'skills/fixture/SKILL.md') -Text @'
---
name: fixture
description: A harmless CI1 candidate fixture.
---

# Fixture
'@

            $candidateValidator = @'
param([string] $RepositoryRoot)

$fixtureBehavior = '__CI1_BEHAVIOR__'
$root = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [string]$env:STANDARD_VALIDATION_CANDIDATE_ROOT
}
else {
    $RepositoryRoot
}
if (-not (Test-Path -LiteralPath $root -PathType Container)) { exit 11 }
if ([string]$env:STANDARD_VALIDATION_DEVELOPMENT_ONLY -cne 'true') { exit 12 }
if ([string]$env:STANDARD_VALIDATION_RELEASE_ELIGIBLE -cne 'false') { exit 13 }
if (-not [string]::IsNullOrWhiteSpace([string]$env:SYP154_INHERITED_SECRET) -or
    -not [string]::IsNullOrWhiteSpace([string]$env:STANDARD_VALIDATION_INHERITED_SECRET)) {
    exit 14
}
Write-Output ("candidate-validator-executed|candidateId={0}" -f $env:STANDARD_VALIDATION_CANDIDATE_ID)
if ($fixtureBehavior -eq 'mutate') {
    Add-Content -LiteralPath (Join-Path $root 'skills/fixture/SKILL.md') -Value 'mutated-by-candidate' -Encoding UTF8
}
if ($fixtureBehavior -eq 'barrier-tamper') {
    $runRoot = Split-Path -Parent $root
    $nestedBarrierArtifact = @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'std') -Recurse -File -Force |
        Where-Object { $_.FullName -ne (Join-Path $runRoot 'std/evidence.json') } |
        Select-Object -First 1)[0]
    if ($null -eq $nestedBarrierArtifact) { exit 15 }
    Add-Content -LiteralPath $nestedBarrierArtifact.FullName -Value 'tampered-by-candidate' -Encoding UTF8
}
if ($fixtureBehavior -eq 'cancel-after-start') {
    # This is a harmless candidate-owned start signal. The trusted test driver
    # watches it and creates the private cancellation marker after process
    # start; candidate code never receives the cancellation path. It is written
    # in the owned working directory rather than the immutable candidate
    # snapshot so the signal cannot itself create snapshot drift.
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'candidate-started.signal'), 'started')
    Start-Sleep -Seconds 10
}
if ($fixtureBehavior -eq 'timeout') {
    Start-Sleep -Seconds 10
}
if ($fixtureBehavior -eq 'exit-fail') {
    Write-Error 'candidate fixture requested a nonzero result'
    exit 17
}
exit 0
'@
            $candidateValidator = $candidateValidator.Replace('__CI1_BEHAVIOR__', $Behavior)
            Write-Ci1Utf8File -Path (Join-Path $candidate 'scripts/Validate.ps1') -Text $candidateValidator

            $toolScript = @'
$fixtureBehavior = '__CI1_BEHAVIOR__'
$logPath = '__CI1_LOG_PATH__'
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    Add-Content -LiteralPath $logPath -Value (
        "{0}|{1}|{2}" -f
        $env:STANDARD_VALIDATION_STAGE_ID,
        $env:STANDARD_VALIDATION_TOOL_ID,
        $env:STANDARD_VALIDATION_SKILL_ID
    ) -Encoding UTF8
}
$skills = @()
if (-not [string]::IsNullOrWhiteSpace($env:STANDARD_VALIDATION_ACTIVE_SKILLS)) {
    $skills = @($env:STANDARD_VALIDATION_ACTIVE_SKILLS -split ';' | Where-Object { $_ })
}
$result = [ordered]@{
    schemaVersion = 1
    status = 'passed'
    decision = 'PASS'
    candidateIdentity = $env:STANDARD_VALIDATION_CANDIDATE_ID
    skillId = $env:STANDARD_VALIDATION_SKILL_ID
    activeSkills = $skills
    skillInventorySha256 = $env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256
    output = "ci1-fixture-$($env:STANDARD_VALIDATION_TOOL_ID)"
}
if ($fixtureBehavior -eq 'static-fail' -and
    $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.scannerIdentity = 'ci1-fixture-static-analyzer'
    $result.analyzerCompleteness = 'complete'
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'repository-tests') {
    $result.testInventory = @('ci1-fixture-repository-test')
    $result.testResult = [ordered]@{ status = 'passed'; decision = 'PASS' }
    $result.domainAdapterResult = [ordered]@{ status = 'passed'; decision = 'PASS' }
}
$result | ConvertTo-Json -Depth 10 -Compress
'@
            $toolScript = $toolScript.Replace('__CI1_BEHAVIOR__', $Behavior)
            $toolScript = $toolScript.Replace('__CI1_LOG_PATH__', $logPath.Replace("'", "''"))
            $toolScriptPath = Join-Path $tools 'ci1-fixture-tool.ps1'
            Write-Ci1Utf8File -Path $toolScriptPath -Text $toolScript

            $toolSpec = [ordered]@{
                command = $script:PowerShellPath
                arguments = @('-NoProfile', '-File', $toolScriptPath)
            }
            $adapter = [ordered]@{
                schemaVersion = 1
                adapter = 'standard-validation-adapter-v1'
                mode = 'development-harness'
                skillsRoot = 'skills'
                activeSkills = @('fixture')
                canonicalValidatorPath = 'scripts/Validate.ps1'
                packageAdapter = $toolSpec
                skillValidator = $toolSpec
                skillTools = $toolSpec
                staticAnalyzer = $toolSpec
                repositoryTests = @(
                    [ordered]@{
                        id = 'ci1-fixture-repository-test'
                        command = $script:PowerShellPath
                        arguments = @('-NoProfile', '-File', $toolScriptPath)
                    }
                )
            }
            Write-Ci1Utf8File -Path $adapterPath -Text ($adapter | ConvertTo-Json -Depth 20)

            return [pscustomobject][ordered]@{
                Root = $Root
                Candidate = $candidate
                Adapter = $adapterPath
                TrustedTools = $tools
                Artifacts = $artifacts
                Output = $outputPath
                Log = $logPath
                Behavior = $Behavior
            }
        }

        function Invoke-Ci1HarnessFixture {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [int] $TimeoutSeconds = 300,
                [int] $CandidateTimeoutSeconds = 0,
                [string] $CancellationPath,
                [AllowEmptyCollection()][string[]] $ValidatorArguments = @()
            )

            $arguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $script:HarnessPath,
                '-CandidateRoot', $Fixture.Candidate,
                '-AdapterPath', $Fixture.Adapter,
                '-TrustedToolRoot', $Fixture.TrustedTools,
                '-CandidateValidatorPath', 'scripts/Validate.ps1',
                '-ArtifactsRoot', $Fixture.Artifacts,
                '-OutputPath', $Fixture.Output,
                '-SourceRepository', 'https://example.com/ci1/fixture.git',
                '-SourceRevision', ('a' * 40),
                '-BaseRevision', ('b' * 40),
                '-EventName', 'local',
                '-TimeoutSeconds', [string]$TimeoutSeconds
            )
            if ($CandidateTimeoutSeconds -gt 0) {
                $arguments += @('-CandidateTimeoutSeconds', [string]$CandidateTimeoutSeconds)
            }
            if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
                $arguments += @('-CancellationPath', $CancellationPath)
            }
            if (@($ValidatorArguments).Count -gt 0) {
                $arguments += '-ValidatorArguments'
                $arguments += @($ValidatorArguments)
            }

            $environmentNames = @('SYP154_INHERITED_SECRET', 'STANDARD_VALIDATION_INHERITED_SECRET')
            $previousEnvironment = @{}
            foreach ($name in $environmentNames) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, "ci1-test-secret-$name", 'Process')
            }
            # Pester 6 runs this helper under StrictMode on Linux as well as
            # Windows. Initialize the optional async-process handle so every
            # early-return path can execute the finally cleanup safely.
            $process = $null
            try {
                if ([string]::IsNullOrWhiteSpace($CancellationPath)) {
                    $captured = & $script:PowerShellPath @arguments 2>&1 | Out-String
                    $exitCode = $LASTEXITCODE
                }
                else {
                    $stdoutPath = Join-Path $Fixture.Root 'harness.stdout.log'
                    $stderrPath = Join-Path $Fixture.Root 'harness.stderr.log'
                    $startParameters = @{
                        FilePath = $script:PowerShellPath
                        ArgumentList = $arguments
                        WorkingDirectory = $script:RepositoryRoot
                        RedirectStandardOutput = $stdoutPath
                        RedirectStandardError = $stderrPath
                        WindowStyle = 'Hidden'
                        PassThru = $true
                        ErrorAction = 'Stop'
                    }
                    $process = Start-Process @startParameters
                    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                    while (-not $process.HasExited) {
                        $startSignal = @(Get-ChildItem -LiteralPath $Fixture.Artifacts -Filter 'candidate-started.signal' -File -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
                        if ($null -ne $startSignal -and -not (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
                            Write-Ci1Utf8File -Path $CancellationPath -Text 'cancelled-by-trusted-test-driver'
                        }
                        if ([DateTime]::UtcNow -ge $deadline) {
                            try { if (-not $process.HasExited) { $process.Kill() } } catch { }
                            throw 'CI1 test driver timed out while waiting for the harness process.'
                        }
                        [void]$process.WaitForExit(100)
                    }
                    [void]$process.WaitForExit()
                    $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $stdoutPath } else { '' }
                    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -Raw -Encoding UTF8 -LiteralPath $stderrPath } else { '' }
                    $captured = "$stdout`n$stderr"
                    $exitCode = $process.ExitCode
                    $process.Dispose()
                    $process = $null
                }
            }
            finally {
                if ($null -ne $process) {
                    try { if (-not $process.HasExited) { $process.Kill() } } catch { }
                    try { $process.Dispose() } catch { }
                }
                foreach ($name in $environmentNames) {
                    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
                }
            }
            $evidence = $null
            if (Test-Path -LiteralPath $Fixture.Output -PathType Leaf) {
                try {
                    $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $Fixture.Output | ConvertFrom-Json
                }
                catch { }
            }
            return [pscustomobject][ordered]@{
                Output = [string]$captured
                ExitCode = [int]$exitCode
                Evidence = $evidence
            }
        }

        function New-Ci1CaseRoot {
            param([Parameter(Mandatory = $true)][string] $Name)
            # Keep the fixture root short enough for the central runner's
            # per-event child working directory on Windows.
            $root = Join-Path ([IO.Path]::GetTempPath()) ("c1-{0}-{1}" -f ([guid]::NewGuid().ToString('N').Substring(0, 12)), $Name)
            [void](New-Item -ItemType Directory -Path $root -Force)
            return $root
        }
    }

    BeforeEach {
        $script:Ci1CaseRoot = New-Ci1CaseRoot -Name 'c'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Ci1CaseRoot -PathType Container) {
            Remove-Item -LiteralPath $script:Ci1CaseRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'InterT01_executes_candidate_only_after_the_central_development_barrier' {
        $fixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 'p')
        $result = Invoke-Ci1HarnessFixture -Fixture $fixture -ValidatorArguments @('__CANDIDATE_ROOT__')

        Assert-Ci1Equal $result.ExitCode 0 'A passing CI1 development fixture must return zero.'
        Assert-Ci1Equal $result.Evidence.state 'PASS' 'The harness evidence must report PASS.'
        Assert-Ci1False ([bool]$result.Evidence.releaseEligible) 'Development evidence must never be release-eligible.'
        Assert-Ci1True ([bool]$result.Evidence.candidateExecutionAttempted) 'The candidate execution attempt must be recorded.'
        Assert-Ci1True ([bool]$result.Evidence.candidateCodeExecuted) 'The candidate validator must execute after the barrier.'
        Assert-Ci1Equal $result.Evidence.preCandidateBarrier.status 'passed' 'The independent barrier must pass before candidate execution.'
        $stageIds = @($result.Evidence.preCandidateBarrier.firstFiveStages | ForEach-Object { [string]$_.id })
        Assert-Ci1Equal ($stageIds -join ',') 'controlled-acquisition,integrity-verification,package-validation,skillspector-static,repository-tests' 'The first five barrier stages must remain canonical.'
        $stageOrders = @($result.Evidence.preCandidateBarrier.firstFiveStages | ForEach-Object { [int]$_.order })
        Assert-Ci1Equal ($stageOrders -join ',') '1,2,3,4,5' 'The barrier stage order must be canonical.'
        Assert-Ci1Match ([string]$result.Evidence.process.candidate.stdout) 'candidate-validator-executed' 'Candidate execution must leave bounded evidence.'
        Assert-Ci1False ([string]$result.Output -match 'ci1-test-secret|SYP154_INHERITED_SECRET|STANDARD_VALIDATION_INHERITED_SECRET') 'Inherited secrets must not cross either owned child boundary.'
        Assert-Ci1False ([bool]$result.Evidence.authority.candidateIsTrustRoot) 'The candidate must not be treated as the authority trust root.'
        $shardExecutorPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $shardExecutorSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardExecutorPath
        Assert-Ci1True (([regex]::Matches($shardExecutorSource, 'Get-PesterShardDescendantProcessIds -RootProcessId')).Count -ge 2) 'The shard executor must retain descendant identities while the child is alive.'
        Assert-Ci1False ($shardExecutorSource -match 'Remove-Item\s+-LiteralPath \$CancellationPath') 'The shard executor must not delete a caller-owned cancellation marker.'
        Assert-Ci1False ($shardExecutorSource -match '&\s+taskkill\.exe') 'The shard executor must not depend on taskkill for owned-process cleanup.'
        Assert-Ci1True ($shardExecutorSource -match 'System\.Diagnostics\.Process\.Kill|Stop-Process') 'The shard executor must use a direct process termination API.'
        Assert-Ci1True ($shardExecutorSource -match 'Get-PesterShardFailureSummary|failureSummary') 'A failed shard must retain a sanitized first-failure summary.'
        Assert-Ci1True ($shardExecutorSource -match 'CreateKillOnCloseJob|AssignProcessToJobObject') 'The shard executor must establish a kernel-owned Job Object before bootstrap release.'
        Assert-Ci1True ($shardExecutorSource -match 'PesterShardBoundedCapture|outputQuotaCharacters') 'The shard executor must bound redirected child output.'
        Assert-Ci1True (([regex]::Matches($shardExecutorSource, 'Get-PesterShardProcessIdentity')).Count -ge 2) 'Retained shard PIDs must be bound to immutable process identities.'
        $harnessSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidationDevelopmentHarness.ps1')
        Assert-Ci1True (([regex]::Matches($harnessSource, 'Assert-StandardValidationCandidateUnchanged')).Count -ge 2) 'The development harness must revalidate the source checkout before and after candidate execution.'
        Assert-Ci1False ($harnessSource -match 'STANDARD_VALIDATION_CI1_CANCELLATION_PATH\s*=') 'The candidate environment must not expose the trusted cancellation marker path.'
        Assert-Ci1True (-not [string]::IsNullOrWhiteSpace([string]$result.Evidence.preCandidateBarrier.artifactInventorySha256)) 'The barrier must retain a complete artifact inventory hash.'
        Assert-Ci1Equal $result.Evidence.preCandidateBarrier.artifactInventorySha256 $result.Evidence.preCandidateBarrier.artifactInventoryPostExecutionSha256 'The barrier artifact inventory must remain unchanged after candidate execution.'
        Assert-Ci1Equal $result.Evidence.recovery.status 'fail-closed' 'Recovery must remain fail-closed.'
    }

    It 'InterT02_stops_before_candidate_execution_when_the_central_barrier_fails' {
        $fixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 's') -Behavior 'static-fail'
        $result = Invoke-Ci1HarnessFixture -Fixture $fixture -ValidatorArguments @('__CANDIDATE_ROOT__')

        Assert-Ci1True ($result.ExitCode -ne 0) 'A failed static barrier must be nonzero.'
        Assert-Ci1Equal $result.Evidence.state 'FAILED' 'A failed static barrier must fail closed.'
        Assert-Ci1False ([bool]$result.Evidence.candidateCodeExecuted) 'Candidate code must not execute after a failed barrier.'
        Assert-Ci1False ([bool]$result.Evidence.candidateExecutionAttempted) 'Candidate execution must not be attempted after a failed barrier.'
        Assert-Ci1Equal $result.Evidence.preCandidateBarrier.status 'failed' 'An attempted failed barrier must retain its process status.'
        Assert-Ci1Match ([string]$result.Output) 'barrier|skillspector-static|failed' 'The failure must retain the barrier diagnosis.'
    }

    It 'InterT03_fails_closed_on_candidate_mutation_and_timeout' {
        $mutationFixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 'm') -Behavior 'mutate'
        $mutationResult = Invoke-Ci1HarnessFixture -Fixture $mutationFixture -ValidatorArguments @('__CANDIDATE_ROOT__')
        Assert-Ci1True ($mutationResult.ExitCode -ne 0) 'A mutated candidate snapshot must be nonzero.'
        Assert-Ci1Equal $mutationResult.Evidence.state 'FAILED' 'Candidate snapshot mutation must fail closed.'
        Assert-Ci1True ([bool]$mutationResult.Evidence.candidateCodeExecuted) 'Mutation must prove the candidate was actually attempted.'
        Assert-Ci1Match ([string]$mutationResult.Output) 'snapshot.*changed|snapshot.*drift' 'The mutation failure must identify snapshot drift.'

        $timeoutFixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 't') -Behavior 'timeout'
        $timeoutResult = Invoke-Ci1HarnessFixture -Fixture $timeoutFixture -TimeoutSeconds 300 -CandidateTimeoutSeconds 1 -ValidatorArguments @('__CANDIDATE_ROOT__')
        Assert-Ci1True ($timeoutResult.ExitCode -ne 0) 'A timed-out candidate validator must be nonzero.'
        Assert-Ci1Equal $timeoutResult.Evidence.state 'FAILED' 'A timed-out candidate validator must fail closed.'
        Assert-Ci1True ([bool]$timeoutResult.Evidence.candidateCodeExecuted) 'Timeout must prove the candidate process was started.'
        Assert-Ci1Equal $timeoutResult.Evidence.recovery.status 'fail-closed' 'Timeout recovery must remain fail-closed.'
        Assert-Ci1Match ([string]$timeoutResult.Output) 'timed out|timeout' 'The timeout diagnosis must be retained.'

        $tamperFixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 'b') -Behavior 'barrier-tamper'
        $tamperResult = Invoke-Ci1HarnessFixture -Fixture $tamperFixture -ValidatorArguments @('__CANDIDATE_ROOT__')
        Assert-Ci1True ($tamperResult.ExitCode -ne 0) 'A candidate that tampers with barrier artifacts must be nonzero.'
        Assert-Ci1Equal $tamperResult.Evidence.state 'FAILED' 'Barrier artifact tampering must fail closed.'
        Assert-Ci1True ([bool]$tamperResult.Evidence.candidateCodeExecuted) 'Barrier artifact tampering must prove candidate execution was attempted.'
        Assert-Ci1Equal $tamperResult.Evidence.candidateOutcome.status 'passed' 'Barrier tampering must preserve the candidate process outcome.'
        Assert-Ci1True ([bool]$tamperResult.Evidence.candidateOutcome.processStarted) 'Barrier tampering must preserve the candidate process-started indicator.'
        Assert-Ci1False ([bool]$tamperResult.Evidence.preCandidateBarrier.evidenceUnchangedAfterCandidate) 'Tampered barrier evidence must not be reported unchanged.'
        Assert-Ci1Match ([string]$tamperResult.Output) 'barrier artifacts changed|barrier evidence changed' 'The barrier artifact diagnosis must be retained.'

        $cancellationPath = Join-Path $script:Ci1CaseRoot 'x.signal'
        $cancelFixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 'x') -Behavior 'cancel-after-start'
        $cancelResult = Invoke-Ci1HarnessFixture -Fixture $cancelFixture -CancellationPath $cancellationPath -ValidatorArguments @('__CANDIDATE_ROOT__')
        Assert-Ci1Equal $cancelResult.Evidence.state 'CANCELLED' 'Cancellation after process start must remain a cancelled result.'
        Assert-Ci1True ([bool]$cancelResult.Evidence.candidateCodeExecuted) 'Cancellation after process start must conservatively report candidate execution.'
        Assert-Ci1True ([bool]$cancelResult.Evidence.process.candidate.processStarted) 'Cancellation after process start must expose the process-started indicator.'
    }

    It 'InterT04_rejects_unsafe_candidate_arguments_before_execution' {
        $fixture = New-Ci1HarnessFixture -Root (Join-Path $script:Ci1CaseRoot 'u')
        $result = Invoke-Ci1HarnessFixture -Fixture $fixture -ValidatorArguments @('..\outside')
        Assert-Ci1True ($result.ExitCode -ne 0) 'Unsafe candidate arguments must be nonzero.'
        Assert-Ci1Equal $result.Evidence.state 'INVALID' 'Unsafe candidate arguments must be invalid.'
        Assert-Ci1False ([bool]$result.Evidence.candidateCodeExecuted) 'Unsafe arguments must not execute candidate code.'
        Assert-Ci1False ([bool]$result.Evidence.candidateExecutionAttempted) 'Unsafe arguments must be rejected before candidate start.'
        Assert-Ci1Match ([string]$result.Output) 'arguments|traversal|parent-directory' 'The invalid argument diagnosis must be retained.'
    }
}
