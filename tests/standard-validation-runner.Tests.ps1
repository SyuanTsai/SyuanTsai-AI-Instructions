Describe 'Standard validation runner contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RunnerPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $script:PowerShellPath = if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Join-Path $PSHOME 'powershell.exe'
        }
        elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Join-Path $PSHOME 'pwsh.exe'
        }
        else {
            Join-Path $PSHOME 'pwsh'
        }
        $script:SemanticBridgeModulePath = Join-Path $script:RepositoryRoot 'scripts/StandardSemanticBridge.psm1'
        Import-Module $script:SemanticBridgeModulePath -Force

        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
        }

        function Assert-Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Write-TestUtf8File {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $Text
            )

            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($fullPath, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-RunnerFixture {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [string[]] $SkillIds = @('alpha', 'beta'),
                [ValidateSet('pass', 'static-fail', 'static-partial', 'package-fail', 'wrong-candidate', 'missing-output', 'timeout', 'snapshot-mutate', 'environment-leak', 'semantic-required', 'output-tamper', 'output-flood', 'output-near-quota', 'repository-missing-evidence', 'repository-zero-tests', 'repository-artifact-tamper')]
                [string] $Behavior = 'pass'
            )

            $candidate = Join-Path $Root 'candidate'
            $tools = Join-Path $Root 'trusted-tools'
            $artifacts = Join-Path $Root 'artifacts'
            $output = Join-Path $artifacts 'evidence.json'
            $log = Join-Path $Root 'tool-events.log'
            $sentinel = Join-Path $Root 'repository-test-ran.txt'
            [void](New-Item -ItemType Directory -Path $candidate -Force)
            [void](New-Item -ItemType Directory -Path $tools -Force)
            [void](New-Item -ItemType Directory -Path $artifacts -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $candidate 'skills') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $candidate 'scripts') -Force)
            Write-TestUtf8File -Path (Join-Path $candidate 'scripts/Invoke-StandardValidation.ps1') -Text '# canonical validation entry point fixture`n'
            foreach ($skillId in $SkillIds) {
                $skillRoot = Join-Path $candidate ("skills/$skillId")
                [void](New-Item -ItemType Directory -Path $skillRoot -Force)
                Write-TestUtf8File -Path (Join-Path $skillRoot 'SKILL.md') -Text "---`nname: $skillId`ndescription: A harmless test Skill.`n---`n`n# $skillId`n"
            }

            $toolScript = Join-Path $tools 'fixture-tool.ps1'
            $toolScriptText = @'
