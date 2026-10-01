Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:GatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
$script:ResultCliPath = Join-Path $script:RepositoryRoot 'scripts/Test-StandardEntryPointResult.ps1'
$script:GitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction Stop | Select-Object -First 1
$script:GitExecutable = if ($null -ne $script:GitCommand.PSObject.Properties['Path']) { [string]$script:GitCommand.Path } else { [string]$script:GitCommand.Source }
$powerShellExecutableName = if ($PSVersionTable.PSEdition -ceq 'Core') { 'pwsh' } else { 'powershell' }
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $powerShellExecutableName += '.exe' }
$script:PowerShellExecutable = Join-Path $PSHOME $powerShellExecutableName
$script:ProcessEvidenceRoot = $null

function Invoke-EntryTestGit {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $safeRoot = $Root.Replace('\', '/')
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr into a terminating error
        # under Stop, even when Git exits successfully. Preserve real exit code.
        $ErrorActionPreference = 'Continue'
        $output = & $script:GitExecutable -c "safe.directory=$safeRoot" -C $Root @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $raw = @($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "Fixture Git command failed with exit ${exitCode}: git -C '$Root' $($Arguments -join ' ')" + [Environment]::NewLine + $raw
    }
    return $raw.Trim()
}

function ConvertTo-EntryTestArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-EntryTestFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash($stream)
        return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}
