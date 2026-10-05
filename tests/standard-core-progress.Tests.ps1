Describe 'Standard Core supervisor progress' {
    BeforeAll {
        $script:CoreProgressRoot = Split-Path -Parent $PSScriptRoot
        $script:CoreProgressRunner = Join-Path $script:CoreProgressRoot 'scripts/Invoke-StandardValidation.ps1'
        $script:CoreProgressPwsh = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $script:CoreProgressPwsh -PathType Leaf)) {
            throw 'This Windows Core regression requires the installed pwsh.exe.'
        }

        function New-CoreProgressFixture {
            param([string] $Root, [string] $Kind, [int] $TimeoutSeconds, [int] $SleepSeconds, [int] $ProgressIntervalSeconds = 30)
            [void](New-Item -ItemType Directory -Path $Root -Force)
            $childPath = Join-Path $Root 'child.ps1'
            $launcherPath = Join-Path $Root 'launcher.ps1'
            [IO.File]::WriteAllText($childPath, "Start-Sleep -Seconds $SleepSeconds`n[Console]::Out.WriteLine('{`"schemaVersion`":1,`"report`":`"fixture`"}')`n[Console]::Error.WriteLine('retained child stderr')`nexit 0`n", [Text.UTF8Encoding]::new($false))
            $launcherText = @'
param([string] $Runner, [string] $Child, [string] $Kind, [int] $TimeoutSeconds, [int] $ProgressIntervalSeconds)
$ErrorActionPreference = 'Stop'
$boundedFixtureTimeoutSeconds = $TimeoutSeconds
. $Runner -CandidateRoot $PSScriptRoot -AdapterPath $Child -ArtifactsRoot $PSScriptRoot `
    -SourceRepository 'https://example.test/core-progress.git' `
    -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$result = Invoke-StandardValidationProcess -Command $pwsh `
    -Arguments @('-NoProfile','-NonInteractive','-File',$Child) `
    -WorkingDirectory $PSScriptRoot `
    -Environment @{ STANDARD_VALIDATION_STAGE_ID = 'repository-tests'; STANDARD_VALIDATION_TOOL_ID = 'repository-test-pester' } `
    -TimeoutSeconds $boundedFixtureTimeoutSeconds -CoreLifecycleOnly -EmitSupervisorProgress:($Kind -ceq 'pester') `
    -SupervisorProgressIntervalSeconds $ProgressIntervalSeconds
[ordered]@{status=[string]$result.status;exitCode=[int]$result.exitCode;cleanedUp=[bool]$result.cleanedUp;stdout=[string]$result.stdout;stderr=[string]$result.stderr} | ConvertTo-Json -Compress
'@
            [IO.File]::WriteAllText($launcherPath, $launcherText, [Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{ Child = $childPath; Launcher = $launcherPath; Kind = $Kind; TimeoutSeconds = $TimeoutSeconds; ProgressIntervalSeconds = $ProgressIntervalSeconds }
        }

        function Start-CoreProgressFixture {
            param($Fixture)
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $script:CoreProgressPwsh
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($arg in @('-NoProfile','-NonInteractive','-File',[string]$Fixture.Launcher,'-Runner',$script:CoreProgressRunner,'-Child',[string]$Fixture.Child,'-Kind',[string]$Fixture.Kind,'-TimeoutSeconds',[string]$Fixture.TimeoutSeconds,'-ProgressIntervalSeconds',[string]$Fixture.ProgressIntervalSeconds)) {
                [void]$info.ArgumentList.Add($arg)
            }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $info
            if (-not $process.Start()) { throw 'Core progress launcher did not start.' }
            return $process
        }
    }

    # Scenario: A Core Pester child remains alive for several seconds while the supervisor waits.
    # Purpose: Prove the first trusted heartbeat reaches the outer stderr before test completion without changing the JSON result or cleanup.
    It 'InterT10_emits_trusted_progress_before_pester_child_exit' {
        $fixture = New-CoreProgressFixture -Root (Join-Path $TestDrive 'live') -Kind 'pester' -TimeoutSeconds 12 -SleepSeconds 5
        $process = Start-CoreProgressFixture -Fixture $fixture
        try {
            $lineTask = $process.StandardError.ReadLineAsync()
            $completed = [Threading.Tasks.Task]::WhenAny($lineTask, [Threading.Tasks.Task]::Delay(8000)).GetAwaiter().GetResult()
            $completed | Should -Be $lineTask
            $line = $lineTask.GetAwaiter().GetResult()
            $line | Should -Match '^Core Pester supervisor utc=.+ elapsedSeconds=\d+ remainingSeconds=\d+ state=running$'
            $process.HasExited | Should -BeFalse
            $process.WaitForExit(15000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            $receipt = $process.StandardOutput.ReadToEnd() | ConvertFrom-Json
            $receipt.status | Should -Be 'passed'
            $receipt.exitCode | Should -Be 0
            $receipt.cleanedUp | Should -BeTrue
            $receipt.stdout.Trim() | Should -Be '{"schemaVersion":1,"report":"fixture"}'
            $receipt.stderr.Trim() | Should -Be 'retained child stderr'
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    # Scenario: A Core Pester child remains alive beyond the configured diagnostic cadence.
    # Purpose: Prove the second heartbeat is emitted before completion using a one-second test cadence while production keeps thirty seconds.
    It 'InterT15_emits_periodic_progress_before_child_exit' {
        $fixture = New-CoreProgressFixture -Root (Join-Path $TestDrive 'periodic') -Kind 'pester' -TimeoutSeconds 10 -SleepSeconds 4 -ProgressIntervalSeconds 1
        $process = Start-CoreProgressFixture -Fixture $fixture
        try {
            $firstTask = $process.StandardError.ReadLineAsync()
            $firstCompleted = [Threading.Tasks.Task]::WhenAny($firstTask, [Threading.Tasks.Task]::Delay(8000)).GetAwaiter().GetResult()
            $firstCompleted | Should -Be $firstTask
            $first = $firstTask.GetAwaiter().GetResult()
            $first | Should -Match 'elapsedSeconds=0 remainingSeconds=\d+ state=running$'
            $secondTask = $process.StandardError.ReadLineAsync()
            $completed = [Threading.Tasks.Task]::WhenAny($secondTask, [Threading.Tasks.Task]::Delay(3000)).GetAwaiter().GetResult()
            $completed | Should -Be $secondTask
            $secondTask.GetAwaiter().GetResult() | Should -Match 'elapsedSeconds=[1-3] remainingSeconds=\d+ state=running$'
            $process.HasExited | Should -BeFalse
            $process.WaitForExit(15000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            ($process.StandardOutput.ReadToEnd() | ConvertFrom-Json).cleanedUp | Should -BeTrue
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    # Scenario: A non-Pester Core check invokes the same owned-process primitive.
    # Purpose: Keep the new supervisor log route opt-in and preserve the ordinary general-check result.
    It 'InterT20_keeps_general_check_without_progress_lines' {
        $fixture = New-CoreProgressFixture -Root (Join-Path $TestDrive 'general') -Kind 'general' -TimeoutSeconds 12 -SleepSeconds 1
        $process = Start-CoreProgressFixture -Fixture $fixture
        try {
            $process.WaitForExit(15000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            $process.StandardError.ReadToEnd() | Should -Be ''
            $receipt = $process.StandardOutput.ReadToEnd() | ConvertFrom-Json
            $receipt.status | Should -Be 'passed'
            $receipt.cleanedUp | Should -BeTrue
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    # Scenario: A Core Pester child exceeds its original one-second process timeout.
    # Purpose: Ensure a visible heartbeat cannot turn a timeout into PASS or leave an owned descendant running.
    It 'InterT30_preserves_timeout_and_owned_cleanup_with_progress' {
        $fixture = New-CoreProgressFixture -Root (Join-Path $TestDrive 'timeout') -Kind 'pester' -TimeoutSeconds 1 -SleepSeconds 20
        $process = Start-CoreProgressFixture -Fixture $fixture
        try {
            $process.WaitForExit(15000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            $process.StandardError.ReadToEnd() | Should -Match '^Core Pester supervisor '
            $receipt = $process.StandardOutput.ReadToEnd() | ConvertFrom-Json
            $receipt.status | Should -Be 'timeout'
            $receipt.exitCode | Should -Not -Be 0
            $receipt.cleanedUp | Should -BeTrue
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }
}