$fixtureBehavior = '__FIXTURE_BEHAVIOR__'
$logPath = '__FIXTURE_LOG_PATH__'
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    Add-Content -LiteralPath $logPath -Value ("{0}|{1}|{2}" -f $env:STANDARD_VALIDATION_STAGE_ID, $env:STANDARD_VALIDATION_TOOL_ID, $env:STANDARD_VALIDATION_SKILL_ID) -Encoding UTF8
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
    output = "fixture-$($env:STANDARD_VALIDATION_TOOL_ID)"
}
if ($fixtureBehavior -eq 'package-fail' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($fixtureBehavior -eq 'environment-leak' -and (
    -not [string]::IsNullOrWhiteSpace($env:SYP154_INHERITED_SECRET) -or
    -not [string]::IsNullOrWhiteSpace($env:STANDARD_VALIDATION_INHERITED_SECRET)
)) {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($fixtureBehavior -eq 'output-tamper' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    try {
        [IO.File]::WriteAllText($env:STANDARD_VALIDATION_OUTPUT_PATH, '{"attacker":true}', (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        $result.status = 'failed'
        $result.decision = 'BLOCK'
    }
}
if ($fixtureBehavior -eq 'wrong-candidate' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.candidateIdentity = ('0' * 64)
}
if ($fixtureBehavior -eq 'missing-output' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    exit 0
}
if ($fixtureBehavior -eq 'timeout' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    Start-Sleep -Seconds 10
}
if ($fixtureBehavior -eq 'output-flood' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    [Console]::Out.Write(('o' * 1100000))
    [Console]::Error.Write(('e' * 1100000))
}
if ($fixtureBehavior -eq 'output-near-quota' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $result.output = 'v' * 1045000
}
if ($fixtureBehavior -eq 'static-fail' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'failed'
    $result.decision = 'BLOCK'
}
if ($fixtureBehavior -eq 'static-partial' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.status = 'partial'
    $result.decision = 'BLOCK'
    $result.analyzerCompleteness = 'partial'
    $result.activeSkills = @($skills | Select-Object -First 1)
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'skillspector-static') {
    $result.scannerIdentity = 'development-fixture-static-analyzer'
    if ($fixtureBehavior -eq 'semantic-required') {
        $result.semanticRequired = $true
    }
    if ($fixtureBehavior -ne 'static-partial') {
        $result.analyzerCompleteness = 'complete'
    }
}
if ($env:STANDARD_VALIDATION_STAGE_ID -eq 'repository-tests') {
    [IO.File]::WriteAllText('__FIXTURE_SENTINEL_PATH__', 'repository-test-ran', (New-Object Text.UTF8Encoding($false)))
    $result.testInventory = @('fixture-repository-test')
    $result.testResult = [ordered]@{ status = 'passed'; decision = 'PASS'; total = 1; passed = 1; skipped = 0 }
    $result.domainAdapterResult = [ordered]@{ status = 'passed'; decision = 'PASS' }
    if ($fixtureBehavior -eq 'repository-artifact-tamper') {
        $artifactRoot = Split-Path -Parent $env:STANDARD_VALIDATION_OUTPUT_PATH
        $receipt = @(Get-ChildItem -LiteralPath (Join-Path $artifactRoot 'runs') -Filter 'receipt.json' -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.FullName -match '[\\/]+controlled-acquisition[\\/]receipt\.json$' } |
                Select-Object -First 1)[0]
        if ($null -ne $receipt) { [IO.File]::Delete($receipt.FullName) }
    }
    if ($fixtureBehavior -eq 'repository-missing-evidence') {
        $result.Remove('testInventory')
    }
    if ($fixtureBehavior -eq 'repository-zero-tests') {
        $result.testInventory = @()
        $result.testResult.total = 0
        $result.testResult.passed = 0
        $result.testResult.skipped = 0
    }
}
if ($fixtureBehavior -eq 'snapshot-mutate' -and $env:STANDARD_VALIDATION_STAGE_ID -eq 'package-validation') {
    $targetSkill = @($skills | Select-Object -First 1)[0]
    Add-Content -LiteralPath (Join-Path $env:STANDARD_VALIDATION_CANDIDATE_ROOT ("skills/$targetSkill/SKILL.md")) -Value 'mutated-by-package-fixture' -Encoding UTF8
}
$result | ConvertTo-Json -Depth 10 -Compress
'@
            $toolScriptText = $toolScriptText.Replace('__FIXTURE_BEHAVIOR__', $Behavior.Replace("'", "''"))
            $toolScriptText = $toolScriptText.Replace('__FIXTURE_LOG_PATH__', $log.Replace("'", "''"))
            $toolScriptText = $toolScriptText.Replace('__FIXTURE_SENTINEL_PATH__', $sentinel.Replace("'", "''"))
            Write-TestUtf8File -Path $toolScript -Text $toolScriptText

            $adapter = [ordered]@{
                schemaVersion = 1
                adapter = 'standard-validation-adapter-v1'
                mode = 'development-harness'
                skillsRoot = 'skills'
                activeSkills = @($SkillIds)
                canonicalValidatorPath = 'scripts/Invoke-StandardValidation.ps1'
                packageAdapter = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                skillValidator = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                skillTools = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                staticAnalyzer = [ordered]@{
                    command = $script:PowerShellPath
                    arguments = @('-NoProfile', '-File', $toolScript)
                }
                repositoryTests = @(
                    [ordered]@{
                        id = 'repository-test-pester'
                        kind = 'pester'
                        command = $script:PowerShellPath
                        arguments = @('-NoProfile', '-File', $toolScript)
                    }
                )
            }
            $adapterPath = Join-Path $Root 'adapter.json'
            Write-TestUtf8File -Path $adapterPath -Text ($adapter | ConvertTo-Json -Depth 20)

            return [pscustomobject][ordered]@{
                Root = $Root
                Candidate = $candidate
                Adapter = $adapterPath
                Artifacts = $artifacts
                TrustedTools = $tools
                Output = $output
                Log = $log
                Sentinel = $sentinel
                Behavior = $Behavior
                SkillIds = @($SkillIds)
            }
        }

        function Resolve-RunnerFixtureCleanupFailure {
            param(
                [AllowNull()][Exception] $PrimaryException,
                [AllowEmptyCollection()][string[]] $CleanupErrors = @()
            )

            $errors = @($CleanupErrors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($errors.Count -eq 0) { return }
            $message = $errors -join ' '
            if ($null -ne $PrimaryException) {
                $PrimaryException.Data['RunnerCleanupError'] = $message
                return
            }
            throw $message
        }

        function Invoke-RunnerFixture {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [string] $ArtifactsRoot,
                [string] $OutputPath,
                [switch] $SemanticTriggered,
                [switch] $SemanticConsent,
                [string] $SemanticProvider,
                [string] $SemanticPurpose,
                [string] $SemanticScope,
                [string] $SemanticEvidencePath,
                [string] $SemanticConsentRequestPath,
                [string] $SemanticConsentDecisionPath,
                [string] $SemanticPublicKeyPath,
                [string] $SemanticPublicKeyId,
                [switch] $CompleteLifecycle,
                [bool] $DevelopmentHarness = $true,
                [string] $AiReviewEvidencePath,
                [string] $HumanApprovalEvidencePath,
                [string] $PublishInstallEvidencePath,
                [string] $PostInstallEvidencePath,
                [string] $CancellationPath,
                [string] $ValidationRunId,
                [string] $SourceRepository = 'https://example.com/example/skills.git',
                [switch] $InjectCaptureFailureAfterStart,
                # Hosted Windows PowerShell 5.1 can spend more than twenty
                # seconds creating the centrally owned child-process boundary;
                # keep the fixture default aligned with the production ceiling,
                # while timeout-specific scenarios pass an explicit one-second limit.
                [int] $TimeoutSeconds = 300
            )

            $effectiveArtifactsRoot = if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) { [string]$Fixture.Artifacts } else { $ArtifactsRoot }
            $effectiveOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                if ([string]::Equals($effectiveArtifactsRoot, [string]$Fixture.Artifacts, [StringComparison]::OrdinalIgnoreCase)) { [string]$Fixture.Output }
                else { Join-Path $effectiveArtifactsRoot 'standard-validation-evidence.json' }
            }
            else { $OutputPath }
            $arguments = @(
                '-NoProfile', '-File', $script:RunnerPath,
                '-CandidateRoot', $Fixture.Candidate,
                '-AdapterPath', $Fixture.Adapter,
                '-ArtifactsRoot', $effectiveArtifactsRoot,
                '-OutputPath', $effectiveOutputPath,
                '-SourceRepository', $SourceRepository,
                '-SourceRevision', ('a' * 40),
                '-BaseRevision', ('b' * 40),
                '-EventName', 'local',
                '-TimeoutSeconds', [string]$TimeoutSeconds,
                '-TrustedToolRoot', $Fixture.TrustedTools
            )
            if ($DevelopmentHarness) { $arguments += '-DevelopmentHarness' }
            if ($SemanticTriggered) { $arguments += '-SemanticTriggered' }
            if ($SemanticConsent) { $arguments += '-SemanticConsent' }
            if (-not [string]::IsNullOrWhiteSpace($SemanticProvider)) { $arguments += @('-SemanticProvider', $SemanticProvider) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticPurpose)) { $arguments += @('-SemanticPurpose', $SemanticPurpose) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticScope)) { $arguments += @('-SemanticScope', $SemanticScope) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticEvidencePath)) { $arguments += @('-SemanticEvidencePath', $SemanticEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticConsentRequestPath)) { $arguments += @('-SemanticConsentRequestPath', $SemanticConsentRequestPath) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticConsentDecisionPath)) { $arguments += @('-SemanticConsentDecisionPath', $SemanticConsentDecisionPath) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticPublicKeyPath)) { $arguments += @('-SemanticPublicKeyPath', $SemanticPublicKeyPath) }
            if (-not [string]::IsNullOrWhiteSpace($SemanticPublicKeyId)) { $arguments += @('-SemanticPublicKeyId', $SemanticPublicKeyId) }
            if ($CompleteLifecycle) { $arguments += '-CompleteLifecycle' }
            if (-not [string]::IsNullOrWhiteSpace($AiReviewEvidencePath)) { $arguments += @('-AiReviewEvidencePath', $AiReviewEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($HumanApprovalEvidencePath)) { $arguments += @('-HumanApprovalEvidencePath', $HumanApprovalEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($PublishInstallEvidencePath)) { $arguments += @('-PublishInstallEvidencePath', $PublishInstallEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($PostInstallEvidencePath)) { $arguments += @('-PostInstallEvidencePath', $PostInstallEvidencePath) }
            if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
                $arguments += @('-CancellationPath', $CancellationPath)
            }
            if (-not [string]::IsNullOrWhiteSpace($ValidationRunId)) {
                $arguments += @('-RunId', $ValidationRunId)
            }

            $fixtureEnvironment = [ordered]@{
                STANDARD_VALIDATION_INHERITED_SECRET = 'fixture-reserved-prefix-secret-must-not-cross-the-child-boundary'
                SYP154_INHERITED_SECRET = 'fixture-secret-must-not-cross-the-child-boundary'
            }
            $runnerBootstrap = @'
$ErrorActionPreference = 'Stop'
$runnerPath = [string]$env:SYP154_TEST_RUNNER_PATH
$encodedArguments = [string]$env:SYP154_TEST_RUNNER_ARGUMENTS_B64
$argumentCountText = [string]$env:SYP154_TEST_RUNNER_ARGUMENT_COUNT
if ([string]::IsNullOrWhiteSpace($runnerPath) -or [string]::IsNullOrWhiteSpace($encodedArguments) -or
    [string]::IsNullOrWhiteSpace($argumentCountText)) {
    throw 'Runner fixture bootstrap metadata is incomplete.'
}
$expectedArgumentCount = 0
if (-not [int]::TryParse($argumentCountText, [ref]$expectedArgumentCount) -or $expectedArgumentCount -lt 1) {
    throw 'Runner fixture argument count is invalid.'
}
$encodedArgumentItems = @($encodedArguments.Split([char[]]@(';'), [StringSplitOptions]::None))
if ($encodedArgumentItems.Count -ne $expectedArgumentCount) {
    throw "Runner fixture argument count mismatch: expected $expectedArgumentCount, got $($encodedArgumentItems.Count)."
}
$runnerArguments = @()
foreach ($item in $encodedArgumentItems) {
    $runnerArguments += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($item))
}
$switchNames = @('DevelopmentHarness', 'SemanticTriggered', 'SemanticConsent', 'CompleteLifecycle')
$valueNames = @(
    'CandidateRoot', 'AdapterPath', 'ArtifactsRoot', 'OutputPath', 'SourceRepository',
    'SourceRevision', 'BaseRevision', 'EventName', 'TimeoutSeconds', 'TrustedToolRoot',
    'SemanticProvider', 'SemanticPurpose', 'SemanticScope', 'SemanticEvidencePath',
    'SemanticConsentRequestPath', 'SemanticConsentDecisionPath', 'SemanticPublicKeyPath',
    'SemanticPublicKeyId',
    'AiReviewEvidencePath', 'HumanApprovalEvidencePath', 'PublishInstallEvidencePath',
    'PostInstallEvidencePath', 'CancellationPath', 'RunId'
)
$runnerParameters = @{}
for ($index = 0; $index -lt $runnerArguments.Count;) {
    $token = [string]$runnerArguments[$index]
    if (-not $token.StartsWith('-', [StringComparison]::Ordinal) -or $token.Length -lt 2) {
        throw "Runner fixture argument name is invalid at index $index."
    }
    $name = $token.Substring(1)
    if ($switchNames -contains $name) {
        $runnerParameters[$name] = $true
        $index++
        continue
    }
    if ($valueNames -notcontains $name -or ($index + 1) -ge $runnerArguments.Count) {
        throw "Runner fixture parameter '$name' is not allowed or has no value."
    }
    $runnerParameters[$name] = [string]$runnerArguments[$index + 1]
    $index += 2
}
[Environment]::SetEnvironmentVariable('SYP154_TEST_RUNNER_PATH', $null, 'Process')
[Environment]::SetEnvironmentVariable('SYP154_TEST_RUNNER_ARGUMENTS_B64', $null, 'Process')
[Environment]::SetEnvironmentVariable('SYP154_TEST_RUNNER_ARGUMENT_COUNT', $null, 'Process')
& $runnerPath @runnerParameters
if ($null -eq $LASTEXITCODE) { exit 0 }
exit ([int]$LASTEXITCODE)
'@
            $encodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runnerBootstrap))
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $script:PowerShellPath
            $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedBootstrap"
            $startInfo.WorkingDirectory = $script:RepositoryRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.EnvironmentVariables['SYP154_TEST_RUNNER_PATH'] = $script:RunnerPath
            $runnerArguments = @($arguments | Select-Object -Skip 3)
            $startInfo.EnvironmentVariables['SYP154_TEST_RUNNER_ARGUMENTS_B64'] = @(
                $runnerArguments | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_)) }
            ) -join ';'
            $startInfo.EnvironmentVariables['SYP154_TEST_RUNNER_ARGUMENT_COUNT'] = [string]$runnerArguments.Count
            foreach ($entry in $fixtureEnvironment.GetEnumerator()) {
                $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
            }
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            $processStarted = $false
            $primaryException = $null
            try {
                if (-not $process.Start()) { throw 'Runner fixture Process.Start returned false.' }
                $processStarted = $true
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if ($InjectCaptureFailureAfterStart) {
                    $injectedFailure = New-Object InvalidOperationException('Injected runner fixture capture failure after process start.')
                    $injectedFailure.Data['RunnerProcessId'] = [int]$process.Id
                    throw $injectedFailure
                }
                $process.WaitForExit()
                $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
                $stderr = [string]$stderrTask.GetAwaiter().GetResult()
                $exitCode = [int]$process.ExitCode
                $captured = $stdout + $stderr
            }
            catch {
                $primaryException = $_.Exception
                throw
            }
            finally {
                try {
                    if ($processStarted) {
                        $processIsRunning = $true
                        try { $processIsRunning = -not $process.HasExited } catch { }
                        if ($processIsRunning) {
                            $descendantIds = New-Object 'System.Collections.Generic.HashSet[int]'
                            $rootProcessId = [int]$process.Id
                            [void]$descendantIds.Add($rootProcessId)
                            $treeKillMethod = $process.GetType().GetMethod('Kill', [type[]]@([bool]))
                            $relationReadError = $null
                            $relations = @()
                            if ($env:OS -eq 'Windows_NT') {
                                try {
                                    $relations = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object {
                                        [pscustomobject][ordered]@{
                                            ProcessId = [int]$_.ProcessId
                                            ParentProcessId = [int]$_.ParentProcessId
                                        }
                                    })
                                }
                                catch {
                                    try {
                                        $relations = @(Get-WmiObject -Class Win32_Process -ErrorAction Stop | ForEach-Object {
                                            [pscustomobject][ordered]@{
                                                ProcessId = [int]$_.ProcessId
                                                ParentProcessId = [int]$_.ParentProcessId
                                            }
                                        })
                                    }
                                    catch { $relationReadError = $_.Exception }
                                }
                            }
                            elseif (Test-Path -LiteralPath '/proc' -PathType Container) {
                                try {
                                    $relations = @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction Stop | ForEach-Object {
                                        if ($_.Name -notmatch '^\d+$') { return }
                                        try {
                                            $stat = Get-Content -Raw -LiteralPath (Join-Path $_.FullName 'stat') -ErrorAction Stop
                                            if ($stat -match '^(\d+)\s+\(.*\)\s+\S\s+(\d+)\s') {
                                                [pscustomobject][ordered]@{
                                                    ProcessId = [int]$Matches[1]
                                                    ParentProcessId = [int]$Matches[2]
                                                }
                                            }
                                        }
                                        catch { }
                                    })
                                }
                                catch { $relationReadError = $_.Exception }
                            }
                            else {
                                $relationReadError = New-Object PlatformNotSupportedException('No supported process relationship source is available.')
                            }
                            for ($pass = 0; $pass -lt $relations.Count; $pass++) {
                                $added = $false
                                foreach ($relation in $relations) {
                                    if ($descendantIds.Contains($relation.ParentProcessId) -and
                                        $descendantIds.Add($relation.ProcessId)) {
                                        $added = $true
                                    }
                                }
                                if (-not $added) { break }
                            }

                            $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
                            $ownedDescendantProcesses = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
                            foreach ($processId in @($descendantIds | Where-Object { $_ -ne $rootProcessId })) {
                                $ownedProcess = $null
                                try {
                                    $ownedProcess = [Diagnostics.Process]::GetProcessById([int]$processId)
                                    [void]$ownedProcess.Handle
                                    $ownedDescendantProcesses.Add($ownedProcess)
                                    $ownedProcess = $null
                                }
                                catch [ArgumentException] { }
                                catch { $cleanupErrors.Add("Descendant process $processId handle capture failed: $($_.Exception.Message)") }
                                finally { if ($null -ne $ownedProcess) { $ownedProcess.Dispose() } }
                            }
                            if ($null -ne $treeKillMethod) {
                                try { [void]$treeKillMethod.Invoke($process, @($true)) }
                                catch { $cleanupErrors.Add("Process-tree termination failed: $($_.Exception.Message)") }
                            }
                            try {
                                if (-not $process.HasExited) { $process.Kill() }
                            }
                            catch {
                                try { if (-not $process.HasExited) { $cleanupErrors.Add("Root process termination failed: $($_.Exception.Message)") } } catch { }
                            }
                            foreach ($ownedProcess in $ownedDescendantProcesses) {
                                try {
                                    if (-not $ownedProcess.HasExited) { $ownedProcess.Kill() }
                                    if (-not $ownedProcess.WaitForExit(5000)) {
                                        $cleanupErrors.Add("Descendant process $($ownedProcess.Id) did not terminate during cleanup.")
                                    }
                                }
                                catch { $cleanupErrors.Add("Retained descendant process cleanup failed: $($_.Exception.Message)") }
                                finally { $ownedProcess.Dispose() }
                            }
                            if (-not $process.WaitForExit(30000)) {
                                $cleanupErrors.Add("Runner fixture process $rootProcessId did not terminate during cleanup.")
                            }
                            if ($null -ne $relationReadError) {
                                $cleanupErrors.Add("Runner fixture process-tree enumeration failed: $($relationReadError.Message)")
                            }
                            Resolve-RunnerFixtureCleanupFailure `
                                -PrimaryException $primaryException `
                                -CleanupErrors @($cleanupErrors.ToArray())
                        }
                    }
                }
                finally { $process.Dispose() }
            }
            $evidence = $null
            if (Test-Path -LiteralPath $effectiveOutputPath -PathType Leaf) {
                try { $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $effectiveOutputPath | ConvertFrom-Json } catch { }
            }
            return [pscustomobject][ordered]@{
                Output = $captured
                ExitCode = $exitCode
                Evidence = $evidence
            }
        }

        function Get-TestHumanApprovalPayload {
            param(
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][string] $ApprovalId,
                [Parameter(Mandatory = $true)][string] $Approver,
                [Parameter(Mandatory = $true)][string] $ApprovalTimestamp,
                [Parameter(Mandatory = $true)][string] $ReviewDisposition,
                [Parameter(Mandatory = $true)][string] $HostId,
                [Parameter(Mandatory = $true)][string] $ActorId
            )
            return "candidateId=$CandidateId`napprovalId=$ApprovalId`napprover=$Approver`napprovalTimestamp=$ApprovalTimestamp`nreviewDisposition=$ReviewDisposition`nhostId=$HostId`nactorId=$ActorId"
        }

        function Write-TestHumanApprovalEvidence {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $CandidateId
            )
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                Write-TestUtf8File -Path (Join-Path $Fixture.TrustedTools 'human-approval-public-key.xml') -Text $rsa.ToXmlString($false)
                $approvalId = 'approval-001'
                $approver = 'human@example.test'
                $approvalTimestamp = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
                $reviewDisposition = 'approved'
                $hostId = 'test-host'
                $actorId = 'test-actor'
                $payload = Get-TestHumanApprovalPayload -CandidateId $CandidateId -ApprovalId $approvalId -Approver $approver -ApprovalTimestamp $approvalTimestamp -ReviewDisposition $reviewDisposition -HostId $hostId -ActorId $actorId
                $signature = [Convert]::ToBase64String($rsa.SignData([Text.Encoding]::UTF8.GetBytes($payload), 'SHA256'))
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = 'human-approval'
                    candidateId = $CandidateId
                    status = 'approved'
                    approvalId = $approvalId
                    approver = $approver
                    approvalTimestamp = $approvalTimestamp
                    reviewDisposition = $reviewDisposition
                    attestation = [ordered]@{
                        schemaVersion = 1
                        attestationType = 'trusted-supervisor-human-approval-v1'
                        candidateId = $CandidateId
                        approvalId = $approvalId
                        hostId = $hostId
                        actorId = $actorId
                        issuedAt = $approvalTimestamp
                        reviewDisposition = $reviewDisposition
                        signature = $signature
                    }
                }
                Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 20)
            }
            finally { $rsa.Dispose() }
        }

        function Get-TestLifecycleAttestationPayload {
            param(
                [Parameter(Mandatory = $true)][string] $ReceiptType,
                [Parameter(Mandatory = $true)][hashtable] $Fields
            )
            $orderedNames = @($Fields.Keys | Sort-Object)
            return (@("receiptType=$ReceiptType" + ($orderedNames | ForEach-Object { "$_=$([string]$Fields[$_])" })) -join "`n")
        }

        function Get-TestTextSha256 {
            param([Parameter(Mandatory = $true)][string] $Value)

            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                return ([System.BitConverter]::ToString(
                    $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Value))
                ) -replace '-', '').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
        }

        function Write-TestAiReviewEvidence {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [object[]] $ReviewFindings = @(),
                [object[]] $FindingDisposition = @(),
                [System.Security.Cryptography.RSACryptoServiceProvider] $Rsa
            )
            $ownsRsa = $null -eq $Rsa
            $signingRsa = if ($ownsRsa) { New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048) } else { $Rsa }
            try {
                Write-TestUtf8File -Path (Join-Path $Fixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $signingRsa.ToXmlString($false)
                $findings = @($ReviewFindings)
                $dispositions = @($FindingDisposition)
                $findingsJson = if ($findings.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject ([object[]]$findings) -Compress -Depth 50 }
                $dispositionsJson = if ($dispositions.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject ([object[]]$dispositions) -Compress -Depth 50 }
                $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
                $fields = @{
                    candidateId = $CandidateId
                    decision = 'PASS'
                    evidenceType = 'ai-review'
                    findingDispositionSha256 = Get-TestTextSha256 -Value $dispositionsJson
                    issuedAt = $issuedAt
                    reviewedCandidate = $CandidateId
                    reviewFindingsSha256 = Get-TestTextSha256 -Value $findingsJson
                    status = 'passed'
                }
                $attestation = [pscustomobject][ordered]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-ai-review-v1'
                    candidateId = $CandidateId
                    evidenceType = 'ai-review'
                    status = 'passed'
                    decision = 'PASS'
                    reviewedCandidate = $CandidateId
                    reviewFindingsSha256 = $fields.reviewFindingsSha256
                    findingDispositionSha256 = $fields.findingDispositionSha256
                    issuedAt = $issuedAt
                    signature = $null
                }
                $payload = Get-TestLifecycleAttestationPayload -ReceiptType 'ai-review-v1' -Fields $fields
                $attestation.signature = [Convert]::ToBase64String($signingRsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = 'ai-review'
                    candidateId = $CandidateId
                    status = 'passed'
                    decision = 'PASS'
                    reviewedCandidate = $CandidateId
                    reviewFindings = $findings
                    findingDisposition = $dispositions
                    reviewFindingsSha256 = $fields.reviewFindingsSha256
                    findingDispositionSha256 = $fields.findingDispositionSha256
                    attestation = $attestation
                }
                Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 50)
            }
            finally {
                if ($ownsRsa) { $signingRsa.Dispose() }
            }
        }

        function Write-TestSemanticEvidence {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][System.Security.Cryptography.RSACryptoServiceProvider] $Rsa,
                [object[]] $Findings = @()
            )

            Write-TestUtf8File -Path (Join-Path $Fixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $Rsa.ToXmlString($false)
            $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
            $provider = 'fixture-semantic-provider'
            $purpose = 'fixture semantic regression'
            $scope = 'candidate'
            $findingsJson = if (@($Findings).Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject ([object[]]$Findings) -Compress -Depth 20 }
            $findingsSha256 = Get-TestTextSha256 -Value $findingsJson
            $fields = @{
                analyzerCompleteness = 'complete'
                analyzerIdentity = 'fixture-semantic-analyzer'
                candidateId = $CandidateId
                consentGranted = 'True'
                decision = 'PASS'
                evidenceType = 'semantic'
                findingsSha256 = $findingsSha256
                issuedAt = $issuedAt
                provider = $provider
                purpose = $purpose
                scope = $scope
                status = 'passed'
            }
            $attestation = [ordered]@{
                schemaVersion = 1
                attestationType = 'trusted-supervisor-semantic-v1'
                candidateId = $CandidateId
                evidenceType = 'semantic'
                status = 'passed'
                decision = 'PASS'
                provider = $provider
                purpose = $purpose
                scope = $scope
                consentGranted = $true
                analyzerIdentity = 'fixture-semantic-analyzer'
                analyzerCompleteness = 'complete'
                findingsSha256 = $findingsSha256
                issuedAt = $issuedAt
                signature = $null
            }
            $payload = Get-TestLifecycleAttestationPayload -ReceiptType 'semantic-v1' -Fields $fields
            $attestation.signature = [Convert]::ToBase64String($Rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
            $evidence = [ordered]@{
                schemaVersion = 1
                evidenceType = 'semantic'
                candidateId = $CandidateId
                status = 'passed'
                decision = 'PASS'
                provider = $provider
                purpose = $purpose
                scope = $scope
                consentGranted = $true
                analyzerIdentity = 'fixture-semantic-analyzer'
                analyzerCompleteness = 'complete'
                findings = @($Findings)
                findingsSha256 = $findingsSha256
                attestation = $attestation
            }
            Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 50)
        }

        function New-TestRunnerSemanticV2Artifacts {
            param(
                [Parameter(Mandatory = $true)] $Fixture,
                [string] $SourceRepository = 'https://example.com/example/skills.git',
                [string] $SourceRevision = ('a' * 40),
                [string] $BaseRevision = ('b' * 40),
                [string] $ValidationRunId
            )

            if ([string]::IsNullOrWhiteSpace($ValidationRunId)) { $ValidationRunId = [guid]::NewGuid().ToString('N') }
            $artifactRunId = [guid]::Empty
            if (-not [guid]::TryParseExact($ValidationRunId, 'N', [ref]$artifactRunId) -or
                $artifactRunId -eq [guid]::Empty -or $artifactRunId.ToString('N') -cne $ValidationRunId) {
                throw 'ValidationRunId must be a lowercase 32-character hexadecimal value for v2 test artifacts.'
            }
            $artifactRunIdText = $artifactRunId.ToString()
            $artifactRunIdSuffix = $artifactRunId.ToString('N')

            . $script:RunnerPath `
                -CandidateRoot $Fixture.Candidate `
                -AdapterPath $Fixture.Adapter `
                -ArtifactsRoot $Fixture.Artifacts `
                -SourceRepository $SourceRepository `
                -SourceRevision $SourceRevision `
                -BaseRevision $BaseRevision `
                -EventName 'local' `
                -DefineFunctionsOnly
            $adapterSha = Get-StandardValidationFileSha256 -Path $Fixture.Adapter -Context 'v2 test adapter'
            $inventory = Get-StandardValidationInventory -Root $Fixture.Candidate -Context 'v2 test candidate'
            $contentSha = Get-StandardValidationInventorySha256 -Inventory $inventory
            $candidateId = Get-StandardValidationTextSha256 -Value ("$SourceRepository`n$SourceRevision`n$BaseRevision`nlocal`n$contentSha`n$adapterSha`n")
            $providerSourcePath = Join-Path $Fixture.Candidate 'skills/alpha/SKILL.md'
            $providerSourceBytes = [IO.File]::ReadAllBytes($providerSourcePath)
            $items = @(
                [pscustomobject][ordered]@{ path = 'skills/alpha/SKILL.md'; contentKind = 'skill-instructions'; bytes = [byte[]]$providerSourceBytes }
            )
            $route = [pscustomobject][ordered]@{
                provider = 'fixture-provider-v2'
                adapter = 'fixture-adapter-v2'
                accountOrTenant = 'fixture-account-v2'
                model = 'fixture-model-v2'
                endpoint = 'https://example.test/v2'
                dataRegion = 'fixture-region-v2'
                retentionPolicy = 'fixture-no-retention'
                trainingPolicy = 'fixture-no-training'
            }
            $scope = [pscustomobject][ordered]@{
                description = 'Synthetic runner v2 semantic scope.'
                paths = @('skills/alpha/SKILL.md')
                contentKinds = @('skill-instructions')
            }
            $analyzers = @(
                [pscustomobject][ordered]@{ id = 'semantic_developer_intent'; version = '1.0.0'; sourceSha256 = ('7' * 64) }
                [pscustomobject][ordered]@{ id = 'semantic_security_discovery'; version = '1.0.0'; sourceSha256 = ('8' * 64) }
            )
            $bridgeInventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $items
            $analyzerSet = New-StandardSemanticBridgeAnalyzerSet -Analyzers $analyzers
            $bindings = [pscustomobject][ordered]@{
                candidate = [pscustomobject][ordered]@{
                    candidateId = $candidateId
                    sourceRepository = $SourceRepository
                    sourceRevision = $SourceRevision
                    baseRevision = $BaseRevision
                    sourceTree = ('d' * 40)
                    inputInventorySha256 = $contentSha
                }
                authority = [pscustomobject][ordered]@{
                    repository = 'https://example.test/authority.git'
                    revision = ('f' * 40)
                    tree = ('1' * 40)
                    snapshotInventorySha256 = ('2' * 64)
                }
                tool = [pscustomobject][ordered]@{
                    toolId = 'fixture-semantic-tool'
                    version = '1.0.0'
                    packageSha256 = ('3' * 64)
                    resolverReceiptSha256 = ('4' * 64)
                }
                launch = [pscustomobject][ordered]@{
                    resolutionRunId = $artifactRunIdText
                    launchReceiptSha256 = ('5' * 64)
                    consumptionSha256 = ('6' * 64)
                }
            }
            $now = [DateTime]::UtcNow.AddMinutes(-2)
            $request = New-StandardSemanticBridgeConsentRequest `
                -Bindings $bindings `
                -ProviderRoute $route `
                -Purpose 'Synthetic runner v2 semantic review.' `
                -Scope $scope `
                -ProviderTextInventory $bridgeInventory `
                -AnalyzerSet $analyzerSet `
                -RequestId '11111111-1111-4111-8111-111111111112' `
                -RequestedAt $now `
                -ExpiresAt $now.AddHours(1)
            $decision = New-StandardSemanticBridgeConsentDecision `
                -Request $request `
                -Authorizer ([pscustomobject][ordered]@{
                    subject = 'fixture-authorizer-v2'
                    authorityScope = 'fixture-semantic-egress-v2'
                    authenticationContext = 'fixture-strong-authentication-v2'
                }) `
                -DecisionId '11111111-1111-4111-8111-111111111113' `
                -AuthorizedAt $now.AddMinutes(1)
            # Windows PowerShell 5.1/.NET Framework exposes RSA.Create() as
            # an implementation whose KeySize setter is read-only.  Use the
            # explicit provider constructor, matching the legacy fixtures,
            # while retaining the RSA base-class signing surface below.
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            $provider = {
                param($providerRequest)
                return [pscustomobject][ordered]@{
                    findings = @(
                        [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = 'runner-v2-finding-intent'; ruleId = 'fixture.intent'; message = 'synthetic runner v2 finding'; path = [string]$providerRequest.path; analyzerId = 'semantic_developer_intent' }
                        [pscustomobject][ordered]@{ severity = 'informational'; fingerprint = 'runner-v2-finding-security'; ruleId = 'fixture.security'; message = 'synthetic runner v2 finding'; path = [string]$providerRequest.path; analyzerId = 'semantic_security_discovery' }
                    )
                    analyzerCoverage = @('semantic_developer_intent', 'semantic_security_discovery')
                }
            }
            $signer = {
                param($signerRequest, $callbackContext)
                $signingKey = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
                try {
                    $signingKey.FromXmlString([string]$callbackContext.privateKeyXml)
                    return [pscustomobject][ordered]@{
                        keyId = 'fixture-semantic-key-v2'
                        algorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
                        signature = [Convert]::ToBase64String($signingKey.SignData([byte[]]$signerRequest.payloadBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
                    }
                }
                finally { $signingKey.Dispose() }
            }
            $publicRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
            try {
                $publicRsa.ImportParameters($rsa.ExportParameters($false))
                $run = Invoke-StandardSemanticBridge `
                    -ConsentRequest $request `
                    -ConsentDecision $decision `
                    -Bindings $bindings `
                    -ProviderRoute $route `
                    -Purpose 'Synthetic runner v2 semantic review.' `
                    -Scope $scope `
                    -TextItems $items `
                    -Analyzers $analyzers `
                    -ProviderCallback $provider `
                    -SignerCallback $signer `
                    -ExpectedSignerPublicKey $publicRsa `
                    -ExpectedSignerKeyId 'fixture-semantic-key-v2' `
                    -SignerCallbackContext ([pscustomobject][ordered]@{ privateKeyXml = $rsa.ToXmlString($true) }) `
                    -Now $now.AddMinutes(2)
            }
            finally { $publicRsa.Dispose() }
            if ([string]$run.status -cne 'PASS') { throw "Could not create v2 runner evidence: $($run.reason)" }
            $requestPath = Join-Path $Fixture.Root "semantic-v2-request-$artifactRunIdSuffix.json"
            $decisionPath = Join-Path $Fixture.Root "semantic-v2-decision-$artifactRunIdSuffix.json"
            $evidencePath = Join-Path $Fixture.Root "semantic-v2-evidence-$artifactRunIdSuffix.json"
            $publicKeyPath = Join-Path $Fixture.TrustedTools "semantic-v2-public-key-$artifactRunIdSuffix.xml"
            Write-TestUtf8File -Path $requestPath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $request)
            Write-TestUtf8File -Path $decisionPath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $decision)
            Write-TestUtf8File -Path $evidencePath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $run.evidence)
            Write-TestUtf8File -Path $publicKeyPath -Text $rsa.ToXmlString($false)
            return [pscustomobject][ordered]@{
                Fixture = $Fixture
                Request = $request
                Decision = $decision
                Evidence = $run.evidence
                EvidenceBytes = [byte[]]$run.evidenceBytes
                Inventory = $bridgeInventory
                Bindings = $bindings
                Route = $route
                Scope = $scope
                PublicKeyPath = $publicKeyPath
                RequestPath = $requestPath
                DecisionPath = $decisionPath
                EvidencePath = $evidencePath
                CandidateId = $candidateId
                RunId = $artifactRunIdSuffix
                KeyId = 'fixture-semantic-key-v2'
                Rsa = $rsa
            }
        }

        function Write-TestLifecycleEvidence {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][ValidateSet('publish-install', 'post-install')][string] $EvidenceType,
                [Parameter(Mandatory = $true)][string] $CandidateId,
                [Parameter(Mandatory = $true)][System.Security.Cryptography.RSACryptoServiceProvider] $Rsa,
                [string[]] $InstalledInventory = @('skill-alpha', 'skill-beta')
            )

            $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
            if ($EvidenceType -ceq 'publish-install') {
                $releaseIdentity = 'release-example'
                $fields = @{
                    authorization = 'True'
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    issuedAt = $issuedAt
                    releaseIdentity = $releaseIdentity
                    status = 'authorized'
                }
                $attestation = [ordered]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-publish-install-v1'
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    status = 'authorized'
                    authorization = $true
                    releaseIdentity = $releaseIdentity
                    issuedAt = $issuedAt
                    signature = $null
                }
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = $EvidenceType
                    candidateId = $CandidateId
                    status = 'authorized'
                    authorization = $true
                    releaseIdentity = $releaseIdentity
                    attestation = $attestation
                }
            }
            else {
                $inventory = @($InstalledInventory)
                $inventoryText = ConvertTo-Json -InputObject ([array]$inventory) -Compress
                $fields = @{
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    installedInventory = $inventoryText
                    issuedAt = $issuedAt
                    postInstallIntegrity = 'True'
                    status = 'passed'
                }
                $attestation = [ordered]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-post-install-v1'
                    candidateId = $CandidateId
                    evidenceType = $EvidenceType
                    status = 'passed'
                    installedInventory = $inventory
                    postInstallIntegrity = $true
                    issuedAt = $issuedAt
                    signature = $null
                }
                $evidence = [ordered]@{
                    schemaVersion = 1
                    evidenceType = $EvidenceType
                    candidateId = $CandidateId
                    status = 'passed'
                    installedInventory = $inventory
                    postInstallIntegrity = $true
                    attestation = $attestation
                }
            }
            $receiptType = "$EvidenceType-v1"
            $payload = Get-TestLifecycleAttestationPayload -ReceiptType $receiptType -Fields $fields
            $evidence.attestation.signature = [Convert]::ToBase64String($Rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
            Write-TestUtf8File -Path $Path -Text ($evidence | ConvertTo-Json -Depth 20)
        }
    }

    # Scenario: The public contract must be machine-readable before a consumer can adopt it.
    # Purpose: Keep the ten canonical stages and non-overlapping terminal outcomes explicit.
    It 'UnitT00_exposes_fixed_stage_order_and_distinct_terminal_states' {
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/standard-validation-contract-v1.json') -PathType Leaf) 'The immutable validation contract is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-adapter-v1.schema.json') -PathType Leaf) 'The adapter schema is missing.'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') -PathType Leaf) 'The evidence schema is missing.'
        $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/standard-validation-contract-v1.json') | ConvertFrom-Json
        Assert-Equal $contract.schemaVersion 1 'Validation contract schema version must be one.'
        $stages = @($contract.stages)
        Assert-Equal $stages.Count 10 'Validation contract must expose exactly ten stages.'
        Assert-Equal (($stages | ForEach-Object id) -join ',') 'controlled-acquisition,integrity-verification,package-validation,skillspector-static,repository-tests,conditional-semantic-scan,ai-review,human-approval,publish-or-install,post-install-verification' 'Stage order must be canonical.'
        Assert-Equal (($contract.terminalStates | ForEach-Object state) -join ',') 'PASS,BLOCKED,FAILED,INVALID,CANCELLED' 'Terminal states must remain distinct.'
        Assert-Match ([string]$contract.execution.productionCommandPolicy) 'signed-resolver-receipt' 'Production commands must carry a trusted signed resolver receipt.'
        Assert-Match ([string]$contract.cli.launchBinding) 'SupervisorLaunchBindingPath' 'Production CLI must expose the trusted supervisor launch binding input.'
        Assert-True ([bool]$contract.execution.productionLaunchBinding.required) 'Production validation must require an authenticated launch binding.'
        Assert-Equal ([string]$contract.execution.productionLaunchBinding.attestation) 'trusted-supervisor-validation-launch-v1' 'Launch binding attestation identity must be canonical.'
        Assert-Equal ([string]$contract.execution.productionLaunchBinding.handoffRunIdFormat) 'lowercase-32-character-hexadecimal-N' 'The launch-binding handoff run-ID format must remain canonical.'
        Assert-Equal ([string]$contract.execution.productionLaunchBinding.evidenceRunIdFormat) 'canonical-hyphenated-UUID-D' 'Evidence must declare the schema-compatible run-ID serialization.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.bindingSnapshot) 'reads.*hashes.*parses.*launch-binding.*snapshot.*evidence registration' 'The production launch-binding contract must retain the authenticated binding snapshot hash.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.adapterSnapshot) 'reads adapter bytes once.*parses those same bytes.*fails closed' 'The production launch-binding contract must bind authentication to one parsed adapter-byte snapshot.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.receiptSnapshot) 'reads.*hashes.*parses.*resolver receipt.*snapshot' 'The production launch-binding contract must bind resolver receipt fields and provenance to one parsed receipt snapshot.'
        Assert-Match ([string]$contract.execution.productionLaunchBinding.oneTimeConsumption) 'consumptionPath.*outside.*roots.*atomically.*marker.*existing marker.*replay' 'The production launch-binding contract must require authenticated one-time consumption outside caller-controlled roots.'
        Assert-True (@($contract.evidence.requiredBinding) -contains 'launchBinding.status=verified') 'Evidence required bindings must include verified launch-binding status.'
        Assert-True (@($contract.evidence.requiredBinding) -contains 'launchBinding.verified=true') 'Evidence required bindings must include the verified launch-binding boolean.'
        Assert-True (@($contract.evidence.requiredBinding) -contains 'authority.semanticBridgeModuleSha256') 'Evidence required bindings must hash-bind the semantic bridge module.'
        Assert-True (@($contract.evidence.requiredBinding) -contains 'authority.semanticBridgeSchemaSha256') 'Evidence required bindings must hash-bind the semantic bridge schema.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.packageAdapter) 'package-adapter' 'The package adapter slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.skillValidator) 'skill-validator' 'The skill-validator slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.skillTools) 'skill-tools' 'The skill-tools slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.staticAnalyzer) 'skillspector' 'The static analyzer slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.productionToolRoles.repositoryTests) 'pester' 'The repository-test slot must have a fixed canonical tool role.'
        Assert-Equal ([string]$contract.execution.inventoryEncoding.line) '<path>\t<raw-file-sha256>\n' 'Canonical inventory hashing must exclude file length and use raw-file hashes.'
        Assert-Match ([string]$contract.execution.installedClosure) 'in-root-unix-symlink-target-identities' 'Installed tool closure must bind approved in-root Unix symlink targets.'
        Assert-Match (($contract.evidence.semanticEvidence.required -join ';') ) 'findingsSha256' 'Semantic evidence must include a complete findings digest.'
        Assert-Equal ([string]$contract.evidence.sourceConformance.contract) 'standard-source-conformance-v1' 'Source-stage output must use the named normative projection.'
        Assert-Equal ([string]$contract.evidence.sourceConformance.scope) 'source-stages-1-5' 'Source-stage output must declare its bounded scope.'
        Assert-Match (($contract.evidence.sourceConformance.binding -join ';')) 'event\.cleanedUp=true.*event\.outputPath-within-artifacts\.root.*raw-output-file-event-process-outputSha256-binding.*role derived from validated central adapter dispatch kind.*IDs may be any adapter-safe ID' 'Source-stage events must bind outputs and derive tool roles from validated dispatch kinds.'
        Assert-Match ([string]$contract.evidence.sourceConformance.pesterCounts) 'general or pester.*general dispatches omit all numeric counts.*every pester dispatch requires complete.*total>0.*passed>0.*passed\+skipped=total.*aggregate all pester dispatches in stable Stage 5 order' 'Source-stage Pester evidence must require counts for each approved Pester dispatch.'
        Assert-Match ([string]$contract.evidence.sourceConformance.terminalStates) 'canonical PASS requires exitCode=0 and conditional-semantic-scan status=passed or not-applicable.*canonical BLOCKED requires exitCode=10.*status=blocked' 'Source projection must preserve canonical PASS and BLOCKED consistency.'
        Assert-Match ([string]$contract.evidence.sourceConformance.releaseEligibility) 'fixed false.*never authorizes' 'Source-stage output must never authorize production or release.'
        $releaseConditions = ($contract.evidence.releaseEligibility.trueOnlyWhen -join ';')
        Assert-Match $releaseConditions 'stages\[1\.\.5\]\.status=passed' 'Release eligibility must bind the first five canonical stages.'
        Assert-Match $releaseConditions 'launchBinding\.status=verified' 'Release eligibility must bind verified launch-binding status.'
        Assert-Match $releaseConditions 'launchBinding\.verified=true' 'Release eligibility must bind the verified launch-binding boolean.'
        foreach ($stageId in @('conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            Assert-Match $releaseConditions ("stages\[[0-9]+\]\.id=$stageId-and-status=") "Release eligibility must bind the '$stageId' canonical stage."
        }
        Assert-Equal $contract.consent.publishInstall 'candidate-bound-trusted-supervisor-signed-lifecycle-attestation' 'Publish/install lifecycle evidence must require a trusted attestation.'
        Assert-Match ([string]$contract.stages[8].barrier) 'trusted-supervisor-signed' 'Publish/install stage must require trusted signed evidence.'
        Assert-Match ([string]$contract.stages[9].barrier) 'trusted-supervisor-signed' 'Post-install stage must require trusted signed evidence.'
        Assert-Equal ([int]$contract.execution.childOutputCapture.perStreamCharacterQuota) 1048576 'Child output capture must expose a fixed per-stream character quota.'
        Assert-Match ([string]$contract.execution.childOutputCapture.onExceeded) 'terminate.*fail' 'Child output quota overflow must terminate the owned process and fail closed.'
        Assert-Match ([string]$contract.execution.childOutputCapture.diagnostic) 'separately' 'Child output quota diagnostics must be recorded separately from bounded stream prefixes.'
        $adapterSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-adapter-v1.schema.json') | ConvertFrom-Json
        $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') | ConvertFrom-Json
        Assert-True (@($adapterSchema.required) -contains 'canonicalValidatorPath') 'The adapter schema must require the canonical validator path.'
        Assert-True (@($adapterSchema.'$defs'.testSpec.required) -contains 'kind') 'Every repository-test dispatch must declare its validated kind.'
        Assert-True (@($evidenceSchema.'$defs'.adapter.required) -contains 'canonicalValidatorPath') 'The evidence schema must require the canonical validator path in adapter evidence.'
        Assert-True (@($evidenceSchema.required) -contains 'sourceConformance') 'The evidence schema must require the source-stage projection.'
        Assert-Equal ([string]$evidenceSchema.'$defs'.sourceConformance.properties.releaseEligible.const) 'False' 'Source-stage evidence must hard-code releaseEligible=false.'
        Assert-True (@($evidenceSchema.'$defs'.sourceConformance.properties.pester.required) -contains 'events') 'Pester projection must enumerate count-bearing dispatch evidence.'
        Assert-True (@($evidenceSchema.'$defs'.sourceConformance.properties.canonicalValidation.allOf).Count -ge 2) 'Nested canonical validation must encode PASS and BLOCKED Stage 6 consistency.'
        Assert-True (@($evidenceSchema.'$defs'.authority.required) -contains 'semanticBridgeModuleSha256') 'Authority evidence must bind the semantic bridge module hash.'
        Assert-True (@($evidenceSchema.'$defs'.authority.required) -contains 'semanticBridgeSchemaSha256') 'Authority evidence must bind the semantic bridge schema hash.'
        Assert-True (@($evidenceSchema.'$defs'.launchBinding.properties.status.enum) -contains 'unverified-production') 'The evidence schema must distinguish rejected production launch bindings from development harness runs.'
        Assert-True (@($evidenceSchema.allOf).Count -ge 6) 'The evidence schema must bind every terminal state to its exit code and release eligibility.'
        $evidenceSchemaText = $evidenceSchema | ConvertTo-Json -Depth 20 -Compress
        Assert-Match $evidenceSchemaText '"if".*"state".*"then".*"exitCode"' 'The evidence schema must express conditional terminal state/exit-code relationships.'
        Assert-Match $evidenceSchemaText '"releaseEligible".*"const":false|"releaseEligible".*"const":true' 'The evidence schema must express release eligibility constraints.'
        $runnerSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RunnerPath
        Assert-False ($runnerSource -match '\[string\]\s+\$TrustedToolRoot\s*=\s*\(Split-Path\s+-Parent\s+\$PSScriptRoot\)') 'The runner must not evaluate PSScriptRoot in a parameter default before script initialization.'
        Assert-Match $runnerSource 'if\s*\(\[string\]::IsNullOrWhiteSpace\(\$TrustedToolRoot\)\)' 'The runner must derive its default trusted tool root after parameter binding.'
        Assert-Match $runnerSource 'Assert-AuthorityConsumerEntryPointContract' 'The runner must enforce the central consumer entry-point contract.'
        Assert-Match $runnerSource 'Assert-StandardValidationSnapshotUnchanged' 'The runner must revalidate the candidate snapshot around child execution.'
        Assert-Match $runnerSource 'Assert-StandardValidationHumanApprovalEvidence' 'Human approval must be authenticated by the runner.'
        Assert-Match $runnerSource 'Assert-StandardValidationLifecycleEvidence' 'Publish/install and post-install evidence must be authenticated by the runner.'
        Assert-Match $runnerSource 'CandidateArchivePath|CandidateAcquisitionEvidencePath' 'Production acquisition must bind the candidate to an acquired immutable archive.'
        Assert-Match $runnerSource 'AuthorityRevision|AuthorityArchivePath|AuthoritySnapshotEvidencePath' 'Authority evidence must bind to an immutable authority snapshot.'
        Assert-Match $runnerSource 'docs/standards/schemas/standard-semantic-consent-evidence-v2\.schema\.json' 'The authority snapshot must include the semantic bridge schema.'
        Assert-Match $runnerSource 'scripts/StandardSemanticBridge\.psm1' 'The authority snapshot must include the semantic bridge module.'
        Assert-Match $runnerSource 'Assert-StandardValidationCandidateAcquisition|Assert-StandardValidationAuthoritySnapshot' 'The runner must verify source and authority acquisition bindings before validation.'
        Assert-Match $runnerSource 'Assert-StandardValidationCandidateAcquisitionArtifactsUnchanged' 'Every child invocation must revalidate the acquired candidate archive and receipt hashes.'
        Assert-Match $runnerSource 'Get-StandardValidationDescendantProcessIds|Kill\(\$true\)' 'Child cleanup must account for the complete owned process tree.'
        Assert-Match $runnerSource 'unshare|--pid|--fork|--kill-child' 'Unix child execution must use a kernel-enforced PID namespace boundary.'
        Assert-Match $runnerSource 'Get-StandardValidationUnixPidNamespaceProcessIds|PidNamespaceRequired' 'Unix cleanup must verify the owned PID namespace is empty before passing an event.'
        Assert-Match $runnerSource 'PR_SET_CHILD_SUBREAPER|SetChildSubreaper|SubreaperRequired' 'Restricted Unix hosts must use a kernel-enforced subreaper boundary and verify its descendants.'
        Assert-Match $runnerSource 'EnvironmentVariables\.Clear\(\)' 'Child processes must not inherit the supervisor environment wholesale.'
        Assert-Match $runnerSource 'New-StandardValidationOutputReservation' 'The runner must reserve the final evidence path.'
        Assert-Match $runnerSource 'Consume-StandardValidationSupervisorLaunchBinding' 'The runner must consume each authenticated launch binding once before production work.'
        Assert-Match $runnerSource 'Get-StandardValidationSemanticRequirement' 'Semantic trigger decisions must include typed analyzer requirements.'
        Assert-Match $runnerSource 'Assert-StandardValidationAiReviewEvidence' 'AI review evidence must use the central typed review policy.'
        Assert-Match $runnerSource 'Assert-StandardValidationToolReceipt' 'Production command provenance must use a signed resolver receipt.'
        Assert-Match $runnerSource 'ExpectedToolName' 'Production command provenance must bind to the expected adapter-slot tool role.'
        Assert-Match $runnerSource 'Get-StandardValidationExpectedToolName' 'Every adapter slot must resolve through the central canonical tool-role map.'
        Assert-Match $runnerSource 'Assert-StandardValidationCanonicalRootPath' 'Root containment checks must use canonical existing filesystem components.'
        Assert-Match $runnerSource 'Get-StandardValidationPathCaseBehavior|Get-StandardValidationPathComparison' 'Path containment checks must detect filesystem case behavior rather than infer it from the operating-system enum.'
        Assert-Match $runnerSource 'ChildWorkingRoot|childWorkingDirectory' 'Candidate-controlled children must run outside the supervisor evidence directory.'
        Assert-Match $runnerSource 'Assert-StandardValidationEvidenceArtifacts' 'Previously written evidence artifacts must be revalidated before finalization.'
        Assert-Match $runnerSource 'symlinked or reparse-point ancestor' 'Symlinked root ancestors must fail closed before artifact creation.'
        Assert-Match $runnerSource 'Assert-StandardValidationLauncherFileIdentity' 'Production package launchers must revalidate safe Unix launcher symlinks through the central helper.'
        Assert-Match $runnerSource 'Get-StandardValidationSafeUnixSymlinkEntry' 'Production installed closures must validate Unix symlink targets centrally.'
        Assert-Match $runnerSource 'Assert-StandardValidationRepositoryTestEnvelope|typed, non-empty testInventory' 'Repository Tests must require typed, non-empty coverage evidence before passing.'
        Assert-Match $runnerSource 'Assert-StandardValidationSemanticEvidence' 'Semantic evidence must be authenticated and complete.'
        Assert-Match $runnerSource 'Assert-StandardValidationSemanticProviderTextInventory' 'v2 provider text must be rebound to the verified candidate snapshot before bridge verification.'
        Assert-Match $runnerSource 'publicKeyBytes|publicKeySha256' 'v2 public-key verification must use one retained byte snapshot.'
        Assert-Match $runnerSource 'requestSnapshot.sha256|decisionSnapshot.sha256|evidenceSnapshot.sha256' 'v2 request, decision, and evidence registration must retain snapshot hashes.'
        Assert-Match $runnerSource 'Register-StandardValidationEvidenceArtifact.*publicKeySha256' 'v2 public-key registration must use the authenticated snapshot hash.'
        Assert-Match $runnerSource 'semanticEvidence = \$null' 'Every stage must expose a writable semantic evidence slot.'
        Assert-False ($runnerSource -match 'return\s+,\$(?:Evidence|evidence)') 'Imported evidence helpers must return objects rather than unary-comma arrays.'
        Assert-Match $runnerSource 'Assert-StandardValidationFreshTimestamp' 'Resolver receipts and trusted review attestations must be fresh for the current run.'
        Assert-Match $runnerSource 'installedClosureSha256' 'Production tool execution must bind the complete installed dependency closure.'
        Assert-Match $runnerSource 'launcherDigestSha256' 'Production tool execution must bind the resolver launcher identity.'
        Assert-Match $runnerSource 'Production validation run IDs are generated by the trusted supervisor' 'Production validation must not accept a caller-selected run ID for receipt replay.'
        Assert-Match $runnerSource 'Assert-StandardValidationSupervisorLaunchBinding' 'Production validation must authenticate a supervisor launch binding before resolver receipt validation.'
        Assert-Match $runnerSource 'Get-StandardValidationJsonSnapshot|adapterSnapshotSha256' 'Production validation must parse the adapter from a retained byte snapshot.'
        Assert-Match $runnerSource 'bindingSnapshot|ExpectedSha256' 'Production validation must retain and register the authenticated launch-binding snapshot hash.'
        Assert-Match $runnerSource 'receiptSnapshot|actualReceiptSha256' 'Production validation must authenticate resolver receipt provenance and fields from one byte snapshot.'
        Assert-Match $runnerSource 'Adapter changed during the trusted supervisor launch handoff' 'Production validation must fail closed on adapter substitution during launch handoff.'
        Assert-Match $runnerSource 'SupervisorLaunchBindingPath' 'Production validation must receive the signed supervisor launch binding path.'
        Assert-Match $runnerSource 'ExpectedRunId' 'Production resolver receipt validation must use the current supervisor launch binding.'
        Assert-Match $runnerSource '-RunId \$ExpectedRunId' 'Production package-adapter receipt validation must reject a receipt from another run.'
        Assert-Match $runnerSource 'outputQuotaDiagnostic' 'Output quota diagnostics must be retained outside bounded stream content.'
        Assert-False ($runnerSource -match '\$stderr\s*=\s*"\$stderr`n\$quotaMessage"') 'Output quota diagnostics must not be appended beyond the stderr quota.'
        Assert-Match $runnerSource 'StandardValidationBoundedCapture' 'Child output capture must use the bounded supervisor-owned reader.'
        Assert-False ($runnerSource -match 'ReadToEndAsync') 'The runner must not retain unbounded child stdout/stderr with ReadToEndAsync.'
        $productionRunIdIndex = $runnerSource.IndexOf('$runId = Get-StandardValidationProductionRunId', [StringComparison]::Ordinal)
        $adapterValidationIndex = $runnerSource.IndexOf('$adapterResult = Assert-StandardValidationAdapter', [StringComparison]::Ordinal)
        Assert-True ($productionRunIdIndex -ge 0 -and $adapterValidationIndex -ge 0 -and $productionRunIdIndex -lt $adapterValidationIndex) 'Production run ID derivation must precede full adapter validation.'
        Assert-False ($runnerSource -match 'LD_LIBRARY_PATH') 'Dynamic loader overrides must not be inherited by child processes.'
        $reservationIndex = $runnerSource.IndexOf('$outputReservation = New-StandardValidationOutputReservation', [StringComparison]::Ordinal)
        $contractResolverIndex = $runnerSource.IndexOf('$contractResult = Assert-StandardValidationContractFiles', [StringComparison]::Ordinal)
        Assert-True ($reservationIndex -ge 0 -and $contractResolverIndex -ge 0 -and $reservationIndex -lt $contractResolverIndex) 'Final output reservation must precede authority contract resolver child processes.'
        $launchBindingIndex = $runnerSource.IndexOf('$launchBinding = Assert-StandardValidationSupervisorLaunchBinding', [StringComparison]::Ordinal)
        $productionReceiptIndex = $runnerSource.IndexOf('$runId = Get-StandardValidationProductionRunId', [StringComparison]::Ordinal)
        Assert-True ($launchBindingIndex -ge 0 -and $productionReceiptIndex -ge 0 -and $launchBindingIndex -lt $productionReceiptIndex) 'The authenticated launch binding must precede package-adapter receipt validation.'
    }

    # Scenario: Supervisor setup, Process.Start, or cleanup fails before or after child output capture begins.
    # Purpose: Preserve the original failure and close supervisor-owned resources without trusting an unstarted process object.
    It 'UnitT04_preserves_supervisor_diagnostics_and_prestart_cleanup' {
        . $script:RunnerPath `
            -CandidateRoot (Join-Path $TestDrive 'stderr-preservation-candidate') `
            -AdapterPath (Join-Path $TestDrive 'stderr-preservation-adapter.json') `
            -ArtifactsRoot (Join-Path $TestDrive 'stderr-preservation-artifacts') `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $firstError = 'Could not assign the validator to the owned Windows job object: AssignProcessToJobObject returned false.'
        Assert-Equal (Merge-StandardValidationProcessStderr -Existing $firstError -Captured '' -Quota 200) $firstError 'An empty child stderr stream must not erase the first supervisor diagnostic.'
        $merged = Merge-StandardValidationProcessStderr -Existing $firstError -Captured 'child stderr detail' -Quota 200
        Assert-Match $merged '(?s)Could not assign the validator.*child stderr detail' 'A non-empty child stderr stream must be appended after the first supervisor diagnostic.'
        Assert-True ($merged.Length -le 200) 'Merged supervisor and child stderr must remain within the process evidence quota.'
        Assert-Equal (Merge-StandardValidationProcessStderr -Existing '' -Captured 'child-only stderr' -Quota 200) 'child-only stderr' 'A child stderr stream must remain available when no supervisor diagnostic exists.'
        $nearQuota = Merge-StandardValidationProcessStderr -Existing 'first supervisor error' -Captured ('x' * 400) -Quota 64
        Assert-True ($nearQuota.StartsWith('first supervisor error')) 'Quota trimming must preserve the first supervisor diagnostic prefix.'
        Assert-True ($nearQuota.Length -le 64) 'Quota trimming must never exceed the process evidence quota.'
        $cleanupError = 'The owned Windows job object could not be closed safely (handle=42).'
        $cleanupFirst = Merge-StandardValidationProcessStderr -Existing $cleanupError -Captured ('child stderr detail ' * 40) -Quota 64
        Assert-True ($cleanupFirst.StartsWith('The owned Windows job object could not be closed safely')) 'Cleanup failure diagnostics must take precedence over child stderr.'
        Assert-True ($cleanupFirst.Length -le 64) 'Cleanup-priority stderr must remain within the process evidence quota.'
        $runnerSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RunnerPath
        Assert-Match $runnerSource 'Merge-StandardValidationProcessStderr[\s\S]*-Existing "The owned Windows job object could not be closed safely \(handle=' 'Job-object close failure must be passed as the first diagnostic before child stderr.'
        $shardExecutorSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1')
        Assert-True (([regex]::Matches($shardExecutorSource, 'Get-PesterShardDescendantProcessIds -RootProcessId')).Count -ge 2) 'The shard executor must retain descendant identities while the child is alive.'
        Assert-Match $shardExecutorSource '\$paths\s*=\s*ConvertFrom-Json\s+-InputObject' 'The shard executor must preserve a multi-file shard path array on Windows PowerShell.'
        Assert-True ($shardExecutorSource -match '\$ownsCancellationPath\s+-and[\s\S]{0,240}Remove-Item\s+-LiteralPath \$CancellationPath') 'The shard executor may delete only a runner-owned cancellation marker.'
        Assert-False ($shardExecutorSource -match '&\s+taskkill\.exe') 'The shard executor must not depend on taskkill for owned-process cleanup.'
        Assert-Match $shardExecutorSource 'System\.Diagnostics\.Process\.Kill|Stop-Process' 'The shard executor must use a direct process termination API.'
        Assert-Match $shardExecutorSource 'Get-PesterShardFailureSummary|failureSummary' 'A failed shard must retain a sanitized first-failure summary.'
        Assert-Match $shardExecutorSource 'Read-PesterShardOutputTail' 'A result-less shard must preserve bounded tail diagnostics instead of retaining only the beginning of each stream.'
        Assert-Match $shardExecutorSource '(?s)Get-PesterShardFailureSummary.*?Read-PesterShardOutputTail' 'Failure summarization must inspect the bounded stream tail where terminal errors are written.'
        Assert-Match $shardExecutorSource 'allowlistedFallback' 'A result-less shard without a recognized Pester failure marker may expose only allowlisted bounded terminal context.'
        Assert-Match $shardExecutorSource "Show = ''All''" 'Pester shards must emit bounded per-test progress so an abrupt hosted exit identifies the last completed test.'
        Assert-Match $shardExecutorSource 'CreateKillOnCloseJob|AssignProcessToJobObject' 'The shard executor must establish a kernel-owned Job Object before bootstrap release.'
        Assert-Match $shardExecutorSource 'Assert-PesterShardPathAncestorsNoReparse' 'The shard preflight must reject reparse-point ancestors before creating shard artifacts.'
        Assert-Match $shardExecutorSource 'symlinked or reparse-point ancestor' 'The shard preflight must preserve a precise ancestor trust diagnostic.'
        Assert-Match $shardExecutorSource '\$isHardLink' 'The shard preflight must not mistake a legitimate hardlink executable for symlink traversal.'
        Assert-Match $shardExecutorSource 'Terminate the Job Object before draining inherited output pipes' 'Owned Job Object termination must precede inherited pipe draining.'
        Assert-Match $shardExecutorSource 'Cancellation marker observed before bootstrap release' 'Cancellation must be rechecked after ownership assignment and before bootstrap release.'
        Assert-Match $shardExecutorSource 'Pester shard process status is not completed or output quota was exceeded' 'The aggregate must fail closed on non-completed shard evidence or output-quota overflow.'
        Assert-Match $shardExecutorSource 'PesterShardBoundedCapture|outputQuotaCharacters' 'The shard executor must bound redirected child output.'
        Assert-Match $shardExecutorSource 'failureKind[\s=]+.*early-child-failure' 'A child initialization or Invoke-Pester exception must be represented as an explicit failed result contract.'
        Assert-Match $shardExecutorSource 'failurePhase\s*=\s*\$childFailurePhase' 'Early child evidence must identify the failing initialization or Invoke-Pester phase.'
        Assert-Match $shardExecutorSource 'FailedCount\s*=\s*1' 'Early child failure evidence must contain a nonzero failed count.'
        Assert-Match $shardExecutorSource 'childExitCode\s*-ne\s*0' 'An early child failure must retain a nonzero child exit code after writing evidence.'
        Assert-Match $shardExecutorSource 'ConvertTo-PesterShardEarlyFailureDiagnostic' 'Early child diagnostics must be bounded and sanitized before result/evidence emission.'
        Assert-Match $shardExecutorSource "invoke\.Parameters\.ContainsKey\(''Show''\)" 'The shard executor must gate the optional Show parameter for Pester versions that do not expose it.'
        Assert-True ($shardExecutorSource.Contains("`$ErrorActionPreference = ''Continue''")) 'The shard executor must preserve the original non-terminating-warning behavior while Pester fixtures execute.'
        Assert-True (([regex]::Matches($shardExecutorSource, 'Get-PesterShardProcessIdentity')).Count -ge 2) 'Retained shard PIDs must be bound to immutable process identities.'
        $moduleAncestorValidation = $shardExecutorSource.IndexOf('Assert-PesterShardPathAncestorsNoReparse -Path $PesterModulePath', [StringComparison]::Ordinal)
        $moduleImport = $shardExecutorSource.IndexOf('Import-Module $PesterModulePath', [StringComparison]::Ordinal)
        Assert-True ($moduleAncestorValidation -ge 0 -and $moduleImport -ge 0 -and $moduleAncestorValidation -lt $moduleImport) 'The Pester module path and all existing ancestors must be validated before module initialization can execute.'

        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before process-start cleanup testing.'
        foreach ($functionName in @('New-PesterShardNotStartedCleanup', 'Get-PesterShardCleanupTarget', 'Resolve-PesterShardOutputFailure')) {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            }, $true)
            Assert-True ($null -ne $definition) "The shard executor must define $functionName."
            Invoke-Expression $definition.Extent.Text
        }

        $unstartedProcess = New-Object Diagnostics.Process
        try {
            $notStarted = Get-PesterShardCleanupTarget `
                -Process $unstartedProcess `
                -ProcessStarted $false `
                -RootProcessId $null
            Assert-True ($null -eq $notStarted) 'An unstarted process must not enter process-tree cleanup or require its Id.'

            $throwingIdProcess = New-Object psobject
            $throwingIdProcess | Add-Member -MemberType ScriptProperty -Name Id -Value { throw 'The process Id getter must not be used.' }
            $started = Get-PesterShardCleanupTarget `
                -Process $throwingIdProcess `
                -ProcessStarted $true `
                -RootProcessId 4242
            Assert-Equal $started.rootProcessId 4242 'A started process cleanup target must use the stored authenticated root process ID.'
            Assert-True ([object]::ReferenceEquals($started.process, $throwingIdProcess)) 'The cleanup target must retain the original process object without reading its Id.'
        }
        finally { $unstartedProcess.Dispose() }

        Assert-Match $shardExecutorSource 'if \(-not \$processStarted\)[\s\S]{0,180}\$status = ''startup-failed''' 'A Process.Start failure must retain the explicit startup-failed status.'
        Assert-Match $shardExecutorSource '\$cleanupTarget\s*=\s*Get-PesterShardCleanupTarget[\s\S]{0,220}if \(\$null -ne \$cleanupTarget\)' 'Process-tree cleanup must be gated by the start-aware target.'
        Assert-False ($shardExecutorSource -match '-RootProcessId\s+\(\[int\]\$process\.Id\)') 'Cleanup must not reacquire the root ID from a process object.'
        $cleanupTargetIndex = $shardExecutorSource.IndexOf('$cleanupTarget = Get-PesterShardCleanupTarget', [StringComparison]::Ordinal)
        $jobHandleCloseIndex = $shardExecutorSource.LastIndexOf('if ($jobHandle -ne [IntPtr]::Zero)', [StringComparison]::Ordinal)
        $processEvidenceIndex = $shardExecutorSource.IndexOf('$diagnostic = [ordered]@{', [StringComparison]::Ordinal)
        Assert-True ($cleanupTargetIndex -ge 0 -and $jobHandleCloseIndex -gt $cleanupTargetIndex -and $processEvidenceIndex -gt $jobHandleCloseIndex) 'Job Object closure must remain independent of process-tree cleanup and precede process evidence finalization.'

        $preStartCleanup = New-PesterShardNotStartedCleanup
        $strictShape = & {
            Set-StrictMode -Version Latest
            $shape = New-PesterShardNotStartedCleanup
            [pscustomobject][ordered]@{
                cleanedUp = [bool]$shape.cleanedUp
                remainingCount = @($shape.remainingProcessIds).Count
                errorCount = @($shape.errors).Count
                warningCount = @($shape.warnings).Count
                authoritative = [bool]$shape.jobObject.authoritative
            }
        }
        Assert-True $strictShape.cleanedUp 'A process-not-started cleanup contract must begin clean.'
        Assert-Equal $strictShape.remainingCount 0 'A process-not-started cleanup contract must expose an empty remaining-process collection.'
        Assert-Equal $strictShape.errorCount 0 'A process-not-started cleanup contract must expose an empty error collection.'
        Assert-Equal $strictShape.warningCount 0 'A process-not-started cleanup contract must expose an empty warning collection.'
        Assert-False $strictShape.authoritative 'A Job Object that contains no started process must not be reported as authoritative containment.'
        $closeFailure = Resolve-PesterShardOutputFailure `
            -Cleanup $preStartCleanup `
            -Errors @('The owned Windows Job Object handle could not be closed safely.') `
            -Status 'startup-failed' `
            -ExceptionText 'Process.Start returned false.'
        Assert-Equal $closeFailure.status 'cleanup-failed' 'A pre-start Job Object close failure must become a cleanup failure.'
        Assert-Match ($closeFailure.cleanup.errors -join ' | ') 'Job Object handle could not be closed safely' 'A pre-start cleanup shape must gain close-failure evidence without throwing.'
        Assert-Match $closeFailure.exceptionText 'Process\.Start returned false.*Job Object handle could not be closed safely' 'The original startup failure and the cleanup failure must both remain available.'

        $postCaptureCleanup = $shardExecutorSource.Substring($shardExecutorSource.IndexOf('$outputWriteFailure = Resolve-PesterShardOutputFailure', [StringComparison]::Ordinal))
        Assert-False ($postCaptureCleanup -match '\$cleanup\.errors\s*=') 'Post-capture Job Object and bootstrap cleanup failures must not assign a missing cleanup.errors property directly.'
        Assert-True (([regex]::Matches($postCaptureCleanup, 'Resolve-PesterShardOutputFailure')).Count -ge 4) 'Output, Job Object, and bootstrap cleanup failures must share the property-safe fail-closed transition.'
    }

    # Scenario: A caller supplies a visible cancellation marker to the shard wrapper.
    # Purpose: Reject the unsupported channel in its own discoverable behavior test before any child or shard artifact can be created.
    It 'UnitT05_rejects_a_caller_visible_cancellation_channel_before_child_execution' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $shardExecutorSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardPath
        Assert-Match $shardExecutorSource 'does not accept a caller-visible CancellationPath' 'The shard executor must reject a caller-visible cancellation path before child execution.'
        $rejectionProbe = @"