function Invoke-EntryTestProcess {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Label,
        [ValidateRange(100, 180000)][int] $TimeoutMilliseconds = 180000
    )

    $commandArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (ConvertTo-EntryTestArgument $ScriptPath))
    foreach ($argument in $Arguments) {
        $commandArguments += ConvertTo-EntryTestArgument ([string]$argument)
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:PowerShellExecutable
    $startInfo.Arguments = $commandArguments -join ' '
    $startInfo.WorkingDirectory = $script:RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['GITHUB_SHA'] = 'ffffffffffffffffffffffffffffffffffffffff'
    [void]$startInfo.EnvironmentVariables.Remove('STANDARD_GO_RUNTIME_VERSION')
    [void]$startInfo.EnvironmentVariables.Remove('STANDARD_GO_COMMAND_PATH')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedAt = [DateTimeOffset]::Now
    $timedOut = $false
    $stdout = ''
    $stderr = ''
    $exitCode = -1
    $cleanupConfirmed = $true
    $cleanupError = $null
    $processId = 0
    $terminationMethod = $null
    $treeKillProcessId = 0
    $treeKillExitCode = $null
    $treeKillStdOut = ''
    $treeKillStdErr = ''
    try {
        if (-not $process.Start()) {
            throw "Could not start PowerShell child for $Label."
        }
        $processId = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $timedOut = $true
            if ($PSVersionTable.PSEdition -ceq 'Core') {
                try {
                    $process.Kill($true)
                    $terminationMethod = 'Process.Kill(entireProcessTree)'
                }
                catch {
                    $cleanupConfirmed = $false
                    $cleanupError = 'process-tree kill failed: ' + $_.Exception.Message
                }
            }
            else {
                $taskkillPath = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                if (-not (Test-Path -LiteralPath $taskkillPath -PathType Leaf)) {
                    $cleanupConfirmed = $false
                    $cleanupError = "Windows taskkill.exe is unavailable for owned PID $processId."
                }
                else {
                    $killStartInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $killStartInfo.FileName = $taskkillPath
                    $killStartInfo.Arguments = "/PID $processId /T /F"
                    $killStartInfo.WorkingDirectory = $script:RepositoryRoot
                    $killStartInfo.UseShellExecute = $false
                    $killStartInfo.CreateNoWindow = $true
                    $killStartInfo.RedirectStandardOutput = $true
                    $killStartInfo.RedirectStandardError = $true
                    $treeKiller = New-Object System.Diagnostics.Process
                    $treeKiller.StartInfo = $killStartInfo
                    try {
                        if (-not $treeKiller.Start()) {
                            $cleanupConfirmed = $false
                            $cleanupError = "Could not start taskkill for owned PID $processId."
                        }
                        else {
                            $treeKillProcessId = $treeKiller.Id
                            $treeKillStdOutTask = $treeKiller.StandardOutput.ReadToEndAsync()
                            $treeKillStdErrTask = $treeKiller.StandardError.ReadToEndAsync()
                            if (-not $treeKiller.WaitForExit(30000)) {
                                $cleanupConfirmed = $false
                                $cleanupError = 'taskkill did not exit within the bounded wait.'
                                try { $treeKiller.Kill() }
                                catch { $cleanupError += ' taskkill stop failed: ' + $_.Exception.Message }
                                if (-not $treeKiller.WaitForExit(10000)) {
                                    $cleanupError += ' taskkill remained alive after its bounded stop wait.'
                                }
                            }
                            if ($treeKiller.HasExited) {
                                $treeKillExitCode = $treeKiller.ExitCode
                                $terminationMethod = 'taskkill.exe /PID /T /F'
                            }
                            else {
                                $cleanupConfirmed = $false
                            }
                            if ($treeKillStdOutTask.Wait(10000) -and $treeKillStdOutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                                $treeKillStdOut = $treeKillStdOutTask.Result
                            }
                            else {
                                $cleanupConfirmed = $false
                                if ($null -eq $cleanupError) { $cleanupError = 'taskkill stdout did not drain within the bounded wait.' }
                                $treeKillStdOut = '<taskkill stdout drain incomplete>'
                            }
                            if ($treeKillStdErrTask.Wait(10000) -and $treeKillStdErrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                                $treeKillStdErr = $treeKillStdErrTask.Result
                            }
                            else {
                                $cleanupConfirmed = $false
                                if ($null -eq $cleanupError) { $cleanupError = 'taskkill stderr did not drain within the bounded wait.' }
                                $treeKillStdErr = '<taskkill stderr drain incomplete>'
                            }
                            if ($null -ne $treeKillExitCode -and $treeKillExitCode -ne 0) {
                                $cleanupConfirmed = $false
                                $cleanupError = "taskkill returned exit $treeKillExitCode for owned PID $processId. " + $treeKillStdOut + $treeKillStdErr
                            }
                        }
                    }
                    catch {
                        $cleanupConfirmed = $false
                        $cleanupError = 'owned process-tree cleanup failed: ' + $_.Exception.Message
                    }
                    finally {
                        $treeKiller.Dispose()
                    }
                }
            }
            if (-not $process.WaitForExit(30000)) {
                $cleanupConfirmed = $false
                if ($null -eq $cleanupError) { $cleanupError = 'process did not exit within the bounded cleanup wait.' }
            }
        }
        $stdoutDrained = $false
        $stderrDrained = $false
        try { $stdoutDrained = $stdoutTask.Wait(30000) }
        catch {
            $cleanupConfirmed = $false
            $cleanupError = 'stdout drain failed: ' + $_.Exception.Message
        }
        try { $stderrDrained = $stderrTask.Wait(30000) }
        catch {
            $cleanupConfirmed = $false
            $cleanupError = 'stderr drain failed: ' + $_.Exception.Message
        }
        if ($stdoutDrained -and $stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stdout = $stdoutTask.Result
        }
        else {
            $cleanupConfirmed = $false
            if ($null -eq $cleanupError) { $cleanupError = 'stdout did not drain within the bounded wait.' }
            $stdout = '<stdout drain incomplete>'
        }
        if ($stderrDrained -and $stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stderr = $stderrTask.Result
        }
        else {
            $cleanupConfirmed = $false
            if ($null -eq $cleanupError) { $cleanupError = 'stderr did not drain within the bounded wait.' }
            $stderr = '<stderr drain incomplete>'
        }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        else {
            $cleanupConfirmed = $false
            if ($null -eq $cleanupError) { $cleanupError = 'process is still running after bounded wait.' }
        }
    }
    finally {
        $process.Dispose()
    }

    $record = [ordered]@{
        label = $Label
        startedAt = $startedAt.ToString('o')
        finishedAt = [DateTimeOffset]::Now.ToString('o')
        processId = $processId
        runtime = $PSVersionTable.PSVersion.ToString()
        executable = $script:PowerShellExecutable
        command = $script:PowerShellExecutable + ' ' + ($commandArguments -join ' ')
        exitCode = $exitCode
        timedOut = $timedOut
        cleanupConfirmed = $cleanupConfirmed
        cleanupError = $cleanupError
        terminationMethod = $terminationMethod
        treeKillProcessId = $treeKillProcessId
        treeKillExitCode = $treeKillExitCode
        treeKillStdout = $treeKillStdOut
        treeKillStderr = $treeKillStdErr
        stdout = $stdout
        stderr = $stderr
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ProcessEvidenceRoot)) {
        $evidencePath = Join-Path $script:ProcessEvidenceRoot ($Label + '-' + [Guid]::NewGuid().ToString('N') + '.json')
        $evidenceJson = $record | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($evidencePath, $evidenceJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }

    if (-not $cleanupConfirmed) {
        throw "Could not confirm bounded child cleanup for $Label. PID=$processId ExitCode=$exitCode TimedOut=$timedOut Cleanup=$cleanupError StdOutRaw=[$stdout] StdErrRaw=[$stderr]"
    }

    $rawOutput = $stdout + [Environment]::NewLine + $stderr
    return [pscustomobject]@{
        Label = $Label
        ProcessId = $processId
        ExitCode = $exitCode
        TimedOut = $timedOut
        CleanupConfirmed = $cleanupConfirmed
        TerminationMethod = $terminationMethod
        TreeKillProcessId = $treeKillProcessId
        TreeKillExitCode = $treeKillExitCode
        TreeKillStdOut = $treeKillStdOut
        TreeKillStdErr = $treeKillStdErr
        StdOut = $stdout
        StdErr = $stderr
        Raw = $rawOutput
        Command = $record.command
    }
}