try {
    & '$($shardPath.Replace("'", "''"))' ``
        -PesterModulePath '$((Join-Path $TestDrive 'missing-pester.psd1').Replace("'", "''"))' ``
        -PesterVersion '4.10.1' ``
        -ExpectedTotalCount 1 ``
        -ExpectedSkippedCount 0 ``
        -CancellationPath '$((Join-Path $TestDrive 'caller-visible.cancel').Replace("'", "''"))'
}
catch {
    [Console]::Error.WriteLine([string]`$_.Exception.Message)
    exit 1
}
"@
        $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rejectionProbe))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:PowerShellPath
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedProbe"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $probeProcess = New-Object Diagnostics.Process
        $probeProcess.StartInfo = $startInfo
        try {
            Assert-True $probeProcess.Start() 'The caller-visible cancellation rejection probe must start.'
            $probeStdout = $probeProcess.StandardOutput.ReadToEnd()
            $probeStderr = $probeProcess.StandardError.ReadToEnd()
            $probeProcess.WaitForExit()
            $probeExitCode = $probeProcess.ExitCode
        }
        finally { $probeProcess.Dispose() }
        $rejectedOutput = "$probeStdout`n$probeStderr"
        Assert-True ($probeExitCode -ne 0) 'A caller-visible cancellation path must cause a nonzero child exit.'
        Assert-Match $rejectedOutput 'does not accept a caller-visible CancellationPath' 'A caller-visible shard cancellation path must be rejected before any child process or shard artifact is created.'
    }

    # Scenario: Windows PowerShell writes only module-initialization progress CLIXML to stderr while the useful terminal context is on stdout.
    # Purpose: Keep progress serialization from masking the first actionable result-less shard diagnostic.
    It 'UnitT06_skips_progress_only_clixml_before_fallback_diagnostics' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before diagnostic helper testing.'
        foreach ($functionName in @(
            'Read-PesterShardOutputPrefix',
            'Read-PesterShardOutputTail',
            'ConvertFrom-PesterShardCliXmlDiagnostic',
            'Remove-PesterShardTerminalControlSequences',
            'ConvertTo-PesterShardSanitizedDiagnosticText',
            'Get-PesterShardFailureSummary'
        )) {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            }, $true)
            Assert-True ($null -ne $definition) "The shard executor is missing $functionName."
            Invoke-Expression $definition.Extent.Text
        }
        $script:PesterShardChildOutputQuotaCharacters = 1048576
        $cliXmlDecoderSource = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'ConvertFrom-PesterShardCliXmlDiagnostic'
        }, $true).Extent.Text
        Assert-Match $cliXmlDecoderSource 'HashSet\[string\]' 'CLIXML diagnostic deduplication must use a set instead of repeatedly scanning the ordered list.'
        Assert-Match $cliXmlDecoderSource 'StringComparer\]::Ordinal' 'CLIXML diagnostic deduplication must preserve exact ordinal identity.'
        Assert-False ($cliXmlDecoderSource -match '\$diagnosticLines\.Contains\(') 'CLIXML diagnostic deduplication must not perform a linear list scan for every decoded line.'

        $manyRecordBuilder = New-Object Text.StringBuilder
        [void]$manyRecordBuilder.Append('#< CLIXML')
        [void]$manyRecordBuilder.Append([Environment]::NewLine)
        [void]$manyRecordBuilder.Append('<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">')
        for ($recordIndex = 0; $recordIndex -lt 12000; $recordIndex++) {
            [void]$manyRecordBuilder.Append(('<S S="information">unique-diagnostic-{0:D5}</S>' -f $recordIndex))
        }
        [void]$manyRecordBuilder.Append('<S S="information">unique-diagnostic-00000</S>')
        [void]$manyRecordBuilder.Append('</Objs>')
        $manyRecordCliXml = $manyRecordBuilder.ToString()
        Assert-True ($manyRecordCliXml.Length -lt $script:PesterShardChildOutputQuotaCharacters) 'The adversarial CLIXML fixture must remain inside the accepted child-output quota.'
        $manyRecordStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $manyRecordDiagnostic = ConvertFrom-PesterShardCliXmlDiagnostic -Text $manyRecordCliXml
        $manyRecordStopwatch.Stop()
        $manyRecordLines = @($manyRecordDiagnostic -split "`r?`n")
        Assert-Equal $manyRecordLines.Count 12000 'Quota-bounded CLIXML must preserve ordered unique diagnostics while removing duplicates.'
        Assert-Equal $manyRecordLines[0] 'unique-diagnostic-00000' 'CLIXML deduplication must preserve first-seen ordering.'
        Assert-Equal $manyRecordLines[-1] 'unique-diagnostic-11999' 'CLIXML deduplication must retain the final unique record.'
        Assert-True ($manyRecordStopwatch.Elapsed.TotalSeconds -lt 10) 'Quota-bounded CLIXML diagnostic decoding must finish within the absolute safety bound.'

        $stderrPath = Join-Path $TestDrive 'progress-only-stderr.txt'
        $stdoutPath = Join-Path $TestDrive 'terminal-stdout.txt'
        Write-TestUtf8File -Path $stderrPath -Text @'
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.ProgressRecord</T></TN><Props><S N="Activity">Preparing modules for first use.</S><S N="StatusDescription">Preparing modules for first use.</S></Props></Obj></Objs>
'@
        Write-TestUtf8File -Path $stdoutPath -Text 'PowerShell 5.1 shard exited before writing its result file.'

        $summary = Get-PesterShardFailureSummary -Paths @($stderrPath, $stdoutPath)
        Assert-Match $summary 'PowerShell 5\.1 shard exited before writing its result file\.' 'A progress-only stderr stream must not mask useful stdout fallback context.'
        Assert-False ($summary -match '(?i)#< CLIXML|Preparing modules for first use') 'Progress-only CLIXML must not become the first-failure summary.'

        $fallbackTerminalPath = Join-Path $TestDrive 'terminal-control-fallback.txt'
        $escape = [string][char]27
        $bell = [string][char]7
        Write-TestUtf8File -Path $fallbackTerminalPath -Text ($escape + ']0;untrusted terminal title' + $bell + 'PowerShell 5.1 shard exited before writing its result file.')
        $fallbackTerminalSummary = Get-PesterShardFailureSummary -Paths @($fallbackTerminalPath)
        Assert-Equal $fallbackTerminalSummary 'PowerShell 5.1 shard exited before writing its result file.' 'Fallback diagnostics must normalize terminal-control strings before applying the fixed allowlist.'
        Assert-False ($fallbackTerminalSummary -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]|untrusted terminal title') 'Fallback diagnostics must not retain terminal controls or their payload.'

        $credentialPath = Join-Path $TestDrive 'credential-continuation.txt'
        Write-TestUtf8File -Path $credentialPath -Text "Authorization:`ncredential-value-that-must-not-be-logged"
        $credentialSummary = Get-PesterShardFailureSummary -Paths @($credentialPath)
        Assert-False ($credentialSummary -match 'credential-value-that-must-not-be-logged') 'An unlabeled value after a sensitive header must never enter the workflow-visible fallback diagnostic.'
        Assert-Match $credentialSummary 'No allowlisted Pester diagnostic' 'Unrecognized arbitrary child output must be replaced by a fixed safe diagnostic.'

        $recognizedCredentialPath = Join-Path $TestDrive 'recognized-credential-continuation.txt'
        Write-TestUtf8File -Path $recognizedCredentialPath -Text "[-] fixture failure`nAuthorization:`nrecognized-credential-value-that-must-not-be-logged`n`nExpected: safe diagnostic context"
        $recognizedCredentialSummary = Get-PesterShardFailureSummary -Paths @($recognizedCredentialPath)
        Assert-False ($recognizedCredentialSummary -match 'recognized-credential-value-that-must-not-be-logged') 'A recognized failure block must not retain an unlabeled value after a sensitive header.'
        Assert-Match $recognizedCredentialSummary '\[-\] fixture failure' 'Sanitizing a sensitive continuation must preserve the recognized failure marker.'
        Assert-False ($recognizedCredentialSummary -match 'Expected: safe diagnostic context') 'A blank line must not restore raw output after a sensitive header.'
        Assert-Match $recognizedCredentialSummary 'redacted sensitive diagnostic continuation' 'The sensitive block must be represented only by a fixed safe continuation marker.'

        $wrappedCredentialPath = Join-Path $TestDrive 'wrapped-credential-before-marker.txt'
        Write-TestUtf8File -Path $wrappedCredentialPath -Text "Authorization:`nwrapped-credential-fragment-one`nwrapped-credential-fragment-two`n`n[-] fixture failure`nExpected: safe diagnostic context"
        $wrappedCredentialSummary = Get-PesterShardFailureSummary -Paths @($wrappedCredentialPath)
        Assert-False ($wrappedCredentialSummary -match 'wrapped-credential-fragment-(?:one|two)') 'Every wrapped credential continuation before a recognized failure marker must be redacted.'
        Assert-False ($wrappedCredentialSummary -match '\[-\] fixture failure|Expected: safe diagnostic context') 'No raw line after a sensitive header may be trusted as a boundary.'
        Assert-Match $wrappedCredentialSummary '\[-\] \[redacted sensitive diagnostic continuation\]' 'A boundary-looking continuation must be represented by a fixed safe marker.'

        $cookieCredentialPath = Join-Path $TestDrive 'cookie-credential-before-marker.txt'
        Write-TestUtf8File -Path $cookieCredentialPath -Text "Set-Cookie: session_id=cookie-credential-that-must-not-be-logged; HttpOnly`n[-] cookie fixture failure`nExpected: cookie-context-that-must-not-be-logged"
        $cookieCredentialSummary = Get-PesterShardFailureSummary -Paths @($cookieCredentialPath)
        Assert-False ($cookieCredentialSummary -match 'cookie-(?:credential|context)-that-must-not-be-logged') 'Cookie/session credentials immediately before a recognized failure marker must never enter the workflow-visible diagnostic window.'
        Assert-Match $cookieCredentialSummary '\[-\] \[redacted sensitive diagnostic continuation\]' 'A failure marker after a cookie credential must be represented only by a fixed safe continuation marker.'

        $credentialLabelPath = Join-Path $TestDrive 'credential-label-before-marker.txt'
        Write-TestUtf8File -Path $credentialLabelPath -Text "credentials:`nq7F9opaqueValue`n[-] credential-label fixture failure`nExpected: safe diagnostic context"
        $credentialLabelSummary = Get-PesterShardFailureSummary -Paths @($credentialLabelPath)
        Assert-False ($credentialLabelSummary -match 'q7F9opaqueValue') 'An opaque value after a credential label must never become the line preceding a workflow-visible failure marker.'
        Assert-Match $credentialLabelSummary '\[-\] \[redacted sensitive diagnostic continuation\]' 'A failure marker after a credential-labeled block must be represented only by a fixed safe continuation marker.'

        $ordinaryAuthorizationProgressPath = Join-Path $TestDrive 'ordinary-authorization-progress.txt'
        Write-TestUtf8File -Path $ordinaryAuthorizationProgressPath -Text "[+] InterT10_requires_explicit_authorization_before_git_index_changes 1s`n[-] actionable fixture failure`nExpected: actionable expected value`nBut was: actionable actual value"
        $ordinaryAuthorizationProgressSummary = Get-PesterShardFailureSummary -Paths @($ordinaryAuthorizationProgressPath)
        Assert-Match $ordinaryAuthorizationProgressSummary '\[-\] actionable fixture failure' 'A non-credential test name containing authorization must not hide the following failure marker.'
        Assert-Match $ordinaryAuthorizationProgressSummary 'Expected: actionable expected value' 'A non-credential test name must not hide actionable expectation context.'
        Assert-Match $ordinaryAuthorizationProgressSummary 'But was: actionable actual value' 'A non-credential test name must not hide the observed failure value.'

        $windowBoundaryCredentialPath = Join-Path $TestDrive 'credential-crossing-tail-window.txt'
        $windowSuffix = "Authorization:`nwindow-boundary-credential`n`n[-] fixture failure`nExpected: safe diagnostic context`n"
        $windowFillerLength = (65536 + 5) - [Text.Encoding]::UTF8.GetByteCount($windowSuffix)
        Assert-True ($windowFillerLength -gt 0) 'The tail-window fixture must place the read offset inside the sensitive header.'
        Write-TestUtf8File -Path $windowBoundaryCredentialPath -Text ("safe prefix`n" + $windowSuffix + ('z' * $windowFillerLength))
        $windowBoundarySummary = Get-PesterShardFailureSummary -Paths @($windowBoundaryCredentialPath)
        Assert-False ($windowBoundarySummary -match 'window-boundary-credential') 'Sanitization must retain sensitive continuation state across a tail-window read boundary.'
        Assert-False ($windowBoundarySummary -match '\[-\] fixture failure|Expected: safe diagnostic context') 'Window-boundary sanitization must not restore raw output after a blank line.'
        Assert-Match $windowBoundarySummary '\[-\] \[redacted sensitive diagnostic continuation\]' 'Window-boundary sanitization must retain only a fixed safe boundary marker.'

        $boundaryLookingCredentialPath = Join-Path $TestDrive 'boundary-looking-credential.txt'
        Write-TestUtf8File -Path $boundaryLookingCredentialPath -Text "[-] fixture failure`nAuthorization:`n[-]window-boundary-credential`nExpected: expected-boundary-credential"
        $boundaryLookingCredentialSummary = Get-PesterShardFailureSummary -Paths @($boundaryLookingCredentialPath)
        Assert-False ($boundaryLookingCredentialSummary -match '(?:window|expected)-boundary-credential') 'Boundary-looking credential continuations must never be trusted as raw diagnostic structure.'
        Assert-Match $boundaryLookingCredentialSummary '\[-\] fixture failure' 'A failure marker before a sensitive continuation must remain available.'

        $quotedKeyCredentialPath = Join-Path $TestDrive 'quoted-key-credential.txt'
        Write-TestUtf8File -Path $quotedKeyCredentialPath -Text "[-] fixture failure`n`"token`":`nquoted-key-credential-that-must-not-be-logged`nExpected: quoted-key-credential-context"
        $quotedKeyCredentialSummary = Get-PesterShardFailureSummary -Paths @($quotedKeyCredentialPath)
        Assert-False ($quotedKeyCredentialSummary -match 'quoted-key-credential-(?:that-must-not-be-logged|context)') 'A quoted sensitive key ending in a separator must enable continuation redaction.'
        Assert-Match $quotedKeyCredentialSummary '\[-\] fixture failure' 'Quoted-key redaction must retain safe context that precedes the sensitive block.'

        $oversizedCliXmlPath = Join-Path $TestDrive 'oversized-valid-clixml-stderr.txt'
        $oversizedCliXmlPadding = 'p' * 140000
        Write-TestUtf8File -Path $oversizedCliXmlPath -Text @"
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><Props><S N="Activity">$oversizedCliXmlPadding</S></Props></Obj><Obj S="information" RefId="1"><ToString>[-] oversized CLIXML fixture failure</ToString></Obj><Obj S="information" RefId="2"><ToString>Expected: safe oversized diagnostic context</ToString></Obj></Objs>
"@
        $oversizedCliXmlSummary = Get-PesterShardFailureSummary -Paths @($oversizedCliXmlPath)
        Assert-Match $oversizedCliXmlSummary '\[-\] oversized CLIXML fixture failure' 'Valid CLIXML within the child-output quota must decode even when it exceeds the former parser limit.'
        Assert-Match $oversizedCliXmlSummary 'Expected: safe oversized diagnostic context' 'Oversized valid CLIXML must preserve adjacent safe diagnostic context.'
        Assert-False ($oversizedCliXmlSummary -match '(?i)#< CLIXML|PowerShell CLIXML diagnostic could not be safely decoded') 'Valid quota-bounded CLIXML must not fall back to an undecodable-stream diagnostic.'

        $mixedStderrPath = Join-Path $TestDrive 'mixed-clixml-stderr.txt'
        Write-TestUtf8File -Path $mixedStderrPath -Text @'
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.ProgressRecord</T></TN><Props><S N="Activity">Preparing modules for first use.</S></Props></Obj><Obj S="information" RefId="1"><ToString> [-] Error occurred in test script 'tests\fixture.Tests.ps1'</ToString></Obj><Obj S="information" RefId="2"><ToString>   PSSecurityException: fixture execution policy failure</ToString></Obj></Objs>
'@
        $mixedSummary = Get-PesterShardFailureSummary -Paths @($mixedStderrPath, $stdoutPath)
        Assert-Match $mixedSummary 'PSSecurityException: fixture execution policy failure' 'Mixed CLIXML must decode the useful non-progress record instead of returning raw XML.'
        Assert-False ($mixedSummary -match '(?i)#< CLIXML|S="progress"') 'Decoded mixed CLIXML must omit serialization markup and progress records.'

        $truncatedStderrPath = Join-Path $TestDrive 'truncated-progress-clixml-stderr.txt'
        Write-TestUtf8File -Path $truncatedStderrPath -Text @'
#< CLIXML
#< CLIXML
<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><MS><PR N="Record"><AV>Preparing modules for first use.</AV><AI>0<
'@
        $actionableStdoutPath = Join-Path $TestDrive 'actionable-stdout.txt'
        Write-TestUtf8File -Path $actionableStdoutPath -Text @'
[-] Error occurred in test script 'tests\fixture.Tests.ps1'
PSSecurityException: fixture execution policy failure
'@
        $truncatedSummary = Get-PesterShardFailureSummary -Paths @($truncatedStderrPath, $actionableStdoutPath)
        Assert-Match $truncatedSummary 'PSSecurityException: fixture execution policy failure' 'Truncated progress CLIXML must be deferred behind actionable stdout.'
        Assert-False ($truncatedSummary -match '(?i)#< CLIXML|Preparing modules for first use') 'Deferred truncated progress CLIXML must not mask actionable stdout.'

        $preservedRawSummary = Get-PesterShardFailureSummary -Paths @($truncatedStderrPath)
        Assert-Equal $preservedRawSummary 'PowerShell CLIXML diagnostic could not be safely decoded.' 'Unparseable CLIXML must retain a fixed diagnostic without exposing raw serialized values.'
        Assert-False ($preservedRawSummary -match '(?i)#< CLIXML|Preparing modules for first use') 'Unparseable CLIXML must never be copied into workflow-visible diagnostics.'
    }

    # Scenario: Parent and generated-child diagnostics contain sensitive continuations split by complete, unterminated, or adversarial terminal controls.
    # Purpose: Normalize terminal controls in one bounded pass before classifying sensitive boundaries and keep continuation values out of every workflow-visible diagnostic.
    It 'UnitT07_normalizes_terminal_controls_before_redacting_parent_and_child_diagnostics_in_bounded_time' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before generated child diagnostic testing.'
        $terminalControlFunction = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Remove-PesterShardTerminalControlSequences'
        }, $true)
        Assert-True ($null -ne $terminalControlFunction) 'The shard executor must define its terminal-control normalizer.'
        Assert-False ($terminalControlFunction.Extent.Text -match '\[regex\]::Replace') 'Terminal-control normalization must not use a backtracking regex over quota-sized child output.'
        Assert-Match $terminalControlFunction.Extent.Text 'while\s*\(' 'Terminal-control normalization must scan its bounded input directly.'
        Invoke-Expression $terminalControlFunction.Extent.Text
        $parentDiagnosticFunction = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'ConvertTo-PesterShardSanitizedDiagnosticText'
        }, $true)
        Assert-True ($null -ne $parentDiagnosticFunction) 'The shard executor must define its parent diagnostic sanitizer.'
        Invoke-Expression $parentDiagnosticFunction.Extent.Text
        $ansiReset = ([string][char]27) + '[0m'
        $parentDiagnostic = ConvertTo-PesterShardSanitizedDiagnosticText -Text "[-] fixture failure`n`"token`":$ansiReset`nparent-ansi-key-credential`nExpected: parent-ansi-key-context"
        Assert-False ($parentDiagnostic -match 'parent-ansi-key-(?:credential|context)') 'The parent sanitizer must strip terminal formatting before classifying a sensitive continuation delimiter.'
        Assert-Match $parentDiagnostic '\[-\] fixture failure' 'Parent ANSI normalization must retain safe context that precedes the sensitive block.'
        $parentAuthorizationProgress = ConvertTo-PesterShardSanitizedDiagnosticText -Text "[+] InterT10_requires_explicit_authorization_before_git_index_changes 1s`n[-] parent actionable failure`nExpected: parent actionable expectation"
        Assert-Match $parentAuthorizationProgress '\[-\] parent actionable failure' 'The parent sanitizer must not treat authorization in an ordinary test name as a sensitive field.'
        Assert-Match $parentAuthorizationProgress 'Expected: parent actionable expectation' 'The parent sanitizer must retain actionable context after an ordinary authorization test name.'

        $escape = [string][char]27
        $indexedColor = $escape + '[38;5;8m'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${indexedColor}context${ansiReset}") 'safe context' 'A color index numerically equal to the concealment opcode must remain ordinary readable SGR formatting.'
        $colonColor = $escape + '[38:2::255:0:0m'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${colonColor}context${ansiReset}") 'safe context' 'A valid colon-form RGB SGR sequence must remain ordinary readable formatting.'
        $differentColors = $escape + '[38:2::255:0:0;48:2::0:0:255m'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${differentColors}context${ansiReset}") 'safe context' 'Different valid foreground and background colors must remain readable formatting.'
        $bell = [string][char]7
        $backspace = [string][char]8
        $osc = $escape + ']0;fixture' + $bell
        $dcs = $escape + 'P1;2|fixture' + $escape + '\'
        $c1Csi = ([string][char]0x9B) + '0m'
        $c1Index = [string][char]0x84
        $cursorLeft = $escape + '[1D'
        $zeroWidthSpace = [string][char]0x200B
        $bidiOverride = [string][char]0x202E
        $lineSeparator = [string][char]0x2028
        $paragraphSeparator = [string][char]0x2029
        $variationSelector = [string][char]0xFE0F
        $visibleReplacementCharacters = "safe$([char]0xFFFC)$([char]0xFFFD)context"
        $parentCases = @(
            [pscustomobject]@{ Name = 'blank'; Text = "[-] fixture failure`nAuthorization:`n`nparent-blank-credential`nExpected: parent-blank-context" },
            [pscustomobject]@{ Name = 'private-key-label'; Text = "[-] fixture failure`nprivateKey:`n-----BEGIN PRIVATE KEY-----`nparent-private-key-label-credential`n-----END PRIVATE KEY-----`nExpected: parent-private-key-label-context" },
            [pscustomobject]@{ Name = 'access-key-label'; Text = "[-] fixture failure`naccess_key:`nparent-access-key-label-credential`nExpected: parent-access-key-label-context" },
            [pscustomobject]@{ Name = 'set-cookie-label'; Text = "Set-Cookie: session_id=parent-set-cookie-label-credential; HttpOnly`n[-] fixture failure`nExpected: parent-set-cookie-label-context" },
            [pscustomobject]@{ Name = 'session-id-label'; Text = "session_id: parent-session-id-label-credential`n[-] fixture failure`nExpected: parent-session-id-label-context" },
            [pscustomobject]@{ Name = 'osc'; Text = "[-] fixture failure`n`"token`":$osc`nparent-osc-credential`nExpected: parent-osc-context" },
            [pscustomobject]@{ Name = 'dcs'; Text = "[-] fixture failure`n`"token`":$dcs`nparent-dcs-credential`nExpected: parent-dcs-context" },
            [pscustomobject]@{ Name = 'c1'; Text = "[-] fixture failure`n`"token`":$c1Csi`nparent-c1-credential`nExpected: parent-c1-context" },
            [pscustomobject]@{ Name = 'esc-csi-incomplete'; Text = "[-] fixture failure`nto${escape}[31`nken:`nparent-esc-csi-incomplete-credential`nExpected: parent-esc-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'c1-csi-incomplete'; Text = "[-] fixture failure`nto$([char]0x9B)31`nken:`nparent-c1-csi-incomplete-credential`nExpected: parent-c1-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-intermediate-incomplete'; Text = "[-] fixture failure`nto${escape}(`nken:`nparent-esc-intermediate-incomplete-credential`nExpected: parent-esc-intermediate-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-low-final'; Text = "[-] fixture failure`nto${escape}#8ken:`nparent-esc-low-final-credential`nExpected: parent-esc-low-final-context" },
            [pscustomobject]@{ Name = 'cursor-bs'; Text = "[-] fixture failure`ntox${backspace}ken:`nparent-cursor-bs-credential`nExpected: parent-cursor-bs-context" },
            [pscustomobject]@{ Name = 'cursor-csi'; Text = "[-] fixture failure`ntox${cursorLeft}ken:`nparent-cursor-csi-credential`nExpected: parent-cursor-csi-context" },
            [pscustomobject]@{ Name = 'cursor-cr'; Text = "[-] fixture failure`ntox`rken:`nparent-cursor-cr-credential`nExpected: parent-cursor-cr-context" },
            [pscustomobject]@{ Name = 'cursor-c1'; Text = "[-] fixture failure`ntox${c1Index}ken:`nparent-cursor-c1-credential`nExpected: parent-cursor-c1-context" },
            [pscustomobject]@{ Name = 'sgr-conceal'; Text = "[-] fixture failure`nto${escape}[8mx${ansiReset}ken:`nparent-sgr-conceal-credential`nExpected: parent-sgr-conceal-context" },
            [pscustomobject]@{ Name = 'sgr-equal-colon'; Text = "[-] fixture failure`nto${escape}[38:2::255:0:0;48:2::255:0:0mx${ansiReset}ken:`nparent-sgr-equal-colon-credential`nExpected: parent-sgr-equal-colon-context" },
            [pscustomobject]@{ Name = 'sgr-equal-indexed'; Text = "[-] fixture failure`nto${escape}[38;5;8m${escape}[48;5;8mx${ansiReset}ken:`nparent-sgr-equal-indexed-credential`nExpected: parent-sgr-equal-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic'; Text = "[-] fixture failure`nto${escape}[31;41mx${ansiReset}ken:`nparent-sgr-equal-basic-credential`nExpected: parent-sgr-equal-basic-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic-indexed'; Text = "[-] fixture failure`nto${escape}[31;48;5;1mx${ansiReset}ken:`nparent-sgr-equal-basic-indexed-credential`nExpected: parent-sgr-equal-basic-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-equal-normalized-index'; Text = "[-] fixture failure`nto${escape}[38:5:01;48;5;1mx${ansiReset}ken:`nparent-sgr-equal-normalized-index-credential`nExpected: parent-sgr-equal-normalized-index-context" },
            [pscustomobject]@{ Name = 'sgr-equal-default-space'; Text = "[-] fixture failure`nto${escape}[38:2:0:255:0:0;48:2::255:0:0mx${ansiReset}ken:`nparent-sgr-equal-default-space-credential`nExpected: parent-sgr-equal-default-space-context" },
            [pscustomobject]@{ Name = 'sgr-equal-fixed-cube'; Text = "[-] fixture failure`nto${escape}[38:2::255:0:0;48;5;196mx${ansiReset}ken:`nparent-sgr-equal-fixed-cube-credential`nExpected: parent-sgr-equal-fixed-cube-context" },
            [pscustomobject]@{ Name = 'sgr-equal-fixed-gray'; Text = "[-] fixture failure`nto${escape}[38;5;244;48:2::128:128:128mx${ansiReset}ken:`nparent-sgr-equal-fixed-gray-credential`nExpected: parent-sgr-equal-fixed-gray-context" },
            [pscustomobject]@{ Name = 'sgr-equal-state'; Text = "[-] fixture failure`n${escape}[31;41m`nx${ansiReset}token:`nparent-sgr-equal-state-credential`nExpected: parent-sgr-equal-state-context" },
            [pscustomobject]@{ Name = 'sgr-conceal-state'; Text = "[-] fixture failure`n${escape}[8m`nx${escape}[28mtoken:`nparent-sgr-conceal-state-credential`nExpected: parent-sgr-conceal-state-context" },
            [pscustomobject]@{ Name = 'sgr-malformed-color'; Text = "[-] fixture failure`nto${escape}[38;5;999mx${ansiReset}ken:`nparent-sgr-malformed-color-credential`nExpected: parent-sgr-malformed-color-context" },
            [pscustomobject]@{ Name = 'unicode-zero-width'; Text = "[-] fixture failure`nto${zeroWidthSpace}ken:`nparent-unicode-zero-width-credential`nExpected: parent-unicode-zero-width-context" },
            [pscustomobject]@{ Name = 'unicode-bidi'; Text = "[-] fixture failure`nto${bidiOverride}ken:`nparent-unicode-bidi-credential`nExpected: parent-unicode-bidi-context" },
            [pscustomobject]@{ Name = 'unicode-line-separator'; Text = "[-] fixture failure`nto${lineSeparator}ken:`nparent-unicode-line-separator-credential`nExpected: parent-unicode-line-separator-context" },
            [pscustomobject]@{ Name = 'unicode-paragraph-separator'; Text = "[-] fixture failure`nto${paragraphSeparator}ken:`nparent-unicode-paragraph-separator-credential`nExpected: parent-unicode-paragraph-separator-context" },
            [pscustomobject]@{ Name = 'unicode-variation'; Text = "[-] fixture failure`nto${variationSelector}ken:`nparent-unicode-variation-credential`nExpected: parent-unicode-variation-context" },
            [pscustomobject]@{ Name = 'block'; Text = "[-] fixture failure`ntoken: |-`nparent-block-credential`nExpected: parent-block-context" }
        )
        $parentLeaks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($case in $parentCases) {
            $caseDiagnostic = ConvertTo-PesterShardSanitizedDiagnosticText -Text $case.Text
            if ($caseDiagnostic -match "parent-$($case.Name)-(?:credential|context)") { [void]$parentLeaks.Add($case.Name) }
        }
        $parentCredentialLabelDiagnostic = ConvertTo-PesterShardSanitizedDiagnosticText -Text "credentials:`nq7F9ParentOpaqueValue`n[-] fixture failure"
        if ($parentCredentialLabelDiagnostic -match 'q7F9ParentOpaqueValue') { [void]$parentLeaks.Add('credential-label') }
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text $visibleReplacementCharacters) $visibleReplacementCharacters 'Visible object and replacement glyphs must remain actionable parent diagnostics.'

        $childScriptAssignment = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$childScript'
        }, $true)
        Assert-True ($null -ne $childScriptAssignment) 'The shard executor must define its generated child script.'
        $PesterVersion = '4.10.1'
        $childScriptText = Invoke-Expression $childScriptAssignment.Right.Extent.Text
        $encodedChildScriptText = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScriptText))
        $childCommandLineLength = ('-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedChildScriptText).Length
        Assert-True ($childCommandLineLength -le 32000) "The generated child command line must retain safety headroom below the Windows 32,767-character limit. Actual=$childCommandLineLength."
        $childTokens = $null
        $childErrors = $null
        $childAst = [Management.Automation.Language.Parser]::ParseInput($childScriptText, [ref]$childTokens, [ref]$childErrors)
        Assert-Equal @($childErrors).Count 0 'The generated child script must parse before early-failure diagnostic testing.'
        $childTerminalControlFunction = $childAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Remove-PesterShardTerminalControlSequences'
        }, $true)
        Assert-True ($null -ne $childTerminalControlFunction) 'The generated child must embed the same bounded terminal-control scanner.'
        Invoke-Expression $childTerminalControlFunction.Extent.Text
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${colonColor}context${ansiReset}") 'safe context' 'The generated child must preserve valid colon-form RGB SGR formatting.'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text "safe ${differentColors}context${ansiReset}") 'safe context' 'The generated child must preserve different foreground and background colors.'
        Assert-Equal (Remove-PesterShardTerminalControlSequences -Text $visibleReplacementCharacters) $visibleReplacementCharacters 'Visible object and replacement glyphs must remain actionable generated-child diagnostics.'
        $childDiagnosticFunction = $childAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'ConvertTo-PesterShardEarlyFailureDiagnostic'
        }, $true)
        Assert-True ($null -ne $childDiagnosticFunction) 'The generated child script must define its early-failure diagnostic sanitizer.'
        Invoke-Expression $childDiagnosticFunction.Extent.Text
        try { throw [InvalidOperationException]::new("[+] InterT10_requires_explicit_authorization_before_git_index_changes 1s`n[-] child actionable failure`nExpected: child actionable expectation") }
        catch { $childAuthorizationProgress = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_ }
        Assert-Match $childAuthorizationProgress '\[-\] child actionable failure' 'The generated child sanitizer must not treat authorization in an ordinary test name as a sensitive field.'
        Assert-Match $childAuthorizationProgress 'Expected: child actionable expectation' 'The generated child sanitizer must retain actionable context after an ordinary authorization test name.'
        $childCases = @(
            [pscustomobject]@{ Name = 'blank'; Text = "fixture failure`nAuthorization:`n`nearly-child-blank-credential`nExpected: early-child-blank-context" },
            [pscustomobject]@{ Name = 'private-key-label'; Text = "fixture failure`nprivateKey:`n-----BEGIN PRIVATE KEY-----`nearly-child-private-key-label-credential`n-----END PRIVATE KEY-----`nExpected: early-child-private-key-label-context" },
            [pscustomobject]@{ Name = 'access-key-label'; Text = "fixture failure`naccess_key:`nearly-child-access-key-label-credential`nExpected: early-child-access-key-label-context" },
            [pscustomobject]@{ Name = 'set-cookie-label'; Text = "Set-Cookie: session_id=early-child-set-cookie-label-credential; HttpOnly`n[-] fixture failure`nExpected: early-child-set-cookie-label-context" },
            [pscustomobject]@{ Name = 'session-id-label'; Text = "session_id: early-child-session-id-label-credential`n[-] fixture failure`nExpected: early-child-session-id-label-context" },
            [pscustomobject]@{ Name = 'osc'; Text = "fixture failure`n`"token`":$osc`nearly-child-osc-credential`nExpected: early-child-osc-context" },
            [pscustomobject]@{ Name = 'dcs'; Text = "fixture failure`n`"token`":$dcs`nearly-child-dcs-credential`nExpected: early-child-dcs-context" },
            [pscustomobject]@{ Name = 'c1'; Text = "fixture failure`n`"token`":$c1Csi`nearly-child-c1-credential`nExpected: early-child-c1-context" },
            [pscustomobject]@{ Name = 'esc-csi-incomplete'; Text = "fixture failure`nto${escape}[31`nken:`nearly-child-esc-csi-incomplete-credential`nExpected: early-child-esc-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'c1-csi-incomplete'; Text = "fixture failure`nto$([char]0x9B)31`nken:`nearly-child-c1-csi-incomplete-credential`nExpected: early-child-c1-csi-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-intermediate-incomplete'; Text = "fixture failure`nto${escape}(`nken:`nearly-child-esc-intermediate-incomplete-credential`nExpected: early-child-esc-intermediate-incomplete-context" },
            [pscustomobject]@{ Name = 'esc-low-final'; Text = "fixture failure`nto${escape}#8ken:`nearly-child-esc-low-final-credential`nExpected: early-child-esc-low-final-context" },
            [pscustomobject]@{ Name = 'cursor-bs'; Text = "fixture failure`ntox${backspace}ken:`nearly-child-cursor-bs-credential`nExpected: early-child-cursor-bs-context" },
            [pscustomobject]@{ Name = 'cursor-csi'; Text = "fixture failure`ntox${cursorLeft}ken:`nearly-child-cursor-csi-credential`nExpected: early-child-cursor-csi-context" },
            [pscustomobject]@{ Name = 'cursor-cr'; Text = "fixture failure`ntox`rken:`nearly-child-cursor-cr-credential`nExpected: early-child-cursor-cr-context" },
            [pscustomobject]@{ Name = 'cursor-c1'; Text = "fixture failure`ntox${c1Index}ken:`nearly-child-cursor-c1-credential`nExpected: early-child-cursor-c1-context" },
            [pscustomobject]@{ Name = 'sgr-conceal'; Text = "fixture failure`nto${escape}[8mx${ansiReset}ken:`nearly-child-sgr-conceal-credential`nExpected: early-child-sgr-conceal-context" },
            [pscustomobject]@{ Name = 'sgr-equal-colon'; Text = "fixture failure`nto${escape}[38:2::255:0:0;48:2::255:0:0mx${ansiReset}ken:`nearly-child-sgr-equal-colon-credential`nExpected: early-child-sgr-equal-colon-context" },
            [pscustomobject]@{ Name = 'sgr-equal-indexed'; Text = "fixture failure`nto${escape}[38;5;8m${escape}[48;5;8mx${ansiReset}ken:`nearly-child-sgr-equal-indexed-credential`nExpected: early-child-sgr-equal-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic'; Text = "fixture failure`nto${escape}[31;41mx${ansiReset}ken:`nearly-child-sgr-equal-basic-credential`nExpected: early-child-sgr-equal-basic-context" },
            [pscustomobject]@{ Name = 'sgr-equal-basic-indexed'; Text = "fixture failure`nto${escape}[31;48;5;1mx${ansiReset}ken:`nearly-child-sgr-equal-basic-indexed-credential`nExpected: early-child-sgr-equal-basic-indexed-context" },
            [pscustomobject]@{ Name = 'sgr-equal-normalized-index'; Text = "fixture failure`nto${escape}[38:5:01;48;5;1mx${ansiReset}ken:`nearly-child-sgr-equal-normalized-index-credential`nExpected: early-child-sgr-equal-normalized-index-context" },
            [pscustomobject]@{ Name = 'sgr-equal-default-space'; Text = "fixture failure`nto${escape}[38:2:0:255:0:0;48:2::255:0:0mx${ansiReset}ken:`nearly-child-sgr-equal-default-space-credential`nExpected: early-child-sgr-equal-default-space-context" },
            [pscustomobject]@{ Name = 'sgr-equal-fixed-cube'; Text = "fixture failure`nto${escape}[38:2::255:0:0;48;5;196mx${ansiReset}ken:`nearly-child-sgr-equal-fixed-cube-credential`nExpected: early-child-sgr-equal-fixed-cube-context" },
            [pscustomobject]@{ Name = 'sgr-equal-fixed-gray'; Text = "fixture failure`nto${escape}[38;5;244;48:2::128:128:128mx${ansiReset}ken:`nearly-child-sgr-equal-fixed-gray-credential`nExpected: early-child-sgr-equal-fixed-gray-context" },
            [pscustomobject]@{ Name = 'sgr-equal-state'; Text = "fixture failure`n${escape}[31;41m`nx${ansiReset}token:`nearly-child-sgr-equal-state-credential`nExpected: early-child-sgr-equal-state-context" },
            [pscustomobject]@{ Name = 'sgr-conceal-state'; Text = "fixture failure`n${escape}[8m`nx${escape}[28mtoken:`nearly-child-sgr-conceal-state-credential`nExpected: early-child-sgr-conceal-state-context" },
            [pscustomobject]@{ Name = 'sgr-malformed-color'; Text = "fixture failure`nto${escape}[38;5;999mx${ansiReset}ken:`nearly-child-sgr-malformed-color-credential`nExpected: early-child-sgr-malformed-color-context" },
            [pscustomobject]@{ Name = 'unicode-zero-width'; Text = "fixture failure`nto${zeroWidthSpace}ken:`nearly-child-unicode-zero-width-credential`nExpected: early-child-unicode-zero-width-context" },
            [pscustomobject]@{ Name = 'unicode-bidi'; Text = "fixture failure`nto${bidiOverride}ken:`nearly-child-unicode-bidi-credential`nExpected: early-child-unicode-bidi-context" },
            [pscustomobject]@{ Name = 'unicode-line-separator'; Text = "fixture failure`nto${lineSeparator}ken:`nearly-child-unicode-line-separator-credential`nExpected: early-child-unicode-line-separator-context" },
            [pscustomobject]@{ Name = 'unicode-paragraph-separator'; Text = "fixture failure`nto${paragraphSeparator}ken:`nearly-child-unicode-paragraph-separator-credential`nExpected: early-child-unicode-paragraph-separator-context" },
            [pscustomobject]@{ Name = 'unicode-variation'; Text = "fixture failure`nto${variationSelector}ken:`nearly-child-unicode-variation-credential`nExpected: early-child-unicode-variation-context" },
            [pscustomobject]@{ Name = 'block'; Text = "fixture failure`ntoken: >-`nearly-child-block-credential`nExpected: early-child-block-context" }
        )
        $childLeaks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($case in $childCases) {
            try { throw [InvalidOperationException]::new($case.Text) }
            catch { $caseDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_ }
            if ($caseDiagnostic -match "early-child-$($case.Name)-(?:credential|context)") { [void]$childLeaks.Add($case.Name) }
        }
        try { throw [InvalidOperationException]::new("credentials:`nq7F9ChildOpaqueValue`n[-] fixture failure") }
        catch { $childCredentialLabelDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_ }
        if ($childCredentialLabelDiagnostic -match 'q7F9ChildOpaqueValue') { [void]$childLeaks.Add('credential-label') }
        Assert-Equal ($parentLeaks.Count + $childLeaks.Count) 0 "Fail-closed continuation leaks: parent=[$($parentLeaks -join ', ')]; child=[$($childLeaks -join ', ')]."

        try {
            throw [InvalidOperationException]::new("fixture failure`nAuthorization:`nearly-child-credential-fragment-one`nearly-child-credential-fragment-two`n`nExpected: safe child context")
        }
        catch {
            $childFailureDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($childFailureDiagnostic -match 'early-child-credential-fragment-(?:one|two)') 'Early child result and stderr diagnostics must not retain any wrapped value after a sensitive header.'
        Assert-Match $childFailureDiagnostic 'fixture failure' 'Early child sanitization must preserve the exception summary.'
        Assert-False ($childFailureDiagnostic -match 'Expected: safe child context') 'Early child sanitization must remain fail closed across blank lines.'
        Assert-Match $childFailureDiagnostic 'redacted sensitive diagnostic continuation' 'Early child sanitization must emit only fixed markers after a sensitive header.'

        try {
            throw [InvalidOperationException]::new("fixture failure`nAuthorization:`n[-]early-child-boundary-credential`nExpected: early-child-expected-credential")
        }
        catch {
            $boundaryLookingChildDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($boundaryLookingChildDiagnostic -match 'early-child-(?:boundary|expected)-credential') 'The generated child sanitizer must not trust boundary-looking text while a sensitive continuation is active.'
        Assert-Match $boundaryLookingChildDiagnostic 'fixture failure' 'The generated child sanitizer must retain safe context that precedes the sensitive continuation.'

        try {
            throw [InvalidOperationException]::new("fixture failure`n`"token`":`nearly-child-quoted-key-credential`nExpected: early-child-quoted-key-context")
        }
        catch {
            $quotedKeyChildDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($quotedKeyChildDiagnostic -match 'early-child-quoted-key-(?:credential|context)') 'The generated child sanitizer must enable continuation redaction for quoted sensitive keys.'
        Assert-Match $quotedKeyChildDiagnostic 'fixture failure' 'The generated child sanitizer must retain safe context that precedes a quoted sensitive key.'

        try {
            throw [InvalidOperationException]::new("fixture failure`n`"token`":$ansiReset`nearly-child-ansi-key-credential`nExpected: early-child-ansi-key-context")
        }
        catch {
            $ansiKeyChildDiagnostic = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_
        }
        Assert-False ($ansiKeyChildDiagnostic -match 'early-child-ansi-key-(?:credential|context)') 'The generated child sanitizer must strip terminal formatting before classifying a sensitive continuation delimiter.'
        Assert-Match $ansiKeyChildDiagnostic 'fixture failure' 'ANSI normalization must retain safe context that precedes the sensitive block.'
    }

    # Scenario: The configured evidence directory is missing beneath a junction or symbolic-link ancestor.
    # Purpose: Reject the ancestor before New-Item can create any directory in the external target.
    It 'UnitT08_rejects_a_reparse_ancestor_before_creating_the_evidence_root' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $fixtureRoot = Join-Path $TestDrive 'precreate-evidence-root'
        $targetRoot = Join-Path $fixtureRoot 'target'
        $aliasRoot = Join-Path $fixtureRoot 'alias'
        $testRoot = Join-Path $fixtureRoot 'tests'
        $moduleRoot = Join-Path $fixtureRoot 'module'
        [void](New-Item -ItemType Directory -Path $targetRoot -Force)
        [void](New-Item -ItemType Directory -Path $testRoot -Force)
        [void](New-Item -ItemType Directory -Path $moduleRoot -Force)
        $linkType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $linkType -Path $aliasRoot -Target $targetRoot)
        Write-TestUtf8File -Path (Join-Path $testRoot 'fixture.Tests.ps1') -Text "Describe 'fixture' { It 'passes' { } }"
        Write-TestUtf8File -Path (Join-Path $moduleRoot 'Pester.psm1') -Text "function Invoke-Pester { }`nExport-ModuleMember -Function Invoke-Pester"
        Write-TestUtf8File -Path (Join-Path $moduleRoot 'Pester.psd1') -Text @'
@{
    RootModule = 'Pester.psm1'
    ModuleVersion = '4.10.1'
    GUID = 'a5e46c75-f24e-4c3f-baa2-57e93b50e620'
    FunctionsToExport = @('Invoke-Pester')
}
'@
        $evidenceRoot = Join-Path $aliasRoot 'must-not-be-created'
        $probeScript = @"
try {
    & '$($shardPath.Replace("'", "''"))' ``
        -PesterModulePath '$((Join-Path $moduleRoot 'Pester.psd1').Replace("'", "''"))' ``
        -PesterVersion '4.10.1' ``
        -ExpectedTotalCount 1 ``
        -ExpectedSkippedCount 0 ``
        -TestRoot '$($testRoot.Replace("'", "''"))' ``
        -EvidenceRoot '$($evidenceRoot.Replace("'", "''"))' ``
        -OuterTimeoutSeconds 5
}
catch {
    [Console]::Error.WriteLine([string]`$_.Exception.Message)
    exit 1
}
"@
        $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:PowerShellPath
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedProbe"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $probeProcess = New-Object Diagnostics.Process
        $probeProcess.StartInfo = $startInfo
        try {
            Assert-True $probeProcess.Start() 'The evidence-root pre-creation probe must start.'
            $probeStdout = $probeProcess.StandardOutput.ReadToEnd()
            $probeStderr = $probeProcess.StandardError.ReadToEnd()
            $probeProcess.WaitForExit()
            $probeExitCode = $probeProcess.ExitCode
        }
        finally { $probeProcess.Dispose() }
        $probeOutput = "$probeStdout`n$probeStderr"
        Assert-True ($probeExitCode -ne 0) 'A reparse-point evidence ancestor must be rejected.'
        Assert-Match $probeOutput 'Preflight evidence root contains a symlinked or reparse-point ancestor' 'The rejection must identify the evidence-root trust boundary.'
        Assert-False (Test-Path -LiteralPath (Join-Path $targetRoot 'must-not-be-created')) 'Evidence-root rejection must happen before the external target is mutated.'
    }

    # Scenario: A bounded stdout or stderr capture task faults after the child wrote otherwise successful result evidence.
    # Purpose: Make missing stream evidence a cleanup failure instead of accepting a completed shard.
    It 'UnitT09_fails_closed_when_bounded_output_capture_faults' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before capture-failure state testing.'
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resolve-PesterShardOutputFailure'
        }, $true)
        Assert-True ($null -ne $definition) 'The shard executor must define its bounded-capture failure transition.'
        Invoke-Expression $definition.Extent.Text

        $cleanup = [pscustomobject][ordered]@{ errors = @(); cleanedUp = $true }
        $faulted = Resolve-PesterShardOutputFailure `
            -Cleanup $cleanup `
            -Errors @('stderr bounded output capture failed: injected I/O fault') `
            -Status 'completed' `
            -ExceptionText $null
        Assert-Equal $faulted.status 'cleanup-failed' 'A capture task fault must override an otherwise completed shard.'
        Assert-False ([bool]$faulted.cleanup.cleanedUp) 'A capture task fault must invalidate cleanup evidence.'
        Assert-Match ($faulted.cleanup.errors -join ' | ') 'injected I/O fault' 'The capture fault must remain available in process evidence.'
        Assert-Match $faulted.exceptionText 'injected I/O fault' 'The capture fault must remain available to the caller.'

        $clean = Resolve-PesterShardOutputFailure `
            -Cleanup ([pscustomobject][ordered]@{ errors = @(); cleanedUp = $true }) `
            -Errors @() `
            -Status 'completed' `
            -ExceptionText $null
        Assert-Equal $clean.status 'completed' 'The normal completed path must remain unchanged when capture has no errors.'
        Assert-True ([bool]$clean.cleanup.cleanedUp) 'The normal completed path must preserve cleanup success.'
    }

    # Scenario: A bounded capture task faults while its child process is still running.
    # Purpose: Surface the fault immediately so the supervisor can break the live wait and start Job Object cleanup.
    It 'UnitT10_terminates_the_live_wait_when_bounded_capture_faults' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before live capture-fault testing.'
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-PesterShardLiveCaptureState'
        }, $true)
        Assert-True ($null -ne $definition) 'The shard executor must expose a testable live capture-state transition.'
        Invoke-Expression $definition.Extent.Text

        $faultSource = New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
        $faultSource.SetException((New-Object IO.IOException('injected live pipe fault')))
        $faulted = Get-PesterShardLiveCaptureState -Name 'stderr' -Task $faultSource.Task
        Assert-True ([bool]$faulted.isCompleted) 'A faulted live capture task must be recognized as completed.'
        Assert-True ([bool]$faulted.faulted) 'A faulted live capture task must be classified as a fault.'
        Assert-Match $faulted.error 'stderr bounded output capture failed:.*injected live pipe fault' 'The live fault must retain its stream and cause.'

        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardPath
        Assert-Match $source '\$captureFaultDetected\s*=\s*\$true' 'The live loop must record a detected capture fault.'
        Assert-Match $source 'if \(\$captureFaultDetected\) \{ break \}' 'The live loop must break immediately after a capture fault.'
    }

    # Scenario: Persisting bounded stdout or stderr evidence fails after capture and child completion.
    # Purpose: Prevent a successful shard result from being accepted without its bounded stream evidence.
    It 'UnitT11_fails_closed_when_bounded_output_evidence_cannot_be_persisted' {
        $shardPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        Assert-Equal @($errors).Count 0 'The shard executor must parse before output-persistence failure testing.'
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resolve-PesterShardOutputFailure'
        }, $true)
        Assert-True ($null -ne $definition) 'The shard executor must define its output-failure transition.'
        Invoke-Expression $definition.Extent.Text

        $faulted = Resolve-PesterShardOutputFailure `
            -Cleanup ([pscustomobject][ordered]@{ errors = @(); cleanedUp = $true }) `
            -Errors @('stdout evidence write failed: injected disk fault') `
            -Status 'completed' `
            -ExceptionText $null
        Assert-Equal $faulted.status 'cleanup-failed' 'An output evidence write fault must override an otherwise completed shard.'
        Assert-False ([bool]$faulted.cleanup.cleanedUp) 'An output evidence write fault must invalidate cleanup evidence.'
        Assert-Match ($faulted.cleanup.errors -join ' | ') 'injected disk fault' 'The output evidence write fault must remain in process evidence.'

        $startupFault = Resolve-PesterShardOutputFailure `
            -Cleanup ([pscustomobject][ordered]@{ cleanedUp = $true; reason = 'process-not-started' }) `
            -Errors @('stderr evidence write failed: injected startup disk fault') `
            -Status 'startup-failed' `
            -ExceptionText $null
        Assert-Equal $startupFault.status 'cleanup-failed' 'An output write fault before process start must still fail closed.'
        Assert-Match ($startupFault.cleanup.errors -join ' | ') 'injected startup disk fault' 'A pre-start cleanup shape must gain output-write error evidence safely.'

        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $shardPath
        $writeFailureIndex = $source.IndexOf('$outputWriteError = "stdout evidence write failed:', [StringComparison]::Ordinal)
        $failClosedIndex = $source.IndexOf('-Errors @($outputWriteError)', [StringComparison]::Ordinal)
        Assert-True ($writeFailureIndex -ge 0 -and $failClosedIndex -gt $writeFailureIndex) 'Output write failures must enter the fail-closed transition before process evidence is finalized.'
    }

    # Scenario: Stream capture aborts after the fixture runner process has started but before the normal wait completes.
    # Purpose: Terminate and wait for the owned runner process tree before releasing its process handle.
    It 'UnitT12_terminates_the_runner_fixture_when_capture_aborts_after_start' {
        $precedenceProbe = New-Object InvalidOperationException('Injected runner fixture capture failure after process start.')
        Resolve-RunnerFixtureCleanupFailure `
            -PrimaryException $precedenceProbe `
            -CleanupErrors @('Injected runner fixture cleanup failure after process start.')
        Assert-Match $precedenceProbe.Message 'Injected runner fixture capture failure after process start' 'Cleanup diagnostics must not replace the primary fixture failure.'
        Assert-Match ([string]$precedenceProbe.Data['RunnerCleanupError']) 'Injected runner fixture cleanup failure after process start' 'Cleanup diagnostics must remain attached to the primary fixture failure.'

        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'fixture-capture-abort') -Behavior 'timeout'
        $caught = $null
        try {
            [void](Invoke-RunnerFixture -Fixture $fixture -InjectCaptureFailureAfterStart)
        }
        catch { $caught = $_ }

        Assert-True ($null -ne $caught) 'The injected post-start capture failure must reach the caller.'
        Assert-Match $caught.Exception.Message 'Injected runner fixture capture failure after process start' 'The injected failure must remain distinguishable from cleanup failures.'
        $runnerProcessId = [int]$caught.Exception.Data['RunnerProcessId']
        Assert-True ($runnerProcessId -gt 0) 'The injected failure must retain the started runner PID for cleanup verification.'

        $processStillRunning = $false
        $probe = $null
        try {
            $probe = [Diagnostics.Process]::GetProcessById($runnerProcessId)
            $processStillRunning = -not $probe.HasExited
        }
        catch [ArgumentException] { $processStillRunning = $false }
        finally { if ($null -ne $probe) { $probe.Dispose() } }
        Assert-False $processStillRunning 'The fixture runner must not survive a post-start capture failure.'
    }

    # Scenario: A value-bearing runner option is deliberately supplied as an empty string.
    # Purpose: Preserve the empty record in the counted base64 transport instead of shifting subsequent parameters.
    It 'UnitT13_preserves_empty_values_in_runner_fixture_argument_transport' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'fixture-empty-argument')
        $result = Invoke-RunnerFixture -Fixture $fixture -SourceRepository ''

        Assert-True ($result.ExitCode -ne 0) 'The runner must reject an explicitly empty mandatory source repository.'
        Assert-Match $result.Output 'SourceRepository|ParameterArgumentValidationErrorEmptyStringNotAllowed,Invoke-StandardValidation\.ps1' 'The empty value must reach the runner parameter binder.'
        Assert-False ($result.Output -match 'argument name is invalid|not allowed or has no value|argument count mismatch') 'The bootstrap must not drop the empty record or shift later parameters.'
    }

    # Scenario: A production adapter tries to bind a resolver receipt from a different slot,
    # or reaches the artifact root through a symlinked ancestor.
    # Purpose: Keep tool-role provenance and checkout-external artifact boundaries authoritative.
    It 'InterT07_rejects_cross_slot_receipts_and_symlinked_root_ancestors' {
        $functionRoot = Join-Path $TestDrive 'central-boundary-functions'
        [void](New-Item -ItemType Directory -Path $functionRoot -Force)
        . $script:RunnerPath `
            -CandidateRoot (Join-Path $functionRoot 'candidate') `
            -AdapterPath (Join-Path $functionRoot 'adapter.json') `
            -ArtifactsRoot (Join-Path $functionRoot 'artifacts') `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $functionRoot `
            -DefineFunctionsOnly

        $wrongRoleRejected = $false
        try {
            Assert-StandardValidationToolReceipt `
                -Provenance ([pscustomobject][ordered]@{
                    toolName = 'skill-validator'
                    receiptPath = [IO.Path]::GetFullPath((Join-Path $functionRoot 'missing-receipt.json'))
                    receiptSha256 = ('0' * 64)
                }) `
                -CommandPath (Join-Path $functionRoot 'missing-command') `
                -CandidateRoot (Join-Path $functionRoot 'candidate') `
                -ArtifactsRoot (Join-Path $functionRoot 'artifacts') `
                -TrustAnchorRoot $functionRoot `
                -RunId ([guid]::NewGuid()) `
                -ExpectedToolName 'skill-tools' `
                -Context 'cross-slot receipt' | Out-Null
        }
        catch {
            $wrongRoleRejected = $true
            Assert-Match $_.Exception.Message 'expected canonical tool role' 'A receipt from another adapter slot must be rejected before receipt I/O.'
        }
        Assert-True $wrongRoleRejected 'A cross-slot resolver receipt must never be accepted.'

        Assert-StandardValidationImmutableArchiveUrl `
            -SourceRepository 'https://github.com/org/repo.git' `
            -SourceRevision ('a' * 40) `
            -ArchiveUrl ('https://github.com/org/repo/archive/' + ('a' * 40) + '.zip') `
            -Context 'valid archive URL'
        $wrongRepositoryRejected = $false
        try {
            Assert-StandardValidationImmutableArchiveUrl `
                -SourceRepository 'https://github.com/org/repo.git' `
                -SourceRevision ('a' * 40) `
                -ArchiveUrl ('https://github.com/org/repository/archive/' + ('a' * 40) + '.zip') `
                -Context 'wrong repository archive URL'
        }
        catch {
            $wrongRepositoryRejected = $true
            Assert-Match $_.Exception.Message 'not bound to the source repository' 'A repository-name prefix collision in an archive URL must be rejected.'
        }
        Assert-True $wrongRepositoryRejected 'An archive URL for a repository sharing the source-name prefix must fail closed.'

        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Unix) { return }
        $symlinkRoot = Join-Path $TestDrive 'symlinked-artifact-ancestor'
        $targetRoot = Join-Path $symlinkRoot 'target'
        $aliasRoot = Join-Path $symlinkRoot 'alias'
        [void](New-Item -ItemType Directory -Path $targetRoot -Force)
        [void](New-Item -ItemType SymbolicLink -Path $aliasRoot -Target $targetRoot)
        $symlinkRejected = $false
        try {
            Assert-StandardValidationCanonicalRootPath `
                -Path (Join-Path $aliasRoot 'output') `
                -Context 'symlinked artifact root' | Out-Null
        }
        catch {
            $symlinkRejected = $true
            Assert-Match $_.Exception.Message 'symlinked or reparse-point ancestor' 'A symlinked artifact-root ancestor must be rejected.'
        }
        Assert-True $symlinkRejected 'An artifact root reached through a symlinked ancestor must fail closed.'
    }

    # Scenario: A production adapter attempts to execute a payload through a generic interpreter.
    # Purpose: Prevent an untrusted -File/-c payload from becoming a pre-Static trusted command.
    It 'InterT05_rejects_generic_interpreter_payloads_in_production_adapters' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'production-interpreter')
        $adapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $fixture.Adapter | ConvertFrom-Json
        $adapter.mode = 'production'
        Write-TestUtf8File -Path $fixture.Adapter -Text ($adapter | ConvertTo-Json -Depth 20)
        $result = Invoke-RunnerFixture -Fixture $fixture -DevelopmentHarness:$false
        Assert-Equal $result.Evidence.state 'INVALID' 'Production adapters must reject incomplete or unsafe acquisition before execution.'
        Assert-Match $result.Output 'generic interpreter|direct executable|Production validation requires' 'The invalid result must explain the production boundary.'
        Assert-False (Test-Path -LiteralPath $fixture.Log -PathType Leaf) 'A rejected interpreter payload must not execute package validation.'

        $runIdFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'caller-run-id')
        $runIdResult = Invoke-RunnerFixture -Fixture $runIdFixture -DevelopmentHarness:$false -ValidationRunId ('a' * 32)
        Assert-Equal $runIdResult.Evidence.state 'INVALID' 'Production validation must reject a caller-selected run ID.'
        Assert-Match $runIdResult.Output 'generated by the trusted supervisor|caller' 'Run-ID replay rejection must identify the trusted supervisor boundary.'

        $missingBindingFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'missing-launch-binding')
        $missingBindingResult = Invoke-RunnerFixture -Fixture $missingBindingFixture -DevelopmentHarness:$false
        Assert-Equal $missingBindingResult.Evidence.state 'INVALID' 'Production validation must reject a missing supervisor launch binding.'
        Assert-Equal $missingBindingResult.Evidence.launchBinding.status 'unverified-production' 'A rejected production launch binding must not be labeled as a development harness.'
        Assert-Match $missingBindingResult.Output 'SupervisorLaunchBindingPath|launch binding' 'The missing launch binding must identify the trusted supervisor boundary.'

        $credentialFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'credentialed-source-repository')
        $credentialResult = Invoke-RunnerFixture `
            -Fixture $credentialFixture `
            -SourceRepository 'https://token@github.com/org/repo.git'
        Assert-Match $credentialResult.Output '"state"\s*:\s*"INVALID"' 'Source repositories with embedded credentials must be rejected before evidence construction.'
        $credentialEvidenceText = if ($null -eq $credentialResult.Evidence) { '' } else { $credentialResult.Evidence | ConvertTo-Json -Depth 20 -Compress }
        Assert-False (($credentialResult.Output + $credentialEvidenceText) -match 'token') 'Rejected source-repository credentials must never appear in output or evidence.'
    }

    # Scenario: A production adapter carries a freshly signed resolver receipt and a trusted supervisor launch binding.
    # Purpose: Authenticate the supervisor-to-resolver handoff before receipt validation, then bind every slot to the same run.
    It 'UnitT01_authenticates_supervisor_launch_binding_before_signed_resolver_receipt' {
        $root = Join-Path $TestDrive 'production-run-id-derivation'
        $candidateRoot = Join-Path $root 'candidate'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedRoot = Join-Path $root 'trusted'
        foreach ($path in @($candidateRoot, $artifactsRoot, $trustedRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }

        . $script:RunnerPath `
            -CandidateRoot $candidateRoot `
            -AdapterPath (Join-Path $root 'adapter.json') `
            -ArtifactsRoot $artifactsRoot `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $trustedRoot `
            -DefineFunctionsOnly

        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            Write-TestUtf8File -Path (Join-Path $trustedRoot 'trusted-supervisor-public-key.xml') -Text $rsa.ToXmlString($false)
            $installRoot = Join-Path $trustedRoot 'fixture-tool'
            [void](New-Item -ItemType Directory -Path $installRoot -Force)
            $commandPath = Join-Path $installRoot 'fixture-tool.bin'
            Write-TestUtf8File -Path $commandPath -Text 'trusted fixture executable bytes'
            $executableSha256 = Get-StandardValidationFileSha256 -Path $commandPath -Context 'test resolver executable'
            $installedInventory = Get-StandardValidationInventory -Root $installRoot -Context 'test resolver closure'
            $installedClosureSha256 = Get-StandardValidationInventorySha256 -Inventory $installedInventory
            $launcher = [ordered]@{
                kind = 'direct-executable'
                shimPath = $null
                shimSha256 = $null
                payloadPath = $null
                payloadSha256 = $null
                runtimePath = $null
                runtimeSha256 = $null
            }
            $launcherDigestSha256 = Get-StandardValidationLauncherDigest -Launcher $launcher -Context 'test resolver launcher'
            $productionGuid = [guid]::NewGuid()
            $runIdText = $productionGuid.ToString('N')
            $resolvedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            $fields = @{
                channel = 'latest-stable'
                executablePath = [IO.Path]::GetFullPath($commandPath)
                executableSha256 = $executableSha256
                installedClosureSha256 = $installedClosureSha256
                installRoot = [IO.Path]::GetFullPath($installRoot)
                launcherDigestSha256 = $launcherDigestSha256
                issuedAt = $resolvedAtUtc
                resolvedIdentity = 'fixture-tool@1.0.0'
                resolvedVersion = '1.0.0'
                resolutionRunId = $runIdText
                resolvedAtUtc = $resolvedAtUtc
                source = 'https://example.com/fixture-tool'
                status = 'verified'
                toolName = 'package-adapter'
            }
            $attestation = [ordered]@{
                schemaVersion = 1
                attestationType = 'trusted-supervisor-validation-tool-v1'
                toolName = 'package-adapter'
                source = 'https://example.com/fixture-tool'
                channel = 'latest-stable'
                status = 'verified'
                resolvedVersion = '1.0.0'
                resolvedIdentity = 'fixture-tool@1.0.0'
                installRoot = [IO.Path]::GetFullPath($installRoot)
                executablePath = [IO.Path]::GetFullPath($commandPath)
                executableSha256 = $executableSha256
                installedClosureSha256 = $installedClosureSha256
                launcherDigestSha256 = $launcherDigestSha256
                resolutionRunId = $runIdText
                resolvedAtUtc = $resolvedAtUtc
                issuedAt = $resolvedAtUtc
                signature = $null
            }
            $payload = Get-StandardValidationSignedReceiptPayload -ReceiptType 'validation-tool-v1' -Fields $fields
            $attestation.signature = [Convert]::ToBase64String($rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($payload), 'SHA256'))
            $receipt = [ordered]@{
                schemaVersion = 1
                evidenceType = 'validation-tool-resolution'
                status = 'verified'
                toolName = 'package-adapter'
                source = 'https://example.com/fixture-tool'
                channel = 'latest-stable'
                resolvedVersion = '1.0.0'
                resolvedIdentity = 'fixture-tool@1.0.0'
                installRoot = [IO.Path]::GetFullPath($installRoot)
                executablePath = [IO.Path]::GetFullPath($commandPath)
                executableSha256 = $executableSha256
                installedClosureSha256 = $installedClosureSha256
                launcher = $launcher
                launcherDigestSha256 = $launcherDigestSha256
                resolutionRunId = $runIdText
                resolvedAtUtc = $resolvedAtUtc
                attestation = $attestation
            }
            $receiptPath = Join-Path $trustedRoot 'fixture-tool-receipt.json'
            Write-TestUtf8File -Path $receiptPath -Text ($receipt | ConvertTo-Json -Depth 20)
            $receiptSha256 = Get-StandardValidationFileSha256 -Path $receiptPath -Context 'test resolver receipt'
            $adapterPath = Join-Path $root 'adapter.json'
            Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
            $adapterSha256 = Get-StandardValidationFileSha256 -Path $adapterPath -Context 'test adapter'
            $outputPath = Join-Path $artifactsRoot 'evidence.json'
            $authorityRevision = 'c' * 40
            $candidateArchiveSha256 = 'd' * 64
            $bindingIssuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
            $bindingExpiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')
            $consumptionPath = Join-Path $root 'launch-consumption.json'
            $bindingFields = @{
                adapterPath = [IO.Path]::GetFullPath($adapterPath)
                adapterSha256 = $adapterSha256
                artifactsRoot = [IO.Path]::GetFullPath($artifactsRoot)
                authorityRevision = $authorityRevision
                baseRevision = 'b' * 40
                candidateArchiveSha256 = $candidateArchiveSha256
                candidateRoot = [IO.Path]::GetFullPath($candidateRoot)
                consumptionPath = [IO.Path]::GetFullPath($consumptionPath)
                eventName = 'local'
                expiresAt = $bindingExpiresAt
                issuedAt = $bindingIssuedAt
                outputPath = [IO.Path]::GetFullPath($outputPath)
                resolutionRunId = $runIdText
                sourceRepository = 'https://example.com/example/skills.git'
                sourceRevision = 'a' * 40
                trustedToolRoot = [IO.Path]::GetFullPath($trustedRoot)
            }
            $launchBinding = [ordered]@{
                schemaVersion = 1
                evidenceType = 'validation-launch-binding'
                status = 'issued'
                candidateRoot = [IO.Path]::GetFullPath($candidateRoot)
                adapterPath = [IO.Path]::GetFullPath($adapterPath)
                artifactsRoot = [IO.Path]::GetFullPath($artifactsRoot)
                outputPath = [IO.Path]::GetFullPath($outputPath)
                trustedToolRoot = [IO.Path]::GetFullPath($trustedRoot)
                sourceRepository = 'https://example.com/example/skills.git'
                sourceRevision = 'a' * 40
                baseRevision = 'b' * 40
                eventName = 'local'
                candidateArchiveSha256 = $candidateArchiveSha256
                adapterSha256 = $adapterSha256
                authorityRevision = $authorityRevision
                resolutionRunId = $runIdText
                issuedAt = $bindingIssuedAt
                expiresAt = $bindingExpiresAt
                consumptionPath = [IO.Path]::GetFullPath($consumptionPath)
                signature = $null
            }
            $bindingPayload = Get-StandardValidationSignedReceiptPayload -ReceiptType 'validation-launch-v1' -Fields $bindingFields
            $launchBinding.signature = [Convert]::ToBase64String($rsa.SignData((New-Object Text.UTF8Encoding($false)).GetBytes($bindingPayload), 'SHA256'))
            $bindingPath = Join-Path $root 'launch-binding.json'
            Write-TestUtf8File -Path $bindingPath -Text ($launchBinding | ConvertTo-Json -Depth 20)
            $bindingSha256 = Get-StandardValidationFileSha256 -Path $bindingPath -Context 'test launch binding'
            $adapterSnapshot = Get-StandardValidationJsonSnapshot -Path $adapterPath -Context 'adapter substitution snapshot'
            Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":2}'
            Assert-Equal $adapterSnapshot.value.schemaVersion 1 'The adapter snapshot must retain the bytes parsed before a path substitution.'
            $substitutionBinding = Assert-StandardValidationSupervisorLaunchBinding `
                -Path $bindingPath `
                -CandidateRoot $candidateRoot `
                -AdapterPath $adapterPath `
                -AdapterSha256 $adapterSnapshot.sha256 `
                -ArtifactsRoot $artifactsRoot `
                -OutputPath $outputPath `
                -TrustedToolRoot $trustedRoot `
                -SourceRepository 'https://example.com/example/skills.git' `
                -SourceRevision ('a' * 40) `
                -BaseRevision ('b' * 40) `
                -EventName 'local' `
                -CandidateArchiveSha256 $candidateArchiveSha256 `
                -AuthorityRevision $authorityRevision `
                -TrustAnchorRoot $trustedRoot `
                -Context 'adapter substitution snapshot'
            Assert-Equal $substitutionBinding.resolutionRunId $runIdText 'The launch binding must authenticate the immutable adapter snapshot rather than rereading a substituted path.'
            Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
            $validatedBinding = Assert-StandardValidationSupervisorLaunchBinding `
                -Path $bindingPath `
                -CandidateRoot $candidateRoot `
                -AdapterPath $adapterPath `
                -AdapterSha256 $adapterSha256 `
                -ArtifactsRoot $artifactsRoot `
                -OutputPath $outputPath `
                -TrustedToolRoot $trustedRoot `
                -SourceRepository 'https://example.com/example/skills.git' `
                -SourceRevision ('a' * 40) `
                -BaseRevision ('b' * 40) `
                -EventName 'local' `
                -CandidateArchiveSha256 $candidateArchiveSha256 `
                -AuthorityRevision $authorityRevision `
                -TrustAnchorRoot $trustedRoot `
                -Context 'test supervisor launch binding'
            Assert-Equal $validatedBinding.resolutionRunId $runIdText 'The trusted launch binding must carry the supervisor-generated N-format run ID.'
            Assert-StandardValidationLaunchBindingUnchanged -Binding $validatedBinding

            $spec = [pscustomobject][ordered]@{
                command = [IO.Path]::GetFullPath($commandPath)
                arguments = [object[]]@()
                provenance = [pscustomobject][ordered]@{
                    toolName = 'package-adapter'
                    receiptPath = [IO.Path]::GetFullPath($receiptPath)
                    receiptSha256 = $receiptSha256
                }
            }
            $adapter = [pscustomobject][ordered]@{ packageAdapter = $spec }
            $derivedRunId = Get-StandardValidationProductionRunId `
                -Adapter $adapter `
                -CandidateRoot $candidateRoot `
                -ArtifactsRoot $artifactsRoot `
                -TrustedToolRoot $trustedRoot `
                -TrustAnchorRoot $trustedRoot `
                -ExpectedRunId $productionGuid `
                -ExpectedLaunchIssuedAt $validatedBinding.issuedAt
            Assert-Equal $derivedRunId.ToString('N') $runIdText 'Production run ID must come from the authenticated supervisor launch binding and signed resolver receipt.'

            $bindingReplayRejected = $false
            try {
                Assert-StandardValidationSupervisorLaunchBinding `
                    -Path $bindingPath `
                    -CandidateRoot $candidateRoot `
                    -AdapterPath $adapterPath `
                    -AdapterSha256 $adapterSha256 `
                    -ArtifactsRoot (Join-Path $root 'replayed-artifacts') `
                    -OutputPath (Join-Path $root 'replayed-artifacts/evidence.json') `
                    -TrustedToolRoot $trustedRoot `
                    -SourceRepository 'https://example.com/example/skills.git' `
                    -SourceRevision ('a' * 40) `
                    -BaseRevision ('b' * 40) `
                    -EventName 'local' `
                    -CandidateArchiveSha256 $candidateArchiveSha256 `
                    -AuthorityRevision $authorityRevision `
                    -TrustAnchorRoot $trustedRoot `
                    -Context 'replayed launch binding' | Out-Null
            }
            catch {
                $bindingReplayRejected = $true
                Assert-Match $_.Exception.Message 'different artifactsRoot' 'A signed launch binding must not be replayable into a different artifact root.'
            }
            Assert-True $bindingReplayRejected 'A signed launch binding must bind the artifact root used by the current invocation.'

            $replayRejected = $false
            try {
                Get-StandardValidationProductionRunId `
                    -Adapter $adapter `
                    -CandidateRoot $candidateRoot `
                    -ArtifactsRoot $artifactsRoot `
                    -TrustedToolRoot $trustedRoot `
                    -TrustAnchorRoot $trustedRoot `
                    -ExpectedRunId ([guid]::NewGuid()) | Out-Null
            }
            catch {
                $replayRejected = $true
                Assert-Match $_.Exception.Message 'different validation run|current trusted-supervisor validation run' 'A signed receipt from an earlier run must be rejected for a new supervisor run.'
            }
            Assert-True $replayRejected 'A still-fresh signed resolver receipt must not be replayable into a new validation run.'

            $validated = Assert-StandardValidationCommandSpec `
                -Spec $spec `
                -Context 'production run-id binding' `
                -CandidateRoot $candidateRoot `
                -ArtifactsRoot $artifactsRoot `
                -TrustedToolRoot $trustedRoot `
                -TrustAnchorRoot $trustedRoot `
                -RunId $derivedRunId `
                -ExpectedToolName 'package-adapter' `
                -DevelopmentHarness:$false
            Assert-Equal $validated.toolReceipt.runId.ToString('N') $runIdText 'The full production command validation must preserve the derived run ID.'

            $script:OriginalLaunchBindingSnapshot = (Get-Command Get-StandardValidationJsonSnapshot -CommandType Function).ScriptBlock
            $script:OriginalLaunchBindingJson = (Get-Command Get-StandardValidationJson -CommandType Function).ScriptBlock
            $script:BindingSubstitutionPath = [IO.Path]::GetFullPath($bindingPath)
            function Get-StandardValidationJsonSnapshot {
                param([string] $Path, [string] $Context)
                $snapshot = & $script:OriginalLaunchBindingSnapshot -Path $Path -Context $Context
                if ([IO.Path]::GetFullPath($Path) -ceq $script:BindingSubstitutionPath) {
                    Write-TestUtf8File -Path $Path -Text '{"replacement":true}'
                }
                return $snapshot
            }
            function Get-StandardValidationJson {
                param([string] $Path, [string] $Context)
                $value = & $script:OriginalLaunchBindingJson -Path $Path -Context $Context
                if ([IO.Path]::GetFullPath($Path) -ceq $script:BindingSubstitutionPath) {
                    Write-TestUtf8File -Path $Path -Text '{"replacement":true}'
                }
                return $value
            }
            $snapshotBinding = Assert-StandardValidationSupervisorLaunchBinding `
                -Path $bindingPath `
                -CandidateRoot $candidateRoot `
                -AdapterPath $adapterPath `
                -AdapterSha256 $adapterSha256 `
                -ArtifactsRoot $artifactsRoot `
                -OutputPath $outputPath `
                -TrustedToolRoot $trustedRoot `
                -SourceRepository 'https://example.com/example/skills.git' `
                -SourceRevision ('a' * 40) `
                -BaseRevision ('b' * 40) `
                -EventName 'local' `
                -CandidateArchiveSha256 $candidateArchiveSha256 `
                -AuthorityRevision $authorityRevision `
                -TrustAnchorRoot $trustedRoot `
                -Context 'launch binding substitution snapshot'
            Assert-Equal $snapshotBinding.sha256 $bindingSha256 'The launch-binding evidence hash must come from the authenticated byte snapshot.'
            Assert-False ((Get-StandardValidationFileSha256 -Path $bindingPath -Context 'substituted launch binding') -ceq $bindingSha256) 'The binding substitution regression must replace the live path after snapshot capture.'
            Write-TestUtf8File -Path $bindingPath -Text ($launchBinding | ConvertTo-Json -Depth 20)
        }
        finally { $rsa.Dispose() }
    }

    # Scenario: The public production runner must consume the exact run-ID format emitted by the authenticated launch-binding helper.
    # Purpose: Exercise Invoke-StandardValidationRun through the launch-binding handoff before the authority gate, so a format mismatch cannot hide behind helper-only coverage.
    It 'UnitT02_public_production_path_preserves_authenticated_launch_run_id_format' {
        $root = Join-Path $TestDrive 'public-production-launch-binding'
        $candidateRoot = Join-Path $root 'candidate'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedRoot = Join-Path $root 'trusted'
        foreach ($path in @($candidateRoot, $artifactsRoot, $trustedRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        $adapterPath = Join-Path $root 'adapter.json'
        $bindingPath = Join-Path $root 'launch-binding.json'
        $consumptionPath = Join-Path $root 'launch-consumption.json'
        $outputPath = Join-Path $artifactsRoot 'evidence.json'
        . $script:RunnerPath `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $trustedRoot `
            -DefineFunctionsOnly
        Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
        Write-TestUtf8File -Path $bindingPath -Text '{"fixture":true}'
        $bindingSha256 = Get-StandardValidationFileSha256 -Path $bindingPath -Context 'public launch binding fixture'
        $publicRunGuid = [guid]::NewGuid()
        $publicRunIdText = $publicRunGuid.ToString('N')
        $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        $expiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')

        $script:PublicLaunchBindingPath = $bindingPath
        $script:PublicLaunchBindingSha256 = $bindingSha256
        $script:PublicLaunchBindingRunIdText = $publicRunIdText
        $script:PublicLaunchBindingIssuedAt = $issuedAt
        $script:PublicLaunchBindingExpiresAt = $expiresAt
        $script:PublicLaunchBindingConsumptionPath = $consumptionPath
        $script:PublicLaunchBindingAdapterSha256 = $null
        function Assert-StandardValidationSupervisorLaunchBinding {
            param([string] $AdapterSha256)
            $script:PublicLaunchBindingAdapterSha256 = $AdapterSha256
            return [pscustomobject][ordered]@{
                status = 'verified'
                verified = $true
                path = $script:PublicLaunchBindingPath
                sha256 = $script:PublicLaunchBindingSha256
                resolutionRunId = $script:PublicLaunchBindingRunIdText
                issuedAt = $script:PublicLaunchBindingIssuedAt
                expiresAt = $script:PublicLaunchBindingExpiresAt
                consumptionPath = $script:PublicLaunchBindingConsumptionPath
                consumptionSha256 = ('0' * 64)
            }
        }
        function Assert-StandardValidationAuthoritySnapshot {
            throw 'BLOCKED|public launch-binding handoff reached the authority gate.'
        }

        $result = Invoke-StandardValidationRun `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -CandidateArchiveSha256 ('d' * 64) `
            -SupervisorLaunchBindingPath $bindingPath `
            -AuthorityRevision ('c' * 40) `
            -AuthorityArchivePath (Join-Path $root 'authority.zip') `
            -AuthoritySnapshotEvidencePath (Join-Path $root 'authority.json') `
            -TrustedToolRoot $trustedRoot `
            -DevelopmentHarness:$false

        Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'The public production path must write terminal evidence after the test authority boundary.'
        $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $outputPath | ConvertFrom-Json
        Assert-Equal $script:PublicLaunchBindingAdapterSha256 (Get-StandardValidationFileSha256 -Path $adapterPath -Context 'public adapter snapshot') 'The public production path must hand the authenticated binding the hash of the parsed adapter snapshot.'
        Assert-Equal $evidence.state 'BLOCKED' 'The public production path must reach the authority boundary after launch binding authentication.'
        Assert-Match ([string]$evidence.failure.message) 'public launch-binding handoff reached the authority gate' 'The public production path must not fail on an N-format launch run ID before the authority boundary.'
        Assert-True (Test-Path -LiteralPath $consumptionPath -PathType Leaf) 'The public production path must consume the signed launch binding before the authority boundary.'

        Remove-Item -LiteralPath $artifactsRoot -Recurse -Force
        [void](New-Item -ItemType Directory -Path $artifactsRoot -Force)
        $replayResult = Invoke-StandardValidationRun `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -CandidateArchiveSha256 ('d' * 64) `
            -SupervisorLaunchBindingPath $bindingPath `
            -AuthorityRevision ('c' * 40) `
            -AuthorityArchivePath (Join-Path $root 'authority.zip') `
            -AuthoritySnapshotEvidencePath (Join-Path $root 'authority.json') `
            -TrustedToolRoot $trustedRoot `
            -DevelopmentHarness:$false
        Assert-Equal $replayResult.state 'BLOCKED' 'A deleted and recreated artifact root must not permit launch-binding replay.'
        Assert-Match ([string]$replayResult.failure.message) 'already been consumed|replay' 'Launch-binding replay must be rejected by the external consumption marker.'
    }

    # Scenario: The adapter is replaced after the immutable bytes have been snapshotted but before launch handoff returns.
    # Purpose: Fail closed before any adapter-derived command can execute when the path no longer matches the authenticated snapshot.
    It 'UnitT03_rejects_adapter_substitution_during_launch_handoff' {
        $root = Join-Path $TestDrive 'adapter-substitution-during-launch'
        $candidateRoot = Join-Path $root 'candidate'
        $artifactsRoot = Join-Path $root 'artifacts'
        $trustedRoot = Join-Path $root 'trusted'
        foreach ($path in @($candidateRoot, $artifactsRoot, $trustedRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        $adapterPath = Join-Path $root 'adapter.json'
        $bindingPath = Join-Path $root 'launch-binding.json'
        $consumptionPath = Join-Path $root 'launch-consumption.json'
        $outputPath = Join-Path $artifactsRoot 'evidence.json'
        . $script:RunnerPath `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $trustedRoot `
            -DefineFunctionsOnly
        Write-TestUtf8File -Path $adapterPath -Text '{"schemaVersion":1}'
        Write-TestUtf8File -Path $bindingPath -Text '{"fixture":true}'
        $adapterSha256 = Get-StandardValidationFileSha256 -Path $adapterPath -Context 'adapter substitution fixture'
        $bindingSha256 = Get-StandardValidationFileSha256 -Path $bindingPath -Context 'adapter substitution binding fixture'
        $runIdText = ([guid]::NewGuid()).ToString('N')
        $issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        $expiresAt = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')
        $script:SubstitutionAdapterPath = $adapterPath
        $script:SubstitutionAdapterSha256 = $null
        $script:SubstitutionBindingPath = $bindingPath
        $script:SubstitutionBindingSha256 = $bindingSha256
        $script:SubstitutionRunIdText = $runIdText
        $script:SubstitutionIssuedAt = $issuedAt
        $script:SubstitutionExpiresAt = $expiresAt
        $script:SubstitutionConsumptionPath = $consumptionPath
        function Assert-StandardValidationSupervisorLaunchBinding {
            param([string] $AdapterSha256)
            $script:SubstitutionAdapterSha256 = $AdapterSha256
            Write-TestUtf8File -Path $script:SubstitutionAdapterPath -Text '{"schemaVersion":2}'
            return [pscustomobject][ordered]@{
                status = 'verified'
                verified = $true
                path = $script:SubstitutionBindingPath
                sha256 = $script:SubstitutionBindingSha256
                resolutionRunId = $script:SubstitutionRunIdText
                issuedAt = $script:SubstitutionIssuedAt
                expiresAt = $script:SubstitutionExpiresAt
                consumptionPath = $script:SubstitutionConsumptionPath
                consumptionSha256 = ('0' * 64)
            }
        }
        function Assert-StandardValidationAuthoritySnapshot {
            throw 'BLOCKED|authority gate must not be reached after adapter substitution.'
        }

        $result = Invoke-StandardValidationRun `
            -CandidateRoot $candidateRoot `
            -AdapterPath $adapterPath `
            -ArtifactsRoot $artifactsRoot `
            -OutputPath $outputPath `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -CandidateArchiveSha256 ('d' * 64) `
            -SupervisorLaunchBindingPath $bindingPath `
            -AuthorityRevision ('c' * 40) `
            -AuthorityArchivePath (Join-Path $root 'authority.zip') `
            -AuthoritySnapshotEvidencePath (Join-Path $root 'authority.json') `
            -TrustedToolRoot $trustedRoot `
            -DevelopmentHarness:$false

        Assert-Equal $script:SubstitutionAdapterSha256 $adapterSha256 'The launch handoff must authenticate the hash of the immutable adapter snapshot.'
        Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Adapter substitution must produce terminal evidence.'
        $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $outputPath | ConvertFrom-Json
        Assert-Equal $evidence.state 'BLOCKED' 'Adapter substitution during launch handoff must fail closed.'
        Assert-Equal $evidence.launchBinding.resolutionRunId ([guid]::ParseExact($runIdText, 'N').ToString()) 'Substitution failure evidence must retain the authenticated launch-binding run ID.'
        Assert-Match ([string]$evidence.failure.message) 'Adapter changed during the trusted supervisor launch handoff' 'The failure must identify the adapter substitution boundary.'
    }

    # Scenario: A child emits more data than the supervisor can safely retain on either redirected stream.
    # Purpose: Bound stdout/stderr memory, terminate the owned process tree, and report a failed validation rather than buffering unbounded output.
    It 'InterT11_terminates_child_when_output_capture_exceeds_quota' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'output-flood') -Behavior 'output-flood'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($result.ExitCode -ne 0) 'An output-flood child must not return a pass exit code.'
        Assert-Equal $result.Evidence.state 'FAILED' 'An output-flood child must fail the validation run.'
        Assert-Match $result.Output 'output.*quota|quota.*output' 'The failure must identify bounded output capture as the cause.'
        $quotaEvent = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Artifacts 'runs') -Filter 'event-*.json' -Recurse -File |
                ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json } |
                Where-Object { $_.process.outputQuotaExceeded -eq $true } | Select-Object -First 1)[0]
        Assert-True ($null -ne $quotaEvent) 'The output-flood event must retain raw bounded-capture evidence.'
        Assert-True (([string]$quotaEvent.process.stdout).Length -le 1048576) 'The stdout prefix must remain within its quota on overflow.'
        Assert-True (([string]$quotaEvent.process.stderr).Length -le 1048576) 'The stderr prefix must remain within its quota on overflow.'
        Assert-Match ([string]$quotaEvent.process.outputQuotaDiagnostic) 'quota exceeded' 'The overflow diagnostic must be recorded outside the bounded stderr prefix.'
    }

    # Scenario: A child emits a valid JSON envelope whose stdout is near, but below, the capture quota.
    # Purpose: Preserve the complete in-quota stream rather than applying an undocumented serialization margin.
    It 'InterT12_preserves_valid_output_below_capture_quota' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'output-near-quota') -Behavior 'output-near-quota'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.Evidence.state 'PASS' 'A valid near-quota output envelope must remain a passing validation.'
        $nearQuotaEvent = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Artifacts 'runs') -Filter 'event-*.json' -Recurse -File |
                ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json } |
                Where-Object { $_.process.outputQuotaExceeded -eq $false -and ([string]$_.process.stdout).Length -gt (1048576 - 4096) } |
                Select-Object -First 1)[0]
        Assert-True ($null -ne $nearQuotaEvent) 'The valid near-quota event must retain the full stream above the former safety-margin threshold.'
        Assert-True (([string]$nearQuotaEvent.process.stdout).Length -le 1048576) 'The valid near-quota stdout must remain within the capture quota.'
    }

    # Scenario: A harmless development adapter exposes two active Skills to the central runner.
    # Purpose: Prove package adapter, skill-validator and skill-tools all emit real receipts before Static.
    It 'InterT10_runs_adapter_and_both_package_tools_for_every_active_skill_before_static' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'package-order')
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.ExitCode 0 'A complete development validation fixture must pass.'
        Assert-Equal $result.Evidence.state 'PASS' 'The evidence state must report a validation pass.'
        Assert-Equal $result.Evidence.sourceConformance.status 'passed' 'A complete source-stage projection must pass.'
        Assert-False ([bool]$result.Evidence.sourceConformance.releaseEligible) 'Source-stage success must never authorize release.'
        Assert-True ([int]$result.Evidence.sourceConformance.pester.passed -gt 0) 'The source projection must retain a positive Pester pass count.'
        Assert-Equal @($result.Evidence.stages).Count 10 'The final evidence must retain the full stage contract.'
        $events = @(Get-Content -Encoding UTF8 -LiteralPath $fixture.Log)
        Assert-True ($events.Count -ge 6) 'The fixture must emit package and Static events.'
        $staticIndex = [Array]::IndexOf($events, ($events | Where-Object { $_ -like 'skillspector-static|staticAnalyzer|*' } | Select-Object -First 1))
        Assert-True ($staticIndex -gt 0) 'Static must execute after package events.'
        foreach ($skillId in $fixture.SkillIds) {
            Assert-True (@($events | Where-Object { $_ -like "package-validation|skill-validator|$skillId" }).Count -eq 1) "skill-validator must run for '$skillId'."
            Assert-True (@($events | Where-Object { $_ -like "package-validation|skill-tools|$skillId" }).Count -eq 1) "skill-tools must run for '$skillId'."
        }
        Assert-True ((@($events | Where-Object { $_ -like 'skillspector-static|staticAnalyzer|*' }).Count) -eq 1) 'Static must run once for the complete active Skill set.'
        $packageStage = @($result.Evidence.stages | Where-Object id -eq 'package-validation')[0]
        Assert-True (@($packageStage.events | Where-Object { $_.outputPath -and (Test-Path -LiteralPath $_.outputPath -PathType Leaf) }).Count -eq 5) 'Every package process must retain an actual output event artifact.'
        foreach ($behavior in @('repository-missing-evidence', 'repository-zero-tests')) {
            $invalidFixture = New-RunnerFixture -Root (Join-Path $TestDrive $behavior) -Behavior $behavior
            $invalidResult = Invoke-RunnerFixture -Fixture $invalidFixture
            Assert-True ($invalidResult.ExitCode -ne 0) "Repository test evidence '$behavior' must not return a pass exit code."
            Assert-Equal $invalidResult.Evidence.state 'FAILED' "Repository test evidence '$behavior' must fail the run."
            Assert-Match $invalidResult.Output 'testInventory|typed.*coverage|Repository Tests' "Repository test evidence '$behavior' must identify the missing or empty coverage."
        }
    }

    # Scenario: Static reports a failure or incomplete analyzer coverage.
    # Purpose: Prevent candidate repository tests from running across the Static barrier.
    It 'InterT20_blocks_repository_test_dispatch_when_static_fails_or_is_partial' {
        foreach ($behavior in @('static-fail', 'static-partial')) {
            $fixture = New-RunnerFixture -Root (Join-Path $TestDrive $behavior) -Behavior $behavior
            $result = Invoke-RunnerFixture -Fixture $fixture
            Assert-True ($result.ExitCode -ne 0) "Static '$behavior' must not return a pass exit code."
            Assert-False (Test-Path -LiteralPath $fixture.Sentinel -PathType Leaf) "Repository tests must not run after Static '$behavior'."
            Assert-Equal @($result.Evidence.stages | Where-Object id -eq 'repository-tests' | Select-Object -ExpandProperty status) 'not-run' "Repository tests must be marked not-run after Static '$behavior'."
        }
    }

    # Scenario: A package validator writes into the candidate snapshot exposed to child processes.
    # Purpose: Detect snapshot drift after every child and fail before the next barrier can consume it.
    It 'InterT25_fails_closed_when_a_child_mutates_the_candidate_snapshot' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'snapshot-mutate') -Behavior 'snapshot-mutate'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.Evidence.state 'FAILED' 'A child-mutated candidate snapshot must fail validation.'
        Assert-Match $result.Output 'snapshot.*changed|snapshot.*drift' 'The failure must identify candidate snapshot drift.'
        Assert-False (@($result.Evidence.stages | Where-Object id -eq 'skillspector-static' | Select-Object -ExpandProperty status) -contains 'passed') 'Snapshot drift must not reach Static.'
        Assert-False (Test-Path -LiteralPath $fixture.Sentinel -PathType Leaf) 'Snapshot drift must not dispatch repository tests.'
    }

    # Scenario: A candidate adds a Skill after the adapter was authored.
    # Purpose: Ensure active Skill coverage is discovered and cannot be silently omitted.
    It 'InterT30_fails_closed_on_undeclared_new_skill_and_runs_it_when_declared' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'new-skill') -SkillIds @('alpha')
        $newSkillRoot = Join-Path $fixture.Candidate 'skills/new-skill'
        [void](New-Item -ItemType Directory -Path $newSkillRoot -Force)
        Write-TestUtf8File -Path (Join-Path $newSkillRoot 'SKILL.md') -Text "---`nname: new-skill`ndescription: Added after adapter creation.`n---`n"
        $blocked = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($blocked.ExitCode -ne 0) 'An undeclared active Skill must fail closed.'
        Assert-Equal $blocked.Evidence.state 'INVALID' 'A stale adapter must be an invalid candidate/configuration.'
        Assert-False (Test-Path -LiteralPath $fixture.Log -PathType Leaf) 'No package tool may run before active Skill reconciliation.'

        $adapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $fixture.Adapter | ConvertFrom-Json
        $adapter.activeSkills = @('alpha', 'new-skill')
        Write-TestUtf8File -Path $fixture.Adapter -Text ($adapter | ConvertTo-Json -Depth 20)
        $fixture2 = New-RunnerFixture -Root (Join-Path $TestDrive 'new-skill-declared') -SkillIds @('alpha', 'new-skill')
        $result = Invoke-RunnerFixture -Fixture $fixture2
        Assert-Equal $result.ExitCode 0 'A declared new Skill must be included by the same runner.'
        Assert-True (@(Get-Content -Encoding UTF8 -LiteralPath $fixture2.Log | Where-Object { $_ -like 'package-validation|skill-validator|new-skill' }).Count -eq 1) 'The newly declared Skill must receive package validation.'
    }

    # Scenario: A report is replayed for a different candidate identity.
    # Purpose: Bind every package receipt to the candidate actually being validated.
    It 'InterT40_rejects_wrong_candidate_evidence_and_does_not_enter_static' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'wrong-candidate') -Behavior 'wrong-candidate'
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($result.ExitCode -ne 0) 'Wrong-candidate evidence must not pass.'
        Assert-Equal $result.Evidence.state 'FAILED' 'A tool identity mismatch must be a failed validation.'
        Assert-False (@(Get-Content -Encoding UTF8 -LiteralPath $fixture.Log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'skillspector-static|*' }).Count -gt 0) 'Static must not run after wrong-candidate evidence.'
    }

    # Scenario: Semantic analysis is triggered without consent, and later lifecycle evidence is incomplete.
    # Purpose: Keep external semantic consent, AI review, human approval, and release evidence independent.
    It 'InterT50_blocks_triggered_semantic_without_consent_and_never_fakes_later_completion' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-consent')
        $result = Invoke-RunnerFixture -Fixture $fixture -SemanticTriggered
        Assert-True ($result.ExitCode -ne 0) 'Triggered semantic work without consent must be blocked.'
        Assert-Equal $result.Evidence.state 'BLOCKED' 'Missing semantic consent must produce BLOCKED.'
        Assert-Equal $result.Evidence.exitCode 10 'Source projection must preserve canonical BLOCKED=10.'
        Assert-False ([bool]$result.Evidence.releaseEligible) 'Missing semantic consent must remain release-ineligible.'
        Assert-Equal $result.Evidence.sourceConformance.status 'passed' 'Source checks may pass while the canonical Stage 6 consent barrier remains blocked.'
        Assert-Equal $result.Evidence.sourceConformance.canonicalValidation.stage6Status 'blocked' 'The source projection must report the unchanged semantic consent block.'
        Assert-False ([bool]$result.Evidence.sourceConformance.releaseEligible) 'A source-only pass must not satisfy the semantic release gate.'
        foreach ($stageId in @('ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            $stage = @($result.Evidence.stages | Where-Object id -eq $stageId)[0]
            Assert-Equal $stage.status 'not-applicable' "Unperformed '$stageId' must not be reported as passed."
        }

        $analyzerTriggerFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-required') -Behavior 'semantic-required'
        $analyzerTriggerResult = Invoke-RunnerFixture -Fixture $analyzerTriggerFixture
        Assert-Equal $analyzerTriggerResult.Evidence.state 'BLOCKED' 'A typed analyzer semantic trigger must not be suppressible by omitting the caller switch.'
        $analyzerTriggerStage = @($analyzerTriggerResult.Evidence.stages | Where-Object id -eq 'conditional-semantic-scan')[0]
        Assert-True ([bool]$analyzerTriggerStage.triggerDecision.analyzerRequired) 'The semantic stage must record the analyzer-required trigger.'
        Assert-True ([bool]$analyzerTriggerStage.triggerDecision.effectiveTriggered) 'The effective semantic trigger must include the analyzer requirement.'

        $semanticEvidenceFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-evidence')
        . $script:RunnerPath `
            -CandidateRoot $semanticEvidenceFixture.Candidate `
            -AdapterPath $semanticEvidenceFixture.Adapter `
            -ArtifactsRoot $semanticEvidenceFixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $semanticAdapterSha = Get-StandardValidationFileSha256 -Path $semanticEvidenceFixture.Adapter -Context 'test adapter'
        $semanticInventory = Get-StandardValidationInventory -Root $semanticEvidenceFixture.Candidate -Context 'test candidate'
        $semanticContentSha = Get-StandardValidationInventorySha256 -Inventory $semanticInventory
        $semanticCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$semanticContentSha`n$semanticAdapterSha`n")
        $semanticEvidencePath = Join-Path $semanticEvidenceFixture.Root 'semantic.json'
        $semanticRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            Write-TestSemanticEvidence -Fixture $semanticEvidenceFixture -Path $semanticEvidencePath -CandidateId $semanticCandidateId -Rsa $semanticRsa
        }
        finally { $semanticRsa.Dispose() }
        $semanticResult = Invoke-RunnerFixture `
            -Fixture $semanticEvidenceFixture `
            -SemanticTriggered `
            -SemanticConsent `
            -SemanticProvider 'fixture-semantic-provider' `
            -SemanticPurpose 'fixture semantic regression' `
            -SemanticScope 'candidate' `
            -SemanticEvidencePath $semanticEvidencePath
        Assert-Equal $semanticResult.Evidence.state 'PASS' 'A valid authenticated semantic result must pass the semantic barrier.'
        $semanticStage = @($semanticResult.Evidence.stages | Where-Object id -eq 'conditional-semantic-scan')[0]
        Assert-Equal $semanticStage.status 'passed' 'A valid semantic result must complete the semantic stage.'
        Assert-Equal ([string]$semanticStage.semanticEvidence.evidenceType) 'semantic' 'The semantic evidence must be retained on its stage object.'
    }

    # Scenario: A development harness supplies a v2 request, decision, canonical
    # evidence artifact, and explicit public key to the public runner.
    # Purpose: Prove the runner reaches the exported v2 verifier and retains the
    # authenticated v2 artifact while leaving the v1 path above intact.
    It 'InterT55_accepts_v2_semantic_bridge_evidence_through_the_runner' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-valid')
        $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
        try {
            $result = Invoke-RunnerFixture `
                -Fixture $fixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifacts.RequestPath `
                -SemanticConsentDecisionPath $artifacts.DecisionPath `
                -SemanticEvidencePath $artifacts.EvidencePath `
                -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                -SemanticPublicKeyId $artifacts.KeyId `
                -ValidationRunId $artifacts.RunId
            Assert-Equal $result.ExitCode 0 'A valid v2 semantic bridge artifact must pass the runner.'
            Assert-Equal $result.Evidence.state 'PASS' 'A valid v2 semantic bridge artifact must produce PASS.'
            $stage = @($result.Evidence.stages | Where-Object id -eq 'conditional-semantic-scan')[0]
            Assert-Equal $stage.status 'passed' 'A valid v2 semantic bridge artifact must complete the semantic stage.'
            Assert-Equal ([string]$stage.semanticBridgeV2Evidence.artifactType) 'semantic-evidence-v2' 'The runner must retain a distinct verified v2 evidence reference.'
            Assert-Equal ([string]$stage.semanticBridgeV2Evidence.attestationKeyId) $artifacts.KeyId 'The runner must retain the verified signer identity.'
            Assert-False ([bool]$stage.semanticBridgeV2Evidence.releaseEligible) 'A local v2 evidence reference must remain release-ineligible.'
            Assert-True ($null -eq $stage.semanticEvidence) 'A local v2 artifact must not be promoted into the production semantic v1 evidence slot.'
            $evidenceSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'
            $evidenceJson = $result.Evidence | ConvertTo-Json -Depth 100 -Compress
            $portableEvidence = $evidenceJson | ConvertFrom-Json
            $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $evidenceSchemaPath | ConvertFrom-Json
            foreach ($requiredProperty in @($evidenceSchema.required)) {
                Assert-True ($null -ne $portableEvidence.PSObject.Properties[[string]$requiredProperty]) "Standard v1 evidence is missing required property '$requiredProperty'."
            }
            $testJsonCommand = Get-Command Test-Json -ErrorAction SilentlyContinue
            if ($null -ne $testJsonCommand -and $testJsonCommand.Parameters.ContainsKey('SchemaFile')) {
                Assert-True (Test-Json -Json $evidenceJson -SchemaFile $evidenceSchemaPath) 'The runner result containing the distinct v2 reference must remain valid Standard v1 evidence.'
            }
        }
        finally { $artifacts.Rsa.Dispose() }
    }

    # Scenario: A signed semantic v2 artifact is reused after the same candidate
    # starts a second validation run, then replaced with evidence bound to that run.
    # Purpose: Consent lifetime and candidate identity must not make old run evidence reusable.
    It 'InterT63_accepts_only_current_run_bound_v2_evidence_across_validation_runs' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-cross-run-replay')
        $runA = [guid]::NewGuid().ToString('N')
        $runB = [guid]::NewGuid().ToString('N')
        $artifactsA = New-TestRunnerSemanticV2Artifacts -Fixture $fixture -ValidationRunId $runA
        $artifactsB = $null
        try {
            $firstRun = Invoke-RunnerFixture `
                -Fixture $fixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifactsA.RequestPath `
                -SemanticConsentDecisionPath $artifactsA.DecisionPath `
                -SemanticEvidencePath $artifactsA.EvidencePath `
                -SemanticPublicKeyPath $artifactsA.PublicKeyPath `
                -SemanticPublicKeyId $artifactsA.KeyId `
                -ValidationRunId $runA
            Assert-Equal $firstRun.ExitCode 0 'Fresh v2 evidence bound to run A must pass run A.'
            Assert-Equal $firstRun.Evidence.state 'PASS' 'Fresh v2 evidence bound to run A must produce PASS.'
            Assert-Equal ([string]$firstRun.Evidence.runId) ([guid]::ParseExact($runA, 'N').ToString()) 'Run A evidence must retain run A ID.'

            $replayArtifactsRoot = Join-Path $fixture.Root 'artifacts-replay-run-b'
            $replayedRun = Invoke-RunnerFixture `
                -Fixture $fixture `
                -ArtifactsRoot $replayArtifactsRoot `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifactsA.RequestPath `
                -SemanticConsentDecisionPath $artifactsA.DecisionPath `
                -SemanticEvidencePath $artifactsA.EvidencePath `
                -SemanticPublicKeyPath $artifactsA.PublicKeyPath `
                -SemanticPublicKeyId $artifactsA.KeyId `
                -ValidationRunId $runB
            Assert-True ($runA -cne $runB) 'The replay regression must exercise two distinct validation IDs.'
            Assert-Equal ([string]$replayedRun.Evidence.runId) ([guid]::ParseExact($runB, 'N').ToString()) 'Run B evidence must retain run B ID.'
            Assert-True ($replayedRun.ExitCode -ne 0) 'Run B must reject signed evidence issued for run A.'
            Assert-Equal $replayedRun.Evidence.state 'BLOCKED' 'Cross-run v2 evidence replay must produce BLOCKED.'
            Assert-Match ([string]$replayedRun.Evidence.failure.message) 'current validation run' 'The replay failure must identify the launch-run mismatch.'

            $artifactsB = New-TestRunnerSemanticV2Artifacts -Fixture $fixture -ValidationRunId $runB
            Assert-Equal $artifactsB.CandidateId $artifactsA.CandidateId 'Both runs must validate the same candidate.'
            $freshArtifactsRoot = Join-Path $fixture.Root 'artifacts-fresh-run-b'
            $freshRun = Invoke-RunnerFixture `
                -Fixture $fixture `
                -ArtifactsRoot $freshArtifactsRoot `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifactsB.RequestPath `
                -SemanticConsentDecisionPath $artifactsB.DecisionPath `
                -SemanticEvidencePath $artifactsB.EvidencePath `
                -SemanticPublicKeyPath $artifactsB.PublicKeyPath `
                -SemanticPublicKeyId $artifactsB.KeyId `
                -ValidationRunId $runB
            Assert-Equal $freshRun.ExitCode 0 'Fresh v2 evidence bound to run B must pass run B.'
            Assert-Equal $freshRun.Evidence.state 'PASS' 'Fresh v2 evidence bound to run B must produce PASS.'
            Assert-Equal ([string]$freshRun.Evidence.runId) ([guid]::ParseExact($runB, 'N').ToString()) 'Fresh run B evidence must retain run B ID.'
        }
        finally {
            $artifactsA.Rsa.Dispose()
            if ($null -ne $artifactsB) { $artifactsB.Rsa.Dispose() }
        }
    }

    # Scenario: The v2 evidence bytes are changed after signing, or the caller
    # supplies an expected signer identity different from the evidence.
    # Purpose: Keep byte authentication and signer identity substitution fail-closed at the runner boundary.
    It 'InterT56_rejects_v2_wrong_signature_and_signer_identity' {
        $signatureFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-wrong-signature')
        $signatureArtifacts = New-TestRunnerSemanticV2Artifacts -Fixture $signatureFixture
        try {
            $mutated = ConvertFrom-Json -InputObject (Get-Content -Raw -Encoding UTF8 -LiteralPath $signatureArtifacts.EvidencePath)
            $signatureText = [string]$mutated.attestation.signature
            $replacement = if ($signatureText[0] -ceq 'A') { 'B' } else { 'A' }
            $mutated.attestation.signature = $replacement + $signatureText.Substring(1)
            Write-TestUtf8File -Path $signatureArtifacts.EvidencePath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $mutated)
            $badSignature = Invoke-RunnerFixture `
                -Fixture $signatureFixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $signatureArtifacts.RequestPath `
                -SemanticConsentDecisionPath $signatureArtifacts.DecisionPath `
                -SemanticEvidencePath $signatureArtifacts.EvidencePath `
                -SemanticPublicKeyPath $signatureArtifacts.PublicKeyPath `
                -SemanticPublicKeyId $signatureArtifacts.KeyId `
                -ValidationRunId $signatureArtifacts.RunId
            Assert-True ($badSignature.ExitCode -ne 0) 'A changed v2 signature must fail the runner.'
            $badSignatureReason = if ($null -ne $badSignature.Evidence) { [string]$badSignature.Evidence.failure.message } else { '<no runner evidence>' }
            $badSignatureDiagnostic = "actualState=$($badSignature.Evidence.state); exitCode=$($badSignature.ExitCode); failure.message=$badSignatureReason"
            Assert-Equal $badSignature.Evidence.state 'BLOCKED' "A changed v2 signature must produce BLOCKED. $badSignatureDiagnostic"
            Assert-Match ([string]$badSignature.Evidence.failure.message) 'signature|evidence rejected' 'The runner must identify v2 signature rejection.'
        }
        finally { $signatureArtifacts.Rsa.Dispose() }

        $identityFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-wrong-identity')
        $identityArtifacts = New-TestRunnerSemanticV2Artifacts -Fixture $identityFixture
        try {
            $wrongIdentity = Invoke-RunnerFixture `
                -Fixture $identityFixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $identityArtifacts.RequestPath `
                -SemanticConsentDecisionPath $identityArtifacts.DecisionPath `
                -SemanticEvidencePath $identityArtifacts.EvidencePath `
                -SemanticPublicKeyPath $identityArtifacts.PublicKeyPath `
                -SemanticPublicKeyId 'substituted-key-id' `
                -ValidationRunId $identityArtifacts.RunId
            Assert-True ($wrongIdentity.ExitCode -ne 0) 'A substituted v2 signer identity must fail the runner.'
            Assert-Equal $wrongIdentity.Evidence.state 'BLOCKED' 'A substituted v2 signer identity must produce BLOCKED.'
            Assert-Match ([string]$wrongIdentity.Evidence.failure.message) 'signer identity|evidence rejected' 'The runner must identify v2 signer identity rejection.'
        }
        finally { $identityArtifacts.Rsa.Dispose() }
    }

    # Scenario: A required v2 evidence property is removed while the request and
    # decision remain otherwise valid.
    # Purpose: Incomplete v2 evidence must not be downgraded to the legacy v1 parser or PASS.
    It 'InterT57_rejects_incomplete_v2_evidence' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-incomplete')
        $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
        try {
            $incomplete = ConvertFrom-Json -InputObject (Get-Content -Raw -Encoding UTF8 -LiteralPath $artifacts.EvidencePath)
            $incomplete.PSObject.Properties.Remove('execution')
            Write-TestUtf8File -Path $artifacts.EvidencePath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $incomplete)
            $result = Invoke-RunnerFixture `
                -Fixture $fixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifacts.RequestPath `
                -SemanticConsentDecisionPath $artifacts.DecisionPath `
                -SemanticEvidencePath $artifacts.EvidencePath `
                -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                -SemanticPublicKeyId $artifacts.KeyId `
                -ValidationRunId $artifacts.RunId
            Assert-True ($result.ExitCode -ne 0) 'Incomplete v2 evidence must fail the runner.'
            Assert-Equal $result.Evidence.state 'BLOCKED' 'Incomplete v2 evidence must produce BLOCKED.'
            Assert-Match ([string]$result.Evidence.failure.message) 'evidence rejected|properties|execution' 'The runner must identify incomplete v2 evidence.'
        }
        finally { $artifacts.Rsa.Dispose() }
    }

    # Scenario: The same verified v2 bytes are submitted twice to the exported
    # verifier with one replay ledger in one process.
    # Purpose: Demonstrate the verifier's feasible single-process replay barrier;
    # cross-process replay requires a protected supervisor ledger and is outside
    # this caller-injected development seam.
    It 'UnitT58_rejects_v2_evidence_replay_within_one_verifier_process' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-replay')
        $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
        $publicRsa = [System.Security.Cryptography.RSA]::Create()
        try {
            $publicRsa.ImportParameters($artifacts.Rsa.ExportParameters($false))
            $ledger = @{}
            $parameters = @{
                EvidenceBytes = $artifacts.EvidenceBytes
                ConsentRequest = $artifacts.Request
                ConsentDecision = $artifacts.Decision
                PublicKey = $publicRsa
                ExpectedKeyId = $artifacts.KeyId
                ExpectedBindings = $artifacts.Bindings
                ExpectedProviderRoute = $artifacts.Route
                ExpectedPurpose = 'Synthetic runner v2 semantic review.'
                ExpectedScope = $artifacts.Scope
                ExpectedProviderTextInventory = $artifacts.Inventory
                Now = [DateTime]::UtcNow
                ReplayLedger = $ledger
            }
            $first = Test-StandardSemanticBridgeEvidence @parameters
            $second = Test-StandardSemanticBridgeEvidence @parameters
            Assert-True ([bool]$first.valid) 'The first v2 verifier submission must pass.'
            Assert-False ([bool]$second.valid) 'The second v2 verifier submission must be rejected as replay.'
            Assert-Match ([string]$second.reason) 'replay' 'The verifier must identify replay.'
        }
        finally {
            $publicRsa.Dispose()
            $artifacts.Rsa.Dispose()
        }
    }

    # Scenario: A consent artifact contains a parser-colliding duplicate property.
    # Purpose: The runner must authenticate canonical request/decision bytes, not only their deserialized values.
    It 'UnitT59_rejects_noncanonical_v2_consent_bytes' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-noncanonical-consent')
        $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
        try {
            $requestJson = Get-Content -Raw -Encoding UTF8 -LiteralPath $artifacts.RequestPath
            Write-TestUtf8File -Path $artifacts.RequestPath -Text $requestJson.Insert(1, '"schemaVersion":2,')
            $result = Invoke-RunnerFixture `
                -Fixture $fixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifacts.RequestPath `
                -SemanticConsentDecisionPath $artifacts.DecisionPath `
                -SemanticEvidencePath $artifacts.EvidencePath `
                -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                -SemanticPublicKeyId $artifacts.KeyId `
                -ValidationRunId $artifacts.RunId
            Assert-True ($result.ExitCode -ne 0) 'Non-canonical consent bytes must fail the runner.'
            Assert-Equal $result.Evidence.state 'BLOCKED' 'Non-canonical consent bytes must produce BLOCKED.'
            Assert-Match ([string]$result.Evidence.failure.message) 'canonical UTF-8 JSON' 'The runner must identify non-canonical consent bytes.'
        }
        finally { $artifacts.Rsa.Dispose() }
    }

    # Scenario: The consent decision remains canonical but its provider-text
    # inventory is edited to describe bytes other than the verified candidate.
    # Purpose: Ensure the runner authenticates source bytes/full manifest subset
    # before the bridge can treat the decision as a consent-bound input.
    It 'InterT61_rejects_v2_provider_inventory_not_bound_to_candidate_source_bytes' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-stale-provider-inventory')
        $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
        try {
            $decision = ConvertFrom-Json -InputObject (Get-Content -Raw -Encoding UTF8 -LiteralPath $artifacts.DecisionPath)
            $item = @($decision.providerTextInventory.items)[0]
            $zeroSha = '0' * 64
            if ($null -ne $item.PSObject.Properties['sourceSha256']) { $item.sourceSha256 = $zeroSha }
            if ($null -ne $item.PSObject.Properties['providerTextSha256']) { $item.providerTextSha256 = $zeroSha }
            if ($null -ne $item.PSObject.Properties['sha256']) { $item.sha256 = $zeroSha }
            Write-TestUtf8File -Path $artifacts.DecisionPath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $decision)
            $result = Invoke-RunnerFixture `
                -Fixture $fixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifacts.RequestPath `
                -SemanticConsentDecisionPath $artifacts.DecisionPath `
                -SemanticEvidencePath $artifacts.EvidencePath `
                -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                -SemanticPublicKeyId $artifacts.KeyId `
                -ValidationRunId $artifacts.RunId
            Assert-True ($result.ExitCode -ne 0) 'A provider inventory with substituted source bytes must fail the runner.'
            Assert-Equal $result.Evidence.state 'BLOCKED' 'A provider inventory with substituted source bytes must produce BLOCKED.'
            Assert-Match ([string]$result.Evidence.failure.message) 'provider text|sourceSha256|digest|scope' 'The runner must identify provider source binding rejection.'
        }
        finally { $artifacts.Rsa.Dispose() }
    }

    # Scenario: An authenticated artifact is replaced before the runner
    # registers it in the evidence ledger.
    # Purpose: Keep the snapshot hash an atomic registration precondition rather
    # than relying only on a later best-effort ledger re-read.
    It 'UnitT62_rejects_artifact_mutation_before_expected_hash_registration' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-registration-binding')
        . $script:RunnerPath `
            -CandidateRoot $fixture.Candidate `
            -AdapterPath $fixture.Adapter `
            -ArtifactsRoot $fixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $fixture.TrustedTools `
            -DefineFunctionsOnly
        $path = Join-Path $fixture.Root 'registration-bound-artifact.json'
        Write-TestUtf8File -Path $path -Text '{"snapshot":true}'
        $expectedSha256 = Get-StandardValidationFileSha256 -Path $path -Context 'test registration snapshot'
        Write-TestUtf8File -Path $path -Text '{"snapshot":false}'
        $rejected = $false
        try {
            [void](Register-StandardValidationEvidenceArtifact `
                -Path $path `
                -ExpectedSha256 $expectedSha256 `
                -Context 'test registration snapshot')
        }
        catch {
            $rejected = $true
            Assert-Match ([string]$_.Exception.Message) 'changed before registration' 'The registration gate must identify a pre-registration artifact mutation.'
        }
        Assert-True $rejected 'A pre-registration artifact mutation must fail the expected-hash registration gate.'
    }

    # Scenario: The same event/candidate is invoked twice against one artifact root.
    # Purpose: Enforce one canonical execution and preserve the first evidence instead of overwriting it.
    It 'InterT60_rejects_duplicate_event_candidate_execution' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'duplicate')
        $first = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $first.ExitCode 0 'The first fixture execution must pass.'
        $firstEvidenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixture.Output).Hash
        $second = Invoke-RunnerFixture -Fixture $fixture
        Assert-True ($second.ExitCode -ne 0) 'A duplicate event/candidate execution must be rejected.'
        $secondEvidenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixture.Output).Hash
        Assert-Equal $secondEvidenceHash $firstEvidenceHash 'Duplicate execution must not overwrite the first evidence.'
    }

    # Scenario: A trusted child process is cancelled, times out, or emits no parseable result.
    # Purpose: Keep supervisor cleanup and output parsing fail-closed instead of converting process failure to PASS.
    It 'InterT70_never_passes_timeout_cancellation_or_missing_output' {
        $timeoutFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'timeout') -Behavior 'timeout'
        $timeoutResult = Invoke-RunnerFixture -Fixture $timeoutFixture -TimeoutSeconds 1
        Assert-Equal $timeoutResult.Evidence.state 'FAILED' 'A timed-out child process must fail validation.'
        Assert-True ($timeoutResult.ExitCode -ne 0) 'A timed-out child process must have a nonzero exit code.'

        $cancelFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'cancelled')
        $cancelPath = Join-Path $cancelFixture.Root 'cancel.requested'
        Write-TestUtf8File -Path $cancelPath -Text 'cancel'
        $cancelResult = Invoke-RunnerFixture -Fixture $cancelFixture -CancellationPath $cancelPath
        Assert-Equal $cancelResult.Evidence.state 'CANCELLED' 'A cancellation request must produce CANCELLED.'
        Assert-True ($cancelResult.ExitCode -ne 0) 'A cancellation request must never have a pass exit code.'

        $missingFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'missing-output') -Behavior 'missing-output'
        $missingResult = Invoke-RunnerFixture -Fixture $missingFixture
        Assert-Equal $missingResult.Evidence.state 'FAILED' 'Missing tool output must fail validation.'
        Assert-False (@($missingResult.Evidence.stages | Where-Object id -eq 'skillspector-static' | Select-Object -ExpandProperty status) -contains 'passed') 'Missing tool output must not reach Static.'

        $environmentFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'environment-leak') -Behavior 'environment-leak'
        $environmentResult = Invoke-RunnerFixture -Fixture $environmentFixture
        Assert-Equal $environmentResult.Evidence.state 'PASS' 'A secret inherited by the supervisor must not be visible to a validation child.'

        $artifactTamperFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'repository-artifact-tamper') -Behavior 'repository-artifact-tamper'
        $artifactTamperResult = Invoke-RunnerFixture -Fixture $artifactTamperFixture
        Assert-Equal $artifactTamperResult.Evidence.state 'FAILED' 'A repository test that removes a prior evidence artifact must fail validation.'
        Assert-Match $artifactTamperResult.Output 'Previously written validation evidence artifact' 'Prior evidence artifact tampering must be reported as a validation failure.'

        $outputTamperFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'output-tamper') -Behavior 'output-tamper'
        $outputTamperResult = Invoke-RunnerFixture -Fixture $outputTamperFixture
        Assert-True ($outputTamperResult.Evidence.state -ne 'PASS') 'A child process that substitutes the reserved final output must never produce PASS.'
        $attackerProperty = if ($null -eq $outputTamperResult.Evidence) { $null } else { $outputTamperResult.Evidence.PSObject.Properties['attacker'] }
        Assert-True ($null -eq $attackerProperty) 'Final evidence must not be replaced by attacker-controlled output.'
    }

    # Scenario: A candidate adds a workflow that invokes an alternate validation script.
    # Purpose: Ensure the runner applies the central consumer entry-point inventory before package validation.
    It 'InterT75_blocks_alternate_consumer_entry_points_before_package_validation' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'alternate-entry-point')
        Write-TestUtf8File -Path (Join-Path $fixture.Candidate '.github/workflows/alternate-validation.yml') -Text @'
name: Alternate validation
on:
  pull_request:
jobs:
  alternate:
    steps:
      - run: ./scripts/alternate-validation.ps1
'@
        $result = Invoke-RunnerFixture -Fixture $fixture
        Assert-Equal $result.Evidence.state 'BLOCKED' 'An alternate consumer validation entry point must block the run.'
        Assert-Match $result.Output 'entry-point|canonical' 'The failure must identify the canonical entry-point contract.'
        Assert-False (Test-Path -LiteralPath $fixture.Log -PathType Leaf) 'Entry-point contract failure must occur before package validation.'
    }

    # Scenario: Adapter configuration is duplicated or requests a mode inconsistent with the trusted supervisor.
    # Purpose: Keep consumer configuration and execution mode as fail-closed inputs rather than policy overrides.
    It 'InterT80_rejects_duplicate_active_skills_and_mode_trust_mismatch' {
        $duplicateFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'duplicate-skills') -SkillIds @('alpha')
        $duplicateAdapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $duplicateFixture.Adapter | ConvertFrom-Json
        $duplicateAdapter.activeSkills = @('alpha', 'alpha')
        Write-TestUtf8File -Path $duplicateFixture.Adapter -Text ($duplicateAdapter | ConvertTo-Json -Depth 20)
        $duplicateResult = Invoke-RunnerFixture -Fixture $duplicateFixture
        Assert-Equal $duplicateResult.Evidence.state 'INVALID' 'Duplicate active Skill configuration must be invalid.'
        Assert-False (Test-Path -LiteralPath $duplicateFixture.Log -PathType Leaf) 'Duplicate active Skill configuration must not run a package tool.'

        $modeFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'mode-mismatch')
        $modeAdapter = Get-Content -Raw -Encoding UTF8 -LiteralPath $modeFixture.Adapter | ConvertFrom-Json
        $modeAdapter.mode = 'production'
        Write-TestUtf8File -Path $modeFixture.Adapter -Text ($modeAdapter | ConvertTo-Json -Depth 20)
        $modeResult = Invoke-RunnerFixture -Fixture $modeFixture
        Assert-Equal $modeResult.Evidence.state 'INVALID' 'A development supervisor must reject a production adapter mode.'
        Assert-False (Test-Path -LiteralPath $modeFixture.Log -PathType Leaf) 'Mode mismatch must not run a package tool.'
    }

    # Scenario: Package, static, v2, AI-review, and v1 semantic evidence supply severity strings with noncanonical casing.
    # Purpose: Every consumer uses the same ordinal severity enum, and lowercase medium still requires human review.
    It 'UnitT94_severity_enums_are_ordinal_across_runner_evidence_guards' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'ordinal-severity')
        . $script:RunnerPath `
            -CandidateRoot $fixture.Candidate `
            -AdapterPath $fixture.Adapter `
            -ArtifactsRoot $fixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly

        foreach ($context in @('package adapter', 'Static analyzer', 'semantic v2 evidence')) {
            foreach ($severityVariant in @('MEDIUM', 'Medium')) {
                $errorMessage = $null
                try {
                    [void](Assert-StandardValidationFindings `
                            -Envelope ([pscustomobject][ordered]@{ findings = @([pscustomobject][ordered]@{ severity = $severityVariant }) }) `
                            -Context $context)
                }
                catch { $errorMessage = [string]$_.Exception.Message }
                Assert-True ($errorMessage -match 'unknown severity') "$context accepted noncanonical severity '$severityVariant'."
            }
            Assert-True ([bool](Assert-StandardValidationFindings `
                        -Envelope ([pscustomobject][ordered]@{ findings = @([pscustomobject][ordered]@{ severity = 'medium' }) }) `
                        -Context $context)) "$context did not require human review for lowercase medium."
            foreach ($severity in @('critical', 'high')) {
                $errorMessage = $null
                try {
                    [void](Assert-StandardValidationFindings `
                            -Envelope ([pscustomobject][ordered]@{ findings = @([pscustomobject][ordered]@{ severity = $severity }) }) `
                            -Context $context)
                }
                catch { $errorMessage = [string]$_.Exception.Message }
                Assert-True ($errorMessage -match 'contains a') "$context failed to reject lowercase $severity severity."
            }
            foreach ($severity in @('low', 'informational')) {
                Assert-False ([bool](Assert-StandardValidationFindings `
                            -Envelope ([pscustomobject][ordered]@{ findings = @([pscustomobject][ordered]@{ severity = $severity }) }) `
                            -Context $context)) "$context changed the no-human-review behavior for lowercase $severity."
            }
        }

        $nonStringError = $null
        try {
            [void](Assert-StandardValidationFindings `
                    -Envelope ([pscustomobject][ordered]@{ findings = @([pscustomobject][ordered]@{ severity = 1 }) }) `
                    -Context 'typed severity')
        }
        catch { $nonStringError = [string]$_.Exception.Message }
        Assert-True ($nonStringError -match 'unknown severity') 'The runner accepted a non-string severity value.'

        $candidateInventory = Get-StandardValidationInventory -Root $fixture.Candidate -Context 'ordinal severity candidate'
        $candidateContentSha = Get-StandardValidationInventorySha256 -Inventory $candidateInventory
        $adapterSha = Get-StandardValidationFileSha256 -Path $fixture.Adapter -Context 'ordinal severity adapter'
        $candidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$candidateContentSha`n$adapterSha`n")
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        try {
            foreach ($severityVariant in @('MEDIUM', 'Medium')) {
                $aiPath = Join-Path $fixture.Root "ai-$severityVariant.json"
                Write-TestAiReviewEvidence `
                    -Fixture $fixture `
                    -Path $aiPath `
                    -CandidateId $candidateId `
                    -ReviewFindings @([ordered]@{ severity = $severityVariant }) `
                    -FindingDisposition @([ordered]@{ disposition = 'accepted'; findingId = 'finding-1' }) `
                    -Rsa $rsa
                $aiEvidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $aiPath | ConvertFrom-Json
                $aiError = $null
                try {
                    [void](Assert-StandardValidationAiReviewEvidence `
                            -Evidence $aiEvidence `
                            -CandidateId $candidateId `
                            -TrustAnchorRoot $fixture.TrustedTools `
                            -Context 'signed AI ordinal severity')
                }
                catch { $aiError = [string]$_.Exception.Message }
                Assert-True ($aiError -match 'non-canonical severity') "A validly signed AI review accepted severity '$severityVariant' or failed for another reason: '$aiError'."

                $semanticPath = Join-Path $fixture.Root "semantic-$severityVariant.json"
                Write-TestSemanticEvidence `
                    -Fixture $fixture `
                    -Path $semanticPath `
                    -CandidateId $candidateId `
                    -Rsa $rsa `
                    -Findings @([pscustomobject][ordered]@{ severity = $severityVariant })
                $semanticEvidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $semanticPath | ConvertFrom-Json
                $semanticError = $null
                try {
                    [void](Assert-StandardValidationSemanticEvidence `
                            -Evidence $semanticEvidence `
                            -CandidateId $candidateId `
                            -TrustAnchorRoot $fixture.TrustedTools `
                            -Context 'signed v1 semantic ordinal severity')
                }
                catch { $semanticError = [string]$_.Exception.Message }
                Assert-True ($semanticError -match 'non-canonical severity') "A validly signed v1 semantic result accepted severity '$severityVariant' or failed for another reason: '$semanticError'."
            }
        }
        finally { $rsa.Dispose() }
    }

    # Scenario: Lifecycle evidence is supplied after validation, first without and then with independent human/release evidence.
    # Purpose: Prove that AI review cannot substitute for human approval and that a development harness is never release-eligible.
    It 'InterT90_keeps_ai_review_human_approval_and_release_evidence_independent' {
        $aiOnlyFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'ai-only')
        . $script:RunnerPath `
            -CandidateRoot $aiOnlyFixture.Candidate `
            -AdapterPath $aiOnlyFixture.Adapter `
            -ArtifactsRoot $aiOnlyFixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $aiOnlyAdapterSha = Get-StandardValidationFileSha256 -Path $aiOnlyFixture.Adapter -Context 'test adapter'
        $aiOnlyInventory = Get-StandardValidationInventory -Root $aiOnlyFixture.Candidate -Context 'test candidate'
        $aiOnlyContentSha = Get-StandardValidationInventorySha256 -Inventory $aiOnlyInventory
        $aiOnlyCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$aiOnlyContentSha`n$aiOnlyAdapterSha`n")
        $aiEvidence = Join-Path $aiOnlyFixture.Root 'ai-review.json'
        Write-TestAiReviewEvidence -Fixture $aiOnlyFixture -Path $aiEvidence -CandidateId $aiOnlyCandidateId
        $aiOnlyResult = Invoke-RunnerFixture -Fixture $aiOnlyFixture -CompleteLifecycle -AiReviewEvidencePath $aiEvidence
        Assert-Equal $aiOnlyResult.Evidence.state 'BLOCKED' 'AI review evidence alone must not satisfy human approval.'
        Assert-Equal (@($aiOnlyResult.Evidence.stages | Where-Object id -eq 'ai-review')[0].status) 'passed' 'AI review evidence should be recorded independently before the block.'
        Assert-Equal (@($aiOnlyResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'Missing human approval must block the lifecycle.'

        $unsignedAiFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'unsigned-ai-review')
        $unsignedAiAdapterSha = Get-StandardValidationFileSha256 -Path $unsignedAiFixture.Adapter -Context 'test adapter'
        $unsignedAiInventory = Get-StandardValidationInventory -Root $unsignedAiFixture.Candidate -Context 'test candidate'
        $unsignedAiContentSha = Get-StandardValidationInventorySha256 -Inventory $unsignedAiInventory
        $unsignedAiCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$unsignedAiContentSha`n$unsignedAiAdapterSha`n")
        $unsignedAiEvidence = Join-Path $unsignedAiFixture.Root 'ai-review.json'
        Write-TestAiReviewEvidence -Fixture $unsignedAiFixture -Path $unsignedAiEvidence -CandidateId $unsignedAiCandidateId
        $unsignedAiObject = Get-Content -Raw -Encoding UTF8 -LiteralPath $unsignedAiEvidence | ConvertFrom-Json
        $unsignedAiObject.PSObject.Properties.Remove('attestation')
        Write-TestUtf8File -Path $unsignedAiEvidence -Text ($unsignedAiObject | ConvertTo-Json -Depth 50)
        $unsignedAiResult = Invoke-RunnerFixture -Fixture $unsignedAiFixture -CompleteLifecycle -AiReviewEvidencePath $unsignedAiEvidence
        Assert-Equal $unsignedAiResult.Evidence.state 'BLOCKED' 'A candidate-bound PASS without a trusted AI attestation must not pass.'
        Assert-Match $unsignedAiResult.Output 'attestation|signature' 'Unsigned AI review evidence must fail at the attestation barrier.'

        $blockedAiFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'blocked-ai-review')
        $blockedAiAdapterSha = Get-StandardValidationFileSha256 -Path $blockedAiFixture.Adapter -Context 'test adapter'
        $blockedAiInventory = Get-StandardValidationInventory -Root $blockedAiFixture.Candidate -Context 'test candidate'
        $blockedAiContentSha = Get-StandardValidationInventorySha256 -Inventory $blockedAiInventory
        $blockedAiCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$blockedAiContentSha`n$blockedAiAdapterSha`n")
        $blockedAiEvidence = Join-Path $blockedAiFixture.Root 'ai-review.json'
        Write-TestUtf8File -Path $blockedAiEvidence -Text ([ordered]@{
                schemaVersion = 1
                evidenceType = 'ai-review'
                candidateId = $blockedAiCandidateId
                status = 'passed'
                decision = 'BLOCK'
                reviewedCandidate = $blockedAiCandidateId
                reviewFindings = @([ordered]@{ severity = 'high' })
                findingDisposition = @([ordered]@{ findingId = 'finding-1'; disposition = 'accepted' })
            } | ConvertTo-Json -Depth 10)
        $blockedAiResult = Invoke-RunnerFixture -Fixture $blockedAiFixture -CompleteLifecycle -AiReviewEvidencePath $blockedAiEvidence
        Assert-True ($blockedAiResult.Evidence.state -ne 'PASS') 'AI evidence with a BLOCK decision must not pass as lifecycle evidence.'

        $ambiguousInventoryFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'ambiguous-inventory')
        $ambiguousInventoryAdapterSha = Get-StandardValidationFileSha256 -Path $ambiguousInventoryFixture.Adapter -Context 'test adapter'
        $ambiguousInventory = Get-StandardValidationInventory -Root $ambiguousInventoryFixture.Candidate -Context 'test candidate'
        $ambiguousContentSha = Get-StandardValidationInventorySha256 -Inventory $ambiguousInventory
        $ambiguousCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$ambiguousContentSha`n$ambiguousInventoryAdapterSha`n")
        $ambiguousAiEvidence = Join-Path $ambiguousInventoryFixture.Root 'ai-review.json'
        $ambiguousHumanEvidence = Join-Path $ambiguousInventoryFixture.Root 'human-approval.json'
        $ambiguousPublishEvidence = Join-Path $ambiguousInventoryFixture.Root 'publish-install.json'
        $ambiguousPostEvidence = Join-Path $ambiguousInventoryFixture.Root 'post-install.json'
        $ambiguousRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        Write-TestAiReviewEvidence -Fixture $ambiguousInventoryFixture -Path $ambiguousAiEvidence -CandidateId $ambiguousCandidateId -Rsa $ambiguousRsa
        Write-TestHumanApprovalEvidence -Fixture $ambiguousInventoryFixture -Path $ambiguousHumanEvidence -CandidateId $ambiguousCandidateId
        try {
            Write-TestUtf8File -Path (Join-Path $ambiguousInventoryFixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $ambiguousRsa.ToXmlString($false)
            Write-TestLifecycleEvidence -Path $ambiguousPublishEvidence -EvidenceType 'publish-install' -CandidateId $ambiguousCandidateId -Rsa $ambiguousRsa
            Write-TestLifecycleEvidence -Path $ambiguousPostEvidence -EvidenceType 'post-install' -CandidateId $ambiguousCandidateId -Rsa $ambiguousRsa -InstalledInventory @('skill;alpha', 'skill', 'beta')
        }
        finally { $ambiguousRsa.Dispose() }
        $ambiguousResult = Invoke-RunnerFixture -Fixture $ambiguousInventoryFixture -CompleteLifecycle -AiReviewEvidencePath $ambiguousAiEvidence -HumanApprovalEvidencePath $ambiguousHumanEvidence -PublishInstallEvidencePath $ambiguousPublishEvidence -PostInstallEvidencePath $ambiguousPostEvidence
        Assert-Equal $ambiguousResult.Evidence.state 'PASS' 'Signed post-install inventory entries containing delimiters must remain unambiguous and verifiable.'

        $forgedFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'forged-human-approval')
        $forgedAdapterSha = Get-StandardValidationFileSha256 -Path $forgedFixture.Adapter -Context 'test adapter'
        $forgedInventory = Get-StandardValidationInventory -Root $forgedFixture.Candidate -Context 'test candidate'
        $forgedContentSha = Get-StandardValidationInventorySha256 -Inventory $forgedInventory
        $forgedCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$forgedContentSha`n$forgedAdapterSha`n")
        $forgedAiEvidence = Join-Path $forgedFixture.Root 'ai-review.json'
        $forgedHumanEvidence = Join-Path $forgedFixture.Root 'human-approval.json'
        Write-TestAiReviewEvidence -Fixture $forgedFixture -Path $forgedAiEvidence -CandidateId $forgedCandidateId
        Write-TestUtf8File -Path $forgedHumanEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'human-approval'; candidateId = $forgedCandidateId; status = 'approved'; approver = 'human@example.test'; approvalTimestamp = '2026-09-11T00:00:00Z' } | ConvertTo-Json -Depth 10)
        $forgedResult = Invoke-RunnerFixture -Fixture $forgedFixture -CompleteLifecycle -AiReviewEvidencePath $forgedAiEvidence -HumanApprovalEvidencePath $forgedHumanEvidence
        Assert-Equal $forgedResult.Evidence.state 'BLOCKED' 'Self-asserted human approval fields must not satisfy the approval barrier.'
        Assert-Match $forgedResult.Output 'attestation|trusted|signature' 'The failure must identify the missing trusted approval attestation.'
        Assert-Equal (@($forgedResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'Unattested human approval must block the lifecycle.'

        $tamperedFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'tampered-human-approval')
        $tamperedAdapterSha = Get-StandardValidationFileSha256 -Path $tamperedFixture.Adapter -Context 'test adapter'
        $tamperedInventory = Get-StandardValidationInventory -Root $tamperedFixture.Candidate -Context 'test candidate'
        $tamperedContentSha = Get-StandardValidationInventorySha256 -Inventory $tamperedInventory
        $tamperedCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$tamperedContentSha`n$tamperedAdapterSha`n")
        $tamperedAiEvidence = Join-Path $tamperedFixture.Root 'ai-review.json'
        $tamperedHumanEvidence = Join-Path $tamperedFixture.Root 'human-approval.json'
        Write-TestAiReviewEvidence -Fixture $tamperedFixture -Path $tamperedAiEvidence -CandidateId $tamperedCandidateId
        Write-TestHumanApprovalEvidence -Fixture $tamperedFixture -Path $tamperedHumanEvidence -CandidateId $tamperedCandidateId
        $tamperedText = Get-Content -Raw -Encoding UTF8 -LiteralPath $tamperedHumanEvidence
        $tamperedText = $tamperedText -replace '("signature"\s*:\s*")[^"]+("\s*})', '$1AAAA$2'
        Write-TestUtf8File -Path $tamperedHumanEvidence -Text $tamperedText
        $tamperedResult = Invoke-RunnerFixture -Fixture $tamperedFixture -CompleteLifecycle -AiReviewEvidencePath $tamperedAiEvidence -HumanApprovalEvidencePath $tamperedHumanEvidence
        Assert-Equal $tamperedResult.Evidence.state 'BLOCKED' 'A tampered human approval signature must not pass the approval barrier.'
        Assert-Match $tamperedResult.Output 'signature verification failed' 'The failure must identify signature verification failure.'
        Assert-Equal (@($tamperedResult.Evidence.stages | Where-Object id -eq 'human-approval')[0].status) 'blocked' 'A tampered approval signature must block the lifecycle.'

        $forgedLifecycleFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'forged-lifecycle-evidence')
        $forgedLifecycleAdapterSha = Get-StandardValidationFileSha256 -Path $forgedLifecycleFixture.Adapter -Context 'test adapter'
        $forgedLifecycleInventory = Get-StandardValidationInventory -Root $forgedLifecycleFixture.Candidate -Context 'test candidate'
        $forgedLifecycleContentSha = Get-StandardValidationInventorySha256 -Inventory $forgedLifecycleInventory
        $forgedLifecycleCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$forgedLifecycleContentSha`n$forgedLifecycleAdapterSha`n")
        $forgedLifecycleAiEvidence = Join-Path $forgedLifecycleFixture.Root 'ai-review.json'
        $forgedLifecycleHumanEvidence = Join-Path $forgedLifecycleFixture.Root 'human-approval.json'
        $forgedLifecyclePublishEvidence = Join-Path $forgedLifecycleFixture.Root 'publish-install.json'
        Write-TestAiReviewEvidence -Fixture $forgedLifecycleFixture -Path $forgedLifecycleAiEvidence -CandidateId $forgedLifecycleCandidateId
        Write-TestHumanApprovalEvidence -Fixture $forgedLifecycleFixture -Path $forgedLifecycleHumanEvidence -CandidateId $forgedLifecycleCandidateId
        Write-TestUtf8File -Path $forgedLifecyclePublishEvidence -Text ([ordered]@{ schemaVersion = 1; evidenceType = 'publish-install'; candidateId = $forgedLifecycleCandidateId; status = 'authorized'; authorization = $true; releaseIdentity = 'release-example' } | ConvertTo-Json -Depth 10)
        $forgedLifecycleResult = Invoke-RunnerFixture -Fixture $forgedLifecycleFixture -CompleteLifecycle -AiReviewEvidencePath $forgedLifecycleAiEvidence -HumanApprovalEvidencePath $forgedLifecycleHumanEvidence -PublishInstallEvidencePath $forgedLifecyclePublishEvidence
        Assert-Equal $forgedLifecycleResult.Evidence.state 'BLOCKED' 'Self-asserted publish/install fields must not satisfy the lifecycle barrier.'
        Assert-Match $forgedLifecycleResult.Output 'attestation|trusted|signature' 'The failure must identify the missing trusted lifecycle attestation.'
        Assert-Equal (@($forgedLifecycleResult.Evidence.stages | Where-Object id -eq 'publish-or-install')[0].status) 'blocked' 'Unattested publish/install evidence must block the lifecycle.'

        $fullFixture = New-RunnerFixture -Root (Join-Path $TestDrive 'full-lifecycle')
        $fullAdapterSha = Get-StandardValidationFileSha256 -Path $fullFixture.Adapter -Context 'test adapter'
        $fullInventory = Get-StandardValidationInventory -Root $fullFixture.Candidate -Context 'test candidate'
        $fullContentSha = Get-StandardValidationInventorySha256 -Inventory $fullInventory
        $fullCandidateId = Get-StandardValidationTextSha256 -Value ("https://example.com/example/skills.git`n$('a' * 40)`n$('b' * 40)`nlocal`n$fullContentSha`n$fullAdapterSha`n")
        $fullAiEvidence = Join-Path $fullFixture.Root 'ai-review.json'
        $fullHumanEvidence = Join-Path $fullFixture.Root 'human-approval.json'
        $fullPublishEvidence = Join-Path $fullFixture.Root 'publish-install.json'
        $fullPostEvidence = Join-Path $fullFixture.Root 'post-install.json'
        $lifecycleRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        Write-TestAiReviewEvidence -Fixture $fullFixture -Path $fullAiEvidence -CandidateId $fullCandidateId -Rsa $lifecycleRsa
        Write-TestHumanApprovalEvidence -Fixture $fullFixture -Path $fullHumanEvidence -CandidateId $fullCandidateId
        try {
            Write-TestUtf8File -Path (Join-Path $fullFixture.TrustedTools 'trusted-supervisor-public-key.xml') -Text $lifecycleRsa.ToXmlString($false)
            Write-TestLifecycleEvidence -Path $fullPublishEvidence -EvidenceType 'publish-install' -CandidateId $fullCandidateId -Rsa $lifecycleRsa
            Write-TestLifecycleEvidence -Path $fullPostEvidence -EvidenceType 'post-install' -CandidateId $fullCandidateId -Rsa $lifecycleRsa
        }
        finally { $lifecycleRsa.Dispose() }
        $fullResult = Invoke-RunnerFixture -Fixture $fullFixture -CompleteLifecycle -AiReviewEvidencePath $fullAiEvidence -HumanApprovalEvidencePath $fullHumanEvidence -PublishInstallEvidencePath $fullPublishEvidence -PostInstallEvidencePath $fullPostEvidence
        Assert-Equal $fullResult.Evidence.state 'PASS' 'Complete lifecycle evidence should pass the development behavior fixture.'
        Assert-False ([bool]$fullResult.Evidence.releaseEligible) 'Development harness evidence must never be release-eligible.'
        foreach ($stageId in @('ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')) {
            Assert-Equal (@($fullResult.Evidence.stages | Where-Object id -eq $stageId)[0].status) 'passed' "Lifecycle stage '$stageId' must be independently recorded."
        }
    }

    # Scenario: A signed v2 artifact supplies numeric purpose/keyId values that stringify to the caller's expected strings.
    # Purpose: Keep JSON Schema native-string requirements enforced before comparison in both the verifier and runner.
    It 'InterT192_rejects_numeric_v2_purpose_and_key_id_in_verifier_and_runner' {
        $readJsonPreservingTimestampStrings = {
            param([string] $Path)
            $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
            if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                return ConvertFrom-Json -InputObject $text -DateKind String
            }
            return ConvertFrom-Json -InputObject $text
        }
        $signEvidence = {
            param($Evidence, $Rsa)
            $unsigned = [ordered]@{}
            foreach ($property in @($Evidence.PSObject.Properties | Where-Object { $_.Name -ne 'attestation' })) {
                $unsigned[$property.Name] = $property.Value
            }
            $unsignedBytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes(
                (Get-StandardSemanticBridgeCanonicalJson -Value ([pscustomobject]$unsigned))
            )
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $Evidence.attestation.signedPayloadSha256 = ([BitConverter]::ToString($sha256.ComputeHash($unsignedBytes))).Replace('-', '').ToLowerInvariant()
            }
            finally { $sha256.Dispose() }
            $Evidence.attestation.signature = [Convert]::ToBase64String(
                $Rsa.SignData($unsignedBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            )
            return (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes(
                (Get-StandardSemanticBridgeCanonicalJson -Value $Evidence)
            )
        }

        foreach ($case in @('purpose', 'keyId')) {
            $fixture = New-RunnerFixture -Root (Join-Path $TestDrive "semantic-v2-numeric-$case")
            $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
            try {
                $request = & $readJsonPreservingTimestampStrings $artifacts.RequestPath
                $decision = & $readJsonPreservingTimestampStrings $artifacts.DecisionPath
                $evidence = & $readJsonPreservingTimestampStrings $artifacts.EvidencePath
                $expectedKeyId = $artifacts.KeyId
                $expectedPurpose = [string]$request.purpose

                if ($case -ceq 'purpose') {
                    $request.purpose = '42'
                    $decision.purpose = '42'
                    $requestPayload = [ordered]@{}
                    foreach ($property in @($request.PSObject.Properties | Where-Object { $_.Name -ne 'consentPayloadSha256' })) { $requestPayload[$property.Name] = $property.Value }
                    $request.consentPayloadSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$requestPayload)
                    $decision.consentRequestSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $request
                    $decisionPayload = [ordered]@{}
                    foreach ($property in @($decision.PSObject.Properties | Where-Object { $_.Name -ne 'consentDecisionPayloadSha256' })) { $decisionPayload[$property.Name] = $property.Value }
                    $decision.consentDecisionPayloadSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$decisionPayload)
                    $evidence.consent.consentRequestSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $request
                    $evidence.consent.consentArtifactSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $decision
                    $evidence.purpose = [int]42
                    $expectedPurpose = '42'
                }
                else {
                    $evidence.attestation.keyId = [int]42
                    $expectedKeyId = '42'
                }

                $evidenceBytes = & $signEvidence $evidence $artifacts.Rsa
                $direct = Test-StandardSemanticBridgeEvidence `
                    -EvidenceBytes $evidenceBytes `
                    -ConsentRequest $request `
                    -ConsentDecision $decision `
                    -PublicKey $artifacts.Rsa `
                    -ExpectedKeyId $expectedKeyId `
                    -ExpectedBindings $artifacts.Bindings `
                    -ExpectedProviderRoute $artifacts.Route `
                    -ExpectedPurpose $expectedPurpose `
                    -ExpectedScope $artifacts.Scope `
                    -ExpectedProviderTextInventory $artifacts.Inventory `
                    -Now ([DateTime]::UtcNow)
                Assert-False ([bool]$direct.valid) "A re-signed numeric $case value must be rejected by the semantic bridge verifier."
                Assert-Match ([string]$direct.reason) 'non-empty scalar string' "The verifier must identify the numeric $case type violation."

                Write-TestUtf8File -Path $artifacts.RequestPath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $request)
                Write-TestUtf8File -Path $artifacts.DecisionPath -Text (Get-StandardSemanticBridgeCanonicalJson -Value $decision)
                Write-TestUtf8File -Path $artifacts.EvidencePath -Text ((New-Object System.Text.UTF8Encoding($false, $true)).GetString($evidenceBytes))
                $runner = Invoke-RunnerFixture `
                    -Fixture $fixture `
                    -SemanticTriggered `
                    -SemanticConsentRequestPath $artifacts.RequestPath `
                    -SemanticConsentDecisionPath $artifacts.DecisionPath `
                    -SemanticEvidencePath $artifacts.EvidencePath `
                    -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                    -SemanticPublicKeyId $expectedKeyId `
                    -ValidationRunId $artifacts.RunId
                Assert-Equal $runner.ExitCode 10 "A signed numeric $case field must produce BLOCKED=10 at the runner boundary."
                Assert-Equal $runner.Evidence.state 'BLOCKED' "A signed numeric $case field must never pass through the runner."
                Assert-Match ([string]$runner.Evidence.failure.message) 'non-empty scalar string' "The runner must surface the numeric $case schema failure."
            }
            finally { $artifacts.Rsa.Dispose() }
        }
    }

    # Scenario: A lexical path below a symlink/junction points into the candidate or artifact roots.
    # Purpose: Reject every external v2 input at the canonical-path gate before parsing or reading candidate-controlled bytes.
    It 'InterT193_rejects_symlinked_ancestors_for_all_external_v2_inputs_before_read' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-external-input-aliases')
        . $script:RunnerPath `
            -CandidateRoot $fixture.Candidate `
            -AdapterPath $fixture.Adapter `
            -ArtifactsRoot $fixture.Artifacts `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -TrustedToolRoot $fixture.TrustedTools `
            -DefineFunctionsOnly

        $malformedTargetFiles = @{
            'consent request' = Join-Path $fixture.Candidate 'syp154-alias-request.json'
            'consent decision' = Join-Path $fixture.Candidate 'syp154-alias-decision.json'
            'evidence' = Join-Path $fixture.Candidate 'syp154-alias-evidence.json'
            'public key' = Join-Path $fixture.Artifacts 'syp154-alias-public-key.xml'
        }
        foreach ($targetFile in $malformedTargetFiles.Values) { Write-TestUtf8File -Path $targetFile -Text 'not-json-or-a-public-key' }

        foreach ($aliasedName in @('consent request', 'consent decision', 'evidence', 'public key')) {
            $targetRoot = if ($aliasedName -ceq 'public key') { $fixture.Artifacts } else { $fixture.Candidate }
            $aliasRoot = Join-Path $fixture.Root ("alias-" + ($aliasedName -replace ' ', '-'))
            $linkType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
            [void](New-Item -ItemType $linkType -Path $aliasRoot -Target $targetRoot -ErrorAction Stop)
            $aliasedPath = Join-Path $aliasRoot (Split-Path -Leaf $malformedTargetFiles[$aliasedName])
            $paths = @{
                'consent request' = Join-Path $fixture.Root 'unused-request.json'
                'consent decision' = Join-Path $fixture.Root 'unused-decision.json'
                'evidence' = Join-Path $fixture.Root 'unused-evidence.json'
                'public key' = Join-Path $fixture.Root 'unused-public-key.xml'
            }
            $paths[$aliasedName] = $aliasedPath

            $failure = $null
            try {
                [void](Assert-StandardValidationSemanticBridgeV2Evidence `
                    -ConsentRequestPath $paths['consent request'] `
                    -ConsentDecisionPath $paths['consent decision'] `
                    -EvidencePath $paths['evidence'] `
                    -PublicKeyPath $paths['public key'] `
                    -ExpectedKeyId 'unused-key-id' `
                    -CandidateId ('a' * 64) `
                    -SourceRepository 'https://example.com/example/skills.git' `
                    -SourceRevision ('a' * 40) `
                    -BaseRevision ('b' * 40) `
                    -ExpectedCandidateContentSha256 ('c' * 64) `
                    -SnapshotRoot $fixture.Candidate `
                    -CandidateInventory @([pscustomobject]@{ path = 'skills/alpha/SKILL.md'; sha256 = ('c' * 64); length = 1 }) `
                    -CandidateRoot $fixture.Candidate `
                    -ArtifactsRoot $fixture.Artifacts `
                    -DevelopmentHarness $true `
                    -CurrentRunId ([guid]::NewGuid())
                )
            }
            catch { $failure = [string]$_.Exception.Message }
            Assert-Match $failure 'symlinked or reparse-point ancestor' "The '$aliasedName' input must fail at the canonical path gate."
            Assert-Match $failure ([regex]::Escape($aliasedName)) "The canonical path failure must identify '$aliasedName'."
        }
    }

    # Scenario: A v2 runner import receives evidence with a parseable but non-RFC 3339 generatedAt value and a valid recomputed signature.
    # Purpose: The runner must rely on the shared verifier's schema gate and report BLOCKED=10 for signed lexical timestamp violations.
    It 'InterT194_blocks_resigned_non_rfc3339_v2_timestamp_at_runner_import' {
        $fixture = New-RunnerFixture -Root (Join-Path $TestDrive 'semantic-v2-non-rfc3339-timestamp')
        $artifacts = New-TestRunnerSemanticV2Artifacts -Fixture $fixture
        try {
            $baseline = Invoke-RunnerFixture `
                -Fixture $fixture `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifacts.RequestPath `
                -SemanticConsentDecisionPath $artifacts.DecisionPath `
                -SemanticEvidencePath $artifacts.EvidencePath `
                -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                -SemanticPublicKeyId $artifacts.KeyId `
                -ValidationRunId $artifacts.RunId
            Assert-Equal $baseline.ExitCode 0 'A canonical RFC 3339 v2 artifact must pass the runner import baseline.'
            Assert-Equal $baseline.Evidence.state 'PASS' 'A canonical RFC 3339 v2 artifact must produce PASS before the malformed timestamp mutation.'

            $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $evidence = ConvertFrom-Json -InputObject $utf8.GetString([byte[]]$artifacts.EvidenceBytes)
            $rawTimestamp = $evidence.generatedAt
            if ($rawTimestamp -is [DateTime]) { $timestamp = [DateTimeOffset]::new(([DateTime]$rawTimestamp).ToUniversalTime()) }
            elseif ($rawTimestamp -is [DateTimeOffset]) { $timestamp = ([DateTimeOffset]$rawTimestamp).ToUniversalTime() }
            else { $timestamp = [DateTimeOffset]::Parse([string]$rawTimestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None).ToUniversalTime() }
            $evidence.generatedAt = $timestamp.ToString('MM/dd/yyyy HH:mm:ss.fff zzz', [Globalization.CultureInfo]::InvariantCulture)
            $unsigned = [ordered]@{}
            foreach ($property in @($evidence.PSObject.Properties | Where-Object { $_.Name -ne 'attestation' })) { $unsigned[$property.Name] = $property.Value }
            $unsignedBytes = $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value ([pscustomobject]$unsigned)))
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $evidence.attestation.signedPayloadSha256 = ([BitConverter]::ToString($sha256.ComputeHash($unsignedBytes))).Replace('-', '').ToLowerInvariant()
            }
            finally { $sha256.Dispose() }
            $evidence.attestation.signature = [Convert]::ToBase64String(
                $artifacts.Rsa.SignData($unsignedBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            )
            $evidenceBytes = $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $evidence))
            $direct = Test-StandardSemanticBridgeEvidence `
                -EvidenceBytes $evidenceBytes `
                -ConsentRequest $artifacts.Request `
                -ConsentDecision $artifacts.Decision `
                -PublicKey $artifacts.Rsa `
                -ExpectedKeyId $artifacts.KeyId `
                -ExpectedBindings $artifacts.Bindings `
                -ExpectedProviderRoute $artifacts.Route `
                -ExpectedPurpose 'Synthetic runner v2 semantic review.' `
                -ExpectedScope $artifacts.Scope `
                -ExpectedProviderTextInventory $artifacts.Inventory `
                -Now ([DateTime]::UtcNow)
            Assert-False ([bool]$direct.valid) 'A re-signed locale-formatted generatedAt value must fail the shared verifier.'
            Assert-Match ([string]$direct.reason) 'RFC 3339' 'The verifier must identify the timestamp lexical contract failure.'

            Write-TestUtf8File -Path $artifacts.EvidencePath -Text $utf8.GetString($evidenceBytes)
            $invalidRunnerArtifactsRoot = Join-Path $fixture.Root 'invalid-timestamp-runner-artifacts'
            $runner = Invoke-RunnerFixture `
                -Fixture $fixture `
                -ArtifactsRoot $invalidRunnerArtifactsRoot `
                -SemanticTriggered `
                -SemanticConsentRequestPath $artifacts.RequestPath `
                -SemanticConsentDecisionPath $artifacts.DecisionPath `
                -SemanticEvidencePath $artifacts.EvidencePath `
                -SemanticPublicKeyPath $artifacts.PublicKeyPath `
                -SemanticPublicKeyId $artifacts.KeyId `
                -ValidationRunId $artifacts.RunId
            Assert-Equal $runner.ExitCode 10 "A signed non-RFC 3339 timestamp must produce BLOCKED=10 at the runner import boundary. state=$($runner.Evidence.state); failure.message=$($runner.Evidence.failure.message)"
            Assert-Equal $runner.Evidence.state 'BLOCKED' 'A signed non-RFC 3339 timestamp must never produce PASS.'
            Assert-Match ([string]$runner.Evidence.failure.message) 'RFC 3339' 'The runner must retain the timestamp schema failure.'
        }
        finally { $artifacts.Rsa.Dispose() }
    }
}