function New-EntryPreflightArguments {
    param(
        [string] $CandidateRoot = $script:RepositoryRoot,
        [string] $AuthorityRoot = $script:AuthorityRoot,
        [string] $CandidateRevision = $script:CandidateRevision,
        [string] $AuthorityRevision = $script:AuthorityRevision,
        [string] $EventName = 'pull_request',
        [string] $ResultArtifact = $script:ResultArtifact,
        [string[]] $OmitInputs = @(),
        [switch] $AllowDevelopmentContent,
        [switch] $BindingOnly,
        [string[]] $AdditionalArguments = @()
    )

    $arguments = @()
    if ($OmitInputs -notcontains 'CandidateRoot') { $arguments += @('-CandidateRoot', $CandidateRoot) }
    if ($OmitInputs -notcontains 'AuthorityRoot') { $arguments += @('-AuthorityRoot', $AuthorityRoot) }
    if ($OmitInputs -notcontains 'CandidateRevision') { $arguments += @('-CandidateRevision', $CandidateRevision) }
    if ($OmitInputs -notcontains 'AuthorityRevision') { $arguments += @('-AuthorityRevision', $AuthorityRevision) }
    if ($OmitInputs -notcontains 'EventName') { $arguments += @('-EventName', $EventName) }
    if ($OmitInputs -notcontains 'ResultArtifact') { $arguments += @('-ResultArtifact', $ResultArtifact) }
    if ($AllowDevelopmentContent) { $arguments += '-AllowDevelopmentContent' }
    if ($BindingOnly) { $arguments += '-BindingOnly' }
    $arguments += $AdditionalArguments
    return $arguments
}

function Assert-EntryPreflightFailure {
    param(
        [Parameter(Mandatory = $true)] $Result,
        [Parameter(Mandatory = $true)][string] $Marker
    )

    $Result.TimedOut | Should Be $false
    $Result.ExitCode | Should Not Be 0
    $Result.Raw | Should Match $Marker
    $Result.Raw | Should Not Match 'run-resolved Go executable|STANDARD_GO_RUNTIME_VERSION|setup-go runtime'
}