Describe 'Pester shard plan contract' {
    # Scenario: The complete repository suite contains many non-isolated test files and one file can terminate its hosted PowerShell process.
    # Purpose: Give every bulk test file an independent owned process by default while retaining an exact, configurable partition for bounded diagnostics.
    It 'UnitT10_partitions_bulk_tests_into_independent_owned_processes_by_default' {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $shardPath = Join-Path $repositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($shardPath, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw 'The shard executor must parse before shard-plan testing.' }
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'New-PesterShardPlan'
        }, $true)
        if ($null -eq $definition) { throw 'The shard executor must expose a testable deterministic shard planner.' }
        Invoke-Expression $definition.Extent.Text

        $testRoot = Join-Path $TestDrive 'shard-plan-tests'
        $allPaths = @(
            (Join-Path $testRoot 'alpha.Tests.ps1'),
            (Join-Path $testRoot 'standard-validation-runner.Tests.ps1'),
            (Join-Path $testRoot 'beta.Tests.ps1'),
            (Join-Path $testRoot 'syp101-production-smoke-contract.Tests.ps1'),
            (Join-Path $testRoot 'gamma.Tests.ps1')
        )
        $isolatedNames = @(
            'standard-validation-runner.Tests.ps1',
            'syp101-production-smoke-contract.Tests.ps1'
        )

        $defaultPlan = @(New-PesterShardPlan -AllTestPaths $allPaths -IsolatedTestFileNames $isolatedNames)
        if ($defaultPlan.Count -ne 5) { throw 'The default plan must create one owned process per discovered test file.' }
        if (@($defaultPlan | Where-Object { @($_.Paths).Count -ne 1 }).Count -ne 0) { throw 'Every default shard must contain exactly one test file.' }
        $defaultPartition = @($defaultPlan | ForEach-Object { @($_.Paths) })
        if ((($defaultPartition | Sort-Object) -join "`n") -cne (($allPaths | Sort-Object) -join "`n")) { throw 'The default shard plan must be an exact partition of the discovered inventory.' }
        if (@($defaultPartition | Group-Object | Where-Object { $_.Count -ne 1 }).Count -ne 0) { throw 'No test file may be duplicated across shards.' }
        if ([string]$defaultPlan[2].Name -notmatch '^bulk-001-alpha$') { throw 'A single-file bulk shard name must identify its deterministic ordinal and public test basename.' }

        $reversedPlan = @(New-PesterShardPlan -AllTestPaths @($allPaths[4], $allPaths[3], $allPaths[2], $allPaths[1], $allPaths[0]) -IsolatedTestFileNames $isolatedNames)
        if ((($reversedPlan | ForEach-Object { "{0}:{1}" -f $_.Name, (@($_.Paths) -join '|') }) -join "`n") -cne
            (($defaultPlan | ForEach-Object { "{0}:{1}" -f $_.Name, (@($_.Paths) -join '|') }) -join "`n")) {
            throw 'Shard identities and path order must be ordinally deterministic regardless of discovery order or host culture.'
        }

        $groupedPlan = @(New-PesterShardPlan -AllTestPaths $allPaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 2)
        if ($groupedPlan.Count -ne 4) { throw 'An explicit group size must retain two isolated shards and two bounded bulk shards.' }
        if (@($groupedPlan[2].Paths).Count -ne 2) { throw 'The first configured bulk shard must contain at most the configured number of paths.' }
        if (@($groupedPlan[3].Paths).Count -ne 1) { throw 'The final configured bulk shard must retain the remainder without padding or omission.' }
        $groupedPartition = @($groupedPlan | ForEach-Object { @($_.Paths) })
        if ((($groupedPartition | Sort-Object) -join "`n") -cne (($allPaths | Sort-Object) -join "`n")) { throw 'A configured shard plan must remain an exact partition.' }
    }
}

Describe 'source conformance projection' {
    BeforeAll {
        $script:SourceProjectionRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceProjectionRunnerPath = Join-Path $script:SourceProjectionRepositoryRoot 'scripts/Invoke-StandardValidation.ps1'
        $script:SourceProjectionArtifactRoot = Join-Path $TestDrive 'source-projection-artifacts'
        [void](New-Item -ItemType Directory -Path $script:SourceProjectionArtifactRoot -Force)
        . $script:SourceProjectionRunnerPath `
            -CandidateRoot $script:SourceProjectionRepositoryRoot `
            -AdapterPath $script:SourceProjectionRunnerPath `
            -ArtifactsRoot $script:SourceProjectionRepositoryRoot `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly

        function Assert-SourceProjectionEqual {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-SourceProjectionFailure {
            param($InputValue, [string] $ExpectedReason)
            try {
                $projection = New-StandardValidationSourceConformanceResult `
                    -Report $InputValue.report `
                    -ExpectedSourceRevision ('a' * 40) `
                    -RepositoryTestEvidence $InputValue.tests `
                    -RepositoryTestDispatches $InputValue.dispatches
            }
            catch {
                throw "Projection threw while testing '$ExpectedReason': $($_.Exception.Message) $($_.ScriptStackTrace)"
            }
            Assert-SourceProjectionEqual $projection.status 'failed' "Projection must reject '$ExpectedReason'."
            if (@($projection.failureReasons) -notcontains $ExpectedReason) { throw "Projection must identify '$ExpectedReason'." }
            if ([bool]$projection.releaseEligible) { throw 'A failed source projection must remain release-ineligible.' }
        }

        function New-SourceProjectionEvent {
            param([string] $StageId, [string] $ToolId, [AllowNull()] $SkillId, [string] $CandidateId)
            $eventId = [guid]::NewGuid().ToString()
            $stdout = 'source projection fixture output'
            $stderr = ''
            $outputPath = Join-Path (Join-Path $script:SourceProjectionArtifactRoot $StageId) "event-$eventId.json"
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force)
            $rawOutput = [ordered]@{
                schemaVersion = 1
                eventId = $eventId
                stageId = $StageId
                toolId = $ToolId
                skillId = $SkillId
                candidateId = $CandidateId
                process = [ordered]@{ exitCode = 0; status = 'passed'; stdout = $stdout; stderr = $stderr; cleanedUp = $true }
                stdout = $stdout
                stderr = $stderr
            }
            [IO.File]::WriteAllText($outputPath, ($rawOutput | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
            return [pscustomobject][ordered]@{
                eventId = $eventId
                stageId = $StageId
                toolId = $ToolId
                skillId = $SkillId
                candidateId = $CandidateId
                commandSha256 = 'e' * 64
                exitCode = 0
                status = 'passed'
                outputSha256 = Get-StandardValidationOutputHash -Stdout $stdout -Stderr $stderr
                outputPath = $outputPath
                cleanedUp = $true
            }
        }

        function New-SourceProjectionRepositoryTestRecord {
            param(
                [Parameter(Mandatory = $true)] $Event,
                [Parameter(Mandatory = $true)][string] $ToolId,
                [Parameter(Mandatory = $true)][array] $Inventory,
                [Parameter(Mandatory = $true)] $TestResult,
                [ValidateSet('general', 'pester')][string] $Kind = 'pester'
            )
            $domainResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = "fixture:$ToolId" }
            $envelope = [ordered]@{
                schemaVersion = 1
                status = 'passed'
                decision = 'PASS'
                candidateIdentity = [string]$Event.candidateId
                testInventory = @($Inventory)
                testResult = $TestResult
                domainAdapterResult = $domainResult
            }
            $stdout = $envelope | ConvertTo-Json -Depth 20 -Compress
            $rawOutput = Get-Content -Raw -Encoding UTF8 -LiteralPath $Event.outputPath | ConvertFrom-Json
            $rawOutput.process.stdout = $stdout
            $rawOutput.stdout = $stdout
            [IO.File]::WriteAllText($Event.outputPath, ($rawOutput | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            $Event.outputSha256 = Get-StandardValidationOutputHash -Stdout $stdout -Stderr ''
            return [pscustomobject][ordered]@{
                toolRole = if ($Kind -ceq 'pester') { 'pester' } else { 'domain' }
                toolId = $ToolId
                eventId = [string]$Event.eventId
                candidateId = [string]$Event.candidateId
                outputSha256 = [string]$Event.outputSha256
                testInventory = @($Inventory)
                testResult = $TestResult
                domainAdapterResult = $domainResult
            }
        }

        function New-SourceProjectionInput {
            $sourceRevision = 'a' * 40
            $candidateId = 'b' * 64
            $contentSha256 = 'c' * 64
            $stageIds = @('controlled-acquisition', 'integrity-verification', 'package-validation', 'skillspector-static', 'repository-tests', 'conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')
            $stages = @()
            for ($index = 0; $index -lt $stageIds.Count; $index++) {
                $status = if ($index -lt 5) { 'passed' } elseif ($index -eq 5) { 'blocked' } else { 'not-applicable' }
                $stages += [pscustomobject][ordered]@{ order = $index + 1; id = $stageIds[$index]; condition = 'fixture'; status = $status; startedAt = '2026-09-25T00:00:00Z'; endedAt = '2026-09-25T00:00:01Z'; reason = $null; events = @() }
            }
            $stages[2].events = @(
                (New-SourceProjectionEvent 'package-validation' 'package-adapter' $null $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-validator' 'alpha' $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-tools' 'alpha' $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-validator' 'beta' $candidateId),
                (New-SourceProjectionEvent 'package-validation' 'skill-tools' 'beta' $candidateId)
            )
            $stages[3].events = @((New-SourceProjectionEvent 'skillspector-static' 'staticAnalyzer' $null $candidateId))
            $generalEvent = New-SourceProjectionEvent 'repository-tests' 'general.dispatch' $null $candidateId
            $pesterWindowsEvent = New-SourceProjectionEvent 'repository-tests' 'windows-pester' $null $candidateId
            $pesterLinuxEvent = New-SourceProjectionEvent 'repository-tests' 'linux.pester' $null $candidateId
            $stages[4].events = @($generalEvent, $pesterWindowsEvent, $pesterLinuxEvent)
            $report = [pscustomobject][ordered]@{
                schemaVersion = 1
                evidence = 'standard-validation-evidence-v1'
                contract = 'standard-validation-contract-v1'
                runId = [guid]::NewGuid().ToString()
                state = 'BLOCKED'
                exitCode = 10
                releaseEligible = $false
                artifacts = [pscustomobject][ordered]@{ root = $script:SourceProjectionArtifactRoot; lockPath = Join-Path $script:SourceProjectionArtifactRoot 'fixture.lock' }
                candidate = [pscustomobject][ordered]@{ sourceRepository = 'https://example.com/example/skills.git'; sourceRevision = $sourceRevision; baseRevision = 'b' * 40; eventName = 'pull_request'; candidateId = $candidateId; contentSha256 = $contentSha256; activeSkills = @('alpha', 'beta') }
                stages = $stages
            }
            $tests = @(
                (New-SourceProjectionRepositoryTestRecord -Event $generalEvent -ToolId 'general.dispatch' -Inventory @('tests/general.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS' }) -Kind general)
                (New-SourceProjectionRepositoryTestRecord -Event $pesterWindowsEvent -ToolId 'windows-pester' -Inventory @('tests/windows.alpha.Tests.ps1', 'tests/windows.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS'; total = 3; passed = 2; skipped = 1 }))
                (New-SourceProjectionRepositoryTestRecord -Event $pesterLinuxEvent -ToolId 'linux.pester' -Inventory @('tests/linux.alpha.Tests.ps1', 'tests/linux.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS'; total = 4; passed = 3; skipped = 1 }))
            )
            $dispatches = @(
                [pscustomobject]@{ id = 'general.dispatch'; kind = 'general' },
                [pscustomobject]@{ id = 'windows-pester'; kind = 'pester' },
                [pscustomobject]@{ id = 'linux.pester'; kind = 'pester' }
            )
            return [pscustomobject][ordered]@{ report = $report; tests = $tests; dispatches = $dispatches }
        }
    }

    # Scenario: The canonical report reaches a blocked Stage 6 after complete source checks.
    # Purpose: Prove the source projection preserves candidate and execution evidence without creating release authority.
    It 'InterT13_projects_candidate_bound_source_conformance_and_rejects_incomplete_evidence' {
        $sourceInput = New-SourceProjectionInput
        $sourceInput.tests = @($sourceInput.tests[2], $sourceInput.tests[0], $sourceInput.tests[1])
        $projection = New-StandardValidationSourceConformanceResult `
            -Report $sourceInput.report `
            -ExpectedSourceRevision ('a' * 40) `
            -RepositoryTestEvidence $sourceInput.tests `
            -RepositoryTestDispatches $sourceInput.dispatches
        if ($projection.status -cne 'passed') {
            throw "Complete source-stage evidence must pass. failureReasons='$(@($projection.failureReasons) -join ',')'."
        }
        Assert-SourceProjectionEqual $projection.status 'passed' 'Complete source-stage evidence must pass.'
        Assert-SourceProjectionEqual $projection.scope 'source-stages-1-5' 'The projection must declare its bounded scope.'
        Assert-SourceProjectionEqual $projection.canonicalValidation.state 'BLOCKED' 'Canonical Stage 6 state must remain visible.'
        Assert-SourceProjectionEqual $projection.canonicalValidation.exitCode 10 'Canonical exit code must remain BLOCKED=10.'
        Assert-SourceProjectionEqual $projection.canonicalValidation.stage6Status 'blocked' 'Stage 6 must remain blocked.'
        Assert-SourceProjectionEqual $projection.pester.eventCount 2 'Both count-bearing dispatches must be represented.'
        Assert-SourceProjectionEqual @($projection.pester.events).Count 2 'The projection must enumerate every count-bearing dispatch.'
        Assert-SourceProjectionEqual $projection.pester.events[0].toolId 'windows-pester' 'The first custom adapter ID must remain bound in Stage 5 order.'
        Assert-SourceProjectionEqual $projection.pester.events[1].toolId 'linux.pester' 'The second custom adapter ID must remain bound in Stage 5 order.'
        Assert-SourceProjectionEqual $projection.pester.total 7 'Pester totals must aggregate all count-bearing dispatches.'
        Assert-SourceProjectionEqual $projection.pester.passed 5 'Pester passed counts must aggregate all count-bearing dispatches.'
        Assert-SourceProjectionEqual $projection.pester.skipped 2 'Pester skipped counts must aggregate all count-bearing dispatches.'
        Assert-SourceProjectionEqual $projection.pester.testInventoryCount 4 'The Pester inventory count must aggregate count-bearing dispatches.'
        $case = New-SourceProjectionInput; $case.report.state = 'PASS'; $case.report.exitCode = 0
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'
        if ([bool]$projection.releaseEligible -or [bool]$sourceInput.report.releaseEligible) { throw 'Source-only conformance must not authorize release.' }
        Assert-SourceProjectionEqual $sourceInput.report.state 'BLOCKED' 'Projection must not mutate canonical state.'
        Assert-SourceProjectionEqual $sourceInput.report.exitCode 10 'Projection must not mutate canonical exit code.'

        $case = New-SourceProjectionInput; $case.report.candidate.candidateId = ('B' + ('b' * 63))
        Assert-SourceProjectionFailure $case 'candidate-id-invalid'
        $case = New-SourceProjectionInput; $case.report = $null
        Assert-SourceProjectionFailure $case 'report-missing'
        $case = New-SourceProjectionInput; $case.report.stages = @($case.report.stages | Select-Object -Skip 1)
        Assert-SourceProjectionFailure $case 'canonical-stage-count-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[3].status = 'failed'
        Assert-SourceProjectionFailure $case 'source-stage-4-not-passed'
        $case = New-SourceProjectionInput; $case.report.stages[4].status = 'failed'
        Assert-SourceProjectionFailure $case 'source-stage-5-not-passed'
        $case = New-SourceProjectionInput; $case.report.stages[2].events = @()
        Assert-SourceProjectionFailure $case 'package-validation-events-missing'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].candidateId = 'f' * 64
        Assert-SourceProjectionFailure $case 'repository-tests-event-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].cleanedUp = $false
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; [void]$case.report.stages[4].events[1].PSObject.Properties.Remove('cleanedUp')
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; [void]$case.report.stages[4].events[1].PSObject.Properties.Remove('outputPath')
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].outputPath = Join-Path $script:SourceProjectionArtifactRoot 'missing-event.json'
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[4].events[1].outputPath = Join-Path ([IO.Path]::GetTempPath()) 'outside-source-event.json'
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput
        $rawOutput = Get-Content -Raw -Encoding UTF8 -LiteralPath $case.report.stages[4].events[1].outputPath | ConvertFrom-Json
        $rawOutput.stdout = 'tampered source event output'
        [IO.File]::WriteAllText($case.report.stages[4].events[1].outputPath, ($rawOutput | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        Assert-SourceProjectionFailure $case 'repository-tests-event-output-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[5].status = 'not-applicable'
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'
        $case = New-SourceProjectionInput; $case.report.exitCode = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'
        $case = New-SourceProjectionInput; $case.report.schemaVersion = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'report-envelope-invalid'
        $case = New-SourceProjectionInput; $case.report.stages[0].order = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'source-stage-1-identity-invalid'
        $case = New-SourceProjectionInput; $case.report.candidate.sourceRevision = 'f' * 40
        Assert-SourceProjectionFailure $case 'candidate-revision-mismatch'
        $case = New-SourceProjectionInput; $case.tests = @()
        Assert-SourceProjectionFailure $case 'pester-evidence-missing-or-ambiguous'
        # Scenario: A general dispatch reports counts while an actual Pester dispatch reports none.
        # Purpose: A different dispatch must not conceal an unexecuted Pester suite.
        $case = New-SourceProjectionInput
        $case.tests[0] = New-SourceProjectionRepositoryTestRecord -Event $case.report.stages[4].events[0] -ToolId 'general.dispatch' -Inventory @('tests/general.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS'; total = 1; passed = 1; skipped = 0 }) -Kind general
        $case.tests[1] = New-SourceProjectionRepositoryTestRecord -Event $case.report.stages[4].events[1] -ToolId 'windows-pester' -Inventory @('tests/windows.alpha.Tests.ps1', 'tests/windows.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS' })
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput
        $case.tests[1] = New-SourceProjectionRepositoryTestRecord -Event $case.report.stages[4].events[1] -ToolId 'windows-pester' -Inventory @('tests/windows.alpha.Tests.ps1', 'tests/windows.beta.Tests.ps1') -TestResult ([ordered]@{ status = 'passed'; decision = 'PASS' })
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.dispatches[1].kind = 'unknown'
        Assert-SourceProjectionFailure $case 'repository-test-dispatch-kind-invalid'
        $case = New-SourceProjectionInput; $case.dispatches[1].kind = 'general'
        Assert-SourceProjectionFailure $case 'repository-test-role-or-id-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = 0; $case.tests[1].testResult.passed = 0; $case.tests[1].testResult.skipped = 0
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = [uint64]::MaxValue
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = 3; $case.tests[1].testResult.passed = 0; $case.tests[1].testResult.skipped = 3
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.Remove('passed')
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].testResult.total = 4
        Assert-SourceProjectionFailure $case 'pester-execution-counts-invalid'
        $case = New-SourceProjectionInput
        foreach ($recordIndex in @(1, 2)) {
            $case.tests[$recordIndex].testResult.total = [int]::MaxValue
            $case.tests[$recordIndex].testResult.passed = [int]::MaxValue
            $case.tests[$recordIndex].testResult.skipped = 0
        }
        Assert-SourceProjectionFailure $case 'pester-aggregate-counts-out-of-range'
        $case = New-SourceProjectionInput; $case.tests[1].testInventory = @()
        Assert-SourceProjectionFailure $case 'pester-test-inventory-or-raw-event-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].outputSha256 = 'f' * 64
        Assert-SourceProjectionFailure $case 'pester-event-binding-invalid'
        $case = New-SourceProjectionInput; $case.tests[1].toolRole = 'untrusted-role'
        Assert-SourceProjectionFailure $case 'repository-test-role-or-id-invalid'
        $case = New-SourceProjectionInput; $case.report.releaseEligible = $true
        Assert-SourceProjectionFailure $case 'canonical-terminal-state-invalid'

        $earlyFailedReportPath = Join-Path $script:SourceProjectionArtifactRoot ('early-failed-' + [guid]::NewGuid().ToString('N') + '.json')
        $earlyFailedEvidence = New-StandardValidationCandidateEvidence `
            -RunId ([guid]::NewGuid()) `
            -State 'FAILED' `
            -ExitCode 20 `
            -ReleaseEligible $false `
            -Candidate $null `
            -Adapter $null `
            -Authority $null `
            -Stages (New-StandardValidationStages) `
            -FailureState 'FAILED' `
            -FailureMessage 'Synthetic early failure before candidate evidence was available.' `
            -ArtifactRoot $script:SourceProjectionArtifactRoot `
            -LockPath 'fixture.lock' `
            -DevelopmentHarness $true `
            -LaunchBinding $null
        $earlyFailedSource = New-StandardValidationSourceConformanceResult `
            -Report $earlyFailedEvidence `
            -ExpectedSourceRevision ('a' * 40) `
            -RepositoryTestEvidence @()
        $earlyFailedEvidence | Add-Member -NotePropertyName sourceConformance -NotePropertyValue $earlyFailedSource -Force
        [void](Write-StandardValidationJsonCreate -Path $earlyFailedReportPath -Value $earlyFailedEvidence -Context 'early failed finalization fixture')
        $persistedEarlyFailedEvidence = Get-StandardValidationJson -Path $earlyFailedReportPath -Context 'early failed finalization fixture'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.state 'FAILED' 'Source projection must not prevent canonical FAILED report writing when candidate evidence is unavailable.'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.exitCode 20 'An early FAILED report must retain its canonical exit code.'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.sourceConformance.status 'failed' 'Missing candidate evidence must fail only the source projection.'
        Assert-SourceProjectionEqual $persistedEarlyFailedEvidence.sourceConformance.releaseEligible $false 'Early FAILED output must remain release-ineligible.'
    }
}