Describe 'Standard authority entry preflight actual CLI' {
    BeforeAll {
        $configuredWorkRoot = [string]$env:SYP226_P01B2_WORK_ROOT
        if ([string]::IsNullOrWhiteSpace($configuredWorkRoot)) {
            $configuredWorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'standard-authority-entry-preflight'
        }
        if (-not (Test-Path -LiteralPath $configuredWorkRoot -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $configuredWorkRoot -Force)
        }

        $script:RunRoot = Join-Path $configuredWorkRoot ('run-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:RunRoot -Force)
        $script:ProcessEvidenceRoot = Join-Path $script:RunRoot 'cli-processes'
        [void](New-Item -ItemType Directory -Path $script:ProcessEvidenceRoot -Force)

        $script:CandidateRoot = [IO.Path]::GetFullPath($script:RepositoryRoot)
        $script:CandidateRevision = Invoke-EntryTestGit -Root $script:CandidateRoot -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
        $script:AuthorityRevision = Invoke-EntryTestGit -Root $script:CandidateRoot -Arguments @('rev-parse', '--verify', 'HEAD^')
        # Keep the Git worktree near the configured evidence root so Windows
        # does not exceed MAX_PATH on the repository's long evidence filenames.
        $fixtureId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:FixtureRoot = Join-Path $configuredWorkRoot ('f' + $fixtureId)
        [void](New-Item -ItemType Directory -Path $script:FixtureRoot -Force)
        $script:AuthorityRoot = Join-Path $script:FixtureRoot 'authority'
        $candidateSafeRoot = $script:CandidateRoot.Replace('\', '/')
        $cloneOutput = & $script:GitExecutable -c "safe.directory=$candidateSafeRoot" -C $script:CandidateRoot clone --shared --no-checkout --quiet -- $script:CandidateRoot $script:AuthorityRoot 2>&1
        $cloneExit = $LASTEXITCODE
        if ($cloneExit -ne 0) {
            throw "Could not create local authority Git fixture (exit $cloneExit): $(@($cloneOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)"
        }
        [void](Invoke-EntryTestGit -Root $script:AuthorityRoot -Arguments @('checkout', '--detach', $script:AuthorityRevision))
        $actualAuthorityRevision = Invoke-EntryTestGit -Root $script:AuthorityRoot -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
        if ($actualAuthorityRevision -cne $script:AuthorityRevision) {
            throw "Authority fixture HEAD $actualAuthorityRevision does not match $script:AuthorityRevision."
        }
        $authorityStatus = Invoke-EntryTestGit -Root $script:AuthorityRoot -Arguments @('status', '--porcelain=v1')
        if (-not [string]::IsNullOrEmpty($authorityStatus)) {
            throw "Authority fixture is not clean: $authorityStatus"
        }
        $script:ResultArtifact = 'artifacts/standard-authority-entry-preflight.json'
        $script:BindingProofDirectory = Join-Path $script:RunRoot 'binding-only-proof'
        [void](New-Item -ItemType Directory -Path $script:BindingProofDirectory -Force)
    }

    # Scenario: A timed-out authority child owns a long-running descendant on both Windows PowerShell 5.1 and PowerShell 7.
    # Purpose: Verify bounded PID-scoped tree termination, raw streams, actual exit, and absence of both owned processes.
    It 'UnitT05_terminates_a_timed_out_owned_process_tree_with_raw_exit_evidence' {
        $pidEvidencePath = Join-Path $script:RunRoot ('timeout-grandchild-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $timeoutScriptPath = Join-Path $script:RunRoot ('timeout-child-' + [Guid]::NewGuid().ToString('N') + '.ps1')
        $timeoutScript = @'
param([string] $PidEvidencePath, [string] $PowerShellExecutable)
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 90'))
$grandchildStartInfo = New-Object System.Diagnostics.ProcessStartInfo
$grandchildStartInfo.FileName = $PowerShellExecutable
$grandchildStartInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand"
$grandchildStartInfo.UseShellExecute = $false
$grandchildStartInfo.CreateNoWindow = $true
$grandchild = New-Object System.Diagnostics.Process
$grandchild.StartInfo = $grandchildStartInfo
if (-not $grandchild.Start()) { throw 'Could not start the owned tree-test descendant.' }
$grandchildId = $grandchild.Id
$grandchild.Dispose()
[IO.File]::WriteAllText($PidEvidencePath, [string]$grandchildId, (New-Object System.Text.UTF8Encoding($false)))
[Console]::Out.WriteLine("owned-tree-grandchild=$grandchildId")
[Console]::Out.Flush()
Start-Sleep -Seconds 90
'@
        [IO.File]::WriteAllText($timeoutScriptPath, $timeoutScript, (New-Object System.Text.UTF8Encoding($false)))

        $result = Invoke-EntryTestProcess -ScriptPath $timeoutScriptPath -Arguments @($pidEvidencePath, $script:PowerShellExecutable) -Label 'UnitT05-timeout-owned-tree' -TimeoutMilliseconds 3000
        $result.TimedOut | Should Be $true
        $result.CleanupConfirmed | Should Be $true
        $result.ProcessId | Should Not Be 0
        $result.ExitCode | Should Not Be 0
        $result.TerminationMethod | Should Not BeNullOrEmpty
        $result.StdOut | Should Match 'owned-tree-grandchild=\d+'
        if ($PSVersionTable.PSEdition -ceq 'Core') {
            $result.TerminationMethod | Should Be 'Process.Kill(entireProcessTree)'
        }
        else {
            $result.TerminationMethod | Should Be 'taskkill.exe /PID /T /F'
            $result.TreeKillExitCode | Should Be 0
            $result.TreeKillStdOut | Should Not BeNullOrEmpty
        }

        $grandchildPid = [int](Get-Content -LiteralPath $pidEvidencePath -Raw)
        $grandchild = Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue
        $grandchildWasRunningAfterTreeKill = $null -ne $grandchild
        if ($grandchildWasRunningAfterTreeKill) {
            $ownedGrandchild = [System.Diagnostics.Process]::GetProcessById($grandchildPid)
            try {
                $ownedGrandchild.Kill()
                [void]$ownedGrandchild.WaitForExit(10000)
            }
            finally {
                $ownedGrandchild.Dispose()
            }
        }
        $grandchildWasRunningAfterTreeKill | Should Be $false
        (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue) | Should Be $null
        (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue) | Should Be $null
    }

    # Scenario: The actual candidate gate receives explicit candidate and authority identities while GITHUB_SHA names another commit.
    # Purpose: Prove the gate binds the dirty current candidate and distinct clean authority snapshot without inferring identity from the runner environment.
    It 'UnitT10_accepts_explicit_candidate_and_authority_with_foreign_github_sha' {
        $arguments = @(New-EntryPreflightArguments -AllowDevelopmentContent -BindingOnly)
        $result = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $arguments -Label 'UnitT10-valid-binding'
        $result.TimedOut | Should Be $false
        $result.ExitCode | Should Be 0
        $diagnostic = $result.StdOut | ConvertFrom-Json
        $diagnostic.type | Should Be 'standard-entry-point-binding-diagnostic'
        $diagnostic.binding.entryId | Should Be 'standard-v1-authority'
        $diagnostic.binding.candidateRevision | Should Be $script:CandidateRevision
        $diagnostic.binding.authorityRevision | Should Be $script:AuthorityRevision
        $diagnostic.binding.eventName | Should Be 'pull_request'
        $diagnostic.binding.contentMode | Should Be 'development'
        ($diagnostic.binding.requiredChecks -is [Array]) | Should Be $true
        @($diagnostic.binding.requiredChecks).Count | Should Be 1
        $diagnostic.binding.requiredChecks[0] | Should Be 'Standard v1 authority gate'
        ($diagnostic.PSObject.Properties.Name -contains 'executed') | Should Be $false
        ($diagnostic.PSObject.Properties.Name -contains 'status') | Should Be $false
        ($diagnostic.PSObject.Properties.Name -contains 'releaseEligible') | Should Be $false
        (Test-Path -LiteralPath (Join-Path $script:CandidateRoot $script:ResultArtifact)) | Should Be $false
    }

    # Scenario: A valid-format candidate revision differs from the candidate root's real Git HEAD.
    # Purpose: Reject an explicit candidate identity that does not name the bytes being bound before tool discovery.
    It 'UnitT20_rejects_candidate_revision_mismatch_before_go' {
        $arguments = @(New-EntryPreflightArguments -CandidateRevision 'ffffffffffffffffffffffffffffffffffffffff' -AllowDevelopmentContent -BindingOnly)
        $result = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $arguments -Label 'UnitT20-candidate-mismatch'
        Assert-EntryPreflightFailure -Result $result -Marker 'STANDARD_ENTRY_BLOCKED\|candidateRevision does not match candidate HEAD'
    }

    # Scenario: AuthorityRevision names the candidate commit instead of the clean authority root's real commit.
    # Purpose: Keep the two role identities independently verified and reject a candidate SHA substituted for authority.
    It 'UnitT30_rejects_authority_revision_and_root_mismatch_before_go' {
        $wrongRevisionArguments = @(New-EntryPreflightArguments -AuthorityRevision $script:CandidateRevision -AllowDevelopmentContent -BindingOnly)
        $wrongRevision = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $wrongRevisionArguments -Label 'UnitT30-authority-revision-mismatch'
        Assert-EntryPreflightFailure -Result $wrongRevision -Marker 'STANDARD_ENTRY_BLOCKED\|authorityRevision does not match authority HEAD'

        $missingRoot = Join-Path $script:FixtureRoot 'missing-authority'
        $wrongRootArguments = @(New-EntryPreflightArguments -AuthorityRoot $missingRoot -AllowDevelopmentContent -BindingOnly)
        $wrongRoot = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $wrongRootArguments -Label 'UnitT30-authority-root-missing'
        Assert-EntryPreflightFailure -Result $wrongRoot -Marker 'STANDARD_ENTRY_INVALID\|authority root path component is missing'
    }

    # Scenario: One explicit identity is omitted, the result artifact path escapes the repository, or a caller adds a check claim.
    # Purpose: Require deterministic validation and prevent input or check claims from expanding the binding.
    It 'UnitT40_rejects_missing_identity_unsafe_artifact_and_unknown_check_arguments' {
        $missingIdentityArguments = @('-CandidateRoot', $script:CandidateRoot, '-BindingOnly')
        $missingIdentity = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $missingIdentityArguments -Label 'UnitT40-missing-identity'
        Assert-EntryPreflightFailure -Result $missingIdentity -Marker 'STANDARD_ENTRY_INVALID\|Missing required explicit preflight identity'

        $unsafeArguments = @(New-EntryPreflightArguments -ResultArtifact '../outside.json' -AllowDevelopmentContent -BindingOnly)
        $unsafeArtifact = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $unsafeArguments -Label 'UnitT40-unsafe-artifact'
        Assert-EntryPreflightFailure -Result $unsafeArtifact -Marker 'STANDARD_ENTRY_INVALID\|resultArtifact.*unsafe'

        $unknownArguments = @(New-EntryPreflightArguments -AllowDevelopmentContent -BindingOnly -AdditionalArguments @('-RequiredChecks', 'caller-added-check'))
        $unknownCheck = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $unknownArguments -Label 'UnitT40-unknown-check-argument'
        Assert-EntryPreflightFailure -Result $unknownCheck -Marker 'parameter cannot be found|NamedParameterNotFound'
    }

    # Scenario: The candidate root contains local changes but AllowDevelopmentContent is omitted.
    # Purpose: Prevent dirty candidate bytes from being bound as immutable content implicitly.
    It 'UnitT50_rejects_dirty_candidate_without_development_opt_in' {
        $arguments = @(New-EntryPreflightArguments -BindingOnly)
        $result = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $arguments -Label 'UnitT50-dirty-without-development'
        Assert-EntryPreflightFailure -Result $result -Marker 'STANDARD_ENTRY_BLOCKED\|immutable content mode rejects modified or untracked input files'
    }

    # Scenario: BindingOnly is invoked with explicit role identity and no Go, provider, supervisor, or scanner arguments.
    # Purpose: Emit only a binding diagnostic, leave the requested success artifact absent, and prove the result validator rejects the diagnostic.
    It 'UnitT60_emits_only_binding_diagnostic_without_tools_or_success_artifact' {
        $arguments = @(New-EntryPreflightArguments -AllowDevelopmentContent -BindingOnly)
        $result = Invoke-EntryTestProcess -ScriptPath $script:GatePath -Arguments $arguments -Label 'UnitT60-binding-only'
        $result.TimedOut | Should Be $false
        $result.ExitCode | Should Be 0
        $diagnosticPath = Join-Path $script:BindingProofDirectory 'binding-diagnostic.json'
        [IO.File]::WriteAllText($diagnosticPath, $result.StdOut, (New-Object System.Text.UTF8Encoding($false)))
        $diagnostic = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
        $diagnostic.type | Should Be 'standard-entry-point-binding-diagnostic'
        ($diagnostic.PSObject.Properties.Name -contains 'executed') | Should Be $false
        ($diagnostic.PSObject.Properties.Name -contains 'status') | Should Be $false
        ($diagnostic.PSObject.Properties.Name -contains 'releaseEligible') | Should Be $false
        (Test-Path -LiteralPath (Join-Path $script:CandidateRoot $script:ResultArtifact)) | Should Be $false

        $expectedBindingPath = Join-Path $script:BindingProofDirectory 'expected-binding.json'
        $expectedBindingJson = ConvertTo-Json -InputObject $diagnostic.binding -Depth 20
        [IO.File]::WriteAllText($expectedBindingPath, $expectedBindingJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        $verifyArguments = @('-BindingPath', $expectedBindingPath, '-ResultPath', $diagnosticPath)
        $verification = Invoke-EntryTestProcess -ScriptPath $script:ResultCliPath -Arguments $verifyArguments -Label 'UnitT60-result-cli-rejects-diagnostic'
        Assert-EntryPreflightFailure -Result $verification -Marker 'STANDARD_ENTRY_INVALID\|result'
    }

    # Scenario: A byte-identical candidate gate script is launched from a path outside the claimed CandidateRoot.
    # Purpose: Reject a caller that claims a clean candidate snapshot while executing code from elsewhere.
    It 'UnitT70_rejects_gate_running_outside_claimed_candidate_root' {
        $foreignRoot = Join-Path $script:FixtureRoot 'foreign-run'
        $foreignScripts = Join-Path $foreignRoot 'scripts'
        [void](New-Item -ItemType Directory -Path $foreignScripts -Force)
        $foreignGate = Join-Path $foreignScripts 'Invoke-StandardAuthorityGate.ps1'
        Copy-Item -LiteralPath $script:GatePath -Destination $foreignGate -Force
        $sourceHash = Get-EntryTestFileSha256 -Path $script:GatePath
        $foreignHash = Get-EntryTestFileSha256 -Path $foreignGate
        $foreignHash | Should Be $sourceHash

        $arguments = @(New-EntryPreflightArguments -AllowDevelopmentContent -BindingOnly)
        $result = Invoke-EntryTestProcess -ScriptPath $foreignGate -Arguments $arguments -Label 'UnitT70-gate-outside-candidate'
        Assert-EntryPreflightFailure -Result $result -Marker '(?s)STANDARD_ENTRY_BLOCKED\|running authority gate script must equal.*?CandidateRoot/scripts/Invoke-StandardAuthorityGate\.ps1'
    }
}
