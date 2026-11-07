# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'SYP353 preparation process and private-root delegation' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        function Copy-P53PhysicalRuntimeFixture {
            param([string]$Source,[string]$Destination)
            # The installed host may have Store hardlinks or directory aliases.
            # Materialize its trusted bytes solely as test input. Production
            # still rejects that linked installation; no link exception is added.
            $pending=[Collections.Generic.Queue[object]]::new()
            $pending.Enqueue(@{source=$Source;relative='';ancestors=@()})
            $links=[Collections.Generic.List[string]]::new()
            while($pending.Count -gt 0){
                $entry=$pending.Dequeue()
                $physical=Resolve-PlatformPhysicalPath $entry.source
                if($entry.ancestors -ccontains $physical){throw 'Runtime fixture source has a directory-link cycle.'}
                $target=if($entry.relative -eq ''){$Destination}else{Join-Path $Destination $entry.relative}
                [void][IO.Directory]::CreateDirectory($target)
                foreach($child in @(Get-ChildItem -LiteralPath $physical -Force)){
                    $relative=if($entry.relative -eq ''){$child.Name}else{$entry.relative+'/'+$child.Name}
                    if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrEmpty([string]$child.LinkType)){$links.Add($relative)}
                    $sourcePath=Resolve-PlatformPhysicalPath $child.FullName
                    $sourceItem=Get-Item -LiteralPath $sourcePath -Force
                    if($sourceItem -is [IO.DirectoryInfo]){
                        $pending.Enqueue(@{source=$sourcePath;relative=$relative;ancestors=@($entry.ancestors)+@($physical)})
                    } elseif($sourceItem -is [IO.FileInfo]){
                        [IO.File]::Copy($sourcePath,(Join-Path $Destination $relative),$false)
                    } else {throw 'Runtime fixture source contains an unsupported entry.'}
                }
            }
            return $links.ToArray()
        }
    }
    # Scenario: The same private child is requested twice and contains caller data.
    # Purpose: Preserve create-only ownership without adopting or modifying the winner.
    It 'InterT10_private_root_creation_rejects_existing_directory' {
        $root=New-PlatformPrivateRoot -Parent $TestDrive -Leaf 'owned'
        [IO.File]::WriteAllText((Join-Path $root 'sentinel'),'keep')
        {New-PlatformPrivateRoot -Parent $TestDrive -Leaf 'owned'} | Should Throw
        [IO.File]::ReadAllText((Join-Path $root 'sentinel')) | Should Be 'keep'
    }
    # Scenario: A prepared command receives arguments and explicit environment, then exits nonzero.
    # Purpose: Bind physical launcher identity and require complete owned cleanup on every host.
    It 'InterT20_preparation_preserves_streams_exit_and_ownership_receipt' {
        $environment=[Collections.Generic.Dictionary[string,string]]::new()
        if($IsWindows){$environment['SystemRoot']=$env:SystemRoot}
        $environment['P53_VALUE']='literal value'
        $command=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $result=Invoke-PlatformPreparationCommand -Command $command -Arguments @('-NoProfile','-NonInteractive','-Command','[Console]::Out.Write($env:P53_VALUE);[Console]::Error.Write("diagnostic");exit 23') -Environment $environment -WorkingDirectory $TestDrive -TimeoutMilliseconds 15000
        $result.exitCode | Should Be 23
        $result.stdout | Should Be 'literal value'
        $result.stderr | Should Be 'diagnostic'
        $result.processOwnership.cleanup.CleanedUp | Should Be $true
        $result.processOwnership.cleanup.CaptureReadersStopped | Should Be $true
        $result.processOwnership.commandPath | Should Be $command
        $result.processOwnership.resolvedCommandPath | Should Be (Resolve-PlatformPhysicalPath $command)
        $result.processOwnership.isolationCapability | Should Be $(if($IsWindows){'strong'}else{'cooperative'})
        if(-not $IsWindows){@($result.processOwnership.limitations).Count | Should BeGreaterThan 0}
        $schema=Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/schemas/validation-security-gate-v1.schema.json')|ConvertFrom-Json
        $receiptSchema=$schema.'$defs'.preparationProcessOwnership|ConvertTo-Json -Depth 30
        Test-Json -Json ($result.processOwnership|ConvertTo-Json -Depth 20) -Schema $receiptSchema | Should Be $true
        $tampered=$result.processOwnership|ConvertTo-Json -Depth 20|ConvertFrom-Json
        $tampered.cleanup.CleanedUp=$false
        Test-Json -Json ($tampered|ConvertTo-Json -Depth 20) -Schema $receiptSchema -ErrorAction SilentlyContinue | Should Be $false
    }
    # Scenario: A physical copy of the host runtime captures Pester, runs it, then its snapshot changes.
    # Purpose: Verify real P4 preparation and P2/P3 execution; mutation must block before the next child starts.
    It 'InterT30_authority_preparation_rechecks_the_physical_pester_snapshot' {
        $pester=@(Get-Module -ListAvailable Pester | Where-Object Version -EQ ([version]'4.10.1'))
        $pester.Count | Should Be 1
        $hostCommand=Resolve-PlatformPhysicalPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $runtimeRoot=Join-Path $TestDrive 'authority-runtime'
        $hostLinks=@(Copy-P53PhysicalRuntimeFixture -Source ([IO.Path]::GetDirectoryName($hostCommand)) -Destination $runtimeRoot)
        if($hostLinks.Count -gt 0){
            Write-Host ('Host runtime links (relative paths): '+($hostLinks -join ', '))
            $failure=$null
            try {Initialize-PlatformAuthorityPester -ModulePath $pester[0].Path -Executable $hostCommand|Out-Null} catch {$failure=$_}
            $failure.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $failure.Exception.Message | Should Match 'Runtime closure contains a link:'
        }
        $command=Join-Path $runtimeRoot ([IO.Path]::GetFileName($hostCommand))
        $receipt=Initialize-PlatformAuthorityPester -ModulePath $pester[0].Path -Executable $command
        try {
            $receipt.processOwnership.Count | Should Be 2
            $receipt.moduleClosure.files.Count | Should BeGreaterThan 0
            $environment=[Collections.Generic.Dictionary[string,string]]::new()
            foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){$environment[[string]$entry.Key]=[string]$entry.Value}
            $probe="`$m=Import-Module -Name '$($receipt.modulePath.Replace("'","''"))' -PassThru;[Console]::Out.Write(`$m.Version.ToString())"
            $arguments=@('-NoProfile','-NonInteractive')
            if($IsWindows){$arguments+=@('-ExecutionPolicy','Bypass')}
            $arguments+=@('-Command',$probe)
            $run=Invoke-PlatformPreparationCommand -Command $command -Arguments $arguments -Environment $environment -WorkingDirectory $TestDrive -PreparationReceipt $receipt
            $run.exitCode | Should Be 0
            $run.stdout | Should Be '4.10.1'
            $run.processOwnership.cleanup.CleanedUp | Should Be $true
            [IO.File]::AppendAllText($receipt.modulePath,"`n# changed snapshot")
            {Assert-PlatformAuthorityPester -Receipt $receipt} | Should Throw 'closure'
            $marker=Join-Path $TestDrive 'must-not-launch'
            $arguments=@('-NoProfile','-Command',"[IO.File]::WriteAllText('$($marker.Replace("'","''"))','launched')")
            {Invoke-PlatformPreparationCommand -Command $command -Arguments $arguments -Environment $environment -WorkingDirectory $TestDrive -PreparationReceipt $receipt} | Should Throw 'closure'
            Test-Path -LiteralPath $marker | Should Be $false
        } finally {[IO.Directory]::Delete($receipt.rootPath,$true)}
    }
}

Describe 'Platform stdin transport primitives' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        $nativeName = if ($IsWindows) { 'WindowsProcessControl' } else { 'UnixProcessControl' }
        $script:InputNative = [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease].Assembly.GetType('SyuanTsai.AIInstructions.PlatformRuntime.' + $nativeName)
        $script:InputFlags = [Reflection.BindingFlags]'Static,NonPublic'
    }
    # Scenario: A native stdin writer sends arbitrary bytes through its anonymous pipe.
    # Purpose: Verify binary transport and EOF independently from filesystem lease permissions.
    It 'InterT10_native_pipe_preserves_all_byte_values_and_eof' {
        $pipe=[IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out,[IO.HandleInheritability]::Inheritable)
        $client=$pipe.ClientSafePipeHandle; $reader=$null
        try {
            $reader=[IO.FileStream]::new([Microsoft.Win32.SafeHandles.SafeFileHandle]::new($client.DangerousGetHandle(),$false),[IO.FileAccess]::Read,1,$false)
            $script:InputNative.GetMethod('PrepareInputWriter',$script:InputFlags).Invoke($null,@($pipe.SafePipeHandle))
            $bytes=[byte[]](0..255)
            $writer=if($IsWindows){$pipe}else{$pipe.SafePipeHandle}
            $script:InputNative.GetMethod('WriteInput',$script:InputFlags).Invoke($null,@($writer,$bytes,[DateTimeOffset]::UtcNow.AddSeconds(5)))
            $pipe.Dispose()
            $received=[IO.MemoryStream]::new()
            try {
                $reader.CopyTo($received)
                [Convert]::ToBase64String($received.ToArray()) | Should Be ([Convert]::ToBase64String($bytes))
                $reader.ReadByte() | Should Be -1
            } finally { $received.Dispose() }
        } finally { if($null -ne $reader){$reader.Dispose()}; $client.Dispose(); $pipe.Dispose() }
    }
    # Scenario: No read end survives when the native writer sends bytes.
    # Purpose: Report a broken pipe instead of silently losing payload bytes.
    It 'InterT20_native_pipe_reports_reader_close' {
        $pipe=[IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out,[IO.HandleInheritability]::Inheritable)
        try {
            $script:InputNative.GetMethod('PrepareInputWriter',$script:InputFlags).Invoke($null,@($pipe.SafePipeHandle))
            $pipe.DisposeLocalCopyOfClientHandle()
            $writer=if($IsWindows){$pipe}else{$pipe.SafePipeHandle}
            { $script:InputNative.GetMethod('WriteInput',$script:InputFlags).Invoke($null,@($writer,[byte[]]@(1),[DateTimeOffset]::UtcNow.AddSeconds(5))) } | Should Throw
        } finally { $pipe.Dispose() }
    }
    if (-not $IsWindows) {
        # Scenario: An unconsumed Unix pipe becomes full.
        # Purpose: Nonblocking writes retain the deadline even if a reader has escaped the group.
        It 'InterT30_native_unix_pipe_bounds_a_stalled_reader' {
            $pipe=[IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out,[IO.HandleInheritability]::Inheritable)
            $client=$pipe.ClientSafePipeHandle
            try {
                $script:InputNative.GetMethod('PrepareInputWriter',$script:InputFlags).Invoke($null,@($pipe.SafePipeHandle))
                { $script:InputNative.GetMethod('WriteInput',$script:InputFlags).Invoke($null,@($pipe.SafePipeHandle,[byte[]]::new(16777216),[DateTimeOffset]::UtcNow.AddMilliseconds(200))) } | Should Throw 'deadline'
            } finally { $client.Dispose(); $pipe.Dispose() }
        }
    }
}

Describe 'Platform owned processes P3' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        $script:P3Root = if ($IsMacOS) { '/private/tmp' } else { [IO.Path]::GetTempPath().TrimEnd('\','/') }
        $script:P3Shell = (Get-Process -Id $PID).Path
        function New-P3Fixture {
            $name = 'p3-' + [guid]::NewGuid().ToString('N')
            $directory = Open-PlatformDirectory -Root $script:P3Root -RelativePath $name -CreatePrivate
            @{ Directory=$directory; Path=(Join-Path $script:P3Root $name) }
        }
        function Start-P3Fixture($Fixture,[string]$Code,[int]$Seconds=20,[long]$Limit=1048576,[byte[]]$InputBytes,[string]$CaptureProfile='standard') {
            $envMap = @{}
            if ($IsWindows) { $envMap.SystemRoot = $env:SystemRoot }
            $processOptions = @{ CaptureProfile = $CaptureProfile }
            if ($PSBoundParameters.ContainsKey('InputBytes')) { $processOptions.StandardInputBytes = $InputBytes }
            if ($CaptureProfile -ceq 'standard') { $processOptions.OutputLimitBytes = $Limit }
            Start-PlatformOwnedProcess @processOptions -ExecutablePath $script:P3Shell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))) -Environment $envMap -WorkingDirectoryLease $Fixture.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds($Seconds)) -IsolationRequirement cooperative -StdoutPath (Join-Path $Fixture.Path 'out') -StderrPath (Join-Path $Fixture.Path 'err')
        }
        function Invoke-P3BoundedDelete([scriptblock]$Action) {
            $until = [DateTimeOffset]::UtcNow.AddSeconds(5)
            while ($true) {
                try { & $Action; return }
                catch [IO.IOException], [UnauthorizedAccessException] {
                    if ([DateTimeOffset]::UtcNow -ge $until) { throw }
                    [Threading.Thread]::Sleep(100)
                }
            }
        }
        function Remove-P3Fixture($Fixture,$Lease) {
            if ($null -ne $Lease) { $Lease.Dispose() }
            $Fixture.Directory.Dispose()
            # Only fixture-owned, explicitly named files; never recursive cleanup.
            foreach ($leaf in @('out','err','child','ready','executable','quota.ps1')) { $path = Join-Path $Fixture.Path $leaf; if ([IO.File]::Exists($path)) { Invoke-P3BoundedDelete { [IO.File]::Delete($path) } } }
            Invoke-P3BoundedDelete { [IO.Directory]::Delete($Fixture.Path) }
        }
        function Assert-P3Exited($Lease) {
            if (-not $Lease.WaitForExit([TimeSpan]::FromSeconds(15))) {
                throw ('Root did not exit: ' + $Lease.TerminationReason + '; observation=' + ($Lease.UnixObservation | ConvertTo-Json -Compress) + '; cleanup=' + ($Lease.Cleanup | ConvertTo-Json -Depth 5 -Compress))
            }
        }
        function Assert-P3Cleaned($Receipt) {
            if (-not $Receipt.CleanedUp) { throw ('Cleanup failed: ' + ($Receipt | ConvertTo-Json -Depth 5 -Compress)) }
            $Receipt.CaptureReadersStopped | Should Be $true
            $Receipt.CaptureResourcesClosed | Should Be $true
        }
    }

    # Scenario: A caller supplies bytes without using a filesystem payload.
    # Purpose: The public entry point must expose a byte-array input contract.
    It 'UnitT05_exposes_optional_stdin_bytes' {
        (Get-Command Start-PlatformOwnedProcess).Parameters['StandardInputBytes'].ParameterType | Should Be ([byte[]])
    }
    # Scenario: The native overload receives oversized input with no launch resources.
    # Purpose: Validate the bound before touching ownership, captures or the OS.
    It 'UnitT06_native_stdin_bound_precedes_spawn' {
        $caught=$null
        try {
            [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($null,$null,@(),@{},$null,[DateTimeOffset]::UtcNow.AddSeconds(10),'cooperative',$null,$null,1048576,$null,[byte[]]::new(16777217))
        } catch { $caught=$_.Exception.GetBaseException() }
        ($caught -is [ArgumentException]) | Should Be $true
        $caught.Message | Should Match 'StandardInputBytes'
    }

    # Scenario: Capture bytes are requested before and after confirmed owned cleanup.
    # Purpose: Expose only the retained, bounded capture lease after all readers stop.
    It 'InterT07_reads_retained_capture_only_after_cleanup_with_a_byte_bound' {
        $f = New-P3Fixture; $p = $null; $standardFixture = $null; $standardProcess = $null
        try {
            $expected = [Text.Encoding]::UTF8.GetBytes('capture-original')
            $p = Start-P3Fixture $f '[Console]::Out.Write("capture-original"); Start-Sleep -Milliseconds 500' -InputBytes ([byte[]]@()) -CaptureProfile semantic-bridge
            $caught = $null
            try { $p.ReadCapture('stdout', 1024) | Out-Null } catch { $caught = $_.Exception.GetBaseException() }
            ($caught -is [InvalidOperationException]) | Should Be $true
            $caught = $null
            try { $p.ReadCapture('invalid', 1024) | Out-Null } catch { $caught = $_.Exception.GetBaseException() }
            ($caught -is [ArgumentException]) | Should Be $true
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            [Convert]::ToBase64String($p.ReadCapture('stdout', $expected.Length)) | Should Be ([Convert]::ToBase64String($expected))
            { $p.ReadCapture('stdout', ($expected.Length - 1)) } | Should Throw 'bounded read limit'
            $p.Dispose()
            [Convert]::ToBase64String($p.ReadCapture('stdout', $expected.Length)) | Should Be ([Convert]::ToBase64String($expected))

            $standardFixture = New-P3Fixture
            $standardProcess = Start-P3Fixture $standardFixture '[Console]::Out.Write("standard-capture")'
            Assert-P3Exited $standardProcess
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $standardProcess)
            { $standardProcess.ReadCapture('stdout', 1024) } | Should Throw 'semantic-bridge capture profile'
            [IO.File]::ReadAllText((Join-Path $standardFixture.Path 'out')) | Should Be 'standard-capture'
        } finally {
            if ($null -ne $standardFixture) { Remove-P3Fixture $standardFixture $standardProcess }
            Remove-P3Fixture $f $p
        }
    }

    # Scenario: A callback-side actor unlinks stdout and replaces its name with /dev/zero.
    # Purpose: Bound cleanup and either retain the original inode or fail closed.
    It 'InterT08_fails_closed_or_reads_original_bytes_after_capture_unlink' {
        $f = New-P3Fixture; $p = $null
        try {
            $expected = [Text.Encoding]::UTF8.GetBytes('retained-inode')
            $p = Start-P3Fixture $f '[Console]::Out.Write("retained-inode")' -Seconds 5 -InputBytes ([byte[]]@()) -CaptureProfile semantic-bridge
            Assert-P3Exited $p
            if (-not $IsWindows) {
                [IO.File]::Delete((Join-Path $f.Path 'out'))
                [IO.File]::CreateSymbolicLink((Join-Path $f.Path 'out'), '/dev/zero') | Out-Null
            }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try { $receipt = Stop-PlatformOwnedProcess -Lease $p } finally { $watch.Stop() }
            $watch.Elapsed.TotalSeconds | Should BeLessThan 15
            if ($IsWindows) {
                Assert-P3Cleaned $receipt
                [Convert]::ToBase64String($p.ReadCapture('stdout', 1024)) | Should Be ([Convert]::ToBase64String($expected))
            }
            elseif (-not $receipt.CleanedUp) {
                { $p.ReadCapture('stdout', 1024) } | Should Throw 'cleanup'
            }
            else {
                [Convert]::ToBase64String($p.ReadCapture('stdout', 1024)) | Should Be ([Convert]::ToBase64String($expected))
            }
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: A child exits with distinct output streams and a nonzero status.
    # Purpose: Preserve argv, explicit environment, byte capture and exit code.
    It 'InterT10_captures_exit_code_and_both_streams' {
        $f = New-P3Fixture; $p = $null
        try {
            $p = Start-P3Fixture $f '[Console]::Out.Write("hello"); [Console]::Error.Write("problem"); exit 23'
            Assert-P3Exited $p
            $r = Stop-PlatformOwnedProcess -Lease $p
            Assert-P3Cleaned $r
            $p.CaptureCompletedNaturally | Should Be $true
            $p.ExitCode | Should Be 23
            if ($IsMacOS) { Write-Host ('Darwin natural-exit evidence: ' + ($p.UnixObservation | ConvertTo-Json -Compress)) }
            [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be 'hello'
            [IO.File]::ReadAllText((Join-Path $f.Path 'err')) | Should Be 'problem'
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: Input exceeds a pipe buffer and contains NUL and multibyte UTF-8.
    # Purpose: Send every byte after ownership, concurrently draining output, and close stdin.
    It 'InterT11_roundtrips_stdin_bytes_and_eof' {
        $f = New-P3Fixture; $p = $null
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((("input`0" + [char]0x754c + "`r`n") * 20000))
            $p = Start-P3Fixture $f '[Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())' -InputBytes $bytes
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $f.Path 'out'))) | Should Be ([Convert]::ToBase64String($bytes))
        } finally { Remove-P3Fixture $f $p }
    }
    # Scenario: No input argument or an explicitly empty array is supplied.
    # Purpose: Preserve immediate EOF in both overloads.
    It 'InterT12_omitted_and_empty_stdin_observe_eof' {
        foreach ($explicit in @($false,$true)) {
            $f = New-P3Fixture; $p = $null
            try {
                $options = @{}
                if ($explicit) { $options.InputBytes = [byte[]]@() }
                $p = Start-P3Fixture $f '[Console]::Write([Console]::OpenStandardInput().ReadByte())' @options
                Assert-P3Exited $p
                Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
                [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be '-1'
            } finally { Remove-P3Fixture $f $p }
        }
    }
    # Scenario: Input exceeds the 16 MiB bound before spawn.
    # Purpose: Reject without executing the child or creating capture files.
    It 'InterT13_rejects_oversize_stdin_before_start' {
        $f = New-P3Fixture
        try {
            { Start-P3Fixture $f '[IO.File]::WriteAllText("ready","started")' -InputBytes ([byte[]]::new(16777217)) } | Should Throw 'StandardInputBytes'
            [IO.File]::Exists((Join-Path $f.Path 'ready')) | Should Be $false
            [IO.File]::Exists((Join-Path $f.Path 'out')) | Should Be $false
        } finally { Remove-P3Fixture $f $null }
    }
    # Scenario: The root delegates inherited stdin to a grandchild before reading it.
    # Purpose: A leaked write end must not keep the grandchild waiting for EOF.
    It 'InterT14_descendant_stdin_reaches_eof' {
        $f = New-P3Fixture; $p = $null
        try {
            $code = '$s=[Diagnostics.ProcessStartInfo]::new(); $s.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; $s.UseShellExecute=$false; $s.Arguments=''-NoProfile -NonInteractive -Command "[Console]::Write([Console]::In.ReadToEnd())"''; $c=[Diagnostics.Process]::Start($s); $c.WaitForExit(); $c.Dispose()'
            $p = Start-P3Fixture $f $code -InputBytes ([Text.Encoding]::UTF8.GetBytes('descendant-input'))
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be 'descendant-input'
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: Another waiter reaps the Darwin root while our supervisor is paused.
    # Purpose: The pre-registered kqueue event preserves status despite waitpid ECHILD and absent libproc identity.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsMacOS) {
        It 'InterT15_preserves_darwin_exit_status_after_external_reaping' {
            $f = New-P3Fixture; $p = $null
            try {
                $p = Start-P3Fixture $f 'Start-Sleep -Milliseconds 500; exit 23'
                $flags = [Reflection.BindingFlags]'Instance,NonPublic'
                $gate = $p.GetType().GetField('gate',$flags).GetValue($p)
                $control = $p.GetType().GetField('control',$flags).GetValue($p)
                $waiter = $control.GetType().GetField('waitForChild',$flags).GetValue($control)
                [Threading.Monitor]::Enter($gate)
                try {
                    $until = [DateTimeOffset]::UtcNow.AddSeconds(10)
                    do {
                        $wait = $waiter.Invoke($p.Pid)
                        if ($wait.Item1 -ne 0) { break }
                        [Threading.Thread]::Sleep(10)
                    } while ([DateTimeOffset]::UtcNow -lt $until)
                    $wait.Item1 | Should Be $p.Pid
                    $wait.Item2 | Should Be (23 * 256)
                } finally { [Threading.Monitor]::Exit($gate) }
                Assert-P3Exited $p
                Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
                $p.ExitCode | Should Be 23
                $p.UnixObservation.WaitIdErrno | Should Be 10
                $p.UnixObservation.KqueueExitStatus | Should Be (23 * 256)
                Write-Host ('Darwin external-reap evidence: ' + ($p.UnixObservation | ConvertTo-Json -Compress))
            } finally { Remove-P3Fixture $f $p }
        }
    }

    # Scenario: A child exits before consuming a payload larger than the pipe buffer.
    # Purpose: Broken-pipe failure must carry stage and confirmed cleanup evidence.
    It 'InterT16_fails_closed_when_stdin_reader_exits' {
        $f = New-P3Fixture; $caught = $null
        try {
            try { Start-P3Fixture $f '[Environment]::Exit(0)' -InputBytes ([byte[]]::new(16777216)) | Out-Null } catch { $caught=$_.Exception }
            while ($null -ne $caught -and -not $caught.Data.Contains('StartupStage')) { $caught=$caught.InnerException }
            $caught | Should Not BeNullOrEmpty
            $caught.Data['StartupStage'] | Should Be 'stdin-write'
            $caught.Data['StartupCleanupConfirmed'] | Should Be $true
        } finally { Remove-P3Fixture $f $null }
    }
    # Scenario: A child never reads stdin and stays alive past the workload deadline.
    # Purpose: Input delivery cannot hang the caller, and the failed start releases ownership.
    It 'InterT17_bounds_stalled_stdin_delivery' {
        $f = New-P3Fixture; $caught = $null; $timer=[Diagnostics.Stopwatch]::StartNew()
        try {
            try { Start-P3Fixture $f '[Threading.Thread]::Sleep(30000)' -Seconds 2 -InputBytes ([byte[]]::new(16777216)) | Out-Null } catch { $caught=$_.Exception }
            $timer.Elapsed.TotalSeconds | Should BeLessThan 12
            while ($null -ne $caught -and -not $caught.Data.Contains('StartupStage')) { $caught=$caught.InnerException }
            $caught | Should Not BeNullOrEmpty
            $caught.Data['StartupStage'] | Should Be 'stdin-write'
            $caught.Data['StartupCleanupConfirmed'] | Should Be $true
        } finally { Remove-P3Fixture $f $null }
    }
    # Scenario: All possible byte values cross stdin, including invalid UTF-8.
    # Purpose: Input transport is binary even though the existing capture contract is text.
    It 'InterT18_delivers_arbitrary_binary_stdin' {
        $f = New-P3Fixture; $p = $null
        try {
            $bytes = [byte[]](0..255)
            $p = Start-P3Fixture $f '$m=[IO.MemoryStream]::new(); [Console]::OpenStandardInput().CopyTo($m); [Console]::Write([Convert]::ToBase64String($m.ToArray())); $m.Dispose()' -InputBytes $bytes
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be ([Convert]::ToBase64String($bytes))
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: No caller polls or stops a sleeping process before its deadline.
    # Purpose: Enforce the execution deadline from a managed background supervisor.
    It 'InterT20_enforces_deadline_without_caller_polling' {
        $f = New-P3Fixture; $p = $null
        try {
            $p = Start-P3Fixture $f 'Start-Sleep 90' 2
            $p.WaitForCleanup([TimeSpan]::FromSeconds(15)) | Should Be $true
            Assert-P3Cleaned $p.Cleanup
            $p.TerminationReason | Should Be 'deadline'
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: Readers reach their deadline while the supervisor cannot acquire its gate.
    # Purpose: Reader termination must never stand in for successful EOF observation.
    It 'InterT25_distinguishes_reader_deadline_from_natural_eof' {
        $f=New-P3Fixture; $p=$null
        try {
            $p=Start-P3Fixture $f 'Start-Sleep 90' 2
            $gate=$p.GetType().GetField('gate',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($p)
            [Threading.Monitor]::Enter($gate)
            try {
                $until=[DateTimeOffset]::UtcNow.AddSeconds(10)
                while(-not $p.CaptureReadersStopped -and [DateTimeOffset]::UtcNow -lt $until){[Threading.Thread]::Sleep(10)}
                $p.CaptureReadersStopped | Should Be $true
                $p.CaptureCompletedNaturally | Should Be $false
            } finally {[Threading.Monitor]::Exit($gate)}
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
        } finally {Remove-P3Fixture $f $p}
    }

    # Scenario: The caller cancels a live lease, then disposes it twice.
    # Purpose: Stop is bounded and resource release is idempotent.
    It 'InterT30_cancels_and_disposes_idempotently' {
        $f = New-P3Fixture; $p = $null
        try {
            $p = Start-P3Fixture $f 'Start-Sleep 90'
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p -GracePeriod ([TimeSpan]::FromMilliseconds(100)) -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)))
            $p.Dispose(); $p.Dispose()
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: A secret sentinel exists only in the parent's environment.
    # Purpose: Child creation never implicitly inherits the parent's environment block.
    It 'InterT40_does_not_inherit_unlisted_environment' {
        $f = New-P3Fixture; $p = $null; $old = $env:P3_PARENT_SENTINEL
        try {
            $env:P3_PARENT_SENTINEL = 'must-not-inherit'
            $p = Start-P3Fixture $f '[Console]::Write([Environment]::GetEnvironmentVariable("P3_PARENT_SENTINEL"))'
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be ''
        } finally { $env:P3_PARENT_SENTINEL = $old; Remove-P3Fixture $f $p }
    }

    # Scenario: stderr produces unlimited bytes.
    # Purpose: Bound persisted output and terminate instead of filling the filesystem.
    It 'InterT50_terminates_on_stderr_character_limit' {
        $f = New-P3Fixture; $p = $null
        try {
            $p = Start-P3Fixture $f 'while ($true) { [Console]::Error.Write(("x" * 8192)) }' 20 4096
            $p.WaitForCleanup([TimeSpan]::FromSeconds(15)) | Should Be $true
            $p.TerminationReason | Should Be 'output-limit'
            $p.OutputLimitExceeded | Should Be $true
            Assert-P3Cleaned $p.Cleanup
            (Get-Item (Join-Path $f.Path 'err')).Length | Should BeLessThan 4097
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: A root with a sleeping descendant exceeds either stream's full quota, then sleeps for 30 seconds.
    # Purpose: Require autonomous owner cleanup in under 25 seconds, without a caller Stop or natural exit.
    It 'InterT67_terminates_the_tree_promptly_after_either_stream_exceeds_quota' {
        foreach ($stream in @('Out','Error')) {
            $f=New-P3Fixture; $p=$null
            try {
                $scriptPath=Join-Path $f.Path 'quota.ps1'
                $code=@'
param([string]$Stream,[switch]$Descendant)
if ($Descendant) { Start-Sleep 90; exit 0 }
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$start.UseShellExecute=$false; $start.CreateNoWindow=$true
foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive')) { $start.ArgumentList.Add($argument) }
if ($IsWindows) { $start.ArgumentList.Add('-ExecutionPolicy'); $start.ArgumentList.Add('Bypass') }
foreach ($argument in @('-File',$PSCommandPath,'-Descendant')) { $start.ArgumentList.Add($argument) }
$child=[Diagnostics.Process]::Start($start)
try {
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ready'),([pscustomobject]@{pid=$child.Id;start=$child.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json))
} finally { $child.Dispose() }
$writer=if ($Stream -ceq 'Out') { [Console]::Out } else { [Console]::Error }
$writer.Write(('x' * 1100000))
Start-Sleep 30
'@
                [IO.File]::WriteAllText($scriptPath,$code,[Text.UTF8Encoding]::new($false))
                $arguments=@('-NoLogo','-NoProfile','-NonInteractive')
                if ($IsWindows) { $arguments+=@('-ExecutionPolicy','Bypass') }
                $arguments+=@('-File',$scriptPath,'-Stream',$stream)
                $environment=@{}; if ($IsWindows) { $environment.SystemRoot=$env:SystemRoot }
                $clock=[Diagnostics.Stopwatch]::StartNew()
                $p=Start-PlatformOwnedProcess -ExecutablePath $script:P3Shell -ArgumentList $arguments -Environment $environment -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(60)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err') -OutputLimitCharacters 1048576
                $p.WaitForCleanup([TimeSpan]::FromSeconds(24)) | Should Be $true
                $clock.Stop()
                $clock.Elapsed.TotalSeconds | Should BeLessThan 25
                $p.OutputLimitExceeded | Should Be $true
                $p.TerminationReason | Should Be 'output-limit'
                Assert-P3Cleaned $p.Cleanup
                @($p.Cleanup.RemainingPids).Count | Should Be 0
                $identity=Get-Content -LiteralPath (Join-Path $f.Path 'ready') -Raw | ConvertFrom-Json
                $child=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
                if ($null -ne $child) {
                    try { ($child.StartTime.ToUniversalTime().ToString('o') -ceq $identity.start -and -not $child.HasExited) | Should Be $false }
                    finally { $child.Dispose() }
                }
            } finally { Remove-P3Fixture $f $p }
        }
    }

    # Scenario: Each stream emits its full allowed quota, including multibyte UTF-8 characters.
    # Purpose: Quotas are per stream and count decoded characters, not aggregate bytes.
    It 'InterT55_preserves_independent_utf8_stream_quotas' {
        $f = New-P3Fixture; $p = $null
        try {
            $p = Start-P3Fixture $f '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $s=([string][char]0x754c)*4096; [Console]::Write($s); [Console]::Error.Write($s)' 20 4096
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            $p.OutputLimitExceeded | Should Be $false
            foreach ($leaf in @('out','err')) { [IO.File]::ReadAllText((Join-Path $f.Path $leaf)) | Should Be (([string][char]0x754c)*4096) }
        } finally { Remove-P3Fixture $f $p }
    }

    # Scenario: A caller requires containment from a process-group-only host.
    # Purpose: Fail with a typed capability error before creating files or processes.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT60_refuses_strong_isolation_on_unix' {
            $f = New-P3Fixture
            try {
                $caught = $null
                try { Start-PlatformOwnedProcess -ExecutablePath $script:P3Shell -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -IsolationRequirement strong -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err') } catch { $caught = $_.Exception }
                while ($null -ne $caught.InnerException) { $caught = $caught.InnerException }
                $caught.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
                Test-Path (Join-Path $f.Path 'out') | Should Be $false
            } finally { Remove-P3Fixture $f $null }
        }
    }

    # Scenario: A caller supplies a stale PID/start identity to Stop.
    # Purpose: An identity mismatch authorizes no signal, even against a live root.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT70_refuses_stale_process_identity_without_signalling' {
            $f = New-P3Fixture; $p = $null
            try {
                $p = Start-P3Fixture $f 'Start-Sleep 90'
                $r = Stop-PlatformOwnedProcess -Lease $p -ExpectedStartIdentity 'incorrect-start-time'
                $r.CleanedUp | Should Be $false
                $r.SignalsSent | Should Be 0
                $p.HasExited | Should Be $false
                Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            } finally { Remove-P3Fixture $f $p }
        }
    }

    # Scenario: A child launches a grandchild and immediately exits.
    # Purpose: Root exit cannot hide live job/group descendants or adopted zombies.
    It 'InterT80_reclaims_grandchildren_after_parent_exit' {
        $f = New-P3Fixture; $p = $null
        try {
            $escapedShell = $script:P3Shell.Replace("'","''")
            $code = '$s = [Diagnostics.ProcessStartInfo]::new(); $s.FileName = ''' + $escapedShell + '''; $s.UseShellExecute = $false; $s.ArgumentList.Add(''-NoProfile''); $s.ArgumentList.Add(''-NonInteractive''); $s.ArgumentList.Add(''-Command''); $s.ArgumentList.Add(''Start-Sleep 90''); $c = [Diagnostics.Process]::Start($s); [IO.File]::WriteAllText(''child'',[string]$c.Id)'
            $p = Start-P3Fixture $f $code
            Assert-P3Exited $p
            $childId = [int][IO.File]::ReadAllText((Join-Path $f.Path 'child'))
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            @(Get-Process -Id $childId -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally { Remove-P3Fixture $f $p }
    }

    # Register Unix-only fixtures conditionally: this file contributes no platform skips to Core CI.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: The native root exits while an in-group child keeps both capture pipes open.
    # Purpose: Retain the zombie and use a group signal to terminate cooperative descendants on both Unix hosts.
    It 'InterT82_uses_the_retained_zombie_to_terminate_the_remaining_group' {
        $f = New-P3Fixture; $p = $null
        try {
            $p = Start-PlatformOwnedProcess -ExecutablePath '/bin/sh' -ArgumentList @('-c','/bin/sleep 90 & echo $! > child; exit 0') -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(20)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
            Assert-P3Exited $p
            $p.UnixObservation.RootReserved | Should Be $true
            $p.UnixObservation.WaitPidResult | Should BeNullOrEmpty
            $childId = [int][IO.File]::ReadAllText((Join-Path $f.Path 'child'))
            $receipt = Stop-PlatformOwnedProcess -Lease $p
            Assert-P3Cleaned $receipt
            $receipt.UnixObservation.GroupSignalsSent | Should BeGreaterThan 0
            $receipt.UnixObservation.WaitPidResult | Should Be $p.Pid
            @(Get-Process -Id $childId -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally { Remove-P3Fixture $f $p }
    }
    }

    # Scenario: Two shell generations exit before a long-lived leaf exits.
    # Purpose: Linux subreaper reaps adopted group descendants, including double-fork orphans.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux) {
        It 'InterT85_reaps_linux_double_fork_orphans' {
            $f = New-P3Fixture; $p = $null
            try {
                $p = Start-PlatformOwnedProcess -ExecutablePath '/bin/sh' -ArgumentList @('-c','( ( /bin/sleep 90 & echo $! > child ) & wait )') -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(20)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                if (-not $p.WaitForExit([TimeSpan]::FromSeconds(10))) { throw ('Double-fork root did not exit: ' + $p.TerminationReason + '; ' + ($p.Cleanup | ConvertTo-Json -Compress)) }
                $childId = [int][IO.File]::ReadAllText((Join-Path $f.Path 'child'))
                $receipt = Stop-PlatformOwnedProcess -Lease $p
                if (-not $receipt.CleanedUp) { throw ('Double-fork cleanup failed: ' + ($receipt | ConvertTo-Json -Compress)) }
                Test-Path ('/proc/' + $childId) | Should Be $false
            } finally { Remove-P3Fixture $f $p }
        }
    }

    # Scenario: A TERM handler starts a new group member and exits during cleanup.
    # Purpose: A post-exit census must find and stop the late child before reaping the root anchor.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT87_reclaims_descendants_forked_by_a_term_handler' {
            $f = New-P3Fixture; $p = $null
            try {
                $command = 'trap ''/bin/sleep 90 & echo $! > child; exit 0'' TERM; echo ready > ready; while :; do /bin/sleep 1; done'
                $p = Start-PlatformOwnedProcess -ExecutablePath '/bin/sh' -ArgumentList @('-c',$command) -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(20)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                $until = [DateTimeOffset]::UtcNow.AddSeconds(10)
                while (-not [IO.File]::Exists((Join-Path $f.Path 'ready')) -and [DateTimeOffset]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
                [IO.File]::Exists((Join-Path $f.Path 'ready')) | Should Be $true
                $receipt = Stop-PlatformOwnedProcess -Lease $p -GracePeriod ([TimeSpan]::FromSeconds(2)) -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10))
                Assert-P3Cleaned $receipt
                $childId = [int][IO.File]::ReadAllText((Join-Path $f.Path 'child'))
                @(Get-Process -Id $childId -ErrorAction SilentlyContinue).Count | Should Be 0
            } finally { Remove-P3Fixture $f $p }
        }
    }

    # Scenario: Failed-start cleanup begins before a real child has been recorded as owned.
    # Purpose: Exercise the native cleanup loop and prove that the late-discovered child no longer lives.
    # Register only on Unix hosts; Windows uses its bound Job Object cleanup path.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT88_failed_start_cleanup_reclaims_unrecorded_native_descendants' {
            $f=New-P3Fixture; $p=$null
            try {
                $p=Start-PlatformOwnedProcess -ExecutablePath '/bin/sh' -ArgumentList @('-c','/bin/sleep 90 & echo $! > child; wait') -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(20)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                $until=[DateTimeOffset]::UtcNow.AddSeconds(10)
                while (-not [IO.File]::Exists((Join-Path $f.Path 'child')) -and [DateTimeOffset]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
                [IO.File]::Exists((Join-Path $f.Path 'child')) | Should Be $true
                # File creation precedes its small write; wait for a complete PID.
                $childId=0
                while (-not [int]::TryParse([IO.File]::ReadAllText((Join-Path $f.Path 'child')),[ref]$childId) -and [DateTimeOffset]::UtcNow -lt $until) { Start-Sleep -Milliseconds 10 }
                $childId | Should BeGreaterThan 0
                $flags=[Reflection.BindingFlags]'Instance,NonPublic'
                $gate=$p.GetType().GetField('gate',$flags).GetValue($p)
                $control=$p.GetType().GetField('control',$flags).GetValue($p)
                [Threading.Monitor]::Enter($gate)
                try {
                    # Reproduce the pre-census startup state without a global fault hook.
                    $control.GetType().GetMethod('ForgetOwned',$flags).Invoke($control,[object[]]@($childId))
                    $control.GetType().GetMethod('CleanupFailedStart',$flags).Invoke($control,[object[]]@([TimeSpan]::FromSeconds(5)))
                    @($control.GetType().GetMethod('Remaining',[Reflection.BindingFlags]'Instance,Public').Invoke($control,@())).Count | Should Be 0
                    @(Get-Process -Id $childId -ErrorAction SilentlyContinue).Count | Should Be 0
                } finally { [Threading.Monitor]::Exit($gate) }
                Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            } finally { Remove-P3Fixture $f $p }
        }
    }

    # Scenario: A native child creates a new session, escaping its original group.
    # Purpose: Linux subreaper can observe adoption; macOS must report uncertainty.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT90_reports_or_reclaims_setsid_escape' {
            $f = New-P3Fixture; $p = $null; $childId = 0; $child = $null
            try {
                $code = 'Add-Type -TypeDefinition ''using System.Runtime.InteropServices; public class P3Escape { [DllImport("libc")] public static extern int setsid(); }''; if ([P3Escape]::setsid() -lt 0) { throw ''setsid fixture failed'' }; [IO.File]::WriteAllText(''child'',[string]$PID); Start-Sleep 90'
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
                $escapedShell = $script:P3Shell.Replace("'","''")
                $parent = '$s = [Diagnostics.ProcessStartInfo]::new(); $s.FileName = ''' + $escapedShell + '''; $s.UseShellExecute = $false; foreach ($a in @(''-NoProfile'',''-NonInteractive'',''-EncodedCommand'',''' + $encoded + ''')) { $s.ArgumentList.Add($a) }; [Diagnostics.Process]::Start($s) | Out-Null; Start-Sleep 3'
                $p = Start-P3Fixture $f $parent
                $until = [DateTime]::UtcNow.AddSeconds(15)
                while (-not [IO.File]::Exists((Join-Path $f.Path 'child')) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
                $childId = [int][IO.File]::ReadAllText((Join-Path $f.Path 'child'))
                $child = Get-Process -Id $childId -ErrorAction Stop
                $childStart = $child.StartTime
                Assert-P3Exited $p
                $r = Stop-PlatformOwnedProcess -Lease $p
                if ($IsMacOS) {
                    $r.Limitations | Should Contain 'macos-process-group-cannot-detect-setsid-escape'
                    # An unobserved escape is outside this capability's cleanup scope.
                    # An observed escape must either exit or keep cleanup incomplete.
                    if (-not $r.CleanedUp) { $r.Uncertainty | Should Not BeNullOrEmpty }
                }
                elseif ($r.CleanedUp) { @(Get-Process -Id $childId -ErrorAction SilentlyContinue).Count | Should Be 0 }
                else { $r.Uncertainty | Should Not BeNullOrEmpty }
                $r.CaptureReadersStopped | Should Be $true
                $r.CaptureResourcesClosed | Should Be $true
            } finally {
                if ($null -ne $p) { $p.Dispose() }
                # Fixture fallback only: kill by a retained Process object/start time, never guessed PID.
                if ($null -ne $child) {
                    $current = Get-Process -Id $childId -ErrorAction SilentlyContinue
                    if ($null -ne $current) { try { if ($current.StartTime -eq $childStart) { $current.Kill(); $current.WaitForExit(5000) | Out-Null } } finally { $current.Dispose() } }
                    $child.Dispose()
                }
                Remove-P3Fixture $f $null
            }
        }
    }

    # Scenario: Output paths already name a caller-owned file.
    # Purpose: Capture creation cannot truncate or overwrite existing content.
    It 'InterT100_refuses_existing_output_files' {
        $f = New-P3Fixture
        try {
            [IO.File]::WriteAllText((Join-Path $f.Path 'out'),'sentinel')
            { Start-P3Fixture $f 'exit 0' } | Should Throw
            [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be 'sentinel'
        } finally { Remove-P3Fixture $f $null }
    }

    # Scenario: Capabilities are requested before using the process API.
    # Purpose: Available means a real child ran and cleanup completed on this host.
    It 'InterT110_probes_actual_process_isolation_and_cleanup' {
        $r = Get-PlatformCapabilities -Required @('owned-process','process-cleanup')
        $expected = if ($IsWindows) { 'windows-job-object' } elseif ($IsLinux) { 'linux-process-group-subreaper' } else { 'macos-process-group' }
        foreach ($name in @('owned-process','process-cleanup','process-isolation')) {
            $c = $r.capabilities | Where-Object name -eq $name
            $c.status | Should Be 'available'
            $c.evidence.isolation | Should Be $expected
            if ($IsMacOS) { $c.evidence[0].limitations | Should Contain 'macos-process-group-cannot-detect-setsid-escape' }
            if ($IsLinux -or $IsMacOS) { $c.evidence[0].limitations | Should Contain 'group-signal-external-reaper-race' }
            else { @($c.evidence[0].limitations).Count | Should Be 0 }
        }
    }

    # Scenario: An executable is supplied as a P2 lease rather than a pathname.
    # Purpose: Preserve descriptor/handle identity and bind the child's working directory.
    It 'InterT120_starts_from_executable_and_directory_leases' {
        $f = New-P3Fixture; $p = $null; $executable = $null; $parent = $null
        try {
            $exePath = $script:P3Shell
            $parentPath = [IO.Path]::GetDirectoryName($exePath); $anchor = [IO.Path]::GetPathRoot($parentPath)
            $parent = Open-PlatformDirectory -Root $anchor -RelativePath $parentPath.Substring($anchor.Length)
            $executable = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($exePath)) -Access Read -CreateMode OpenExisting
            $argsList = @('-NoProfile','-NonInteractive','-Command','[Console]::Write([Environment]::CurrentDirectory); if ([Console]::Read() -ne -1) { exit 9 }')
            $envMap = @{}; if ($IsWindows) { $envMap.SystemRoot = $env:SystemRoot }
            $p = Start-PlatformOwnedProcess -ExecutableLease $executable -ArgumentList $argsList -Environment $envMap -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(20)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
            $executable.Dispose(); $parent.Dispose()
            Assert-P3Exited $p
            Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
            $p.ExitCode | Should Be 0
            [IO.File]::ReadAllText((Join-Path $f.Path 'out')).Trim() | Should Be $f.Path
        } finally { if ($null -ne $executable) { $executable.Dispose() }; if ($null -ne $parent) { $parent.Dispose() }; Remove-P3Fixture $f $p }
    }

    # Scenario: A caller supplies a relative, empty or NUL-containing invocation path.
    # Purpose: Reject invalid argv0 before reserving capture files or starting a process.
    It 'InterT121_rejects_invalid_argument_zero_before_capture' {
        $f = New-P3Fixture
        try {
            foreach ($invalid in @('relative-host', '', ($script:P3Shell + [char]0 + 'suffix'))) {
                { Start-PlatformOwnedProcess -ExecutablePath $script:P3Shell -ArgumentZero $invalid -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err') } | Should Throw 'ArgumentZero must be an absolute path without NUL.'
                [IO.File]::Exists((Join-Path $f.Path 'out')) | Should -BeFalse
                [IO.File]::Exists((Join-Path $f.Path 'err')) | Should -BeFalse
            }
        } finally { Remove-P3Fixture $f $null }
    }

    if ($IsWindows) {
        # Scenario: A Windows caller passes a valid Unix-only argv0 override.
        # Purpose: Keep Windows executable selection and Job ownership unchanged.
        It 'InterT122_preserves_windows_launch_with_argument_zero' {
            $f = New-P3Fixture; $p = $null
            try {
                $environment = [Collections.Generic.Dictionary[string,string]]::new()
                $environment['SystemRoot'] = [string]$env:SystemRoot
                $p = Start-PlatformOwnedProcess -ExecutablePath $script:P3Shell -ArgumentZero (Join-Path $f.Path 'alias.exe') -ArgumentList @('-NoProfile','-NonInteractive','-Command',"[Console]::Write('windows-unchanged')") -Environment $environment -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                Assert-P3Exited $p
                (Stop-PlatformOwnedProcess -Lease $p).CleanedUp | Should -BeTrue
                $p.ExitCode | Should -Be 0
                [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should -Be 'windows-unchanged'
            } finally { Remove-P3Fixture $f $p }
        }
    }
    if ($IsLinux -or $IsMacOS) {
        # Scenario: A leased shell is executed with a different absolute invocation name.
        # Purpose: argv0 is caller-controlled data while the executable remains lease-bound.
        It 'InterT123_preserves_argument_zero_with_executable_lease' {
          foreach ($override in @($false,$true)) {
            $f = New-P3Fixture; $file = $null; $p = $null
            try {
                [IO.File]::Copy('/bin/sh',(Join-Path $f.Path 'executable'))
                $file = Open-PlatformFile -ParentLease $f.Directory -Leaf 'executable' -Access Read -CreateMode OpenExisting
                Set-PlatformPermissions -Lease $file -Policy @{ Mode=448 } | Out-Null
                $invocation = Join-Path $f.Path 'venv/bin/sh'
                $options = @{}
                if ($override) { $options.ArgumentZero = $invocation }
                $environment = [Collections.Generic.Dictionary[string,string]]::new()
                $p = Start-PlatformOwnedProcess -ExecutableLease $file @options -ArgumentList @('-c','printf "%s" "$0"') -Environment $environment -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                Assert-P3Exited $p
                (Stop-PlatformOwnedProcess -Lease $p).CleanedUp | Should -BeTrue
                $p.ExitCode | Should -Be 0
                $expected = if ($override) { $invocation } elseif ($IsLinux) { '/proc/self/fd/3' } else { Join-Path $f.Path 'executable' }
                [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should -Be $expected
            } finally { if ($null -ne $file) { $file.Dispose() }; Remove-P3Fixture $f $p }
          }
        }
    }

    # Scenario: An ordinary newly created P2 file is supplied as an executable lease.
    # Purpose: Refuse mode 0600 with a typed error; never silently add executable permissions.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT125_refuses_an_executable_lease_without_execute_permission' {
            $f = New-P3Fixture; $file = $null
            try {
                $file = Open-PlatformFile -ParentLease $f.Directory -Leaf 'executable' -Access Read -CreateMode CreateNew
                [IO.File]::WriteAllText((Join-Path $f.Path 'executable'),"#!/bin/sh`nexit 0`n",[Text.UTF8Encoding]::new($false))
                $caught = $null
                try { Start-PlatformOwnedProcess -ExecutableLease $file -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err') | Out-Null } catch { $caught = $_.Exception }
                $caught | Should Not BeNullOrEmpty
                while ($null -ne $caught.InnerException) { $caught = $caught.InnerException }
                $caught.GetType().Name | Should Be 'PlatformErrnoException'
                $caught.Operation | Should Be 'executable-lease-permission'
                $caught.Errno | Should Be 13
                (Get-PlatformPermissions -Lease $file).Mode | Should Be '600'
            } finally { if ($null -ne $file) { $file.Dispose() }; Remove-P3Fixture $f $null }
        }
    }

    if ($IsLinux) {
        # Scenario: A shebang interpreter must reopen the leased script through fd 3.
        # Purpose: The child descriptor survives exec and the parent's lease disposal.
        It 'InterT128_keeps_leased_script_descriptor_readable_after_exec' {
            $f = New-P3Fixture; $file = $null; $p = $null
            try {
                $file = Open-PlatformFile -ParentLease $f.Directory -Leaf 'executable' -Access Read -CreateMode CreateNew
                [IO.File]::WriteAllText((Join-Path $f.Path 'executable'),@'
#!/bin/sh
IFS= read -r first < /proc/self/fd/3 || exit 91
[ "$first" = '#!/bin/sh' ] || exit 92
printf '%s' "$0"
'@,[Text.UTF8Encoding]::new($false))
                Set-PlatformPermissions -Lease $file -Policy @{ Mode=448 } | Out-Null
                $environment = [Collections.Generic.Dictionary[string,string]]::new()
                $p = Start-PlatformOwnedProcess -ExecutableLease $file -ArgumentZero (Join-Path $f.Path 'invocation') -Environment $environment -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                $file.Dispose(); $file = $null
                Assert-P3Exited $p
                (Stop-PlatformOwnedProcess -Lease $p).CleanedUp | Should -BeTrue
                $p.ExitCode | Should -Be 0
                [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should -Be '/proc/self/fd/3'
            } finally { if ($null -ne $file) { $file.Dispose() }; Remove-P3Fixture $f $p }
        }
    }

    # Scenario: The caller explicitly makes a P2-created script executable using fchmod.
    # Purpose: Exercise Darwin's validated pathname and Linux's descriptor execution with mode 0700.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
        It 'InterT130_starts_a_lease_with_explicit_execute_permission' {
            $f = New-P3Fixture; $file = $null; $p = $null
            try {
                $file = Open-PlatformFile -ParentLease $f.Directory -Leaf 'executable' -Access Read -CreateMode CreateNew
                [IO.File]::WriteAllText((Join-Path $f.Path 'executable'),"#!/bin/sh`nprintf lease-ok`nexit 17`n",[Text.UTF8Encoding]::new($false))
                (Set-PlatformPermissions -Lease $file -Policy @{ Mode=448 }).Mode | Should Be '700'
                $p = Start-PlatformOwnedProcess -ExecutableLease $file -Environment @{} -WorkingDirectoryLease $f.Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -StdoutPath (Join-Path $f.Path 'out') -StderrPath (Join-Path $f.Path 'err')
                Assert-P3Exited $p
                Assert-P3Cleaned (Stop-PlatformOwnedProcess -Lease $p)
                $p.ExitCode | Should Be 17
                [IO.File]::ReadAllText((Join-Path $f.Path 'out')) | Should Be 'lease-ok'
            } finally { if ($null -ne $file) { $file.Dispose() }; Remove-P3Fixture $f $p }
        }
    }
}

Describe 'Unix process observation regressions' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        $script:UnixControlType = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative].Assembly.GetType('SyuanTsai.AIInstructions.PlatformRuntime.UnixProcessControl')
        if ($null -eq ('UnixObservationFixture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
public static class UnixObservationFixture
{
    public static Func<int, string> Read(Hashtable state)
    {
        return pid => {
            var table = (IDictionary)state["Table"];
            if (!table.Contains(pid)) throw new System.IO.FileNotFoundException();
            var error = table[pid] as Exception;
            if (error != null) throw error;
            return (string)table[pid];
        };
    }
    public static Func<int, byte[]> BsdInfo(Hashtable state)
    {
        var read = Read(state);
        return pid => {
            string stat;
            try { stat = read(pid); } catch (System.IO.FileNotFoundException) { return null; }
            var fields = stat.Substring(stat.LastIndexOf(')') + 2).Split(' ');
            var data = new byte[136];
            Array.Copy(BitConverter.GetBytes(fields[0] == "Z" ? 5 : 2), 0, data, 4, 4);
            Array.Copy(BitConverter.GetBytes(pid), 0, data, 12, 4);
            Array.Copy(BitConverter.GetBytes(Int32.Parse(fields[1])), 0, data, 16, 4);
            Array.Copy(BitConverter.GetBytes(Int32.Parse(fields[2])), 0, data, 100, 4);
            Array.Copy(BitConverter.GetBytes(UInt64.Parse(fields[19])), 0, data, 120, 8);
            return data;
        };
    }
}
'@
        }
        function Set-UnixTestField($Control,[string]$Name,$Value) { $script:UnixControlType.GetField($Name,[Reflection.BindingFlags]'Instance,NonPublic').SetValue($Control,$Value) }
        function Invoke-UnixTestMethod($Control,[string]$Name,[object[]]$Arguments=@()) { $script:UnixControlType.GetMethod($Name,[Reflection.BindingFlags]'Instance,NonPublic,Public').Invoke($Control,$Arguments) }
        function New-UnixTestStat([int]$Id,[int]$Parent,[int]$Group,[string]$Start,[string]$State='S') {
            $fields = @($State,[string]$Parent,[string]$Group) + @('0') * 16 + @($Start)
            "$Id (fixture) " + ($fields -join ' ')
        }
        function New-UnixObservationFixture {
            $state = @{ Pids=[int[]]@(100,200); Table=@{}; Waited=[Collections.Generic.List[int]]::new(); Signals=[Collections.Generic.List[string]]::new(); Peek=$null; WaitStatus=0; ExitEvent=$null; WaitError=0; GroupErrno=0 }
            $state.Table[100] = New-UnixTestStat 100 1 100 'supervisor'
            $state.Table[200] = New-UnixTestStat 200 100 200 'root'
            $control = [Activator]::CreateInstance($script:UnixControlType,$true)
            Set-UnixTestField $control mac $false
            Set-UnixTestField $control supervisor 100
            Set-UnixTestField $control '<Pid>k__BackingField' 200
            Set-UnixTestField $control '<StartIdentity>k__BackingField' 'root'
            Set-UnixTestField $control listLinuxPids ([Func[int[]]]{ return ,$state.Pids }.GetNewClosure())
            Set-UnixTestField $control readStat ([UnixObservationFixture]::Read($state))
            $state.Pidfds = @{}; $state.PidfdStarts = @{}; $state.ClosedPidfds = [Collections.Generic.List[int]]::new()
            $state.PidfdSignals = [Collections.Generic.List[string]]::new()
            Set-UnixTestField $control openPidfd ([Func[int,Tuple[int,int]]]{ param($id) $state.Pidfds[$id + 1000] = $id; $state.PidfdStarts[$id + 1000] = ($state.Table[$id] -split ' ')[-1]; return [Tuple]::Create(($id + 1000),0) }.GetNewClosure())
            Set-UnixTestField $control sendPidfdSignal ([Func[int,int,int]]{
                param($fd,$signal)
                $state.PidfdSignals.Add("${fd}:$signal"); $id=$state.Pidfds[$fd]
                if (-not $state.Table.ContainsKey($id)) { return 3 }
                if ($state.Table[$id] -is [string] -and ($state.Table[$id] -split ' ')[-1] -ne $state.PidfdStarts[$fd]) { return 3 }
                $state.Signals.Add("${id}:$signal"); return 0
            }.GetNewClosure())
            Set-UnixTestField $control closePidfd ([Action[int]]{ param($fd) $state.ClosedPidfds.Add($fd) }.GetNewClosure())
            Set-UnixTestField $control waitPidfd ([Func[int,int,bool,Tuple[int,int,int]]]{ param($id,$fd,$peek) return [Tuple]::Create(-1,0,10) })
            Set-UnixTestField $control sendSignal ([Func[int,int,int]]{ param($id,$signal) $state.Signals.Add("${id}:$signal"); if ($id -eq -200 -and $signal -eq 0) { return [int]$state.GroupErrno }; return 0 }.GetNewClosure())
            Set-UnixTestField $control peekChild ([Func[int,Tuple[int,int,int]]]{
                param($id)
                if ($null -ne $state.Peek) { return $state.Peek }
                if ($state.Table.ContainsKey($id) -and $state.Table[$id] -is [string] -and $state.Table[$id] -match '\) Z ') { return [Tuple]::Create([int]$id,[int]$state.WaitStatus,0) }
                return [Tuple]::Create(0,0,0)
            }.GetNewClosure())
            Set-UnixTestField $control readExitEvent ([Func[Nullable[int]]]{ return $state.ExitEvent }.GetNewClosure())
            Set-UnixTestField $control waitForChild ([Func[int,Tuple[int,int,int]]]{ param($id) $state.Waited.Add($id); if ($state.WaitError) { return [Tuple]::Create(-1,0,[int]$state.WaitError) }; $state.Table.Remove($id); return [Tuple]::Create([int]$id,[int]$state.WaitStatus,0) }.GetNewClosure())
            $root = Invoke-UnixTestMethod $control Read @([int]200)
            $owned = $script:UnixControlType.GetField('owned',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($control)
            $owned.Add(200,$root)
            @{ Control=$control; State=$state; Owned=$owned }
        }
        function Set-DarwinObservationFixture($Fixture) {
            $state = $Fixture.State
            $state.Table[100] = New-UnixTestStat 100 1 100 '1'
            $state.Table[200] = New-UnixTestStat 200 100 200 '10'
            Set-UnixTestField $Fixture.Control mac $true
            Set-UnixTestField $Fixture.Control '<StartIdentity>k__BackingField' '10:0'
            Set-UnixTestField $Fixture.Control effectiveUid ([Func[uint32]]{ return 501 })
            Set-UnixTestField $Fixture.Control readBsdInfo ([UnixObservationFixture]::BsdInfo($state))
            Set-UnixTestField $Fixture.Control listDarwinPids ([Func[uint32,uint32,int[]]]{ param($kind,$value) if ($kind -eq 4) { return ,$state.Pids }; return ,([int[]]@()) }.GetNewClosure())
            Set-UnixTestField $Fixture.Control peekChild ([Func[int,Tuple[int,int,int]]]{
                param($id)
                if ($null -ne $state.Peek) { return $state.Peek }
                if ($state.WaitError) { return [Tuple]::Create(-1,0,[int]$state.WaitError) }
                if ($null -ne $state.ExitEvent) { return [Tuple]::Create([int]$id,0,0) }
                return [Tuple]::Create(0,0,0)
            }.GetNewClosure())
            [void]$script:UnixControlType.GetField('baseline',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($Fixture.Control).Add('100:1:0')
            $Fixture.Owned.Clear(); $Fixture.Owned.Add(200,(Invoke-UnixTestMethod $Fixture.Control Read @([int]200)))
        }
    }

    BeforeEach {
        $flags=[Reflection.BindingFlags]'Static,NonPublic'
        $script:SavedUnixPending=$script:UnixControlType.GetField('pendingFailedStart',$flags).GetValue($null)
        $script:SavedUnixActive=$script:UnixControlType.GetField('active',$flags).GetValue($null)
    }
    AfterEach {
        # These syscall fixtures own fake PIDs/fds. A deliberately poisoned test
        # must not poison later real probes or erase an existing runtime owner.
        $flags=[Reflection.BindingFlags]'Static,NonPublic'
        $pendingField=$script:UnixControlType.GetField('pendingFailedStart',$flags)
        $pending=$pendingField.GetValue($null)
        if($null -ne $pending -and -not [object]::ReferenceEquals($pending,$script:SavedUnixPending)) { Invoke-UnixTestMethod $pending ClosePidfds }
        $pendingField.SetValue($null,$script:SavedUnixPending)
        $script:UnixControlType.GetField('active',$flags).SetValue($null,$script:SavedUnixActive)
    }

    # Scenario: A foreign PID denies inspection, while the owned root is readable.
    # Purpose: Unrelated permissions must not invalidate workload capability or cleanup.
    It 'UnitT10_ignores_foreign_permission_denials_but_preserves_owned_failures' {
        $f = New-UnixObservationFixture
        $f.State.Pids = [int[]]@(100,200,999)
        $f.State.Table[999] = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException]::new('proc_pidinfo',1)
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Uncertainty | Should BeNullOrEmpty
        $f.State.Table[200] = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException]::new('proc_pidinfo',13)
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Uncertainty | Should Match 'owned-process-inventory-permission-denied'
        $f.Owned.ContainsKey(200) | Should Be $true
    }

    # Scenario: Darwin's UID census omits a newly born descendant and rejects a foreign PID.
    # Purpose: Scope discovery by UID, then follow group/PPID queries; denied owned descendants remain unknown.
    It 'UnitT15_scopes_darwin_census_and_follows_owned_descendants' {
        $f = New-UnixObservationFixture; $state = $f.State
        $state.Table[100] = New-UnixTestStat 100 1 100 '1'
        $state.Table[200] = New-UnixTestStat 200 100 200 '10'
        $state.Table[300] = New-UnixTestStat 300 200 200 '11'
        $state.Table[301] = New-UnixTestStat 301 300 200 '12'
        $state.Table[999] = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException]::new('proc_pidinfo',1)
        $state.Calls = [Collections.Generic.List[string]]::new()
        $state.Lists = @{ '4:501'=[int[]]@(100,200,300,999); '2:200'=[int[]]@(200,300); '6:200'=[int[]]@(300); '6:300'=[int[]]@(301) }
        Set-UnixTestField $f.Control mac $true
        Set-UnixTestField $f.Control '<StartIdentity>k__BackingField' '10:0'
        Set-UnixTestField $f.Control effectiveUid ([Func[uint32]]{ return 501 })
        Set-UnixTestField $f.Control readBsdInfo ([UnixObservationFixture]::BsdInfo($state))
        [void]$script:UnixControlType.GetField('baseline',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($f.Control).Add('100:1:0')
        Set-UnixTestField $f.Control listDarwinPids ([Func[uint32,uint32,int[]]]{
            param($kind,$value)
            $key = "${kind}:$value"; $state.Calls.Add($key)
            if ($state.Lists.ContainsKey($key)) { return ,$state.Lists[$key] }
            return ,([int[]]@())
        }.GetNewClosure())
        $f.Owned.Clear(); $f.Owned.Add(200,(Invoke-UnixTestMethod $f.Control Read @([int]200)))
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Uncertainty | Should BeNullOrEmpty
        $f.Owned.ContainsKey(301) | Should Be $true
        $state.Calls | Should Contain '4:501'
        $state.Calls | Should Contain '6:300'
        $state.Calls | Should Not Contain '1:0'
        $state.Table[301] = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException]::new('proc_pidinfo',1)
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Uncertainty | Should Match 'owned-process-inventory-permission-denied'
        $f.Owned.ContainsKey(301) | Should Be $true
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $state.Signals | Should Not Contain '200:9'
        $state.Signals | Should Not Contain '301:9'
    }

    # Scenario: A known child is omitted from a UID-filtered census after credentials change.
    # Purpose: Explicitly query owned identities; a missing census entry does not prove exit.
    It 'UnitT20_queries_owned_pids_even_when_missing_from_the_census' {
        $f = New-UnixObservationFixture
        $f.State.Pids = [int[]]@(100)
        $f.State.Table[200] = [UnauthorizedAccessException]::new('fixture')
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Uncertainty | Should Match 'owned-process-inventory-permission-denied'
        $f.Owned.ContainsKey(200) | Should Be $true
    }

    # Scenario: /proc stat opens successfully but its process disappears before read.
    # Purpose: ESRCH/ENOENT mean gone; EIO and other failures must not be swallowed.
    It 'UnitT30_treats_proc_disappearance_as_gone_but_preserves_other_io_errors' {
        $f = New-UnixObservationFixture
        $f.State.Pids = [int[]]@(100,200,999)
        foreach ($errno in @(2,3,-2147024894,-2147024893)) {
            $f.State.Table[999] = [IO.IOException]::new('fixture',$errno)
            Invoke-UnixTestMethod $f.Control Read @([int]999) | Should BeNullOrEmpty
            Invoke-UnixTestMethod $f.Control Poll
            $f.Control.Uncertainty | Should BeNullOrEmpty
        }
        $f.State.Table[999] = [IO.IOException]::new('fixture',5)
        { Invoke-UnixTestMethod $f.Control Read @([int]999) } | Should Throw
        { Invoke-UnixTestMethod $f.Control Poll } | Should Throw
    }

    # Scenario: A grandchild is absent from the first census, which already sees a zombie root.
    # Purpose: Do not reap the last group anchor before Stop can discover orphan descendants.
    It 'UnitT40_keeps_the_root_anchor_until_cleanup_discovers_late_orphans' {
        $f = New-UnixObservationFixture
        $f.State.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z'
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Exited | Should Be $true
        $f.State.Waited.Count | Should Be 0
        $f.State.Pids = [int[]]@(100,200,300)
        $f.State.Table[300] = New-UnixTestStat 300 100 200 'orphan'
        Invoke-UnixTestMethod $f.Control Poll
        $f.Owned.ContainsKey(300) | Should Be $true
        $f.Control.Uncertainty | Should BeNullOrEmpty
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.Table[300] = New-UnixTestStat 300 100 200 'orphan' 'Z'
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Poll
        $f.State.Waited | Should Contain 300
        $f.State.Waited | Should Contain 200
        $f.Owned.Count | Should Be 0
    }

    # Scenario: TERM forks a child after enumeration, then the root becomes a zombie before stat.
    # Purpose: Cleanup must take a census after observing exit before releasing the last group anchor.
    It 'UnitT45_refreshes_census_after_exit_even_when_cleanup_has_started' {
        $f = New-UnixObservationFixture
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
        $f.State.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z'
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Exited | Should Be $true
        $f.State.Waited | Should Not Contain 200
        $f.State.Pids = [int[]]@(100,200,300)
        $f.State.Table[300] = New-UnixTestStat 300 100 200 'term-orphan'
        Invoke-UnixTestMethod $f.Control Poll
        $f.Owned.ContainsKey(300) | Should Be $true
        $f.State.Waited | Should Not Contain 200
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.PidfdSignals | Should Contain '1300:9'
        $f.State.Table[300] = New-UnixTestStat 300 100 200 'term-orphan' 'Z'
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Poll
        $f.State.Waited | Should Contain 300
        $f.State.Waited | Should Contain 200
        $f.Control.Uncertainty | Should BeNullOrEmpty
    }

    # Scenario: A reaped child's PID is immediately assigned to another workload.
    # Purpose: Retire the old identity so root cancellation continues without signalling the replacement.
    It 'UnitT50_retires_reaped_identities_before_pid_reuse' {
        $f = New-UnixObservationFixture
        $f.State.Pids = [int[]]@(100,200,300)
        $f.State.Table[300] = New-UnixTestStat 300 100 200 'old-child' 'Z'
        Invoke-UnixTestMethod $f.Control Poll
        $f.Owned.ContainsKey(300) | Should Be $false
        $f.State.Table[300] = New-UnixTestStat 300 1 900 'replacement'
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.PidfdSignals | Should Contain '1200:9'
        $f.State.Signals | Should Not Contain '300:9'
        $f.Control.Uncertainty | Should BeNullOrEmpty
    }

    # Scenario: An unreaped observed child is replaced while the root remains alive.
    # Purpose: Refuse the replacement without globally disabling cleanup of verified processes.
    It 'UnitT60_keeps_signalling_verified_processes_after_one_identity_mismatch' {
        $f = New-UnixObservationFixture
        $f.State.Pids = [int[]]@(100,200,300)
        $f.State.Table[300] = New-UnixTestStat 300 200 200 'old-child'
        Invoke-UnixTestMethod $f.Control Poll
        $f.State.Table[300] = New-UnixTestStat 300 1 200 'replacement'
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.Signals | Should Contain '200:9'
        $f.State.Signals | Should Not Contain '300:9'
        $f.State.Signals | Should Not Contain '-200:9'
        $f.Control.Uncertainty | Should Match 'process-start-identity-mismatch'
    }

    # Scenario: libproc omits a dead root for which kqueue reports NOTE_EXIT.
    # Purpose: Detect exit/status independently of the census and retain the group anchor until a later census.
    It 'UnitT70_observes_darwin_exit_when_libproc_omits_the_zombie' {
        $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f
        $f.State.Table.Remove(200)
        $f.State.WaitStatus = 23 * 256
        $f.State.ExitEvent = 23 * 256
        Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Exited | Should Be $true
        $f.Control.ExitCode | Should Be 23
        $f.State.Waited.Count | Should Be 0
        $f.Owned.ContainsKey(200) | Should Be $true
        $f.State.GroupErrno = 3
        Invoke-UnixTestMethod $f.Control Poll
        $f.State.Waited | Should Contain 200
        $f.Control.Uncertainty | Should BeNullOrEmpty
    }

    # Scenario: A post-exit Darwin census finds a previously unseen orphan in the root's group.
    # Purpose: WNOWAIT reserves the absent zombie for discovery and signalling; ECHILD revokes authority.
    It 'UnitT75_requires_a_waitable_darwin_root_to_adopt_unanchored_group_members' {
        foreach ($waitError in @(0,10)) {
            $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f
            $f.State.Table.Remove(200); $f.State.ExitEvent = 0; $f.State.WaitError = $waitError
            Invoke-UnixTestMethod $f.Control Poll
            Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
            $f.State.Pids = [int[]]@(100,300)
            $f.State.Table[300] = New-UnixTestStat 300 1 200 '11'
            Invoke-UnixTestMethod $f.Control Poll
            $f.State.Waited | Should Not Contain 200
            Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
            if ($waitError -eq 0) {
                $f.Owned.ContainsKey(300) | Should Be $true
                $f.State.Signals | Should Contain '-200:9'
                $f.Control.Uncertainty | Should BeNullOrEmpty
            } else {
                $f.Owned.ContainsKey(300) | Should Be $false
                $f.State.Signals.Count | Should Be 0
                @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 300
                $f.Control.Uncertainty | Should Match 'root-anchor-lost'
            }
        }
    }

    # Scenario: Another reaper consumes the native root's status before our waitid/waitpid.
    # Purpose: ECHILD requires identity absence; Darwin's pre-registered event preserves exit status.
    It 'UnitT80_confirms_absence_after_echild_and_preserves_darwin_exit_event' {
        foreach ($darwin in @($false,$true)) {
            $f = New-UnixObservationFixture
            if ($darwin) { Set-DarwinObservationFixture $f; $f.State.ExitEvent = 23 * 256; $f.State.WaitError = 10 }
            $f.State.Table.Remove(200)
            $f.State.Peek = [Tuple]::Create(-1,0,10)
            if ($darwin) { Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null }
            Invoke-UnixTestMethod $f.Control Poll
            if ($darwin) { Invoke-UnixTestMethod $f.Control Poll }
            $f.Control.Exited | Should Be $true
            $f.Owned.ContainsKey(200) | Should Be $false
            $f.Control.Uncertainty | Should BeNullOrEmpty
            if ($darwin) { $f.Control.ExitCode | Should Be 23 }
            else { $f.Control.ExitCode | Should BeNullOrEmpty }
            Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
            $f.State.Signals.Count | Should Be 0
        }
    }

    # Scenario: A reaper wins between our WNOWAIT exit observation and destructive waitpid.
    # Purpose: Confirm disappearance again on ECHILD; permission failure and a live identity stay unresolved.
    It 'UnitT85_revalidates_identity_when_waitpid_loses_the_reaping_race' {
        foreach ($outcome in @('gone','present','denied','replacement')) {
            $f = New-UnixObservationFixture; $state = $f.State
            $state.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z'
            $state.WaitStatus = 23 * 256
            $state.Outcome = $outcome
            $state.ReplacementStat = New-UnixTestStat 200 100 200 'replacement'
            Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{
                param($id)
                $state.Waited.Add($id)
                if ($state.Outcome -eq 'gone') { $state.Table.Remove($id); $state.GroupErrno = 3 }
                if ($state.Outcome -eq 'denied') { $state.Table[$id] = [UnauthorizedAccessException]::new('fixture') }
                if ($state.Outcome -eq 'replacement') { $state.Table[$id] = $state.ReplacementStat }
                return [Tuple]::Create(-1,0,10)
            }.GetNewClosure())
            Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
            Invoke-UnixTestMethod $f.Control Poll
            Invoke-UnixTestMethod $f.Control Poll
            $state.Waited | Should Contain 200
            $f.Control.ExitCode | Should Be 23
            if ($outcome -eq 'gone') {
                $f.Owned.ContainsKey(200) | Should Be $false
                @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
                $f.Control.Uncertainty | Should BeNullOrEmpty
            } else {
                @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 200
                if ($outcome -ne 'present') { $f.Control.Uncertainty | Should Not BeNullOrEmpty }
            }
        }
    }

    # Scenario: ECHILD is returned for a still-visible, denied or reused root PID.
    # Purpose: ECHILD alone cannot authorize cleanup or signalling a replacement identity.
    It 'UnitT90_does_not_treat_echild_as_proof_of_identity_exit' {
        foreach ($kind in @('present','denied','replacement')) {
            $f = New-UnixObservationFixture
            $f.State.Peek = [Tuple]::Create(-1,0,10)
            if ($kind -eq 'denied') { $f.State.Table[200] = [UnauthorizedAccessException]::new('fixture') }
            if ($kind -eq 'replacement') { $f.State.Table[200] = New-UnixTestStat 200 100 200 'replacement' }
            Invoke-UnixTestMethod $f.Control Poll
            if ($kind -ne 'replacement') {
                $f.Control.Exited | Should Be $false
                $f.Owned.ContainsKey(200) | Should Be $true
                @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 200
            }
            if ($kind -ne 'present') {
                $f.Control.Uncertainty | Should Not BeNullOrEmpty
                Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
                $f.State.Signals | Should Not Contain '200:9'
                $f.State.Signals | Should Not Contain '-200:9'
            }
        }
    }

    # Scenario: A root becomes unqueryable just before its exit is reported, or waitid is interrupted.
    # Purpose: Retry incomplete observations without losing ownership or claiming cleanup.
    It 'UnitT100_retries_incomplete_root_observation_and_preserves_wait_errors' {
        foreach ($errno in @(0,4,5)) {
            $f = New-UnixObservationFixture
            $f.State.Table.Remove(200)
            $f.State.Peek = if ($errno) { [Tuple]::Create(-1,0,[int]$errno) } else { [Tuple]::Create(0,0,0) }
            Invoke-UnixTestMethod $f.Control Poll
            $f.Control.Exited | Should Be $false
            $f.Owned.ContainsKey(200) | Should Be $true
            @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 200
            if ($errno -eq 5) { $f.Control.Uncertainty | Should Match 'root-waitid-failed: 5' }
        }
    }

    # Scenario: Darwin no longer lists an owned zombie, but its group persists until launchd reaps it.
    # Purpose: Positive kill(0) must keep cleanup pending, and subsequent ESRCH may confirm completion.
    It 'UnitT110_keeps_unlisted_groups_pending_until_they_disappear' {
        $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f
        $f.State.Table.Remove(200)
        $f.State.Peek = [Tuple]::Create(-1,0,10)
        $f.State.ExitEvent = 0; $f.State.WaitError = 10
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Poll
        @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 200
        $f.State.GroupErrno = 3
        @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
        $f.Control.Uncertainty | Should BeNullOrEmpty
    }

    # Scenario: Post-spawn validation fails after the original PID disappears, is denied, or is reused.
    # Purpose: Neither rootReaped=false nor a matching numeric PGID authorizes a startup kill.
    It 'UnitT120_revalidates_startup_identity_before_any_failure_signal' {
        foreach ($kind in @('gone','denied','replacement','unknown-start','owned')) {
            $f = New-UnixObservationFixture
            if ($kind -eq 'gone') { $f.State.Table.Remove(200) }
            if ($kind -eq 'denied') { $f.State.Table[200] = [UnauthorizedAccessException]::new('fixture') }
            if ($kind -eq 'replacement') { $f.State.Table[200] = New-UnixTestStat 200 100 200 'replacement' }
            if ($kind -eq 'unknown-start') { Set-UnixTestField $f.Control '<StartIdentity>k__BackingField' $null }
            Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
            if ($kind -eq 'owned') { $f.State.PidfdSignals | Should Contain '1200:9' }
            else { $f.State.Signals.Count | Should Be 0; $f.State.Waited.Count | Should Be 0 }
        }
    }

    # Scenario: Another waiter reaps the root after pidfd binding and the numeric PID is reused.
    # Purpose: Startup cleanup must neither signal nor reap the replacement by its numeric PID.
    It 'UnitT130_keeps_startup_cleanup_bound_after_pid_reuse' {
        $f = New-UnixObservationFixture; $state = $f.State
        Invoke-UnixTestMethod $f.Control RecordSpawnIdentity @([int]200)
        $state.ReplacementStat = New-UnixTestStat 200 100 200 'replacement'
        Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{
            param($fd,$signal)
            $state.PidfdSignals.Add("${fd}:$signal")
            $state.Table[200] = $state.ReplacementStat
            return 3
        }.GetNewClosure())
        Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{ param($id) return [Tuple]::Create(-1,0,10) })
        Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
        $state.Signals | Should Not Contain '-200:9'
        $state.Signals | Should Not Contain '200:9'
        $state.PidfdSignals | Should Contain '1200:9'
        $state.Table[200] | Should Be $state.ReplacementStat
        $state.Waited.Count | Should Be 0
    }

    # Scenario: An unrelated same-UID service appears under launchd during cleanup.
    # Purpose: The macOS group contract excludes never-owned processes outside the group.
    It 'UnitT140_ignores_unowned_launchd_children_outside_the_group' {
        $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f
        $f.State.Table.Remove(200); $f.State.ExitEvent = 0; $f.State.WaitError = 10
        $f.State.Table[300] = New-UnixTestStat 300 1 300 '11'
        $f.State.Pids = [int[]]@(100,300); $f.State.GroupErrno = 3
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Poll
        @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
        $f.Control.Uncertainty | Should BeNullOrEmpty
        $f.Owned.ContainsKey(300) | Should Be $false
    }

    # Scenario: kill(group,0) reports EPERM, success, ESRCH, or an unexpected error.
    # Purpose: Existing groups remain pending without poisoning a later confirmed absence.
    It 'UnitT150_classifies_group_probe_errors_and_reports_the_actual_errno' {
        foreach ($errno in @(0,1,3,22)) {
            $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f
            $f.Owned.Clear(); Set-UnixTestField $f.Control rootReaped $true
            $f.State.GroupErrno = $errno
            $remaining = @(Invoke-UnixTestMethod $f.Control Remaining)
            if ($errno -eq 0 -or $errno -eq 1) { $remaining | Should Contain 200 }
            if ($errno -eq 22) { $f.Control.Uncertainty | Should Match 'group-existence-unknown: 22' }
            else {
                $f.Control.Uncertainty | Should BeNullOrEmpty
                $f.State.GroupErrno = 3
                @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
            }
            $observation = $script:UnixControlType.GetProperty('Observation',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($f.Control)
            $observation.GroupProbeErrno | Should Be $(if ($errno -eq 22) { 22 } else { 3 })
        }
    }

    # Scenario: A previously observed Darwin child leaves the group, then exits independently.
    # Purpose: Refuse unbound PID signals, retain the live identity, and resolve uncertainty on exit.
    It 'UnitT160_tracks_observed_darwin_escapees_without_numeric_pid_signals' {
        $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f
        $f.State.Pids = [int[]]@(100,200,300)
        $f.State.Table[300] = New-UnixTestStat 300 200 200 '11'
        Invoke-UnixTestMethod $f.Control Poll
        $f.Owned.ContainsKey(300) | Should Be $true
        $f.State.Table[300] = New-UnixTestStat 300 1 300 '11'
        $f.State.Table.Remove(200); $f.State.ExitEvent = 0; $f.State.WaitError = 10
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        Invoke-UnixTestMethod $f.Control Poll
        $f.State.GroupErrno = 3
        @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 300
        $f.Control.Uncertainty | Should Match 'macos-unbound-pid-signal-refused'
        $f.State.Signals | Should Not Contain '300:9'
        $f.State.PidfdSignals.Count | Should Be 0
        $f.State.Table.Remove(300)
        Invoke-UnixTestMethod $f.Control Poll
        @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
        $f.Control.Uncertainty | Should BeNullOrEmpty
    }

    # Scenario: The new Linux child changes its group before post-spawn validation.
    # Purpose: Preserve its start identity for failure cleanup, without signalling its new group.
    It 'UnitT170_preserves_start_identity_before_rejecting_a_changed_spawn_group' {
        $f = New-UnixObservationFixture
        $f.Owned.Clear(); Set-UnixTestField $f.Control '<StartIdentity>k__BackingField' $null
        $f.State.Table[200] = New-UnixTestStat 200 100 900 'root'
        { Invoke-UnixTestMethod $f.Control RecordSpawnIdentity @([int]200) } | Should Throw
        $f.Control.StartIdentity | Should Be 'root'
        $f.Owned.ContainsKey(200) | Should Be $true
        Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
        $f.State.PidfdSignals | Should Contain '1200:9'
        $f.State.ClosedPidfds | Should Contain 1200
        $f.State.Signals | Should Not Contain '-900:9'
        $f.State.Signals | Should Not Contain '-200:9'
    }

    # Scenario: A PID is replaced before pidfd identity verification or immediately before signalling.
    # Purpose: Reject a replacement-bound descriptor; a verified descriptor targets only the original process.
    It 'UnitT180_binds_individual_signals_to_verified_pidfds_and_closes_them' {
        foreach ($race in @('open','send','error')) {
            $f = New-UnixObservationFixture; $state = $f.State
            Invoke-UnixTestMethod $f.Control Poll
            $state.Pids = [int[]]@(100,200,300)
            $state.Table[300] = New-UnixTestStat 300 200 200 'child'
            $state.ReplacementStat = New-UnixTestStat 300 1 300 'replacement'
            $state.Race = $race; $state.BoundIdentity = $null
            Set-UnixTestField $f.Control openPidfd ([Func[int,Tuple[int,int]]]{
                param($id)
                if ($state.Race -eq 'open') { $state.Table[$id] = $state.ReplacementStat }
                $state.BoundIdentity = $state.Table[$id]
                return [Tuple]::Create(1300,0)
            }.GetNewClosure())
            Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{
                param($fd,$signal)
                if ($fd -eq 1300 -and $signal -eq 9) { $state.Table[300] = $state.ReplacementStat }
                $state.PidfdSignals.Add("${fd}:$signal")
                if ($state.Race -eq 'error' -and $fd -eq 1300 -and $signal -eq 9) { return 1 }; return 0
            }.GetNewClosure())
            Invoke-UnixTestMethod $f.Control Poll
            Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
            $state.Signals | Should Not Contain '300:9'
            $f.Control.Dispose()
            $state.ClosedPidfds | Should Contain 1300
            if ($race -eq 'open') { $state.PidfdSignals | Should Not Contain '1300:9' }
            else { $state.PidfdSignals | Should Contain '1300:9'; $state.BoundIdentity | Should Match ' child$' }
            if ($race -eq 'error') { $f.Control.Uncertainty | Should Match 'pidfd-send-signal-failed: 1' }
        }
    }

    # Scenario: The kernel refuses pidfd_open for an observed escaped Linux child.
    # Purpose: Missing pidfd support must never fall back to a racy numeric PID signal.
    It 'UnitT190_fails_closed_when_pidfd_open_is_unavailable' {
        $f = New-UnixObservationFixture
        $f.State.Table[200] = New-UnixTestStat 200 100 900 'root'
        Set-UnixTestField $f.Control openPidfd ([Func[int,Tuple[int,int]]]{ param($id) return [Tuple]::Create(-1,38) })
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.Signals.Count | Should Be 0
        $f.State.ClosedPidfds.Count | Should Be 0
        $f.Control.Uncertainty | Should Match 'pidfd-open-failed: 38'
    }

    # Scenario: Capability probing encounters a missing pidfd entry point or a refused syscall.
    # Purpose: Reject unavailable Linux signalling support before spawn and always release probe descriptors.
    It 'UnitT195_probes_pidfd_support_without_leaking_descriptors' {
        foreach ($kind in @('available','open-error','signal-error','entrypoint')) {
            $f = New-UnixObservationFixture
            if ($kind -eq 'open-error') { Set-UnixTestField $f.Control openPidfd ([Func[int,Tuple[int,int]]]{ param($id) return [Tuple]::Create(-1,38) }) }
            if ($kind -eq 'signal-error') { Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{ param($fd,$signal) return 1 }) }
            if ($kind -eq 'entrypoint') { Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{ param($fd,$signal) throw [EntryPointNotFoundException]::new('fixture') }) }
            if ($kind -eq 'available') {
                Invoke-UnixTestMethod $f.Control ProbePidfd
                $f.State.PidfdSignals | Should Contain '1100:0'
            } else { { Invoke-UnixTestMethod $f.Control ProbePidfd } | Should Throw }
            if ($kind -eq 'open-error') { $f.State.ClosedPidfds.Count | Should Be 0 }
            else { $f.State.ClosedPidfds | Should Contain 1100 }
        }
    }

    # Scenario: Unix cleanup succeeds or rejects a mismatched caller identity.
    # Purpose: Both receipt outcomes disclose the group/reaper race and Darwin's escape limitation.
    It 'UnitT200_discloses_macos_limits_in_success_and_rejected_cleanup_receipts' {
        foreach ($darwin in @($false,$true)) {
        $f = New-UnixObservationFixture
        if ($darwin) { Set-DarwinObservationFixture $f }
        $f.State.Peek = [Tuple]::Create(-1,0,10)
        $f.State.Table.Remove(200); $f.State.ExitEvent = 0; $f.State.WaitError = 10; $f.State.GroupErrno = 3
        $type = [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
        $flags = [Reflection.BindingFlags]'Instance,NonPublic'
        $lease = [Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(10),[long]4096),$null)
        $type.GetField('control',$flags).SetValue($lease,$f.Control)
        $type.GetField('captureClosed',$flags).SetValue($lease,$true) # No capture resources in this fixture.
        try {
            $rejected = $lease.Stop([TimeSpan]::Zero,[DateTimeOffset]::UtcNow.AddSeconds(1),'incorrect')
            $rejected.CleanedUp | Should Be $false
            $rejected.Limitations | Should Contain 'group-signal-external-reaper-race'
            if ($darwin) { $rejected.Limitations | Should Contain 'macos-process-group-cannot-detect-setsid-escape' }
            $cleaned = $lease.Stop([TimeSpan]::Zero,[DateTimeOffset]::UtcNow.AddSeconds(1),$null)
            $cleaned.CleanedUp | Should Be $true
            $cleaned.Limitations | Should Contain 'group-signal-external-reaper-race'
            $lease.Limitations | Should Contain 'group-signal-external-reaper-race'
            if ($darwin) { $cleaned.Limitations | Should Contain 'macos-process-group-cannot-detect-setsid-escape' }
        } finally { $lease.Dispose() }
        }
    }

    # Scenario: A Darwin cleanup census outlasts its deadline while escaped writers retain both pipes.
    # Purpose: Capture must cancel independently of process observation and still report incomplete cleanup.
    It 'InterT205_stops_capture_during_a_slow_macos_cleanup_census' {
        $fixture = New-UnixObservationFixture
        Set-DarwinObservationFixture $fixture
        $fixture.State.Peek = [Tuple]::Create(-1,0,10)
        $fixture.State.Table.Remove(200); $fixture.State.ExitEvent = 0; $fixture.State.WaitError = 10; $fixture.State.GroupErrno = 3
        $type = [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
        $flags = [Reflection.BindingFlags]'Instance,NonPublic'
        $lease = [Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(30),[long]4096),$null)
        $type.GetField('control',$flags).SetValue($lease,$fixture.Control)
        $captureRoot = if ($IsMacOS) { '/private/tmp' } else { [IO.Path]::GetTempPath().TrimEnd('\','/') }
        $name = 'p3-slow-census-' + [guid]::NewGuid().ToString('N')
        $directory = Open-PlatformDirectory -Root $captureRoot -RelativePath $name -CreatePrivate
        $writers = @(); $readHandles = @(); $fileHandles = @()
        $observation = @{ Entered=$false; ReadersStopped=$false; ResourcesClosed=$false; StopDeadline=$null }
        try {
            foreach ($stream in @('out','err')) {
                $pipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In,[IO.HandleInheritability]::Inheritable)
                $writers += $pipe.ClientSafePipeHandle; $readHandles += $pipe.SafePipeHandle
                $type.GetField($(if ($stream -eq 'out') { 'stdout' } else { 'stderr' }),$flags).SetValue($lease,$pipe)
                $fileLease = Open-PlatformFile -ParentLease $directory -Leaf $stream -Access ReadWrite -CreateMode CreateNew
                $type.GetField(($stream+'Lease'),$flags).SetValue($lease,$fileLease)
                $file = $type.GetMethod('CaptureFile',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($fileLease))
                $type.GetField(($stream+'File'),$flags).SetValue($lease,$file)
                $fileHandles += $file.SafeFileHandle
                $reader = $type.GetMethod('Reader',$flags).Invoke($lease,[object[]]@($pipe,$file))
                $type.GetField(($stream+'Reader'),$flags).SetValue($lease,$reader)
            }
            $lease.CaptureReadersStopped | Should Be $false
            # This census never signals the pipe writers. It waits for capture's
            # independent stop budget, simulating a slow native process inventory.
            Set-UnixTestField $fixture.Control listDarwinPids ([Func[uint32,uint32,int[]]]{
                param($kind,$value)
                if (-not $observation.Entered) {
                    $observation.Entered = $true
                    $until = [DateTimeOffset]::UtcNow.AddSeconds(2)
                    while (-not $lease.CaptureReadersStopped -and [DateTimeOffset]::UtcNow -lt $until) { [Threading.Thread]::Sleep(10) }
                    $observation.ReadersStopped = $lease.CaptureReadersStopped
                    $observation.ResourcesClosed = $lease.CaptureResourcesClosed
                    # Keep the census in flight past Stop's deadline even when
                    # readers cancel promptly; the later Join has no budget left.
                    while ([DateTimeOffset]::UtcNow -lt $observation.StopDeadline.AddMilliseconds(100)) { [Threading.Thread]::Sleep(10) }
                }
                return ,[int[]]@()
            }.GetNewClosure())
            $observation.StopDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds(250)
            $receipt = $lease.Stop([TimeSpan]::Zero,$observation.StopDeadline,$null)
            $observation.Entered | Should Be $true
            $observation.ReadersStopped | Should Be $true
            $observation.ResourcesClosed | Should Be $true
            $receipt.CaptureReadersStopped | Should Be $true
            $receipt.CaptureResourcesClosed | Should Be $true
            $receipt.CleanedUp | Should Be $false
            $receipt.Uncertainty | Should Match 'capture-pipe-still-open'
            $receipt.Limitations | Should Contain 'macos-process-group-cannot-detect-setsid-escape'
            foreach ($handle in $readHandles + $fileHandles) { $handle.IsClosed | Should Be $true }
            foreach ($handle in $writers) { $handle.IsClosed | Should Be $false }
        } finally {
            foreach ($handle in $writers) { $handle.Dispose() }
            $type.GetMethod('CancelCaptureReaders',$flags).Invoke($lease,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(2))) | Out-Null
            $type.GetMethod('CloseCapture',$flags).Invoke($lease,@())
            $lease.Dispose(); $directory.Dispose()
            foreach ($stream in @('out','err')) { $path = Join-Path (Join-Path $captureRoot $name) $stream; if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
            [IO.Directory]::Delete((Join-Path $captureRoot $name))
        }
    }

    # Scenario: The root was reaped and the last observed descendant can exit before signalling.
    # Purpose: A census identity is not a lifetime reservation for a numeric process group.
    It 'UnitT210_uses_pidfds_when_the_root_group_anchor_has_been_reaped' {
        $f = New-UnixObservationFixture
        $f.State.Pids = [int[]]@(100,200,300)
        $f.State.Table[300] = New-UnixTestStat 300 200 200 'child'
        Invoke-UnixTestMethod $f.Control Poll
        Set-UnixTestField $f.Control rootReaped $true
        $f.Owned.Remove(200) | Out-Null
        $f.State.Table.Remove(200)
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.Signals | Should Not Contain '-200:9'
        $f.State.PidfdSignals | Should Contain '1300:9'
    }

    # Scenario: Only a Darwin descendant remains after the direct root was reaped.
    # Purpose: A transient descendant observation must not authorize a numeric group signal.
    It 'UnitT215_refuses_darwin_group_signals_without_the_direct_root_anchor' {
        $f=New-UnixObservationFixture; Set-DarwinObservationFixture $f
        $f.State.Pids=[int[]]@(100,200,300)
        $f.State.Table[300]=New-UnixTestStat 300 200 200 '11'
        Invoke-UnixTestMethod $f.Control Poll
        Set-UnixTestField $f.Control rootReaped $true
        $f.Owned.Remove(200) | Out-Null; $f.State.Table.Remove(200)
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.Signals | Should Not Contain '-200:9'
        $f.State.Signals | Should Not Contain '300:9'
        $f.Control.Uncertainty | Should Match 'macos-unbound-pid-signal-refused'
        @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 300
    }

    # Scenario: Both census and stat become unreadable after verified identities were recorded.
    # Purpose: Retained pidfds must allow TERM and KILL without another filesystem read.
    It 'UnitT220_keeps_bound_termination_available_after_inventory_failure' {
        $f = New-UnixObservationFixture
        Invoke-UnixTestMethod $f.Control Poll
        Set-UnixTestField $f.Control listLinuxPids ([Func[int[]]]{ throw [IO.IOException]::new('fixture-census-io-error') })
        $f.State.Table[200] = [IO.IOException]::new('fixture-stat-io-error',5)
        { Invoke-UnixTestMethod $f.Control Poll } | Should Throw
        Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $f.State.PidfdSignals | Should Contain '1200:15'
        $f.State.PidfdSignals | Should Contain '1200:9'
        $f.State.Signals | Should Not Contain '-200:9'
    }

    # Scenario: Startup validation fails and subsequent stat reads also fail.
    # Purpose: Failure cleanup must retain and use the already verified kernel process binding.
    It 'UnitT230_uses_a_retained_pidfd_during_failed_start_cleanup' {
        $f = New-UnixObservationFixture
        Invoke-UnixTestMethod $f.Control RecordSpawnIdentity @([int]200)
        $f.State.Table[200] = [IO.IOException]::new('fixture-stat-io-error',5)
        Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
        $f.State.PidfdSignals | Should Contain '1200:9'
        $f.State.Signals | Should Not Contain '-200:9'
    }

    # Scenario: A numeric PID is reused before consuming an owned child's exit status.
    # Purpose: The wait operation must receive the retained pidfd, never an unbound P_PID request.
    It 'UnitT240_binds_waits_to_the_original_pidfd_after_pid_reuse' {
        $f = New-UnixObservationFixture; $state = $f.State
        Invoke-UnixTestMethod $f.Control RecordSpawnIdentity @([int]200)
        $state.Table[200] = New-UnixTestStat 200 100 200 'replacement'
        $state.BoundWaits = [Collections.Generic.List[string]]::new()
        Set-UnixTestField $f.Control waitPidfd ([Func[int,int,bool,Tuple[int,int,int]]]{
            param($id,$fd,$peek)
            $state.BoundWaits.Add("${id}:${fd}:$peek")
            return [Tuple]::Create(-1,0,10)
        }.GetNewClosure())
        $result = Invoke-UnixTestMethod $f.Control WaitOwnedLinuxChild @([int]200,$false)
        $result.Item3 | Should Be 10
        $state.BoundWaits | Should Contain '200:1200:False'
        $state.Table[200] | Should Match ' replacement$'
        $state.Waited.Count | Should Be 0
        $f.Control.Dispose()
        $state.ClosedPidfds | Should Contain 1200
    }

    # Scenario: Census fails permanently during cancellation, deadline handling, or disposal.
    # Purpose: Every entry point must still attempt TERM and KILL and return incomplete-inventory evidence.
    It 'UnitT250_terminates_bound_processes_despite_poll_failure_on_every_cleanup_entry' {
        foreach ($entry in @('cancel','deadline','supervisor','dispose','expired-deadline','long-grace')) {
            $f = New-UnixObservationFixture; $state = $f.State
            Invoke-UnixTestMethod $f.Control Poll
            $state.CensusCalls=0; $state.Entry=$entry
            Set-UnixTestField $f.Control listLinuxPids ([Func[int[]]]{
                $state.CensusCalls++
                if ($state.Entry -eq 'deadline' -and $state.CensusCalls -eq 1) { return ,$state.Pids }
                throw [IO.IOException]::new('fixture-persistent-inventory-failure')
            }.GetNewClosure())
            Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{
                param($fd,$signal)
                $state.PidfdSignals.Add("${fd}:$signal")
                if ($signal -eq 9) { $state.GroupErrno=3 }
                return 0
            }.GetNewClosure())
            $type=[SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
            $flags=[Reflection.BindingFlags]'Instance,NonPublic'
            $lease=[Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(-1),[long]4096),$null)
            $type.GetField('control',$flags).SetValue($lease,$f.Control)
            $type.GetField('captureClosed',$flags).SetValue($lease,$true)
            try {
                if ($entry -in @('cancel','expired-deadline','long-grace')) {
                    $until=if ($entry -eq 'expired-deadline') { [DateTimeOffset]::MinValue } else { [DateTimeOffset]::UtcNow.AddMilliseconds(400) }
                    $grace=if ($entry -eq 'long-grace') { [TimeSpan]::MaxValue } else { [TimeSpan]::Zero }
                    $receipt=$lease.Stop($grace,$until,$null)
                }
                elseif ($entry -eq 'dispose') { $lease.Dispose(); $receipt=$lease.Cleanup }
                else { $type.GetMethod('Supervise',$flags).Invoke($lease,@()); $receipt=$lease.Cleanup }
                $state.PidfdSignals | Should Contain '1200:15'
                $state.PidfdSignals | Should Contain '1200:9'
                $receipt.CleanedUp | Should Be $false
                $receipt.Uncertainty | Should Match 'inventory-incomplete'
                $receipt.UnixObservation.InventoryComplete | Should Be $false
                $receipt.CaptureReadersStopped | Should Be $true
                $receipt.CaptureResourcesClosed | Should Be $true
                $state.Waited | Should Contain 200
                if ($entry -eq 'deadline') { $lease.TerminationReason | Should Be 'deadline' }
            } finally { $lease.Dispose() }
            $state.ClosedPidfds | Should Contain 1200
        }
    }

    # Scenario: A candidate group member is read before another waiter releases the original root PID.
    # Purpose: A reused PGID must not let census discovery authorize signalling an unrelated process.
    It 'UnitT260_rejects_group_attribution_when_the_original_root_binding_is_gone' {
        $f=New-UnixObservationFixture; $state=$f.State
        Invoke-UnixTestMethod $f.Control Poll
        $state.Pids=[int[]]@(100,200,300)
        $state.Table[300]=New-UnixTestStat 300 100 200 'candidate'
        Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{
            param($fd,$signal)
            $state.PidfdSignals.Add("${fd}:$signal")
            if ($fd -eq 1200) { return 3 }; return 0
        }.GetNewClosure())
        Invoke-UnixTestMethod $f.Control Poll
        $f.Owned.ContainsKey(300) | Should Be $false
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $state.PidfdSignals | Should Not Contain '1300:9'
        $state.ClosedPidfds | Should Contain 1300
        $f.Control.Uncertainty | Should Match 'owned-attribution-lost'
    }

    # Scenario: Signalling one bound process throws while another owned descendant remains live.
    # Purpose: A per-process error must not prevent termination attempts on the other bindings.
    It 'UnitT270_continues_bound_signalling_after_one_target_fails' {
        $f=New-UnixObservationFixture; $state=$f.State
        $state.Pids=[int[]]@(100,200,300)
        $state.Table[300]=New-UnixTestStat 300 200 200 'child'
        Invoke-UnixTestMethod $f.Control Poll
        Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{
            param($fd,$signal)
            if ($fd -eq 1200) { throw [IO.IOException]::new('fixture-one-target-failed') }
            $state.PidfdSignals.Add("${fd}:$signal"); return 0
        }.GetNewClosure())
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        $state.PidfdSignals | Should Contain '1300:9'
        $f.Control.Uncertainty | Should Match 'owned-signal-failed'
    }

    # Scenario: Startup polling recorded a descendant before failing, after root was already reaped.
    # Purpose: Failed-start cleanup must handle every recorded binding even when root cleanup is done.
    It 'UnitT280_cleans_recorded_descendants_after_root_reaping_on_failed_start' {
        $f=New-UnixObservationFixture; $state=$f.State
        $state.Pids=[int[]]@(100,200,300)
        $state.Table[300]=New-UnixTestStat 300 200 200 'child'
        Invoke-UnixTestMethod $f.Control Poll
        Invoke-UnixTestMethod $f.Control ForgetOwned @([int]200)
        Set-UnixTestField $f.Control rootReaped $true
        $state.Table.Remove(200)
        Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
        $state.PidfdSignals | Should Contain '1300:9'
        $state.Waited | Should Contain 300
        $state.ClosedPidfds | Should Contain 1300
        $f.Owned.Count | Should Be 0
    }

    # Scenario: Startup cleanup first sees only root; a later census discovers its still-running child.
    # Purpose: Repeated cleanup must signal new bindings/group members before attempting their nonblocking wait.
    It 'UnitT285_terminates_descendants_discovered_during_failed_start_cleanup' {
        foreach ($darwin in @($false,$true)) {
            $f=New-UnixObservationFixture; $state=$f.State
            if ($darwin) { Set-DarwinObservationFixture $f }
            $state.Darwin=$darwin; $state.Kills=0
            $state.RootZombie=New-UnixTestStat 200 100 200 $(if ($darwin) { '10' } else { 'root' }) 'Z'
            $state.ChildZombie=New-UnixTestStat 300 100 200 '11' 'Z'
            $state.Table[300]=New-UnixTestStat 300 200 200 '11'
            Set-UnixTestField $f.Control sendPidfdSignal ([Func[int,int,int]]{
                param($fd,$signal) $state.PidfdSignals.Add("${fd}:$signal")
                if ($signal -eq 9 -and $fd -eq 1200) { $state.Table[200]=$state.RootZombie; $state.Pids=[int[]]@(100,200,300) }
                if ($signal -eq 9 -and $fd -eq 1300) { $state.Table[300]=$state.ChildZombie }
                return 0
            }.GetNewClosure())
            Set-UnixTestField $f.Control sendSignal ([Func[int,int,int]]{
                param($id,$signal) $state.Signals.Add("${id}:$signal")
                if ($signal -eq 0) { return [int]$state.GroupErrno }
                if ($state.Darwin -and $signal -eq 9) {
                    $state.Kills++; $state.Table[200]=$state.RootZombie; $state.ExitEvent=0
                    $state.Pids=[int[]]@(100,200,300)
                    if ($state.Kills -ge 2) { $state.Table.Remove(300); $state.GroupErrno=3 }
                }
                return 0
            }.GetNewClosure())
            Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{
                param($id) $state.Waited.Add($id)
                if ($state.Table.ContainsKey($id) -and $state.Table[$id] -match '\) Z ') {
                    $state.Table.Remove($id)
                    if (-not $state.Table.ContainsKey(200) -and -not $state.Table.ContainsKey(300)) { $state.GroupErrno=3 }
                    return [Tuple]::Create([int]$id,0,0)
                }
                return [Tuple]::Create(0,0,0)
            }.GetNewClosure())
            Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::FromMilliseconds(150))
            $state.Table.ContainsKey(300) | Should Be $false
            $f.Owned.Count | Should Be 0
            if ($darwin) { $state.Kills | Should BeGreaterThan 1 }
            else { $state.PidfdSignals | Should Contain '1300:9' }
            @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
            $failure=[IO.IOException]::new('fixture-startup-failure')
            Invoke-UnixTestMethod $f.Control AttachStartupCleanupReceipt @($failure)
            $failure.Data['StartupCleanupReceipt'].CleanedUp | Should Be $true
            $failure.Data['StartupCleanupReceipt'].SignalsSent | Should BeGreaterThan 0
        }
    }

    # Scenario: Startup cleanup reaches its deadline with a live identity or persistent inventory failure.
    # Purpose: The original exception carries a full false receipt, including completed capture cleanup and limits.
    It 'UnitT286_attaches_complete_receipts_to_unconfirmed_startup_failures' {
        foreach ($darwin in @($false,$true)) {
            foreach ($mode in @('live','inventory-error')) {
                $f=New-UnixObservationFixture
                if ($darwin) { Set-DarwinObservationFixture $f }
                Invoke-UnixTestMethod $f.Control Poll
                Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{ param($id) return [Tuple]::Create(0,0,0) })
                if ($mode -eq 'inventory-error') {
                    if ($darwin) { Set-UnixTestField $f.Control listDarwinPids ([Func[uint32,uint32,int[]]]{ param($kind,$value) throw [IO.IOException]::new('fixture-census-error') }) }
                    else { Set-UnixTestField $f.Control listLinuxPids ([Func[int[]]]{ throw [IO.IOException]::new('fixture-census-error') }) }
                }
                Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
                $failure=[IO.IOException]::new('original-startup-failure')
                Invoke-UnixTestMethod $f.Control AttachStartupCleanupReceipt @($failure)
                $type=[SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
                $flags=[Reflection.BindingFlags]'Instance,NonPublic'
                $owner=[Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(10),[long]4096),$null)
                # Native startup threw before assigning control or starting readers.
                $type.GetMethod('CompleteFailedStart',$flags).Invoke($owner,[object[]]@($failure))
                $receipt=$failure.Data['StartupCleanupReceipt']
                $failure.Message | Should Be 'original-startup-failure'
                $receipt.CleanedUp | Should Be $false
                $receipt.RemainingPids | Should Contain 200
                $receipt.SignalsSent | Should BeGreaterThan 0
                $receipt.Isolation | Should Be $f.Control.Isolation
                $receipt.Limitations | Should Contain 'group-signal-external-reaper-race'
                $receipt.Uncertainty | Should Not BeNullOrEmpty
                $receipt.CaptureReadersStopped | Should Be $true
                $receipt.CaptureResourcesClosed | Should Be $true
                $receipt.UnixObservation | Should Not BeNullOrEmpty
                if ($mode -eq 'inventory-error') { $receipt.UnixObservation.InventoryComplete | Should Be $false }
                $failure.Data['StartupCleanupConfirmed'] | Should Be $false
            }
        }
    }

    # Scenario: Startup cleanup times out while its root remains alive, then a later retry observes exit.
    # Purpose: Retain bindings and reject a second spawn until cleanup is positively confirmed.
    It 'UnitT287_retains_failed_start_control_until_cleanup_is_confirmed' {
        $staticFlags=[Reflection.BindingFlags]'Static,NonPublic'
        $pending=$script:UnixControlType.GetField('pendingFailedStart',$staticFlags)
        $active=$script:UnixControlType.GetField('active',$staticFlags)
        $guard=$script:UnixControlType.GetMethod('EnsureStartAvailable',$staticFlags)
        $pending | Should Not BeNullOrEmpty
        $savedPending=$pending.GetValue($null); $savedActive=$active.GetValue($null)
        try {
            foreach ($darwin in @($false,$true)) {
                $f=New-UnixObservationFixture; $state=$f.State
                if ($darwin) { Set-DarwinObservationFixture $f }
                Invoke-UnixTestMethod $f.Control Poll
                Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{ param($id) return [Tuple]::Create(0,0,0) })
                $failure=[IO.IOException]::new('fixture-post-spawn-failure')
                Invoke-UnixTestMethod $f.Control FinishFailedStart @($failure,[TimeSpan]::Zero)
                $failure.Data['StartupCleanupReceipt'].CleanedUp | Should Be $false
                $failure.Data['UnixRuntimePoisoned'] | Should Be $true
                [object]::ReferenceEquals($pending.GetValue($null),$f.Control) | Should Be $true
                $state.ClosedPidfds.Count | Should Be 0
                { $guard.Invoke($null,@()) } | Should Throw 'previous process cleanup is incomplete'
                $active.GetValue($null) | Should Be $true
                $state.Table[200]=New-UnixTestStat 200 100 200 $(if ($darwin) { '10' } else { 'root' }) 'Z'
                $state.ExitEvent=0; $state.GroupErrno=3
                Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{ param($id) $state.Table.Remove($id); return [Tuple]::Create([int]$id,0,0) }.GetNewClosure())
                $guard.Invoke($null,@())
                $pending.GetValue($null) | Should BeNullOrEmpty
                $active.GetValue($null) | Should Be $false
                $f.Owned.Count | Should Be 0
                if (-not $darwin) { $state.ClosedPidfds | Should Contain 1200 }
            }
        } finally {
            $pending.SetValue($null,$savedPending); $active.SetValue($null,$savedActive)
        }
    }

    # Scenario: Dispose cannot reap a reserved root, with either a live descendant or failed inventory.
    # Purpose: Keep native bindings and admission poisoned even though the public lease is disposed.
    It 'UnitT288_retains_unresolved_disposal_in_pending_cleanup' {
        $staticFlags=[Reflection.BindingFlags]'Static,NonPublic'
        $pending=$script:UnixControlType.GetField('pendingFailedStart',$staticFlags)
        $active=$script:UnixControlType.GetField('active',$staticFlags)
        $savedPending=$pending.GetValue($null); $savedActive=$active.GetValue($null)
        try {
            foreach($darwin in @($false,$true)) { foreach($mode in @('live','inventory-error')) {
                $f=New-UnixObservationFixture; $state=$f.State
                if($darwin){Set-DarwinObservationFixture $f}
                Invoke-UnixTestMethod $f.Control Poll
                $state.Table[200]=New-UnixTestStat 200 100 200 $(if($darwin){'10'}else{'root'}) 'Z'
                $state.ExitEvent=0
                Invoke-UnixTestMethod $f.Control Poll
                Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{param($id) return [Tuple]::Create(0,0,0)})
                if($mode -eq 'inventory-error') {
                    if($darwin){Set-UnixTestField $f.Control listDarwinPids ([Func[uint32,uint32,int[]]]{param($kind,$value) throw [IO.IOException]::new('dispose-census-error')})}
                    else {Set-UnixTestField $f.Control listLinuxPids ([Func[int[]]]{throw [IO.IOException]::new('dispose-census-error')})}
                }
                $timer=[Diagnostics.Stopwatch]::StartNew()
                $f.Control.Dispose(); $f.Control.Dispose()
                $timer.Elapsed.TotalSeconds | Should BeLessThan 2
                [object]::ReferenceEquals($pending.GetValue($null),$f.Control) | Should Be $true
                $active.GetValue($null) | Should Be $true
                $state.ClosedPidfds.Count | Should Be 0
                { $script:UnixControlType.GetMethod('EnsureStartAvailable',$staticFlags).Invoke($null,@()) } | Should Throw 'cleanup is incomplete'
                if($mode -eq 'live') {
                    $state.GroupErrno=3
                    Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{param($id) $state.Table.Remove($id); return [Tuple]::Create([int]$id,0,0)}.GetNewClosure())
                    $script:UnixControlType.GetMethod('EnsureStartAvailable',$staticFlags).Invoke($null,@())
                    $pending.GetValue($null) | Should BeNullOrEmpty
                    $active.GetValue($null) | Should Be $false
                }
                # Fake syscalls own no real process/descriptor; release fixture bookkeeping only.
                Invoke-UnixTestMethod $f.Control ClosePidfds
                $pending.SetValue($null,$savedPending); $active.SetValue($null,$savedActive)
            } }
        } finally { $pending.SetValue($null,$savedPending); $active.SetValue($null,$savedActive) }
    }

    # Scenario: Root exits before its cooperative child; Darwin omits the zombie from libproc.
    # Purpose: Keep the root waitable through TERM/KILL, then reap only after descendants and group exit.
    It 'UnitT290_retains_the_zombie_root_until_group_descendants_exit' {
        foreach ($darwin in @($false,$true)) {
            $f = New-UnixObservationFixture; $state = $f.State
            if ($darwin) { Set-DarwinObservationFixture $f }
            $state.Pids = [int[]]@(100,200,300)
            $state.Table[300] = New-UnixTestStat 300 200 200 '11'
            Invoke-UnixTestMethod $f.Control Poll
            if ($darwin) { $state.Table.Remove(200); $state.ExitEvent = 0 }
            else { $state.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z' }
            $state.Peek = [Tuple]::Create(200,0,0)
            Invoke-UnixTestMethod $f.Control Poll
            Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
            Invoke-UnixTestMethod $f.Control Poll
            Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
            $state.Waited | Should Not Contain 200
            $state.Signals | Should Contain '-200:15'
            $state.Signals | Should Contain '-200:9'
            $f.Owned.ContainsKey(300) | Should Be $true
            $state.Table.Remove(300); $state.GroupErrno = 3
            Invoke-UnixTestMethod $f.Control Poll
            $state.Waited | Should Contain 200
            @(Invoke-UnixTestMethod $f.Control Remaining).Count | Should Be 0
            $f.Control.Uncertainty | Should BeNullOrEmpty
        }
    }

    # Scenario: An external waiter consumes the retained root before the next group signal.
    # Purpose: Revoke PGID authority; Linux may use recorded pidfds, Darwin must report uncertainty.
    It 'UnitT300_revokes_group_authority_after_external_reaping' {
        foreach ($darwin in @($false,$true)) {
            $f = New-UnixObservationFixture; $state = $f.State
            if ($darwin) { Set-DarwinObservationFixture $f }
            $state.Pids = [int[]]@(100,200,300)
            $state.Table[300] = New-UnixTestStat 300 200 200 '11'
            Invoke-UnixTestMethod $f.Control Poll
            $state.Peek = [Tuple]::Create(200,0,0)
            if ($darwin) { $state.ExitEvent = 0; $state.Table.Remove(200) }
            else { $state.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z' }
            Invoke-UnixTestMethod $f.Control Poll
            $state.Table.Remove(200); $state.Peek = [Tuple]::Create(-1,0,10)
            Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
            $state.Signals | Should Not Contain '-200:9'
            $state.Waited | Should Not Contain 200
            if ($darwin) { $f.Control.Uncertainty | Should Not BeNullOrEmpty }
            else { $state.PidfdSignals | Should Contain '1300:9' }
        }
    }

    # Scenario: Census and pathname reads fail after a zombie root was reserved.
    # Purpose: Termination still uses the retained root, without authorizing signals from descendants.
    It 'UnitT310_terminates_a_reserved_group_when_inventory_fails' {
        foreach ($darwin in @($false,$true)) {
            $f = New-UnixObservationFixture; $state = $f.State
            if ($darwin) { Set-DarwinObservationFixture $f; $state.ExitEvent = 0; $state.Table.Remove(200) }
            else { $state.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z' }
            $state.Peek = [Tuple]::Create(200,0,0)
            Invoke-UnixTestMethod $f.Control Poll
            $state.Table[200] = [IO.IOException]::new('fixture-persistent-inventory-error')
            { Invoke-UnixTestMethod $f.Control Poll } | Should Throw
            Invoke-UnixTestMethod $f.Control Signal @($false) | Out-Null
            Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
            $state.Signals | Should Contain '-200:15'
            $state.Signals | Should Contain '-200:9'
            $f.Control.Uncertainty | Should Match 'inventory-incomplete'
        }
    }

    # Scenario: A bound child remains waitable/running while recovery cannot inventory the group.
    # Purpose: Recovery must not consume the root first and lose the PGID reservation.
    It 'UnitT320_keeps_the_root_when_bound_recovery_cannot_confirm_descendant_exit' {
        $f = New-UnixObservationFixture; $state = $f.State
        $state.Pids = [int[]]@(100,200,300)
        $state.Table[300] = New-UnixTestStat 300 200 200 'child'
        Invoke-UnixTestMethod $f.Control Poll
        Set-UnixTestField $f.Control waitForChild ([Func[int,Tuple[int,int,int]]]{
            param($id) $state.Waited.Add($id); return [Tuple]::Create(0,0,0)
        }.GetNewClosure())
        Invoke-UnixTestMethod $f.Control ReapBoundAfterInventoryFailure
        $state.Waited | Should Contain 300
        $state.Waited | Should Not Contain 200
        $f.Owned.ContainsKey(200) | Should Be $true
    }

    # Scenario: Darwin startup failed after observing a child and the root's exit event.
    # Purpose: Failed-start cleanup uses group signalling without consuming the remaining group's root.
    It 'UnitT330_retains_the_darwin_group_anchor_during_failed_start_cleanup' {
        $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f; $state = $f.State
        $state.Pids = [int[]]@(100,200,300)
        $state.Table[300] = New-UnixTestStat 300 200 200 '11'
        Invoke-UnixTestMethod $f.Control Poll
        $state.Table.Remove(200); $state.ExitEvent = 0
        Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
        $state.Waited | Should Not Contain 200
        $state.Signals | Should Contain '-200:9'
        $state.Table.Remove(300); $state.GroupErrno = 3
        Invoke-UnixTestMethod $f.Control CleanupFailedStart @([TimeSpan]::Zero)
        $state.Waited | Should Contain 200
        $f.Owned.Count | Should Be 0
    }

    # Scenario: Darwin's waitid record and option values differ from Linux on both supported architectures.
    # Purpose: Request a non-consuming observation and reject Linux SIGCHLD/layout assumptions.
    It 'UnitT340_uses_darwin_nonconsuming_wait_options_and_siginfo_prefix' {
        $f = New-UnixObservationFixture; $state = $f.State
        $state.WaitCalls = [Collections.Generic.List[string]]::new()
        $state.NativeErrno = 0; $state.NativeSigno = 20
        Set-UnixTestField $f.Control waitDarwin ([Func[int,uint32,IntPtr,int,Tuple[int,int]]]{
            param($kind,$id,$info,$options)
            $state.WaitCalls.Add("${kind}:${id}:${options}")
            if ($state.NativeErrno) { return [Tuple]::Create(-1,[int]$state.NativeErrno) }
            [Runtime.InteropServices.Marshal]::WriteInt32($info,0,[int]$state.NativeSigno)
            [Runtime.InteropServices.Marshal]::WriteInt32($info,12,[int]$id)
            [Runtime.InteropServices.Marshal]::WriteInt32($info,16,999) # Darwin si_uid, NOT Linux si_pid
            [Runtime.InteropServices.Marshal]::WriteInt32($info,20,77) # status is deliberately not decoded here
            return [Tuple]::Create(0,0)
        }.GetNewClosure())
        $wait = Invoke-UnixTestMethod $f.Control PeekDarwinChild @([int]200)
        $wait.Item1 | Should Be 200
        $wait.Item2 | Should Be 0
        $state.WaitCalls | Should Contain '1:200:37' # P_PID, WNOHANG|WEXITED|WNOWAIT (0x25)
        $state.NativeSigno = 17
        { Invoke-UnixTestMethod $f.Control PeekDarwinChild @([int]200) } | Should Throw
        $state.NativeErrno = 10
        $wait = Invoke-UnixTestMethod $f.Control PeekDarwinChild @([int]200)
        $wait.Item1 | Should Be -1
        $wait.Item3 | Should Be 10
        $state.Waited.Count | Should Be 0
    }

    # Scenario: Darwin returns EPERM for TERM/KILL and kill(0) when only the retained zombie remains.
    # Purpose: A fresh group census distinguishes zombie-only completion from live or unreadable members.
    It 'UnitT345_classifies_darwin_zombie_only_group_eperm_without_hiding_live_members' {
        foreach ($outcome in @('zombie-only','live','denied','inventory-error')) {
            $f = New-UnixObservationFixture; Set-DarwinObservationFixture $f; $state = $f.State
            $state.Table.Remove(200); $state.ExitEvent = 0; $state.GroupErrno = 1
            Invoke-UnixTestMethod $f.Control Poll
            $state.Outcome = $outcome
            if ($outcome -eq 'live') { $state.Table[300] = New-UnixTestStat 300 1 200 '11' }
            if ($outcome -eq 'denied') { $state.Table[300] = [UnauthorizedAccessException]::new('fixture-group-denied') }
            Set-UnixTestField $f.Control listDarwinPids ([Func[uint32,uint32,int[]]]{
                param($kind,$value)
                if ($kind -eq 2) {
                    if ($state.Outcome -eq 'inventory-error') { throw [IO.IOException]::new('fixture-group-census-failed') }
                    if ($state.Outcome -ne 'zombie-only') { return ,([int[]]@(300)) }
                    return ,([int[]]@())
                }
                if ($kind -eq 4) { return ,$state.Pids }
                return ,([int[]]@())
            }.GetNewClosure())
            Set-UnixTestField $f.Control sendSignal ([Func[int,int,int]]{
                param($id,$signal) $state.Signals.Add("${id}:$signal"); return 1
            }.GetNewClosure())
            if ($outcome -eq 'zombie-only') {
                $type = [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
                $flags = [Reflection.BindingFlags]'Instance,NonPublic'
                $lease = [Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(10),[long]4096),$null)
                $type.GetField('control',$flags).SetValue($lease,$f.Control)
                $type.GetField('captureClosed',$flags).SetValue($lease,$true)
                try {
                    $receipt = $lease.Stop([TimeSpan]::Zero,[DateTimeOffset]::UtcNow.AddMilliseconds(300),$null)
                    $receipt.CleanedUp | Should Be $true
                    $receipt.Uncertainty | Should BeNullOrEmpty
                    $receipt.RemainingPids.Count | Should Be 0
                    $receipt.UnixObservation.GroupProbeErrno | Should Be 1
                    $state.Waited | Should Contain 200
                } finally { $lease.Dispose() }
            } else {
                Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
                if ($outcome -eq 'live') { $f.Control.Uncertainty | Should Match 'group-signal-failed: 1' }
                else { $f.Control.Uncertainty | Should Match 'group-inventory-incomplete' }
                @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 200
                $state.Waited | Should Not Contain 200
            }
        }
    }

    # Scenario: Linux reports EPERM while the root is waitable and its group is still present.
    # Purpose: The Darwin zombie-only exception must not change Linux signalling or existence semantics.
    It 'UnitT346_preserves_linux_eperm_failure_and_pending_group' {
        $f = New-UnixObservationFixture; $state = $f.State
        $state.Table[200] = New-UnixTestStat 200 100 200 'root' 'Z'
        Invoke-UnixTestMethod $f.Control Poll
        Set-UnixTestField $f.Control sendSignal ([Func[int,int,int]]{ param($id,$signal) return 1 })
        Invoke-UnixTestMethod $f.Control Signal @($true) | Out-Null
        Invoke-UnixTestMethod $f.Control Poll
        $f.Control.Uncertainty | Should Match 'group-signal-failed: 1'
        @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 200
        $state.Waited | Should Not Contain 200
    }

    # Scenario: A recorded Darwin group member is also a direct child of the host and becomes a zombie.
    # Purpose: Do not steal/reap an unbound numeric descendant PID; Linux retains its pidfd wait path.
    It 'UnitT350_refuses_unbound_darwin_descendant_waits' {
        foreach ($darwin in @($false,$true)) {
            $f = New-UnixObservationFixture; $state = $f.State
            if ($darwin) { Set-DarwinObservationFixture $f }
            $state.Pids = [int[]]@(100,200,300)
            $state.Table[300] = New-UnixTestStat 300 100 200 '11' 'Z'
            Invoke-UnixTestMethod $f.Control Poll
            if ($darwin) {
                $state.Waited | Should Not Contain 300
                @(Invoke-UnixTestMethod $f.Control Remaining) | Should Contain 300
                $f.Control.Uncertainty | Should Match 'macos-unbound-child-wait-refused'
            } else { $state.Waited | Should Contain 300 }
        }
    }


}

Describe 'Windows owned process termination regressions' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
    }

    # Scenario: QueryInformationJobObject cannot report the active process count.
    # Purpose: The retained Job handle must still authorize TerminateJobObject independently.
    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsWindows) {
        It 'InterT10_terminates_the_bound_job_when_accounting_fails' {
            $type=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative].Assembly.GetType('SyuanTsai.AIInstructions.PlatformRuntime.WindowsProcessControl')
            $flags=[Reflection.BindingFlags]'Instance,NonPublic'
            $control=[Activator]::CreateInstance($type,$true)
            $job=$type.GetMethod('CreateJobObjectW',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@([IntPtr]::Zero,$null))
            try {
                $job.IsInvalid | Should Be $false
                $type.GetField('job',$flags).SetValue($control,$job)
                $type.GetField('countProcesses',$flags).SetValue($control,[Func[uint32]]{ throw [IO.IOException]::new('fixture-job-accounting-failure') })
                { $control.Remaining() } | Should Throw
                $control.Signal($true) | Should Be 1
            } finally { $control.Dispose(); $job.Dispose() }
            $job.IsClosed | Should Be $true
        }
    }
}

Describe 'Platform capture cancellation regressions' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
    }

    # Scenario: Both pipe writers stay open and never send a byte or EOF.
    # Purpose: Cancelling capture must join readers and release their pipe/file handles without writer cooperation.
    It 'InterT10_cancels_idle_capture_readers_and_releases_owned_handles' {
        $flags = [Reflection.BindingFlags]'Instance,NonPublic'
        $type = [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
        $directory = Join-Path ([IO.Path]::GetTempPath()) ('p3-capture-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($directory)
        try {
            foreach ($iteration in 1..3) {
                $lease = [Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(10),[long]4096),$null)
                $pipes = @(); $files = @(); $readers = @(); $readHandles = @(); $writeHandles = @(); $fileHandles = @()
                try {
                    foreach ($stream in @('out','err')) {
                        $pipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In,[IO.HandleInheritability]::Inheritable)
                        $file = [IO.File]::Open((Join-Path $directory ("$iteration-$stream")),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                        $pipes += $pipe; $files += $file
                        $readHandles += $pipe.SafePipeHandle; $writeHandles += $pipe.ClientSafePipeHandle; $fileHandles += $file.SafeFileHandle
                        $type.GetField($(if ($stream -eq 'out') { 'stdout' } else { 'stderr' }),$flags).SetValue($lease,$pipe)
                        $type.GetField(($stream+'File'),$flags).SetValue($lease,$file)
                        $reader = $type.GetMethod('Reader',$flags).Invoke($lease,[object[]]@($pipe,$file))
                        $readers += $reader
                        $type.GetField(($stream+'Reader'),$flags).SetValue($lease,$reader)
                    }
                    [Threading.Thread]::Sleep(50)
                    $lease.CaptureReadersStopped | Should Be $false
                    foreach ($pipe in $pipes) { $pipe.ClientSafePipeHandle.IsClosed | Should Be $false }
                    $until = [DateTimeOffset]::UtcNow.AddSeconds(2)
                    $type.GetMethod('CancelCaptureReaders',$flags).Invoke($lease,[object[]]@($until)) | Should Be $true
                    $type.GetMethod('CloseCapture',$flags).Invoke($lease,@())
                    $lease.CaptureReadersStopped | Should Be $true
                    $lease.CaptureResourcesClosed | Should Be $true
                    foreach ($handle in $readHandles + $fileHandles) { $handle.IsClosed | Should Be $true }
                    # These writer handles belong to the fixture, not the lease;
                    # they remain open throughout cancellation, like escaped writers.
                    foreach ($handle in $writeHandles) { $handle.IsClosed | Should Be $false }
                } finally {
                    # Release fixture writers even against a regressed blocking reader.
                    foreach ($handle in $writeHandles) { $handle.Dispose() }
                    $type.GetMethod('CancelCaptureReaders',$flags).Invoke($lease,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(2))) | Out-Null
                    $type.GetMethod('CloseCapture',$flags).Invoke($lease,@())
                }
            }
        } finally {
            foreach ($iteration in 1..3) { foreach ($stream in @('out','err')) { $path = Join-Path $directory ("$iteration-$stream"); if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } }
            [IO.Directory]::Delete($directory)
        }
    }
}

Describe 'Platform capture startup failure regressions' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
    }

    # Scenario: Spawn fails after pipes are created but before local client copies are released.
    # Purpose: Closing a failed lease releases both ends; disposing the server stream alone is insufficient.
    It 'InterT10_releases_local_client_copies_when_startup_fails' {
        $type = [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
        $flags = [Reflection.BindingFlags]'Instance,NonPublic'
        $lease = [Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(10),[long]4096),$null)
        $handles = @()
        try {
            foreach ($name in @('stdout','stderr')) {
                $pipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In,[IO.HandleInheritability]::Inheritable)
                $handles += $pipe.SafePipeHandle; $handles += $pipe.ClientSafePipeHandle
                $type.GetField($name,$flags).SetValue($lease,$pipe)
                $type.GetField(($name+'Client'),$flags).SetValue($lease,$pipe.ClientSafePipeHandle)
            }
            $type.GetMethod('CloseCapture',$flags).Invoke($lease,@())
            $lease.CaptureReadersStopped | Should Be $true
            $lease.CaptureResourcesClosed | Should Be $true
            foreach ($handle in $handles) { $handle.IsClosed | Should Be $true }
        } finally { foreach ($handle in $handles) { $handle.Dispose() } }
    }
}

Describe 'Platform capture character quotas' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        function Invoke-CaptureQuotaChild([string]$CaseName,[int]$TimeoutMilliseconds=15000) {
            # A parent watchdog bounds constructor, Write, Flush and Dispose too;
            # a timed Join cannot protect code which never reaches that Join.
            $testPath=Join-Path $PSScriptRoot 'platform-runtime.Tests.ps1'
            $code=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Import-Module Microsoft.PowerShell.Utility
Import-Module $env:CAPTURE_QUOTA_PESTER -Force
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($env:CAPTURE_QUOTA_TEST_FILE,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture parse failed'}
$describe=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Describe' -and $n.CommandElements[1].Value -eq 'Platform capture character quotas'},$true))[0]
$PSScriptRoot=[IO.Path]::GetDirectoryName($env:CAPTURE_QUOTA_TEST_FILE)
$before=@($describe.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'BeforeAll'},$true))[0].CommandElements[-1].ScriptBlock.Extent.Text
$before=$before.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
if($PSVersionTable.PSVersion.Major -lt 7){$before=$before.Replace('platform-runtime.psd1','platform-runtime.psm1')}
. ([scriptblock]::Create($before.Substring(1,$before.Length-2)))
$test=@($describe.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'It' -and $n.CommandElements[1].Value -eq $env:CAPTURE_QUOTA_CHILD},$true))[0].CommandElements[-1].ScriptBlock.Extent.Text
. ([scriptblock]::Create($test.Substring(1,$test.Length-2)))
'quota-child-passed'
'@
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=(Get-Process -Id $PID).Path
            $start.Arguments='-NoLogo -NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            $start.UseShellExecute=$false; $start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
            $start.EnvironmentVariables['CAPTURE_QUOTA_TEST_FILE']=$testPath
            $start.EnvironmentVariables['CAPTURE_QUOTA_CHILD']=$CaseName
            $start.EnvironmentVariables['CAPTURE_QUOTA_PESTER']=(Get-Module Pester | Where-Object { $_.Version -eq [version]'4.10.1' } | Select-Object -First 1).Path
            $child=[Diagnostics.Process]::new(); $child.StartInfo=$start; $started=$false
            try {
                $started=$child.Start()
                $output=$child.StandardOutput.ReadToEndAsync(); $errorOutput=$child.StandardError.ReadToEndAsync()
                if(-not $child.WaitForExit($TimeoutMilliseconds)){
                    $child.Kill()
                    if(-not $child.WaitForExit(2000)){throw 'Capture fixture termination timed out'}
                    $diagnostics=if($output.Wait(1000)){$output.Result}else{'diagnostics unavailable'}
                    throw ('Capture fixture exceeded its deadline: '+$diagnostics)
                }
                if(-not $output.Wait(1000) -or -not $errorOutput.Wait(1000)){throw 'Capture fixture diagnostics timed out'}
                if($child.ExitCode -ne 0){throw ($errorOutput.Result+$output.Result)}
                $output.Result | Should Match 'quota-child-passed'
            } finally {
                if($started -and -not $child.HasExited){$child.Kill(); if(-not $child.WaitForExit(2000)){throw 'Capture fixture termination timed out'}}
                $child.Dispose()
            }
        }
    }

    # Scenario: Two streams write split UTF-8 sequences, at or above their separate limits.
    # Purpose: Preserve whole decoded prefixes and stop on either stream's overflow without sharing counters.
    It 'UnitT10_enforces_independent_character_limits_across_utf8_chunks' {
        if($env:CAPTURE_QUOTA_CHILD -ne 'UnitT10_enforces_independent_character_limits_across_utf8_chunks') { Invoke-CaptureQuotaChild 'UnitT10_enforces_independent_character_limits_across_utf8_chunks'; return }
        $type=[SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]
        $flags=[Reflection.BindingFlags]'Instance,NonPublic'
        foreach ($mode in @('exact','stdout-over','stderr-over')) {
            $lease=[Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddSeconds(10),[long]4),$null)
            $paths=@(); $pipes=@(); $files=@(); $readers=@()
            try {
                foreach ($stream in @('stdout','stderr')) {
                    [Console]::WriteLine("quota: $mode $stream create")
                    $path=Join-Path ([IO.Path]::GetTempPath()) ('quota-'+[guid]::NewGuid().ToString('N')); $paths+=$path
                    $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read); $files+=$file
                    $pipe=[IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In,[IO.HandleInheritability]::Inheritable); $pipes+=$pipe
                    $readers+=$type.GetMethod('Reader',$flags).Invoke($lease,[object[]]@($pipe,$file))
                    # Avoid the managed AnonymousPipeClientStream path implicated
                    # by the Unix hang. The fixture writes at most 15 bytes into a
                    # fresh pipe; the separate-process watchdog bounds library I/O.
                    [Console]::WriteLine("quota: $mode $stream writer")
                    $handle=[Microsoft.Win32.SafeHandles.SafeFileHandle]::new($pipe.ClientSafePipeHandle.DangerousGetHandle(),$false)
                    $writer=[IO.FileStream]::new($handle,[IO.FileAccess]::Write,1,$false)
                    try {
                        $length=if ($mode -eq ($stream+'-over')) { 5 } else { 4 }
                        $bytes=[Text.Encoding]::UTF8.GetBytes((([string][char]0x754c)*$length))
                        [Console]::WriteLine("quota: $mode $stream write")
                        $writer.Write($bytes,0,1); $writer.Flush(); [Threading.Thread]::Sleep(20)
                        $writer.Write($bytes,1,$bytes.Length-1); $writer.Flush()
                    } finally { [Console]::WriteLine("quota: $mode $stream close-writer"); $writer.Dispose(); $pipe.ClientSafePipeHandle.Dispose() }
                }
                [Console]::WriteLine("quota: $mode join")
                foreach ($reader in $readers) { $reader.Join(2000) | Should Be $true }
                $lease.OutputLimitExceeded | Should Be ($mode -ne 'exact')
                foreach ($file in $files) { $file.Dispose() }
                foreach ($path in $paths) { [IO.File]::ReadAllText($path) | Should Be (([string][char]0x754c)*4) }
            } finally {
                $type.GetField('captureCancelled',$flags).GetValue($lease).Set()
                foreach ($pipe in $pipes) { $pipe.ClientSafePipeHandle.Dispose() }
                foreach ($reader in $readers) { if(-not $reader.Join(2000)){throw 'Capture reader cancellation exceeded its deadline'} }
                foreach ($file in $files) { $file.Dispose() }; foreach ($pipe in $pipes) { $pipe.Dispose() }
                foreach ($path in $paths) { [IO.File]::Delete($path) }
            }
        }
    }

    # Scenario: A writer leaves an incomplete UTF-8 character and keeps its pipe open.
    # Purpose: A standalone reader must honor its lease deadline without a supervisor or EOF.
    It 'UnitT15_bounds_incomplete_utf8_capture_by_the_lease_deadline' {
        if($env:CAPTURE_QUOTA_CHILD -ne 'UnitT15_bounds_incomplete_utf8_capture_by_the_lease_deadline') { Invoke-CaptureQuotaChild 'UnitT15_bounds_incomplete_utf8_capture_by_the_lease_deadline'; return }
        $type=[SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]; $flags=[Reflection.BindingFlags]'Instance,NonPublic'
        $lease=[Activator]::CreateInstance($type,$flags,$null,[object[]]@([DateTimeOffset]::UtcNow.AddMilliseconds(300),[long]4),$null)
        $path=Join-Path ([IO.Path]::GetTempPath()) ('quota-'+[guid]::NewGuid().ToString('N'))
        $pipe=[IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In,[IO.HandleInheritability]::Inheritable)
        $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $reader=$null; $writer=$null
        try {
            $reader=$type.GetMethod('Reader',$flags).Invoke($lease,[object[]]@($pipe,$file))
            $writer=[IO.FileStream]::new([Microsoft.Win32.SafeHandles.SafeFileHandle]::new($pipe.ClientSafePipeHandle.DangerousGetHandle(),$false),[IO.FileAccess]::Write,1,$false)
            $writer.WriteByte(0xe7); $writer.Flush()
            $reader.Join(1500) | Should Be $true
            $type.GetField('captureFailure',$flags).GetValue($lease) | Should Be 'capture-deadline'
            $lease.OutputLimitExceeded | Should Be $false
        } finally {
            $type.GetField('captureCancelled',$flags).GetValue($lease).Set()
            if($null -ne $reader -and -not $reader.Join(2000)){throw 'Partial-character capture cancellation timed out'}
            if($null -ne $writer){$writer.Dispose()}; $pipe.ClientSafePipeHandle.Dispose(); $pipe.Dispose(); $file.Dispose(); [IO.File]::Delete($path)
        }
    }

    # Scenario: No quota override is supplied, or a caller requests more than the standard permits.
    # Purpose: The public default and maximum are 1,048,576 characters per stream.
    It 'UnitT20_defaults_to_and_caps_the_standard_character_limit' {
        $command=Get-Command Start-PlatformOwnedProcess
        $parameter=$command.Parameters['OutputLimitCharacters']
        $parameter | Should Not BeNullOrEmpty
        $range=@($parameter.Attributes | Where-Object { $_ -is [Management.Automation.ValidateRangeAttribute] })[0]
        $range.MaxRange | Should Be 1048576
        $node=@($command.ScriptBlock.Ast.FindAll({param($n) $n -is [Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'OutputLimitCharacters'},$true))[0]
        $node.DefaultValue.SafeGetValue() | Should Be 1048576
    }

    # Scenario: Fixture code stops making progress before its reader Join.
    # Purpose: The parent watchdog kills the isolated fixture instead of hanging CI.
    It 'UnitT25_bounds_a_stalled_capture_fixture' {
        if($env:CAPTURE_QUOTA_CHILD -eq 'UnitT25_bounds_a_stalled_capture_fixture'){Start-Sleep -Seconds 30; return}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        { Invoke-CaptureQuotaChild 'UnitT25_bounds_a_stalled_capture_fixture' 2000 } | Should Throw 'exceeded its deadline'
        $timer.Elapsed.TotalSeconds | Should BeLessThan 10
    }
}

# Native directory handles are only available on Unix; conditional registration keeps zero skips.
if ($IsLinux -or $IsMacOS) {
    Describe 'Unix executable parent directories' {
        BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force }
        # Scenario: A Darwin executable path has / as its immediate parent.
        # Purpose: Open the root directory itself without passing an empty relative path to P2.
        It 'InterT10_opens_root_parent_for_a_root_level_executable' {
            $type=[SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease].Assembly.GetType('SyuanTsai.AIInstructions.PlatformRuntime.UnixProcessControl')
            $parent=$type.GetMethod('OpenExecutableParent',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,@('/fixture-executable'))
            try { $parent.Observation.Kind | Should Be 'directory'; $type.Assembly.GetType('SyuanTsai.AIInstructions.PlatformRuntime.UnixLease').GetField('Path',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($parent) | Should Be '/' }
            finally { $parent.Dispose() }
        }
    }
}

Describe 'Platform runtime contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ModuleManifest = Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1'
        Import-Module $script:ModuleManifest -Force

        if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
            $script:ExpectedOs = 'windows'
        }
        elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
            $script:ExpectedOs = 'linux'
        }
        elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
            $script:ExpectedOs = 'macos'
        }
        else {
            throw 'The test host is not a supported platform.'
        }

        function Copy-PlatformRuntimeFixture {
            param([Parameter(Mandatory = $true)][string] $Destination)

            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            $sourceRoot=Join-Path $script:RepositoryRoot 'scripts'
            $manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $sourceRoot 'platform-runtime.psd1')
            foreach($relative in $manifest.FileList) {
                $target=Join-Path $Destination $relative
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $target
            }
            # Each mutation starts from a genuinely importable complete closure.
            # Do not let a missing dependency masquerade as tamper detection.
            $modules=@(Import-Module (Join-Path $Destination 'platform-runtime.psd1') -Force -PassThru -Scope Local -ErrorAction Stop)
            try {
                $modules.Count | Should Be 1
                $receipt=& $modules[0].ExportedCommands['Assert-PlatformRuntimeInventory']
                $receipt.files.Count | Should Be $manifest.PrivateData.PlatformRuntime.Inventory.Count
            } finally { $modules | Remove-Module -Force -ErrorAction SilentlyContinue }
        }
    }

    AfterAll {
        Remove-Module platform-runtime -Force -ErrorAction SilentlyContinue
    }

    # Scenario: A caller inspects the current host before requesting a platform primitive.
    # Purpose: Keep the capability receipt stable, exact, and based on actual runtime detection.
    It 'UnitT10_returns_the_exact_capability_receipt_shape_and_current_os' {
        $receipt = Get-PlatformCapabilities -Required @('process-environment')

        (@($receipt.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'apiVersion,architecture,capabilities,os,runtime'
        (@($receipt.runtime.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'dotNetVersion,powerShellVersion'
        $receipt.os | Should Be $script:ExpectedOs
        $receipt.apiVersion | Should Be '1.0'
        $receipt.architecture | Should Match '^(x64|x86|arm64|arm)$'
        @($receipt.capabilities).Count | Should BeGreaterThan 0
        foreach ($capability in @($receipt.capabilities)) {
            (@($capability.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'evidence,name,status'
            @('available','unavailable','unverified') | Should Contain $capability.status
            $capability.evidence -is [array] | Should Be $true
        }
        ($receipt.capabilities | Where-Object name -eq 'process-environment').status | Should Be 'available'
    }

    # Scenario: A caller sets a temporary runtime variable on any supported host.
    # Purpose: Bind the operation to Process scope without returning the potentially sensitive value.
    It 'UnitT15_sets_only_process_scope_and_returns_no_value' {
        $name = 'SYP353_PLATFORM_RUNTIME_TEST'
        try {
            $receipt = Set-PlatformProcessEnvironment -Name $name -Value 'fixture-value'
            (@($receipt.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'apiVersion,name,scope'
            $receipt.scope | Should Be 'Process'
            $receipt.name | Should Be $name
            $receipt.PSObject.Properties.Name | Should Not Contain 'value'
            [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process) | Should Be 'fixture-value'
        }
        finally {
            [Environment]::SetEnvironmentVariable($name,$null,[EnvironmentVariableTarget]::Process)
        }
    }

    # Scenario: A Windows caller requires the durable file publication and owned-file removal primitives.
    # Purpose: Bind availability to a live no-replace publication and tombstone-removal probe instead of OS inference.
    if ($IsWindows) {
        It 'UnitT20_reports_windows_file_publication_from_native_probe_evidence' {
            $receipt=Get-PlatformCapabilities -Required @('publication','owned-file-removal')
            foreach($name in @('publication','owned-file-removal')){
                $capability=@($receipt.capabilities|Where-Object name -ceq $name)
                $capability.Count|Should Be 1
                $capability[0].status|Should Be available
                ($capability[0].evidence -join ' ')|Should Match 'confirmed.*durability'
            }
        }
    }

    # Scenario: A caller changes the case of a known capability name.
    # Purpose: Treat capability identifiers as ordinal contracts and return the documented typed failure for unknown names.
    It 'UnitT25_rejects_case_variant_capability_names_with_a_typed_failure' {
        $caught = $null
        try { Get-PlatformCapabilities -Required @('LOCK') | Out-Null }
        catch { $caught = $_ }

        $caught | Should Not BeNullOrEmpty
        $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
        $caught.Exception.Capability | Should Be 'LOCK'
        $caught.Exception.Platform | Should Be $script:ExpectedOs
    }

    # Scenario: Reserved target paths are evaluated for both Windows and Unix adapters.
    # Purpose: Bind both platform implementations to one ordinal-ignore-case transaction-store boundary helper.
    It 'UnitT27_shares_transaction_store_target_semantics_across_platform_adapters' {
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::IsTransactionStoreTarget('/root/ordinary','target') | Should Be $false
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::IsTransactionStoreTarget('/root/ordinary','.ai-instructions-txn') | Should Be $true
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::IsTransactionStoreTarget('/root/.ai-instructions-txn/0123456789abcdef0123456789abcdef','target') | Should Be $true
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::IsTransactionStoreTarget('C:\root\.AI-INSTRUCTIONS-TXN\0123456789abcdef0123456789abcdef','target') | Should Be $true
    }

    # Scenario: Linux and macOS adapters are loaded directly on Windows after their P7 primitives exist.
    # Purpose: Preserve origin/main's typed fail-closed assertion without retaining a NotImplemented stub.
    if ($IsWindows) {
        It 'UnitT30_rejects_cross_os_unix_primitives_with_typed_failures' {
            foreach ($adapter in @('Linux','MacOS')) {
                $adapterPath = Join-Path $script:RepositoryRoot "scripts/platform/$adapter.psm1"
                Import-Module $adapterPath -Force
                $command = "Publish-$($adapter)PlatformFile"
                $caught = $null
                try { & $command -ParentLease 'fixture' -Leaf 'target' -TransactionLease 'fixture' -StageLease 'fixture' -ExpectedState 'fixture' -DisplacedLeaf $null -ExpectedStage 'fixture' | Out-Null }
                catch { $caught = $_ }
                $caught | Should Not BeNullOrEmpty
                $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
                $caught.Exception.Capability | Should Be 'publication'
                $caught.Exception.Platform | Should Be 'windows'
                Remove-Module $adapter -Force -ErrorAction SilentlyContinue
            }
        }

        # P7c originally added a second signature regression with a non-null displaced leaf.
        # Keep it under a new number because origin/main owns UnitT30.
        It 'UnitT31_rejects_complete_cross_os_unix_mutation_signatures_with_typed_failures' {
            foreach ($adapter in @('Linux','MacOS')) {
                $adapterPath = Join-Path $script:RepositoryRoot "scripts/platform/$adapter.psm1"
                Import-Module $adapterPath -Force
                $command = "Publish-$($adapter)PlatformFile"
                $caught = $null
                try { & $command -ParentLease 'fixture' -Leaf 'target' -TransactionLease 'fixture' -StageLease 'fixture' -ExpectedState 'fixture' -DisplacedLeaf 'backup' -ExpectedStage 'fixture' | Out-Null }
                catch { $caught = $_ }
                $caught | Should Not BeNullOrEmpty
                $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
                $caught.Exception.Capability | Should Be 'publication'
                $caught.Exception.Platform | Should Be 'windows'
                $remove = "Remove-$($adapter)PlatformOwnedFile"
                $caught = $null
                try { & $remove -ParentLease 'fixture' -Leaf 'target' -ExpectedState 'fixture' -TransactionLease 'fixture' -TombstoneLeaf 'tombstone' | Out-Null } catch { $caught = $_ }
                $caught | Should Not BeNullOrEmpty
                $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
                $caught.Exception.Capability | Should Be 'owned-file-removal'
                $caught.Exception.Platform | Should Be 'windows'
                Remove-Module $adapter -Force -ErrorAction SilentlyContinue
            }
        }

        # Scenario: Linux and macOS directory adapters remain explicit P11 stubs after P7c file primitives are merged.
        # Purpose: Keep every directory facade signature aligned, including the mandatory ExpectedIdentity cleanup guard.
        It 'UnitT705_rejects_unimplemented_unix_directory_primitives_with_typed_failures' {
            foreach ($adapter in @('Linux','MacOS')) {
                $adapterPath = Join-Path $script:RepositoryRoot "scripts/platform/$adapter.psm1"
                Import-Module $adapterPath -Force
                foreach($directoryCase in @(
                    @{Command="Get-$($adapter)PlatformDirectoryState";Arguments=@{ParentLease='fixture';Leaf='source'};Capability='directory-publication'},
                    @{Command="Move-$($adapter)PlatformOwnedDirectory";Arguments=@{ParentLease='fixture';Leaf='source';TransactionLease='fixture';DestinationLeaf='destination';ExpectedIdentity='fixture';Direction='ToTransaction'};Capability='directory-publication'},
                    @{Command="Remove-$($adapter)PlatformOwnedDirectoryTree";Arguments=@{TransactionLease='fixture';Leaf='backup';ExpectedIdentity='fixture'};Capability='owned-file-removal'}
                )){
                    $directoryCaught=$null
                    $directoryArguments=$directoryCase.Arguments
                    try{& $directoryCase.Command @directoryArguments|Out-Null}catch{$directoryCaught=$_}
                    $directoryCaught | Should Not BeNullOrEmpty
                    $directoryCaught.Exception.GetType().Name | Should Be 'PlatformNotImplementedException'
                    $directoryCaught.Exception.Capability | Should Be $directoryCase.Capability
                    $directoryCaught.Exception.ImplementationStep | Should Be 'P11'
                }
                Remove-Module $adapter -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Scenario: Every reviewed entry point carries its own platform-runtime manifest trust anchor.
    # Purpose: Keep all independent pins synchronized with the canonical manifest before executable code is imported.
    It 'UnitT35_keeps_platform_runtime_entry_pins_synchronized' {
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $manifestBytes = [IO.File]::ReadAllBytes($script:ModuleManifest)
        if ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 239 -and $manifestBytes[1] -eq 187 -and $manifestBytes[2] -eq 191) {
            throw 'The platform runtime manifest must not have a BOM.'
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $expected = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($utf8.GetString($manifestBytes).Replace("`r`n", "`n"))))).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }

        $entryPoints = @(
            @{ Path = 'scripts/Invoke-PesterShardProcess.ps1'; Function = 'Import-PesterShardRuntime'; Variable = 'manifestSha256' },
            @{ Path = 'scripts/Invoke-StandardValidation.ps1'; Function = 'Initialize-StandardValidationPlatformRuntime'; Variable = 'pin' },
            @{ Path = 'scripts/StandardSemanticBridge.psm1'; Function = 'Initialize-StandardSemanticBridgePlatformRuntime'; Variable = 'pin' },
            @{ Path = 'scripts/install-ai-instructions-bootstrap.ps1'; Function = 'Assert-InstallerPlatformRuntimeSourceInventory'; Variable = 'expectedManifestSha256' }
        )
        foreach ($entryPoint in $entryPoints) {
            $tokens = $null
            $errors = $null
            $path = Join-Path $script:RepositoryRoot $entryPoint.Path
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should Be 0
            $scope = $ast
            if ($null -ne $entryPoint.Function) {
                $scope = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $entryPoint.Function
                }, $true)
            }
            $assignment = $scope.Find({ param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -ceq $entryPoint.Variable
            }, $true)
            $assignment | Should Not BeNullOrEmpty
            $pin = $assignment.Right.Find({ param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true)
            $pin | Should Not BeNullOrEmpty
            $pin.Value | Should Be $expected
        }
    }

    # Scenario: The host capability receipt is queried for the directory-publication primitive.
    # Purpose: Report Windows availability only after no-replace, identity, and same-filesystem probes; Unix remains explicitly deferred to P11.
    It 'UnitT360_reports_directory_publication_from_native_probe_evidence' {
        $receipt=Get-PlatformCapabilities -Required @()
        $capability=@($receipt.capabilities|Where-Object name -ceq 'directory-publication')
        $capability.Count|Should Be 1
        $schema=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/schemas/runtime-bundle-v3.schema.json')|ConvertFrom-Json
        (@($receipt.capabilities.name|Sort-Object)-join ',')|Should Be (@($schema.properties.requiredCapabilities.items.enum|Sort-Object)-join ',')
        if($script:ExpectedOs -ceq 'windows'){
            $capability[0].status|Should Be 'available'
            $capability[0].evidence.Count|Should Be 1
            $evidence=$capability[0].evidence[0]
            (@($evidence.PSObject.Properties.Name|Sort-Object)-join ',')|Should Be 'identityPreserved,noReplace,sameFileSystem'
            $evidence.noReplace|Should Match 'rejected an existing destination'
            $evidence.identityPreserved|Should Match 'file ID'
            $evidence.sameFileSystem|Should Match 'same volume'
        }
        else{
            $capability[0].status|Should Be 'unavailable'
            $capability[0].evidence[0].implementation|Should Match 'P11'
        }
    }

    # Scenario: The manifest and imported module expose the two directory mutation façades.
    # Purpose: Keep FunctionsToExport synchronized with the callable platform-runtime API.
    It 'UnitT370_exports_the_directory_mutation_facades_exactly_once' {
        $manifest=Import-PowerShellDataFile -LiteralPath $script:ModuleManifest
        $module=@(Get-Module platform-runtime)[0]
        foreach($name in @('Get-PlatformDirectoryState','Move-PlatformOwnedDirectory','Remove-PlatformOwnedDirectoryTree')){
            @($manifest.FunctionsToExport|Where-Object{[string]$_ -ceq $name}).Count|Should Be 1
            @($module.ExportedCommands.Keys|Where-Object{[string]$_ -ceq $name}).Count|Should Be 1
        }
    }

    # Scenario: One child process imports the same runtime twice, then a source-modified copy.
    # Purpose: Reuse an identical sealed build and reject a different verified source build already loaded in-process.
    It 'InterT36_rejects_a_different_loaded_runtime_build' {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('platform-runtime-build-' + [Guid]::NewGuid().ToString('N'))
        $copyRoot = Join-Path $tempRoot 'copy'
        $childScript = Join-Path $tempRoot 'verify-runtime-build.ps1'
        try {
            [void][IO.Directory]::CreateDirectory($copyRoot)
            $sourceRoot = Join-Path $script:RepositoryRoot 'scripts'
            $manifest = Import-PowerShellDataFile -LiteralPath $script:ModuleManifest
            foreach ($relative in @($manifest.FileList)) {
                $destination = Join-Path $copyRoot $relative
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                [IO.File]::Copy((Join-Path $sourceRoot $relative), $destination, $false)
            }
            $changedSource = Join-Path $copyRoot 'platform/PlatformNative.cs'
            [IO.File]::AppendAllText($changedSource, "`n// runtime fingerprint regression", [Text.UTF8Encoding]::new($false))
            $utf8 = [Text.UTF8Encoding]::new($false, $true)
            $changedBytes = [IO.File]::ReadAllBytes($changedSource)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $changedHash = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($utf8.GetString($changedBytes).Replace("`r`n", "`n"))))).Replace('-', '').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
            $oldHash = [string](@($manifest.PrivateData.PlatformRuntime.Inventory | Where-Object Path -ceq 'platform/PlatformNative.cs')[0].Sha256)
            $copyManifest = Join-Path $copyRoot 'platform-runtime.psd1'
            $manifestText = [IO.File]::ReadAllText($copyManifest)
            if (-not $manifestText.Contains($oldHash)) { throw 'Fixture manifest did not contain the expected source hash.' }
            [IO.File]::WriteAllText($copyManifest, $manifestText.Replace($oldHash, $changedHash), [Text.UTF8Encoding]::new($false))
            $childText = @'
param([string]$OriginalManifest,[string]$OriginalModule,[string]$ChangedModule)
$ErrorActionPreference = 'Stop'
Import-Module -Name $OriginalManifest -Force -ErrorAction Stop
Import-Module -Name $OriginalModule -Force -ErrorAction Stop
try {
    Import-Module -Name $ChangedModule -Force -ErrorAction Stop
    throw 'A different runtime build was accepted.'
}
catch {
    if (-not $_.Exception.Message.Contains('different platform runtime build is already loaded')) { throw }
}
'same-source-reimported-and-different-source-rejected'
'@
            [IO.File]::WriteAllText($childScript, $childText, [Text.UTF8Encoding]::new($false))
            $shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            $output = @(& $shell -NoLogo -NoProfile -NonInteractive -File $childScript $script:ModuleManifest (Join-Path $sourceRoot 'platform-runtime.psm1') (Join-Path $copyRoot 'platform-runtime.psm1'))
            $LASTEXITCODE | Should Be 0
            $output[-1] | Should Be 'same-source-reimported-and-different-source-rejected'
        }
        finally {
            if ([IO.Directory]::Exists($tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    # Scenario: The current host is Windows and can load the Windows-only adapter and identity primitives.
    # Purpose: Register these tests only where Windows reparse, lease, and module semantics apply; Unix hosts must not report them as skips.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: The Windows adapter wraps the retained safe directory guard.
    # Purpose: Preserve verified installer delegation while extending ancestor protection.
    It 'UnitT40_delegates_windows_directory_arguments_to_the_existing_installer_function' {
        $root = Join-Path $TestDrive 'delegation-root'
        New-Item -ItemType Directory -Path (Join-Path $root 'child/path') -Force | Out-Null
        Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform/Windows.psm1') -Force
        $lease = Open-WindowsPlatformDirectory -Root $root -RelativePath 'child/path'
        try { $lease | Should Not BeNullOrEmpty }
        finally {
            if ($null -ne $lease) { $lease.Dispose() }
            Remove-Module Windows -Force
        }
    }

    # Scenario: The caller session defines a malicious command with the same name as a verified dependency export.
    # Purpose: Bind delegation to the full-path module object instead of ambient PowerShell name resolution.
    It 'UnitT42_ignores_an_ambient_same_name_installer_function' {
        $root = Join-Path $TestDrive 'ambient-shadow-root'
        New-Item -ItemType Directory -Path (Join-Path $root 'child') -Force | Out-Null
        $global:Syp353AmbientGuardCalled = $false
        function global:Open-InstallerMutationDirectoryGuard {
            $global:Syp353AmbientGuardCalled = $true
            throw 'Ambient installer mutation command executed.'
        }

        $lease = $null
        try {
            Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform/Windows.psm1') -Force
            $lease = Open-WindowsPlatformDirectory -Root $root -RelativePath 'child'
            $lease | Should Not BeNullOrEmpty
            $global:Syp353AmbientGuardCalled | Should Be $false
        }
        finally {
            if ($null -ne $lease) { $lease.Dispose() }
            Remove-Module Windows -Force -ErrorAction SilentlyContinue
            Remove-Item Function:\Open-InstallerMutationDirectoryGuard -Force -ErrorAction SilentlyContinue
            Remove-Variable Syp353AmbientGuardCalled -Scope Global -Force -ErrorAction SilentlyContinue
        }
    }

    # Scenario: A caller supplies a pathname instead of a live lease.
    # Purpose: A serialized or path-only value cannot authorize a handle-bound identity assertion.
    It 'InterT45_rejects_a_path_instead_of_a_live_lease' {
        $path = Join-Path $TestDrive 'identity-target.txt'
        Set-Content -LiteralPath $path -Value 'original' -Encoding UTF8
        $expected = [pscustomobject]@{ volumeSerial = 1; fileIndex = 1 }
        Remove-Item -LiteralPath $path -Force
        Set-Content -LiteralPath $path -Value 'replacement' -Encoding UTF8

        Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform/Windows.psm1') -Force
        $caught = $null
        try { Assert-WindowsPlatformFileIdentity -Lease $path -Expected $expected -SingleLink }
        catch { $caught = $_ }

        # A pathname is not a lease and must never authorize an identity assertion.
        $caught | Should Not BeNullOrEmpty
        Remove-Module Windows -Force
    }
    }

    # Scenario: A distributed module closure gains a file or a declared file changes after review.
    # Purpose: Refuse import when the bound platform runtime inventory is no longer exact.
    It 'InterT50_rejects_extra_and_content_tampered_module_closures' {
        $extraFixture = Join-Path $TestDrive 'extra'
        Copy-PlatformRuntimeFixture -Destination $extraFixture
        Set-Content -LiteralPath (Join-Path $extraFixture 'platform/unreviewed.ps1') -Value '# extra' -Encoding UTF8
        { Import-Module (Join-Path $extraFixture 'platform-runtime.psd1') -Force -ErrorAction Stop } | Should Throw 'implementation directory contains missing or extra files'

        $changedFixture = Join-Path $TestDrive 'changed'
        Copy-PlatformRuntimeFixture -Destination $changedFixture
        Add-Content -LiteralPath (Join-Path $changedFixture 'platform/Linux.psm1') -Value '# tampered' -Encoding UTF8
        { Import-Module (Join-Path $changedFixture 'platform-runtime.psd1') -Force -ErrorAction Stop } | Should Throw 'inventory hash mismatch: platform/Linux.psm1'
        foreach ($relative in @('platform/UnixNative.cs','platform/WindowsNative.cs','platform/Unix.psm1','platform/RuntimePreparation.psm1','Resolve-StandardValidationTool.ps1')) {
            $nativeFixture = Join-Path $TestDrive ('changed-' + [IO.Path]::GetFileName($relative))
            Copy-PlatformRuntimeFixture -Destination $nativeFixture
            Add-Content -LiteralPath (Join-Path $nativeFixture $relative) -Value 'tampered' -Encoding UTF8
            { Import-Module (Join-Path $nativeFixture 'platform-runtime.psd1') -Force -ErrorAction Stop } | Should Throw "inventory hash mismatch: $relative"
        }
    }

    # Scenario: The Windows installer mutation native source is absent from a distributed runtime closure.
    # Purpose: Refuse import before the adapter can resolve an unbound native implementation.
    It 'InterT55_rejects_a_missing_installer_mutation_dependency' {
        $fixture = Join-Path $TestDrive 'missing-installer-dependency'
        Copy-PlatformRuntimeFixture -Destination $fixture
        Remove-Item -LiteralPath (Join-Path $fixture 'platform/WindowsInstallerMutation.cs') -Force

        { Import-Module (Join-Path $fixture 'platform-runtime.psd1') -Force -ErrorAction Stop } | Should Throw 'implementation directory contains missing or extra files'
    }

    # Scenario: The retained Windows mutation dependency changes after its runtime inventory was reviewed.
    # Purpose: Refuse import when delegated code no longer matches the bound SHA-256.
    It 'InterT60_rejects_a_tampered_installer_mutation_dependency' {
        $fixture = Join-Path $TestDrive 'tampered-installer-dependency'
        Copy-PlatformRuntimeFixture -Destination $fixture
        Add-Content -LiteralPath (Join-Path $fixture 'platform/WindowsInstallerMutation.cs') -Value '// tampered' -Encoding UTF8

        { Import-Module (Join-Path $fixture 'platform-runtime.psd1') -Force -ErrorAction Stop } | Should Throw 'inventory hash mismatch: platform/WindowsInstallerMutation.cs'
    }
}

Describe 'Platform P2 root directory leases' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
    }
    # Scenario: Open an existing filesystem root twice, without creating or changing anything beneath it.
    # Purpose: Root-only leases preserve no-follow identity checks without permitting empty relative paths.
    It 'InterT10_opens_and_verifies_existing_filesystem_root' {
        $root = [IO.Path]::GetPathRoot($PSHOME)
        $first = Open-PlatformDirectory -Root $root -RootOnly
        try {
            $second = Open-PlatformDirectory -Root $root -RootOnly
            try {
                $observed = Assert-PlatformFileIdentity -Lease $second -Expected $first.Observation -VerifyPath
                $observed.Kind | Should Be 'directory'
                $observed.Inode | Should Be $first.Observation.Inode
                { $first.WriteNewBytes([byte[]]@(1)) } | Should Throw
                { Open-PlatformDirectory -Root $root -RelativePath '' } | Should Throw
                { Open-PlatformDirectory -Root $root -RootOnly -CreatePrivate } | Should Throw
            } finally { $second.Dispose() }
        } finally { $first.Dispose() }
    }
}

Describe 'Platform P2 primitives' {
    BeforeAll {
        $script:P2Manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1'
        Import-Module $script:P2Manifest -Force
        $script:P2Root = [IO.Path]::GetFullPath($TestDrive)
        if ($IsLinux -or $IsMacOS) {
            # Pester's macOS temp path may traverse /var -> /private/var. Resolve only
            # the trusted fixture anchor; unsafe-path tests below retain their links.
            $physical = '/'
            foreach ($part in $script:P2Root.Trim('/').Split('/')) {
                $item = [IO.DirectoryInfo]::new((Join-Path $physical $part))
                $target = $item.ResolveLinkTarget($true)
                $physical = if ($null -eq $target) { $item.FullName } else { $target.FullName }
            }
            $script:P2Root = $physical
        }
        function Invoke-P2LockChild {
            param([string] $Directory, [string] $Mode)
            $child = @'
$ErrorActionPreference = 'Stop'
Import-Module '__MANIFEST__' -Force
$parent = Open-PlatformDirectory -Root '__ROOT__' -RelativePath '__DIRECTORY__'
try {
    try {
        $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode '__MODE__' -Timeout ([TimeSpan]::FromMilliseconds(150))
        $lease.Dispose()
        exit 0
    } catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [TimeoutException]) { exit 71 }
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 72
    }
} finally { $parent.Dispose() }
'@
            $child = $child.Replace('__MANIFEST__',$script:P2Manifest.Replace("'","''")).Replace('__ROOT__',$script:P2Root.Replace("'","''")).Replace('__DIRECTORY__',$Directory).Replace('__MODE__',$Mode)
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Process -Id $PID).Path
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child)))) { $start.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $start
            try {
                [void]$process.Start()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); throw 'Child lock probe timed out.' }
                $output = $stdout.GetAwaiter().GetResult()
                $errorText = $stderr.GetAwaiter().GetResult()
                if ($process.ExitCode -notin @(0,71)) { throw "Child failed: $output $errorText" }
                return $process.ExitCode
            } finally { $process.Dispose() }
        }
        function Assert-P2EquivalentDacl {
            param([string] $Actual, [string] $Expected)
            $actualDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Actual)
            $expectedDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Expected)
            $actualBytes = [byte[]]::new($actualDescriptor.DiscretionaryAcl.BinaryLength)
            $expectedBytes = [byte[]]::new($expectedDescriptor.DiscretionaryAcl.BinaryLength)
            $actualDescriptor.DiscretionaryAcl.GetBinaryForm($actualBytes,0)
            $expectedDescriptor.DiscretionaryAcl.GetBinaryForm($expectedBytes,0)
            [Convert]::ToBase64String($actualBytes) | Should Be ([Convert]::ToBase64String($expectedBytes))
            # SetSecurityInfo can canonicalize the informational AUTO_INHERITED bit.
            # Compare the actual ACE bytes and protection boundary, not SDDL spelling.
            ($actualDescriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) |
                Should Be ($expectedDescriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)
        }
    }

    # Scenario: A caller creates a directory and a file using only relative child names.
    # Purpose: Exercise real leases, create-only, identity, and handle-free evidence.
    It 'InterT10_opens_safe_directories_and_files_without_truncating' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'safe' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try {
                $observation = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink
                $observation.Kind | Should Be 'file'
                ($observation | ConvertTo-Json) | Should Not Match 'handle'
                { Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew } | Should Throw
            } finally { $file.Dispose() }
            [IO.File]::WriteAllText((Join-Path $script:P2Root 'safe/data'), 'preserve')
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode OpenExisting
            try { $file.Observation.Size | Should Be 8 } finally { $file.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: An evidence producer writes a new file through its lease and reads it with a bound.
    # Purpose: Keep bytes attached to the verified identity without reopening a pathname or invoking P7.
    It 'InterT15_reads_and_writes_create_only_evidence_through_the_lease' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'lease-io' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'evidence' -Access ReadWrite -CreateMode CreateNew
            try {
                $file.WriteNewBytes([byte[]]@(1,2,3))
                [Convert]::ToBase64String($file.ReadAllBytes(3)) | Should Be 'AQID'
                { $file.ReadAllBytes(2) } | Should Throw
                { $file.WriteNewBytes([byte[]]@(4)) } | Should Throw
            } finally { $file.Dispose() }
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'evidence' -Access ReadWrite -CreateMode OpenExisting
            try {
                { $file.WriteNewBytes([byte[]]@(4)) } | Should Throw
                [Convert]::ToBase64String($file.ReadAllBytes(3)) | Should Be 'AQID'
            } finally { $file.Dispose() }
            { $file.ReadAllBytes(3) } | Should Throw
        } finally { $parent.Dispose() }
    }

    if ($IsLinux -or $IsMacOS) {
        # Scenario: A lease's pathname is replaced between creation and data I/O on a Unix host.
        # Purpose: Revalidate identity before read/write and preserve the replacement's sentinel bytes.
        It 'InterT17_rejects_lease_io_after_unix_identity_substitution' {
            $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'lease-io-substitution' -CreatePrivate
            try {
                $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
                try {
                    $path = Join-Path $script:P2Root 'lease-io-substitution/data'
                    [IO.File]::Move($path,($path+'.retained'))
                    [IO.File]::WriteAllText($path,'outside-sentinel')
                    { $file.WriteNewBytes([byte[]]@(1,2,3)) } | Should Throw
                    { $file.ReadAllBytes(100) } | Should Throw
                    [IO.File]::ReadAllText($path) | Should Be 'outside-sentinel'
                } finally { $file.Dispose() }
            } finally { $parent.Dispose() }
        }
    }

    # Scenario: Untrusted child paths contain traversal, empty, or absolute components.
    # Purpose: Reject lexical escapes before any create operation.
    It 'InterT20_rejects_unsafe_relative_paths' {
        foreach ($relative in @('../escape','a/../escape','/absolute','a//b','a/','C:/absolute','a/./b')) {
            { Open-PlatformDirectory -Root $script:P2Root -RelativePath $relative -CreatePrivate } | Should Throw
        }
    }

    # Scenario: A caller requests the implemented P2 capability set.
    # Purpose: Require actual probe evidence including the selected lock primitive.
    It 'InterT30_probes_p2_capabilities_and_records_lock_primitive' {
        $receipt = Get-PlatformCapabilities -Required @()
        foreach ($capability in @($receipt.capabilities | Where-Object name -in @('directory-lease','file-lease','file-identity','lock','permissions'))) {
            if ($capability.status -ne 'available') { throw ($capability.evidence | ConvertTo-Json -Depth 5 -Compress) }
        }
        Get-PlatformCapabilities -Required @('directory-lease','file-lease','file-identity','lock','permissions') | Out-Null
        ($receipt.capabilities | Where-Object name -eq 'lock').evidence.lockPrimitive | Should Be $(if ($IsWindows) { 'windows-fileshare' } else { 'flock' })
    }

    # Scenario: A closed file is renamed and another file takes its old name.
    # Purpose: Expected identity compares device/inode (Windows volume/file ID), not pathname.
    It 'InterT40_rejects_replacement_against_a_recorded_identity' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'replacement' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            $expected = $file.Observation
            $file.Dispose()
            [IO.File]::Move((Join-Path $script:P2Root 'replacement/data'),(Join-Path $script:P2Root 'replacement/old'))
            $replacement = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try { { Assert-PlatformFileIdentity -Lease $replacement -Expected $expected -SingleLink } | Should Throw }
            finally { $replacement.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: A file API receives a path, directory, unsupported mode, or disposed lease.
    # Purpose: Fail before opening an unintended object and reject use after Dispose.
    It 'InterT45_rejects_invalid_file_arguments_and_disposed_leases' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'arguments' -CreatePrivate
        try {
            foreach ($leaf in @('../data','a/b','/absolute','C:/absolute','.','..')) {
                { Open-PlatformFile -ParentLease $parent -Leaf $leaf -Access Read -CreateMode OpenExisting } | Should Throw
            }
            { Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access Read -CreateMode OpenOrCreate } | Should Throw
            { Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access Unknown -CreateMode CreateNew } | Should Throw
            [IO.Directory]::CreateDirectory((Join-Path $script:P2Root 'arguments/directory')) | Out-Null
            { Open-PlatformFile -ParentLease $parent -Leaf 'directory' -Access Read -CreateMode OpenExisting } | Should Throw
        } finally { $parent.Dispose() }
        { Assert-PlatformFileIdentity -Lease $parent -Expected $parent.Observation } | Should Throw
        { Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew } | Should Throw
        $parent.Dispose()
    }

    # Scenario: Independent pwsh processes use the shared/exclusive protocol on one inode.
    # Purpose: Prove cross-process contention, including shared coexistence and both exclusive conflicts.
    It 'InterT50_enforces_shared_exclusive_locks_across_processes' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'process-lock' -CreatePrivate
        try {
            $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::Zero)
            try {
                Invoke-P2LockChild 'process-lock' 'Shared' | Should Be 0
                Invoke-P2LockChild 'process-lock' 'Exclusive' | Should Be 71
            } finally { $lease.Dispose() }
            $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            try {
                Invoke-P2LockChild 'process-lock' 'Shared' | Should Be 71
                Invoke-P2LockChild 'process-lock' 'Exclusive' | Should Be 71
            } finally { $lease.Dispose() }
            Invoke-P2LockChild 'process-lock' 'Exclusive' | Should Be 0
        } finally { $parent.Dispose() }
    }

    # Scenario: The current host provides Unix ownership, mode, and flock semantics.
    # Purpose: Register Unix lock-initialization tests only on Linux and macOS; Windows must not report them as skips.
    if (
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux) -or
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)
    ) {
    # Scenario: Two non-root processes first acquire a missing lock while its creator
    # deliberately holds the real 0000 -> 0600 initialization window open.
    # Purpose: Deterministically reproduce EEXIST/EACCES and require both public lock
    # callers to succeed on the same inode without weakening no-follow/single-link checks.
    It 'InterT52_retries_unix_simultaneous_first_lock_initialization_across_processes' {
        $relative = 'first-lock-race'
        $path = Join-Path $script:P2Root $relative
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath $relative -CreatePrivate
        $children = [Collections.Generic.List[object]]::new()
        try {
            # Root bypasses mode-based EACCES and would make this regression vacuous.
            $parent.Observation.Uid | Should Not Be 0
            Test-Path -LiteralPath (Join-Path $path 'lock') | Should Be $false
            $childTemplate = @'
$ErrorActionPreference = 'Stop'
Import-Module '__MANIFEST__' -Force
$path = '__PATH__'
$role = '__ROLE__'
$parent = Open-PlatformDirectory -Root '__ROOT__' -RelativePath 'first-lock-race'
$lease = $null; $initial = $null
function Wait-Marker([string] $Name) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $path $Name))) {
        if ($timer.Elapsed.TotalSeconds -gt 20) { throw "Marker deadline expired: $Name" }
        Start-Sleep -Milliseconds 10
    }
}
try {
    [IO.File]::WriteAllText((Join-Path $path ('ready-' + $role)), 'ready')
    Wait-Marker 'start'
    if ($role -eq 'creator') {
        # Test fixture models the kernel-visible creation window without a
        # production test hook or another hand-written variadic P/Invoke.
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew
        $options.Access = [IO.FileAccess]::ReadWrite
        $options.Share = [IO.FileShare]::ReadWrite
        $options.UnixCreateMode = [IO.UnixFileMode]0
        $initial = [IO.FileStream]::new((Join-Path $path 'lock'),$options)
        if ([int][IO.File]::GetUnixFileMode((Join-Path $path 'lock')) -ne 0) { throw 'Fixture did not create mode 0000.' }
        [IO.File]::WriteAllText((Join-Path $path 'created'), '0000')
        Wait-Marker 'initialize'
        [IO.File]::SetUnixFileMode((Join-Path $path 'lock'),[IO.UnixFileMode]384)
        $initial.Dispose(); $initial = $null
    } else {
        Wait-Marker 'created'
        [IO.File]::WriteAllText((Join-Path $path 'attempting'), 'attempting')
    }
    $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::FromSeconds(15))
    [IO.File]::WriteAllText((Join-Path $path ('acquired-' + $role)),($lease.Observation | ConvertTo-Json -Compress))
    Wait-Marker 'done'
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 72
} finally {
    if ($null -ne $lease) { $lease.Dispose() }
    if ($null -ne $initial) { $initial.Dispose() }
    $parent.Dispose()
}
'@
            foreach ($role in @('creator','contender')) {
                $child = $childTemplate.Replace('__MANIFEST__',$script:P2Manifest.Replace("'","''")).Replace('__PATH__',$path.Replace("'","''")).Replace('__ROOT__',$script:P2Root.Replace("'","''")).Replace('__ROLE__',$role)
                $start = [Diagnostics.ProcessStartInfo]::new()
                $start.FileName = (Get-Process -Id $PID).Path
                $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                foreach ($argument in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child)))) { $start.ArgumentList.Add($argument) }
                $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
                try { [void]$process.Start() } catch { $process.Dispose(); throw }
                $children.Add([pscustomobject]@{ Role=$role; Process=$process; Output=$process.StandardOutput.ReadToEndAsync(); Error=$process.StandardError.ReadToEndAsync() })
            }
            function Wait-P2RaceMarker([string] $Name) {
                $timer = [Diagnostics.Stopwatch]::StartNew()
                while (-not [IO.File]::Exists((Join-Path $path $Name))) {
                    foreach ($child in $children) {
                        if ($child.Process.HasExited) { throw "Child $($child.Role) exited before ${Name}: $($child.Error.GetAwaiter().GetResult())" }
                    }
                    if ($timer.Elapsed.TotalSeconds -gt 20) { throw "Parent marker deadline expired: $Name" }
                    Start-Sleep -Milliseconds 10
                }
            }
            Wait-P2RaceMarker 'ready-creator'; Wait-P2RaceMarker 'ready-contender'
            [IO.File]::WriteAllText((Join-Path $path 'start'),'start')
            Wait-P2RaceMarker 'attempting'
            [int][IO.File]::GetUnixFileMode((Join-Path $path 'lock')) | Should Be 0
            # The old implementation exits here with EACCES. Keep the initializer
            # gated until the contender has had a scheduling window to attempt open.
            $contender = $children | Where-Object Role -eq 'contender'
            if ($contender.Process.WaitForExit(500)) { throw "Contender failed during initialization: $($contender.Error.GetAwaiter().GetResult())" }
            Test-Path -LiteralPath (Join-Path $path 'acquired-contender') | Should Be $false
            [IO.File]::WriteAllText((Join-Path $path 'initialize'),'initialize')
            Wait-P2RaceMarker 'acquired-creator'; Wait-P2RaceMarker 'acquired-contender'
            [IO.File]::WriteAllText((Join-Path $path 'done'),'done')
            foreach ($child in $children) {
                $child.Process.WaitForExit(10000) | Should Be $true
                if ($child.Process.ExitCode -ne 0) { throw $child.Error.GetAwaiter().GetResult() }
            }
            $creatorIdentity = [IO.File]::ReadAllText((Join-Path $path 'acquired-creator')) | ConvertFrom-Json
            $contenderIdentity = [IO.File]::ReadAllText((Join-Path $path 'acquired-contender')) | ConvertFrom-Json
            $contenderIdentity.Device | Should Be $creatorIdentity.Device
            $contenderIdentity.Inode | Should Be $creatorIdentity.Inode
            $contenderIdentity.LinkCount | Should Be 1
            [int][IO.File]::GetUnixFileMode((Join-Path $path 'lock')) | Should Be 384
        } finally {
            foreach ($child in $children) {
                if (-not $child.Process.HasExited) { $child.Process.Kill($true); $child.Process.WaitForExit() }
                $child.Process.Dispose()
            }
            $parent.Dispose()
        }
    }

    # Scenario: An existing single-link lock is read-only, not an initializing inode.
    # Purpose: Ordinary EACCES remains an immediate native failure, not a timeout/retry.
    It 'InterT53_does_not_retry_unix_permission_denial_outside_initialization' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'lock-denied' -CreatePrivate
        try {
            $parent.Observation.Uid | Should Not Be 0
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'lock' -Access ReadWrite -CreateMode CreateNew
            try { Set-PlatformPermissions -Lease $file -Policy @{ Mode=256 } | Out-Null } finally { $file.Dispose() }
            $timer = [Diagnostics.Stopwatch]::StartNew(); $caught = $null
            try { $unexpected = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::FromSeconds(15)); $unexpected.Dispose() } catch { $caught = $_.Exception }
            $caught | Should Not BeNullOrEmpty
            while ($null -ne $caught.InnerException) { $caught = $caught.InnerException }
            $caught.GetType().Name | Should Be 'PlatformErrnoException'
            $caught.Errno | Should Be 13
            $timer.Elapsed.TotalSeconds | Should BeLessThan 5
        } finally { $parent.Dispose() }
    }

    # Scenario: An owned 0000 lock never finishes initialization.
    # Purpose: Initialization waits consume the caller's deadline and cannot spin forever.
    It 'InterT54_bounds_unix_lock_initialization_wait_by_the_deadline' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'lock-initialization-timeout' -CreatePrivate
        try {
            $parent.Observation.Uid | Should Not Be 0
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'lock' -Access ReadWrite -CreateMode CreateNew
            try { Set-PlatformPermissions -Lease $file -Policy @{ Mode=0 } | Out-Null } finally { $file.Dispose() }
            $timer = [Diagnostics.Stopwatch]::StartNew(); $caught = $null
            try { $unexpected = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::FromMilliseconds(150)); $unexpected.Dispose() } catch { $caught = $_.Exception }
            $caught | Should Not BeNullOrEmpty
            while ($null -ne $caught.InnerException) { $caught = $caught.InnerException }
            $caught.GetType().Name | Should Be 'TimeoutException'
            $timer.Elapsed.TotalMilliseconds | Should BeGreaterThan 100
            $timer.Elapsed.TotalSeconds | Should BeLessThan 5
            [int][IO.File]::GetUnixFileMode((Join-Path $script:P2Root 'lock-initialization-timeout/lock')) | Should Be 0
        } finally { $parent.Dispose() }
    }
    }

    # Scenario: A lock is released and reacquired.
    # Purpose: Preserve the lock pathname and inode; release must never unlink.
    It 'InterT55_retains_lock_inode_after_release' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'retained-lock' -CreatePrivate
        try {
            $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            $expected = $lease.Observation
            $lease.Dispose(); $lease.Dispose()
            Test-Path -LiteralPath (Join-Path $script:P2Root 'retained-lock/lock') | Should Be $true
            $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::Zero)
            try { (Assert-PlatformFileIdentity -Lease $lease -Expected $expected -SingleLink).Inode | Should Be $expected.Inode }
            finally { $lease.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: A caller reads directory and file permission observations.
    # Purpose: Evidence contains permissions but never native handles.
    It 'InterT60_returns_handle_free_permission_observations' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'permission-read' -CreatePrivate
        try {
            $permissions = Get-PlatformPermissions -Lease $parent
            ($permissions | ConvertTo-Json) | Should Not Match 'handle'
            if ($IsWindows) { $permissions.Sddl | Should Match '^D:' }
            else { $permissions.Kind | Should Be 'unix-mode'; $permissions.Mode | Should Be '700' }
        } finally { $parent.Dispose() }
    }

    # Scenario: The caller disposes its parent before disposing the child.
    # Purpose: A file lease owns the parent reference needed for name revalidation.
    It 'InterT65_retains_parent_resources_for_a_live_child' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'lifetime' -CreatePrivate
        $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
        $parent.Dispose()
        try { (Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink).Kind | Should Be 'file' }
        finally { $file.Dispose() }
    }

    # Scenario: The current host provides Unix symlink, descriptor, mode, and ABI semantics.
    # Purpose: Register Unix filesystem tests only on Linux and macOS; Windows must not report them as skips.
    if (
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux) -or
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)
    ) {
    # Scenario: A Unix file leaf is a symlink to an ordinary file.
    # Purpose: O_NOFOLLOW rejects the link for file and lock acquisition.
    It 'InterT70_rejects_unix_symlink_leaves' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'symlink-leaf' -CreatePrivate
        try {
            $path = Join-Path $script:P2Root 'symlink-leaf'
            [IO.File]::WriteAllText((Join-Path $path 'target'),'target')
            [IO.File]::CreateSymbolicLink((Join-Path $path 'alias'),'target') | Out-Null
            { Open-PlatformFile -ParentLease $parent -Leaf 'alias' -Access Read -CreateMode OpenExisting } | Should Throw
            { Enter-PlatformLock -ParentLease $parent -Leaf 'alias' -Mode Exclusive -Timeout ([TimeSpan]::Zero) } | Should Throw
        } finally { $parent.Dispose() }
    }

    # Scenario: A symlink occurs inside RelativePath or inside Root itself.
    # Purpose: Validate every ancestor from the physical filesystem anchor.
    It 'InterT72_rejects_unix_symlink_ancestors_including_root' {
        $target = Join-Path $script:P2Root 'ancestor-target'
        [IO.Directory]::CreateDirectory((Join-Path $target 'child')) | Out-Null
        $alias = Join-Path $script:P2Root 'ancestor-alias'
        [IO.Directory]::CreateSymbolicLink($alias,$target) | Out-Null
        { Open-PlatformDirectory -Root $script:P2Root -RelativePath 'ancestor-alias/child' } | Should Throw
        { Open-PlatformDirectory -Root $alias -RelativePath 'child' } | Should Throw
        { Open-PlatformDirectory -Root $alias -RootOnly } | Should Throw
    }

    # Scenario: A dangling link is encountered during private directory or file creation.
    # Purpose: Missing targets must not turn no-follow checks into path-following creation.
    It 'InterT74_rejects_unix_dangling_links' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'dangling' -CreatePrivate
        try {
            [IO.File]::CreateSymbolicLink((Join-Path $script:P2Root 'dangling/link'),'absent') | Out-Null
            { Open-PlatformDirectory -Root $script:P2Root -RelativePath 'dangling/link/child' -CreatePrivate } | Should Throw
            { Open-PlatformFile -ParentLease $parent -Leaf 'link' -Access ReadWrite -CreateMode CreateNew } | Should Throw
            { Open-PlatformFile -ParentLease $parent -Leaf 'link' -Access Read -CreateMode OpenExisting } | Should Throw
            Test-Path -LiteralPath (Join-Path $script:P2Root 'dangling/absent') | Should Be $false
        } finally { $parent.Dispose() }
    }

    # Scenario: A second hard link is introduced after opening a single-link file.
    # Purpose: fstat observes nlink=2 and both new opens and ownership assertions refuse it.
    It 'InterT76_rejects_unix_multiple_hard_links' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'unix-hardlink' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try {
                New-Item -ItemType HardLink -Path (Join-Path $script:P2Root 'unix-hardlink/alias') -Target (Join-Path $script:P2Root 'unix-hardlink/data') | Out-Null
                (Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation).LinkCount | Should Be 2
                { Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink } | Should Throw
                { Open-PlatformFile -ParentLease $parent -Leaf 'alias' -Access Read -CreateMode OpenExisting } | Should Throw
                { Enter-PlatformLock -ParentLease $parent -Leaf 'data' -Mode Exclusive -Timeout ([TimeSpan]::Zero) } | Should Throw
            } finally { $file.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: CreateNew must return a usable 0600 file even on Darwin arm64's varargs ABI.
    # Purpose: Inspect mode before any permission setter can mask a broken openat creation mode.
    It 'InterT78_verifies_unix_creation_mode_before_reopening' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'creation-mode' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try {
                ($file.Observation.Mode -band 4095) | Should Be 384
                [int][IO.File]::GetUnixFileMode((Join-Path $script:P2Root 'creation-mode/data')) | Should Be 384
                [IO.File]::WriteAllText((Join-Path $script:P2Root 'creation-mode/data'),'usable')
                [IO.File]::ReadAllText((Join-Path $script:P2Root 'creation-mode/data')) | Should Be 'usable'
            } finally { $file.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: CreatePrivate creates multiple nested Unix directories.
    # Purpose: Every new segment has exactly 0700, independently checked through .NET.
    It 'InterT80_creates_unix_private_directories_with_mode_0700' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'private/nested' -CreatePrivate
        try {
            foreach ($relative in @('private','private/nested')) {
                [int][IO.File]::GetUnixFileMode((Join-Path $script:P2Root $relative)) | Should Be 448
            }
        } finally { $parent.Dispose() }
    }

    # Scenario: A caller applies mode bits and then requests ACL support.
    # Purpose: fchmod readback is exact; unsupported ACL policies produce a typed failure.
    It 'InterT82_applies_unix_fchmod_and_refuses_acl_policy' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'chmod' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try {
                (Set-PlatformPermissions -Lease $file -Policy @{ Mode=416 }).Mode | Should Be '640'
                [int][IO.File]::GetUnixFileMode((Join-Path $script:P2Root 'chmod/data')) | Should Be 416
                $caught = $null
                try { Set-PlatformPermissions -Lease $file -Policy @{ Acl='unsupported' } } catch { $caught = $_ }
                $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
                [int][IO.File]::GetUnixFileMode((Join-Path $script:P2Root 'chmod/data')) | Should Be 416
            } finally { $file.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: The active libc/stat ABI is validated before native primitives run.
    # Purpose: Require independent size/mode and nlink checks instead of an assumed layout.
    It 'InterT84_passes_unix_abi_runtime_self_check' {
        $abi = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ValidateAbi()
        $abi | Should Match 'stat/fstatat size, type, mode, uid, gid, inode, nlink( and st_flags)? self-test passed'
        $abi | Should Match 'create mode 0000 -> 0600 verified'
        $receipt = Get-PlatformCapabilities -Required @('file-identity')
        ($receipt.capabilities | Where-Object name -eq 'file-identity').evidence.abi | Should Match '^(linux|macos)-(x64|arm64):'
    }

    # Scenario: A still-open file is renamed and a replacement occupies its original name.
    # Purpose: fstatat must detect replacement even when fstat and Expected still match.
    It 'InterT86_rejects_unix_name_replacement_while_file_is_open' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'live-replacement' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try {
                [IO.File]::Move((Join-Path $script:P2Root 'live-replacement/data'),(Join-Path $script:P2Root 'live-replacement/old'))
                [IO.File]::WriteAllText((Join-Path $script:P2Root 'live-replacement/data'),'replacement')
                { Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink } | Should Throw
            } finally { $file.Dispose() }
        } finally { $parent.Dispose() }
    }

    # Scenario: A noncooperating Unix writer replaces a held lock's pathname.
    # Purpose: Expose the A1 limit, detect identity loss, and never unlink the replacement on release.
    It 'InterT88_detects_unix_lock_substitution_without_unlinking' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'lock-substitution' -CreatePrivate
        try {
            $lease = Enter-PlatformLock -ParentLease $parent -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            try {
                [IO.File]::Move((Join-Path $script:P2Root 'lock-substitution/lock'),(Join-Path $script:P2Root 'lock-substitution/old'))
                [IO.File]::WriteAllText((Join-Path $script:P2Root 'lock-substitution/lock'),'replacement')
                { Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -SingleLink } | Should Throw
            } finally { $lease.Dispose() }
            [IO.File]::ReadAllText((Join-Path $script:P2Root 'lock-substitution/lock')) | Should Be 'replacement'
        } finally { $parent.Dispose() }
    }

    # Scenario: The probe directory is renamed and an unrelated empty directory replaces it.
    # Purpose: Failed identity validation must preserve the replacement and expose cleanup evidence.
    It 'InterT89_preserves_replaced_unix_probe_directory_and_cleanup_evidence' {
        $result = & (Get-Module platform-runtime) {
            param($FixtureRoot)
            $name = 'cleanup-replacement'
            $path = Join-Path $FixtureRoot $name
            $moved = Join-Path $FixtureRoot ($name + '-moved')
            $directory = Open-PlatformDirectory -Root $FixtureRoot -RelativePath $name -CreatePrivate
            [IO.Directory]::Move($path,$moved)
            [IO.Directory]::CreateDirectory($path) | Out-Null
            $evidence = [ordered]@{}
            Clear-PlatformProbe -Directory $directory -Path $path -Entries @() -Evidence $evidence
            [pscustomobject]@{
                replacementExists = [IO.Directory]::Exists($path)
                originalExists = [IO.Directory]::Exists($moved)
                cleanupFailure = $evidence['cleanupFailure']
            }
        } $script:P2Root
        $result.replacementExists | Should Be $true
        $result.originalExists | Should Be $true
        $result.cleanupFailure | Should Not BeNullOrEmpty
    }
    }

    # Scenario: The current host provides Windows junction, hard-link, FileShare, and DACL semantics.
    # Purpose: Register Windows filesystem tests only on Windows; Linux and macOS must not report them as skips.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: A Windows junction appears in the child path or Root ancestors.
    # Purpose: Preserve no-reparse guards and cover the root-ancestor gap in the old helper.
    It 'InterT90_rejects_windows_junctions_including_root_ancestors' {
        $target = Join-Path $script:P2Root 'junction-target'
        [IO.Directory]::CreateDirectory((Join-Path $target 'child')) | Out-Null
        $alias = Join-Path $script:P2Root 'junction-alias'
        New-Item -ItemType Junction -Path $alias -Target $target | Out-Null
        try {
            { Open-PlatformDirectory -Root $script:P2Root -RelativePath 'junction-alias/child' } | Should Throw
            { Open-PlatformDirectory -Root $alias -RelativePath 'child' } | Should Throw
            { Open-PlatformDirectory -Root $alias -RootOnly } | Should Throw
            $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'junction-target'
            try { { Open-PlatformFile -ParentLease $parent -Leaf 'child' -Access Read -CreateMode OpenExisting } | Should Throw }
            finally { $parent.Dispose() }
        } finally { [IO.Directory]::Delete($alias) }
    }

    # Scenario: A Windows regular file has two directory entries.
    # Purpose: NumberOfLinks rejects aliases for file and lock leases.
    It 'InterT92_rejects_windows_multiple_hard_links' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'windows-hardlink' -CreatePrivate
        try {
            [IO.File]::WriteAllText((Join-Path $script:P2Root 'windows-hardlink/data'),'data')
            New-Item -ItemType HardLink -Path (Join-Path $script:P2Root 'windows-hardlink/alias') -Target (Join-Path $script:P2Root 'windows-hardlink/data') | Out-Null
            { Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access Read -CreateMode OpenExisting } | Should Throw
            { Enter-PlatformLock -ParentLease $parent -Leaf 'alias' -Mode Exclusive -Timeout ([TimeSpan]::Zero) } | Should Throw
        } finally { $parent.Dispose() }
    }

    # Scenario: A Windows lease changes read-only attributes and restores its DACL.
    # Purpose: Permissions stay handle-bound; sharing still denies outside write and rename.
    It 'InterT94_preserves_windows_dacl_readonly_and_share_guards' {
        $parent = Open-PlatformDirectory -Root $script:P2Root -RelativePath 'windows-permissions' -CreatePrivate
        try {
            $file = Open-PlatformFile -ParentLease $parent -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
            try {
                $snapshot = Get-PlatformPermissions -Lease $file
                (Set-PlatformPermissions -Lease $file -Policy @{ ReadOnly=$true }).ReadOnly | Should Be $true
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                try { $privateDacl = 'D:P(A;;FA;;;' + $identity.User.Value + ')' } finally { $identity.Dispose() }
                $changed = Set-PlatformPermissions -Lease $file -Policy @{ Sddl=$privateDacl }
                Assert-P2EquivalentDacl $changed.Sddl $privateDacl
                $changed.ReadOnly | Should Be $true
                (Set-PlatformPermissions -Lease $file -Policy @{ Sddl=$snapshot.Sddl; ReadOnly=$false }).ReadOnly | Should Be $false
                Assert-P2EquivalentDacl (Get-PlatformPermissions -Lease $file).Sddl $snapshot.Sddl
                { [IO.File]::WriteAllText((Join-Path $script:P2Root 'windows-permissions/data'),'outside') } | Should Throw
                { [IO.File]::Move((Join-Path $script:P2Root 'windows-permissions/data'),(Join-Path $script:P2Root 'windows-permissions/moved')) } | Should Throw
            } finally { $file.Dispose() }
        } finally { $parent.Dispose() }
    }
    }
}

Describe 'Unix P7c durable publication and removal' {
    $script:P7cSetfacl = @(Get-Command setfacl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    $script:P7cChattr = @(Get-Command chattr -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    $script:P7cId = @(Get-Command id -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    $p7cIsRoot = $IsLinux -and $script:P7cId.Count -gt 0 -and ((& $script:P7cId[0].Source -u 2>$null | Out-String).Trim()) -ceq '0'
    $p7cSupportsAccessAcl = $false
    $p7cSupportsDefaultAcl = $false
    $p7cSupportsNodump = $false
    $p7cSupportsDeniedFlags = $false
    $p7cSupportsSetgid = $false
    $p7cSupportsUnsafeTargetTypes = $false

    if ($IsLinux -or $IsMacOS) {
        $p7cProbeRoot = Join-Path ([IO.Path]::GetTempPath()) "syp-354-p7c-$([Guid]::NewGuid().ToString('N'))"
        try {
            [void][IO.Directory]::CreateDirectory($p7cProbeRoot)
            if ($IsLinux -and $script:P7cSetfacl.Count -gt 0) {
                $accessAclPath = Join-Path $p7cProbeRoot 'access-acl'
                [IO.File]::WriteAllText($accessAclPath, 'probe')
                & $script:P7cSetfacl[0].Source -m 'u:12345:r--' $accessAclPath 2>$null
                $p7cSupportsAccessAcl = $LASTEXITCODE -eq 0

                $defaultAclPath = Join-Path $p7cProbeRoot 'default-acl'
                [void][IO.Directory]::CreateDirectory($defaultAclPath)
                & $script:P7cSetfacl[0].Source -d -m 'u::rwx,g::r-x,o::---' $defaultAclPath 2>$null
                $p7cSupportsDefaultAcl = $LASTEXITCODE -eq 0
            }
            if ($IsLinux -and $script:P7cChattr.Count -gt 0) {
                $nodumpPath = Join-Path $p7cProbeRoot 'nodump'
                [IO.File]::WriteAllText($nodumpPath, 'probe')
                & $script:P7cChattr[0].Source +d $nodumpPath 2>$null
                $p7cSupportsNodump = $LASTEXITCODE -eq 0
                if ($p7cSupportsNodump) { & $script:P7cChattr[0].Source -d $nodumpPath 2>$null | Out-Null }

                if ($p7cIsRoot) {
                    $p7cSupportsDeniedFlags = $true
                    foreach ($flag in @('i','a')) {
                        $deniedFlagPath = Join-Path $p7cProbeRoot "denied-$flag"
                        [IO.File]::WriteAllText($deniedFlagPath, 'probe')
                        & $script:P7cChattr[0].Source "+$flag" $deniedFlagPath 2>$null
                        $flagApplied = $LASTEXITCODE -eq 0
                        if ($flagApplied) { & $script:P7cChattr[0].Source "-$flag" $deniedFlagPath 2>$null | Out-Null }
                        $p7cSupportsDeniedFlags = $p7cSupportsDeniedFlags -and $flagApplied
                    }
                }
            }

            $chmod = @(Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            $stat = @(Get-Command stat -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($chmod.Count -gt 0 -and $stat.Count -gt 0) {
                $setgidPath = Join-Path $p7cProbeRoot 'setgid'
                [void][IO.Directory]::CreateDirectory($setgidPath)
                & $chmod[0].Source 2700 $setgidPath 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $setgidMode = if ($IsLinux) { (& $stat[0].Source -c '%a' $setgidPath 2>$null | Out-String).Trim() } else { (& $stat[0].Source -f '%Lp' $setgidPath 2>$null | Out-String).Trim() }
                    $p7cSupportsSetgid = $LASTEXITCODE -eq 0 -and $setgidMode -match '^2[0-7]{3}$'
                }
            }

            $mkfifo = @(Get-Command mkfifo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($mkfifo.Count -gt 0) {
                try {
                    $targetTypePath = Join-Path $p7cProbeRoot 'target-types'
                    [void][IO.Directory]::CreateDirectory($targetTypePath)
                    $realPath = Join-Path $targetTypePath 'real'
                    [IO.File]::WriteAllText($realPath, 'probe')
                    [void][IO.File]::CreateSymbolicLink((Join-Path $targetTypePath 'symlink'), 'real')
                    New-Item -ItemType HardLink -Path (Join-Path $targetTypePath 'hardlink') -Target $realPath | Out-Null
                    & $mkfifo[0].Source (Join-Path $targetTypePath 'fifo') 2>$null
                    $p7cSupportsUnsafeTargetTypes = $LASTEXITCODE -eq 0
                }
                catch { $p7cSupportsUnsafeTargetTypes = $false }
            }
        }
        finally {
            if (Test-Path -LiteralPath $p7cProbeRoot) { Remove-Item -LiteralPath $p7cProbeRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/ai-instructions-runtime-contract.psm1') -Force
        $script:P7cRoot = Join-Path $TestDrive 'p7c-root'
        [void][IO.Directory]::CreateDirectory($script:P7cRoot)

        function New-P7cDirectory([string]$Relative) { Open-PlatformDirectory -Root $script:P7cRoot -RelativePath $Relative -CreatePrivate }
        function New-P7cTransaction {
            $id = [Guid]::NewGuid().ToString('N')
            [pscustomobject]@{ Id=$id; Lease=(New-P7cDirectory ".ai-instructions-txn/$id") }
        }
        function New-P7cFile($Parent,[string]$Leaf,[string]$Text) {
            $lease = Open-PlatformFile -ParentLease $Parent -Leaf $Leaf -Access ReadWrite -CreateMode CreateNew
            $lease.WriteNewBytes([Text.UTF8Encoding]::new($false).GetBytes($Text))
            return $lease
        }
        function Get-P7cState($Lease) {
            $observed = Assert-PlatformFileIdentity -Lease $Lease -Expected $Lease.Observation -SingleLink
            [pscustomobject][ordered]@{
                exists=$true
                sha256=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetSha256($Lease)
                length=[long]$observed.Size
                identity=[pscustomobject][ordered]@{
                    kind='unix-device-inode'
                    device=([uint64]$observed.Device).ToString([Globalization.CultureInfo]::InvariantCulture)
                    fileId=([uint64]$observed.Inode).ToString([Globalization.CultureInfo]::InvariantCulture)
                }
            }
        }
        function Get-P7cStageState($Lease) {
            $state = Get-P7cState $Lease
            [pscustomobject][ordered]@{ exists=$true;sha256=$state.sha256;length=$state.length;identity=$state.identity }
        }
        function Get-P7cAbsentState { [pscustomobject][ordered]@{ exists=$false; sha256=$null; length=$null; identity=$null } }
        function Read-P7cText($Parent,[string]$Leaf) {
            $lease = Open-PlatformFile -ParentLease $Parent -Leaf $Leaf -Access Read -CreateMode OpenExisting
            try { [Text.UTF8Encoding]::new($false).GetString($lease.ReadAllBytes(1048576)) } finally { $lease.Dispose() }
        }
        function New-P7cJournalOperation {
            param(
                [string]$TargetRelativePath,[string]$Kind,[string]$Method,[AllowNull()][string]$StageLeaf,
                [AllowNull()][string]$BackupLeaf,$Original,$Applied,[AllowNull()]$Permissions
            )
            $operation=[pscustomobject][ordered]@{
                sequence=1;kind=$Kind;method=$Method;targetRelativePath=$TargetRelativePath
                stageLeaf=$StageLeaf;backupLeaf=$BackupLeaf;quarantineLeaf=$null;original=$Original
                backupIdentity=$(if([bool]$Original.exists){$Original.identity}else{$null})
                applied=$Applied;permissions=$Permissions;state='pending'
            }
            $journal=New-AiInstructionsInstallJournalV1 -OwnerComponent installer -OwnerProcessId 1 -OwnerProcessStartIdentity 'p7c-test' `
                -PlatformOs $(if($IsMacOS){'macos'}else{'linux'}) -PlatformArchitecture x64 -LockPrimitive flock -LockLeaf install.lock `
                -CandidateBundleSha256 ('a'*64) -Phase prepared -Operations @($operation)
            return $journal.operations[0]
        }
        function New-P7cAppliedState($StageState) {
            [pscustomobject][ordered]@{ exists=$true;sha256=$StageState.sha256;length=$StageState.length;identity=$StageState.identity }
        }
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: A 0640 target is replaced by a transaction stage.
    # Purpose: Preserve mode/uid/gid and move the original inode to DisplacedLeaf.
    It 'InterT500_preserves_unix_metadata_and_original_inode_during_write' {
        $parent=New-P7cDirectory 'write'; $txn=New-P7cTransaction; $target=$null; $stage=$null; $backup=$null
        try {
            $target=New-P7cFile $parent 'target' 'original'; Set-PlatformPermissions -Lease $target -Policy @{Mode=416}|Out-Null
            $original=Get-P7cState $target; $permissions=Get-PlatformPermissions $target; $target.Dispose(); $target=$null
            $stage=New-P7cFile $txn.Lease 'stage' 'replacement'; $expectedStage=Get-P7cStageState $stage
            $receipt=Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $original -DisplacedLeaf original -ExpectedStage $expectedStage
            (Read-P7cText $parent target)|Should Be 'replacement'
            $receipt.permissions.mode|Should Be '640'; $receipt.permissions.uid|Should Be $permissions.uid; $receipt.permissions.gid|Should Be $permissions.gid
            $receipt.durability|Should Be 'confirmed'
            $backup=Open-PlatformFile -ParentLease $txn.Lease -Leaf original -Access Read -CreateMode OpenExisting
            $backup.Observation.Inode|Should Be ([uint64]$original.identity.fileId)
        } finally { if($null-ne$backup){$backup.Dispose()};if($null-ne$stage){$stage.Dispose()};if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose();$parent.Dispose() }
    }

    # Scenario: A stage is published to an absent target.
    # Purpose: New targets use explicit mode 0600 while retaining supported target-parent inheritance semantics.
    It 'InterT505_publishes_new_unix_files_with_default_mode_0600' {
        $parent=New-P7cDirectory 'create';$txn=New-P7cTransaction;$stage=$null;$published=$null
        try {
            $stage=New-P7cFile $txn.Lease stage 'created';$stageState=Get-P7cStageState $stage
            $receipt=Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $stageState
            $published=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting
            (Get-PlatformPermissions $published).mode|Should Be '600';$receipt.displacedIdentity|Should BeNullOrEmpty
            (@($receipt.completedSteps)-contains 'destination-preflight')|Should Be $true
        } finally {if($null-ne$published){$published.Dispose()};if($null-ne$stage){$stage.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Expected hash, length, or identity differs from the current target.
    # Purpose: Every state mismatch fails before either directory entry is renamed.
    It 'InterT510_rejects_unix_target_state_mismatches_without_mutation' {
        foreach($variant in @('hash','length','identity')){
            $parent=New-P7cDirectory "mismatch-$variant";$txn=New-P7cTransaction;$target=$null;$stage=$null
            try{
                $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
                $bad=[pscustomobject][ordered]@{exists=$true;sha256=$state.sha256;length=$state.length;identity=[pscustomobject][ordered]@{kind=$state.identity.kind;device=$state.identity.device;fileId=$state.identity.fileId}}
                if($variant-eq'hash'){$bad.sha256='0'*64}elseif($variant-eq'length'){$bad.length++}else{$bad.identity.fileId=([uint64]$bad.identity.fileId+1).ToString()}
                $stage=New-P7cFile $txn.Lease stage replacement
                {Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $bad -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)}|Should Throw
                (Read-P7cText $parent target)|Should Be original
                Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
            }finally{if($null-ne$stage){$stage.Dispose()};if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
        }
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    # Capability condition: the temporary filesystem must support symlinks, hard links, FIFOs, and mkfifo.
    if (($IsLinux -or $IsMacOS) -and $p7cSupportsUnsafeTargetTypes) {
    # Scenario: Target names resolve to symlink, hard-link, FIFO, or directory objects.
    # Purpose: No-follow and single-regular-file checks reject all unsafe target types without rename.
    It 'InterT515_rejects_unsafe_unix_target_types_without_mutation' {
        $fake=[pscustomobject]@{exists=$true;sha256='0'*64;length=0;identity=[pscustomobject]@{kind='unix-device-inode';device='1';fileId='1'}}
        foreach($kind in @('symlink','hardlink','fifo','directory')){
            $parent=New-P7cDirectory "type-$kind";$txn=New-P7cTransaction;$stage=$null
            try{
                $path=Join-Path $script:P7cRoot "type-$kind"
                if($kind-eq'symlink'){[IO.File]::WriteAllText((Join-Path $path real),'real');[IO.File]::CreateSymbolicLink((Join-Path $path target),'real')|Out-Null}
                elseif($kind-eq'hardlink'){[IO.File]::WriteAllText((Join-Path $path real),'real');New-Item -ItemType HardLink -Path (Join-Path $path target) -Target (Join-Path $path real)|Out-Null}
                elseif($kind-eq'fifo'){$mkfifo=@(Get-Command mkfifo -CommandType Application -ErrorAction Stop)[0];& $mkfifo.Source (Join-Path $path target);$LASTEXITCODE|Should Be 0}
                else{[IO.Directory]::CreateDirectory((Join-Path $path target))|Out-Null}
                $stage=New-P7cFile $txn.Lease stage replacement
                {Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $fake -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)}|Should Throw
                Test-Path -LiteralPath (Join-Path $path target)|Should Be $true
            }finally{if($null-ne$stage){$stage.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
        }
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: Stage authority, displacement exclusivity, and NoReplace preconditions are violated.
    # Purpose: Publication refuses each condition before changing target or stage names.
    It 'InterT520_enforces_transaction_stage_and_noreplace_boundaries' {
        $parent=New-P7cDirectory boundary;$txn=New-P7cTransaction;$outside=New-P7cDirectory outside;$outsideStage=$null;$target=$null;$stage=$null;$collision=$null
        try{
            $outsideStage=New-P7cFile $outside stage outside
            {Publish-PlatformFile -ParentLease $parent -Leaf absent -TransactionLease $txn.Lease -StageLease $outsideStage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage (Get-P7cStageState $outsideStage)}|Should Throw
            $target=New-P7cFile $parent target original;$targetState=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement;$collision=New-P7cFile $txn.Lease backup occupied
            {Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $targetState -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)}|Should Throw
            (Read-P7cText $parent target)|Should Be original
            $collision.Dispose();$collision=$null
            {Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $targetState -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage) -NoReplace}|Should Throw
            (Read-P7cText $parent target)|Should Be original;(Read-P7cText $txn.Lease stage)|Should Be replacement
        }finally{foreach($lease in @($collision,$stage,$target,$outsideStage)){if($null-ne$lease){$lease.Dispose()}};$outside.Dispose();$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: A completed write is rolled back by publishing its displaced original.
    # Purpose: Symmetric rename restores the original inode and tombstones the applied inode without copying.
    It 'InterT525_rolls_back_by_rename_with_original_inode_unchanged' {
        $parent=New-P7cDirectory rollback;$txn=New-P7cTransaction;$target=$null;$stage=$null;$originalLease=$null;$appliedLease=$null
        try{
            $target=New-P7cFile $parent target original;$original=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease newstage applied;$newState=Get-P7cStageState $stage
            Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $original -DisplacedLeaf original -ExpectedStage $newState|Out-Null
            $appliedLease=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting;$applied=Get-P7cState $appliedLease;$appliedLease.Dispose();$appliedLease=$null
            $originalLease=Open-PlatformFile -ParentLease $txn.Lease -Leaf original -Access Read -CreateMode OpenExisting
            Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $originalLease -ExpectedState $applied -DisplacedLeaf newstage -ExpectedStage (Get-P7cStageState $originalLease)|Out-Null
            $restored=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting
            try{$restored.Observation.Inode|Should Be ([uint64]$original.identity.fileId);[Text.UTF8Encoding]::new($false).GetString($restored.ReadAllBytes(64))|Should Be original}finally{$restored.Dispose()}
        }finally{foreach($lease in @($appliedLease,$originalLease,$stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: An owned target is tombstoned, then explicitly cleaned inside its private transaction directory.
    # Purpose: Both rename and cleanup preserve/verify the inode; unlinkat is unreachable outside the private root.
    It 'InterT530_tombstones_then_cleans_only_a_private_transaction_leaf' {
        $parent=New-P7cDirectory remove;$txn=New-P7cTransaction;$target=$null;$tombstone=$null
        try{
            $target=New-P7cFile $parent target owned;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $receipt=Remove-PlatformOwnedFile -ParentLease $parent -Leaf target -ExpectedState $state -TransactionLease $txn.Lease -TombstoneLeaf tombstone
            $receipt.method|Should Be 'tombstone-rename';Test-Path -LiteralPath (Join-Path $script:P7cRoot remove/target)|Should Be $false
            (@($receipt.completedSteps)-contains 'destination-preflight')|Should Be $true
            $tombstone=Open-PlatformFile -ParentLease $txn.Lease -Leaf tombstone -Access Read -CreateMode OpenExisting;$tombstone.Observation.Inode|Should Be ([uint64]$state.identity.fileId);$tombstone.Dispose();$tombstone=$null
            $cleanup=Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf tombstone -ExpectedState $state
            $cleanup.method|Should Be 'cleanup-unlinkat';Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/tombstone")|Should Be $false
            (@($cleanup.completedSteps)-contains 'destination-preflight')|Should Be $true
            {Remove-PlatformOwnedFile -ParentLease $parent -Leaf target -ExpectedState $state -TransactionLease $parent -TombstoneLeaf target}|Should Throw
        }finally{foreach($lease in @($tombstone,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    # Capability condition: setfacl and access ACLs must be supported by the temporary filesystem.
    if ($IsLinux -and $p7cSupportsAccessAcl) {
    # Scenario: Linux target metadata contains system.posix_acl_access.
    # Purpose: Extended ACL ownership is never partially replaced by mode-only publication.
    It 'InterT535_fails_closed_for_linux_posix_acl_targets' {
        $parent=New-P7cDirectory acl;$txn=New-P7cTransaction;$target=$null;$stage=$null
        try{
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            & $script:P7cSetfacl[0].Source -m 'u:12345:r--' (Join-Path $script:P7cRoot 'acl/target') 2>$null
            $LASTEXITCODE|Should Be 0
            $stage=New-P7cFile $txn.Lease stage replacement;$caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformCapabilityUnavailableException';(Read-P7cText $parent target)|Should Be original
        }finally{if($null-ne$stage){$stage.Dispose()};if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: Capability reporting is requested on the same Unix host that performs publication.
    # Purpose: Probe evidence must name the tested no-replace primitive and directory fsync, not infer support from OS.
    It 'InterT540_matches_unix_capabilities_to_live_publication_probe' {
        $receipt=Get-PlatformCapabilities -Required @('publication','owned-file-removal','permissions')
        foreach($name in @('publication','owned-file-removal','permissions')){($receipt.capabilities|Where-Object name -eq $name).status|Should Be available}
        (($receipt.capabilities|Where-Object name -eq publication).evidence -join ' ')|Should Match 'renameat(2|x_np).*fsync'
    }

    # Scenario: Two journal operations share SKILL.md as their leaf, and one operation names a different parent lease.
    # Purpose: Bind the caller-supplied operation by its full target path and reject parent confusion before mutation.
    It 'InterT545_binds_one_journal_operation_by_full_parent_path' {
        $parent=New-P7cDirectory 'journal-a';$wrongParent=New-P7cDirectory 'journal-wrong';$txn=New-P7cTransaction
        $target=$null;$wrongTarget=$null;$stage=$null;$wrongStage=$null
        try {
            $target=New-P7cFile $parent 'SKILL.md' 'a-original';$original=Get-P7cState $target;$permissions=Get-PlatformPermissions $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease 'stage-a' 'a-applied';$stageState=Get-P7cStageState $stage
            $operations=@(
                (New-P7cJournalOperation -TargetRelativePath 'journal-a/SKILL.md' -Kind write-file -Method stage-rename -StageLeaf stage-a -BackupLeaf backup-a -Original $original -Applied (New-P7cAppliedState $stageState) -Permissions $permissions),
                (New-P7cJournalOperation -TargetRelativePath 'journal-b/SKILL.md' -Kind write-file -Method stage-rename -StageLeaf stage-b -BackupLeaf backup-b -Original $original -Applied (New-P7cAppliedState $stageState) -Permissions $permissions)
            )
            Publish-PlatformFile -ParentLease $parent -Leaf 'SKILL.md' -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $original -DisplacedLeaf backup-a -ExpectedStage $stageState -Journal $operations[0] | Out-Null
            (Read-P7cText $parent 'SKILL.md') | Should Be 'a-applied'

            $wrongTarget=New-P7cFile $wrongParent 'SKILL.md' 'wrong-original';$wrongOriginal=Get-P7cState $wrongTarget;$wrongPermissions=Get-PlatformPermissions $wrongTarget;$wrongTarget.Dispose();$wrongTarget=$null
            $wrongStage=New-P7cFile $txn.Lease 'stage-wrong' 'wrong-applied';$wrongStageState=Get-P7cStageState $wrongStage
            $wrongOperation=New-P7cJournalOperation -TargetRelativePath 'journal-a/SKILL.md' -Kind write-file -Method stage-rename -StageLeaf stage-wrong -BackupLeaf backup-wrong -Original $wrongOriginal -Applied (New-P7cAppliedState $wrongStageState) -Permissions $wrongPermissions
            $caught=$null
            try { Publish-PlatformFile -ParentLease $wrongParent -Leaf 'SKILL.md' -TransactionLease $txn.Lease -StageLease $wrongStage -ExpectedState $wrongOriginal -DisplacedLeaf backup-wrong -ExpectedStage $wrongStageState -Journal $wrongOperation | Out-Null } catch { $caught=$_.Exception }
            $caught.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Capability | Should Be 'publication'
            (Read-P7cText $wrongParent 'SKILL.md') | Should Be 'wrong-original'
            (Read-P7cText $txn.Lease 'stage-wrong') | Should Be 'wrong-applied'
            (Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup-wrong")) | Should Be $false
        } finally { foreach($lease in @($wrongStage,$stage,$wrongTarget,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$wrongParent.Dispose();$parent.Dispose() }
    }

    # Scenario: Journal permissions record mode 0600, but the live target is changed to 0640 before publication.
    # Purpose: Refuse stale permission ownership evidence before either target or stage is renamed.
    It 'InterT550_rejects_journal_permission_drift_without_mutation' {
        $parent=New-P7cDirectory 'journal-permissions';$txn=New-P7cTransaction;$target=$null;$stage=$null
        try {
            $target=New-P7cFile $parent target original;$original=Get-P7cState $target;$journalPermissions=Get-PlatformPermissions $target
            Set-PlatformPermissions -Lease $target -Policy @{Mode=416} | Out-Null
            $target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
            $operation=New-P7cJournalOperation -TargetRelativePath 'journal-permissions/target' -Kind write-file -Method stage-rename -StageLeaf stage -BackupLeaf backup -Original $original -Applied (New-P7cAppliedState $stageState) -Permissions $journalPermissions
            $caught=$null
            try { Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $original -DisplacedLeaf backup -ExpectedStage $stageState -Journal $operation | Out-Null } catch { $caught=$_.Exception }
            $caught.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Capability | Should Be 'publication'
            (Read-P7cText $parent target) | Should Be original
            (Read-P7cText $txn.Lease stage) | Should Be replacement
            (Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")) | Should Be $false
        } finally { foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose() }
    }

    # Scenario: A test barrier renames the target parent after durable publication and before pathname post-check.
    # Purpose: Return a typed recovery receipt and leave the durable applied/backup entries untouched.
    It 'InterT555_reports_post_publication_parent_move_without_compensation' {
        $parent=New-P7cDirectory 'post-parent';$txn=New-P7cTransaction;$target=$null;$stage=$null
        $sourcePath=Join-Path $script:P7cRoot 'post-parent';$movedPath=Join-Path $script:P7cRoot 'post-parent-moved'
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $parent target original;$original=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'publication-after-fsync-before-postcheck'){[IO.Directory]::Move($sourcePath,$movedPath)}})
            $caught=$null
            try { Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $original -DisplacedLeaf backup -ExpectedStage $stageState | Out-Null } catch { $caught=$_.Exception }
            $caught.GetType().Name | Should Be 'PlatformMutationException'
            $caught.Capability | Should Be 'publication-post-verification'
            $caught.Receipt.durability | Should Be 'confirmed'
            (@($caught.Receipt.completedSteps) -contains 'stage-published') | Should Be $true
            (@($caught.Receipt.completedSteps) -contains 'transaction-directory-fsynced') | Should Be $true
            $caught.Receipt.appliedIdentity | Should Not BeNullOrEmpty
            $caught.Receipt.displacedIdentity | Should Not BeNullOrEmpty
            [IO.File]::ReadAllText((Join-Path $movedPath target)) | Should Be replacement
            [IO.File]::ReadAllText((Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")) | Should Be original
            (Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/stage")) | Should Be $false
        } finally { $field.SetValue($null,$null);foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose() }
    }

    # Scenario: Publication changes a 0600 stage to the existing target's 0640 ownership snapshot.
    # Purpose: Require the post-permission stage fsync and mode/uid/gid readback before either rename.
    It 'InterT560_fsyncs_and_revalidates_stage_permissions_before_publication' {
        $parent=New-P7cDirectory 'permission-fsync';$txn=New-P7cTransaction;$target=$null;$stage=$null;$published=$null
        try {
            $target=New-P7cFile $parent target original;Set-PlatformPermissions -Lease $target -Policy @{Mode=416}|Out-Null
            $state=Get-P7cState $target;$expectedPermissions=Get-PlatformPermissions $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement
            $receipt=Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)
            $published=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting
            $actualPermissions=Get-PlatformPermissions $published
            $actualPermissions.mode|Should Be '640';$actualPermissions.uid|Should Be $expectedPermissions.uid;$actualPermissions.gid|Should Be $expectedPermissions.gid
            (@($receipt.completedSteps)-contains 'stage-permissions-fsynced')|Should Be $true
            (@($receipt.completedSteps)-contains 'stage-permissions-verified')|Should Be $true
        } finally {foreach($lease in @($published,$stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Private tombstone unlink succeeds, then transaction-directory fsync fails.
    # Purpose: Distinguish an already-deleted entry from a pre-mutation failure with an unconfirmed durability receipt.
    It 'InterT565_reports_cleanup_unlink_before_fsync_failure_as_a_mutation' {
        $txn=New-P7cTransaction;$target=$null;$field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $txn.Lease tombstone owned;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'removal-cleanup-after-unlink-before-fsync'){throw [IO.IOException]::new('injected cleanup fsync failure')}})
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf tombstone -ExpectedState $state|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformMutationException';$caught.Capability|Should Be 'owned-file-removal-durability'
            $caught.Receipt.method|Should Be 'cleanup-unlinkat';$caught.Receipt.durability|Should Be 'unconfirmed'
            $caught.Receipt.flush.file|Should Be $false;$caught.Receipt.flush.fileNotRequired|Should Be $true
            (@($caught.Receipt.completedSteps)-contains 'private-tombstone-unlinked')|Should Be $true
            (@($caught.Receipt.completedSteps)-contains 'transaction-directory-fsynced')|Should Be $false
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/tombstone")|Should Be $false
        } finally {$field.SetValue($null,$null);if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose()}
    }

    # Scenario: The private transaction directory is moved after identity/hash verification and immediately before cleanup unlink.
    # Purpose: Revalidate both directory paths at the mutation boundary and leave the tombstone linked when either path moved.
    It 'InterT570_rejects_moved_cleanup_directory_before_unlink' {
        $txn=New-P7cTransaction;$target=$null;$sourcePath=Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)";$movedPath="$sourcePath-moved"
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $txn.Lease tombstone owned;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'removal-cleanup-before-unlink'){[IO.Directory]::Move($sourcePath,$movedPath)}})
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf tombstone -ExpectedState $state|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformErrnoException'
            [IO.File]::ReadAllText((Join-Path $movedPath tombstone))|Should Be owned
        } finally {$field.SetValue($null,$null);if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose()}
    }

    # Scenario: The publication probe is forced unavailable while the permission-only probe remains operational.
    # Purpose: Prove permissions capability does not inherit rename or directory-fsync probe status.
    It 'InterT575_probes_unix_permissions_independently_from_publication' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('ProbeTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'publication-probe'){throw [IO.IOException]::new('injected publication probe failure')}})
            $receipt=Get-PlatformCapabilities -Required @('permissions')
            ($receipt.capabilities|Where-Object name -eq permissions).status|Should Be available
            (($receipt.capabilities|Where-Object name -eq permissions).evidence -join ' ')|Should Match 'fstat/fchmod.*ACL.*flags'
            ($receipt.capabilities|Where-Object name -eq publication).status|Should Be unavailable
            (($receipt.capabilities|Where-Object name -eq publication).evidence -join ' ')|Should Match 'injected publication probe failure'
        } finally {$field.SetValue($null,$null)}
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    # Capability condition: chattr and FS_NODUMP_FL must be supported by the temporary filesystem.
    if ($IsLinux -and $p7cSupportsNodump) {
    # Scenario: A Linux target carries only FS_NODUMP_FL in addition to ordinary filesystem implementation flags.
    # Purpose: Accept flags outside the explicit deny mask and complete normal stage-to-rename publication.
    It 'InterT580_accepts_linux_nodump_and_implementation_inode_flags' {
        $parent=New-P7cDirectory 'flags-accepted';$txn=New-P7cTransaction;$target=$null;$stage=$null;$targetPath=Join-Path $script:P7cRoot 'flags-accepted/target';$backupPath=Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup"
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            & $script:P7cChattr[0].Source +d $targetPath 2>$null
            $LASTEXITCODE|Should Be 0
            $stage=New-P7cFile $txn.Lease stage replacement
            Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null
            (Read-P7cText $parent target)|Should Be replacement
        } finally {if(Test-Path -LiteralPath $targetPath){& $script:P7cChattr[0].Source -d $targetPath 2>$null|Out-Null};if(Test-Path -LiteralPath $backupPath){& $script:P7cChattr[0].Source -d $backupPath 2>$null|Out-Null};foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    # Capability condition: the Linux runner must be root-capable and support both denied chattr flags.
    if ($IsLinux -and $p7cIsRoot -and $p7cSupportsDeniedFlags) {
    # Scenario: A root-capable Linux fixture applies FS_IMMUTABLE_FL and FS_APPEND_FL to an owned target.
    # Purpose: Fail closed from descriptor-bound flag evidence before target or stage names change, then always clear test flags.
    It 'InterT585_rejects_linux_immutable_or_append_inode_flags_without_mutation' {
        foreach($flag in @('i','a')){
            $parent=New-P7cDirectory "flags-denied-$flag";$txn=New-P7cTransaction;$target=$null;$stage=$null;$targetPath=Join-Path $script:P7cRoot "flags-denied-$flag/target"
            try {
                $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
                & $script:P7cChattr[0].Source "+$flag" $targetPath 2>$null
                $LASTEXITCODE|Should Be 0
                $stage=New-P7cFile $txn.Lease stage replacement;$caught=$null
                try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
                $caught.GetType().Name|Should Be 'PlatformCapabilityUnavailableException'
                (Read-P7cText $parent target)|Should Be original;(Read-P7cText $txn.Lease stage)|Should Be replacement
                Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
            } finally {if(Test-Path -LiteralPath $targetPath){& $script:P7cChattr[0].Source "-$flag" $targetPath 2>$null|Out-Null};foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
        }
    }

    }

    # Scenario: Linux inode-flag integers contain ignored implementation bits or one explicit denied bit.
    # Purpose: Keep deny-mask policy deterministic and testable on Windows without invoking ioctl.
    It 'UnitT590_applies_only_the_explicit_linux_inode_flag_deny_mask' {
        foreach($accepted in @([int]0,[int]0x40,[int]0x00080000,[int]0x10000000,[int]0x00001000,[int]0x00040000)){
            [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::HasDeniedLinuxInodeFlags($accepted)|Should Be $false
        }
        foreach($denied in @([int]0x00000004,[int]0x00000010,[int]0x00000020,[int]0x00000800,[int]0x00800000,[int]0x00100000,[int]0x02000000,[int]0x40000000,[int]0x42900834)){
            [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::HasDeniedLinuxInodeFlags($denied)|Should Be $true
        }
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    # Capability condition: the temporary filesystem must retain setgid directories.
    if (($IsLinux -or $IsMacOS) -and $p7cSupportsSetgid) {
    # Scenario: A new target is published beneath a setgid target directory.
    # Purpose: Apply the target parent's gid to the staged inode before rename and verify the published gid from the retained lease.
    It 'InterT595_inherits_the_setgid_parent_group_for_new_targets' {
        $parent=New-P7cDirectory 'setgid-parent';$txn=New-P7cTransaction;$stage=$null;$published=$null
        try {
            $parentPermissions=Get-PlatformPermissions $parent
            Set-PlatformPermissions -Lease $parent -Policy @{Mode=[Convert]::ToInt32('2700',8)}|Out-Null
            $setgidPermissions=Get-PlatformPermissions $parent
            $setgidBit=[Convert]::ToUInt32('2000',8)
            ([Convert]::ToUInt32($setgidPermissions.mode,8) -band $setgidBit)|Should Be $setgidBit
            $stage=New-P7cFile $txn.Lease stage created
            $receipt=Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage (Get-P7cStageState $stage)
            $published=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting
            $publishedPermissions=Get-PlatformPermissions $published
            $publishedPermissions.gid|Should Be $parentPermissions.gid
            $receipt.permissions.gid|Should Be $parentPermissions.gid
            (@($receipt.completedSteps)-contains 'stage-permissions-fsynced')|Should Be $true
            (@($receipt.completedSteps)-contains 'stage-permissions-verified')|Should Be $true
        } finally {foreach($lease in @($published,$stage)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    # Capability condition: setfacl and default ACLs must be supported by the temporary filesystem.
    if ($IsLinux -and $p7cSupportsDefaultAcl) {
    # Scenario: A Linux target parent supplies a default POSIX ACL for newly created children.
    # Purpose: Fail closed before publication because stage-to-rename cannot reproduce target-directory ACL inheritance.
    It 'InterT600_rejects_default_acl_inheritance_without_moving_target_or_stage' {
        $parent=New-P7cDirectory 'default-acl-parent';$txn=New-P7cTransaction;$stage=$null
        try {
            $parentPath=Join-Path $script:P7cRoot 'default-acl-parent'
            & $script:P7cSetfacl[0].Source -d -m 'u::rwx,g::r-x,o::---' $parentPath 2>$null
            $LASTEXITCODE|Should Be 0
            $stage=New-P7cFile $txn.Lease stage created;$caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformCapabilityUnavailableException'
            $caught.Capability|Should Match 'parent-inheritance-acl'
            Test-Path -LiteralPath (Join-Path $parentPath target)|Should Be $false
            (Read-P7cText $txn.Lease stage)|Should Be created
            @([IO.Directory]::EnumerateFileSystemEntries((Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)"))|Where-Object{[IO.Path]::GetFileName($_)-like'.ai-instructions-preflight-*'}).Count|Should Be 0
        } finally {if($null-ne$stage){$stage.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
    }

    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: Destination directory fsync or no-replace support fails during the operation-local filesystem preflight.
    # Purpose: Return a typed capability failure before target/stage rename and remove every private probe entry.
    It 'InterT605_fails_destination_preflight_without_moving_target_or_stage' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        foreach($case in @(
            [pscustomobject]@{Name='directory-fsync';Point='destination-preflight-before-transaction-fsync';Capability='directory-fsync: EINVAL'},
            [pscustomobject]@{Name='noreplace';Point='destination-preflight-before-noreplace';Capability='publication-noreplace: ENOTSUP'}
        )){
            $parent=New-P7cDirectory "preflight-$($case.Name)";$txn=New-P7cTransaction;$target=$null;$stage=$null
            try {
                $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
                $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
                $failurePoint=$case.Point;$failureCapability=$case.Capability
                $hook={param($point)if($point-ceq$failurePoint){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($failureCapability,[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem())}}.GetNewClosure()
                $field.SetValue($null,[Action[string]]$hook)
                $caught=$null
                try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage $stageState|Out-Null}catch{$caught=$_.Exception}
                $caught.GetType().Name|Should Be 'PlatformCapabilityUnavailableException'
                (Read-P7cText $parent target)|Should Be original
                (Read-P7cText $txn.Lease stage)|Should Be replacement
                Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
                @([IO.Directory]::EnumerateFileSystemEntries((Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)"))|Where-Object{[IO.Path]::GetFileName($_)-like'.ai-instructions-preflight-*'}).Count|Should Be 0
            } finally {$field.SetValue($null,$null);foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
        }
    }

    }

    # Scenario: The P7d1 constructor emits a strict create-file operation including quarantineLeaf=null.
    # Purpose: Unix pure validation accepts the real journal-v1 operation shape on every host before lease-specific checks.
    It 'UnitT690_accepts_the_real_p7d1_unix_file_operation_shape' {
        $absent=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        $applied=[pscustomobject][ordered]@{
            exists=$true;sha256=('b'*64);length=7
            identity=[pscustomobject][ordered]@{kind='unix-device-inode';device='11';fileId='22'}
        }
        $operation=[pscustomobject][ordered]@{
            sequence=1;kind='create-file';method='stage-rename';targetRelativePath='target/file'
            stageLeaf='file.stage';backupLeaf=$null;quarantineLeaf=$null;original=$absent;backupIdentity=$null
            applied=$applied;permissions=$null;state='pending'
        }
        $journal=New-AiInstructionsInstallJournalV1 -OwnerComponent installer -OwnerProcessId 1 -OwnerProcessStartIdentity 'p7c-shape' `
            -PlatformOs linux -PlatformArchitecture x64 -LockPrimitive flock -LockLeaf install.lock `
            -CandidateBundleSha256 ('a'*64) -Phase prepared -Operations @($operation)
        $unixModule=New-Module -Name "P7cUnixShape$([Guid]::NewGuid().ToString('N'))" -ScriptBlock ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform/Unix.psm1'))))
        try {
            { & $unixModule {param($Operation)Assert-UnixJournalOperationShape -Journal $Operation} $journal.operations[0] } | Should Not Throw
            (@($journal.operations[0].PSObject.Properties.Name)-join ',') | Should Be 'sequence,kind,method,targetRelativePath,stageLeaf,backupLeaf,quarantineLeaf,original,backupIdentity,applied,permissions,state'
            $journal.operations[0].quarantineLeaf | Should BeNullOrEmpty
        } finally {Remove-Module -ModuleInfo $unixModule -Force}
    }

    # Scenario: Unix journal applied identity is missing, null, malformed, mismatched, or equal to the retained stage descriptor identity.
    # Purpose: Validate the complete unix-device-inode shape as a publication typed failure without requiring a native Unix host.
    It 'UnitT695_validates_unix_journal_applied_identity_shape_and_binding' {
        $unixModule=Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform/Unix.psm1') -Force -PassThru
        try {
            $stage=[pscustomobject]@{Device=[uint64]11;Inode=[uint64]22}
            $valid=[pscustomobject]@{identity=[pscustomobject][ordered]@{kind='unix-device-inode';device='11';fileId='22'}}
            { & $unixModule {param($applied,$identity) Assert-UnixJournalAppliedIdentity $applied $identity} $valid $stage } | Should Not Throw
            foreach($applied in @(
                [pscustomobject]@{},
                [pscustomobject]@{identity=$null},
                [pscustomobject]@{identity=[pscustomobject]@{kind='windows-file-id';device='11';fileId='22'}},
                [pscustomobject]@{identity=[pscustomobject]@{kind='unix-device-inode';device='11'}},
                [pscustomobject]@{identity=[pscustomobject]@{kind='unix-device-inode';device='11';fileId='23'}}
            )) {
                $caught=$null
                try { & $unixModule {param($value,$identity) Assert-UnixJournalAppliedIdentity $value $identity} $applied $stage } catch { $caught=$_.Exception }
                $caught.GetType().Name | Should Be 'PlatformVerificationException'
                $caught.Capability | Should Be 'publication'
            }
        } finally { Remove-Module $unixModule -Force }
    }

    # Scenario: A removal journal omits backupIdentity or binds it to an inode different from ExpectedState.
    # Purpose: Reject the journal with a typed verification failure before any mutation; this pure binding regression runs on Windows too.
    It 'UnitT610_rejects_removal_backup_identity_drift_before_mutation' {
        $targetPath=Join-Path $TestDrive 'journal-identity-target';$stagePath=Join-Path $TestDrive 'journal-identity-stage'
        [IO.File]::WriteAllText($targetPath,'original');[IO.File]::WriteAllText($stagePath,'staged')
        $expected=[pscustomobject]@{exists=$true;device=[uint64]11;inode=[uint64]22}
        $unixModule=New-Module -Name "P7cUnixBinding$([Guid]::NewGuid().ToString('N'))" -ScriptBlock ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform/Unix.psm1'))))
        try {
            foreach($identity in @($null,[pscustomobject]@{kind='unix-device-inode';device='11';fileId='23'})){
                $journal=[pscustomobject]@{backupIdentity=$identity};$caught=$null
                try{& $unixModule {param($Journal,$Expected)Assert-UnixJournalBackupIdentity -Journal $Journal -ExpectedState $Expected -Required} $journal $expected}catch{$caught=$_.Exception}
                $caught.GetType().Name|Should Be 'PlatformVerificationException'
                $caught.Capability|Should Be 'owned-file-removal'
                [IO.File]::ReadAllText($targetPath)|Should Be original
                [IO.File]::ReadAllText($stagePath)|Should Be staged
            }
            $publicationJournal=[pscustomobject]@{backupIdentity=[pscustomobject]@{kind='unix-device-inode';device='12';fileId='22'}};$caught=$null
            try{& $unixModule {param($Journal,$Expected)Assert-UnixJournalBackupIdentity -Journal $Journal -ExpectedState $Expected} $publicationJournal $expected}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformVerificationException'
        } finally {Remove-Module -ModuleInfo $unixModule -Force}
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: The public Unix removal adapter receives a tombstone journal whose backupIdentity differs from ExpectedState.
    # Purpose: Prove journal binding rejects removal before native rename while preserving the target and empty tombstone name.
    It 'InterT615_rejects_removal_journal_backup_identity_drift_without_mutation' {
        $parent=New-P7cDirectory 'journal-remove';$txn=New-P7cTransaction;$target=$null
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$permissions=Get-PlatformPermissions $target;$target.Dispose();$target=$null
            $operation=New-P7cJournalOperation -TargetRelativePath 'journal-remove/target' -Kind remove-file -Method tombstone-rename -StageLeaf $null -BackupLeaf tombstone -Original $state -Applied (Get-P7cAbsentState) -Permissions $permissions
            $operation.backupIdentity=[pscustomobject][ordered]@{kind='unix-device-inode';device=$state.identity.device;fileId=([uint64]$state.identity.fileId+1).ToString([Globalization.CultureInfo]::InvariantCulture)}
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $parent -Leaf target -ExpectedState $state -TransactionLease $txn.Lease -TombstoneLeaf tombstone -Journal $operation|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformVerificationException'
            $caught.Capability|Should Be 'owned-file-removal'
            (Read-P7cText $parent target)|Should Be original
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/tombstone")|Should Be $false
        } finally {if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Replacement publication and tombstone removal persist original file data before moving either name.
    # Purpose: Record the crash-safe file-fsync/rename/directory-fsync order, including durable backup naming before replacement publication.
    It 'InterT620_records_backup_and_tombstone_fsync_order' {
        $publishParent=New-P7cDirectory 'ordered-publish';$removeParent=New-P7cDirectory 'ordered-remove';$txn=New-P7cTransaction;$target=$null;$stage=$null;$removeTarget=$null
        try {
            $target=New-P7cFile $publishParent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement
            $publish=Publish-PlatformFile -ParentLease $publishParent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)
            $publishOrder=@($publish.completedSteps|Where-Object{$_-in @('stage-file-fsynced','stage-permissions-fsynced','original-file-fsynced','target-displaced','backup-transaction-directory-fsynced','backup-parent-directory-fsynced','stage-published','parent-directory-fsynced','transaction-directory-fsynced')}) -join '|'
            $publishOrder|Should Be 'stage-file-fsynced|stage-permissions-fsynced|original-file-fsynced|target-displaced|backup-transaction-directory-fsynced|backup-parent-directory-fsynced|stage-published|parent-directory-fsynced|transaction-directory-fsynced'
            $publish.flush.directory|Should Be $true;$publish.flush.transactionDirectory|Should Be $true;$publish.durability|Should Be confirmed

            $removeTarget=New-P7cFile $removeParent target owned;$removeState=Get-P7cState $removeTarget;$removeTarget.Dispose();$removeTarget=$null
            $remove=Remove-PlatformOwnedFile -ParentLease $removeParent -Leaf target -ExpectedState $removeState -TransactionLease $txn.Lease -TombstoneLeaf tombstone
            $removeOrder=@($remove.completedSteps|Where-Object{$_-in @('original-file-fsynced','target-tombstoned','transaction-directory-fsynced','parent-directory-fsynced')}) -join '|'
            $removeOrder|Should Be 'original-file-fsynced|target-tombstoned|transaction-directory-fsynced|parent-directory-fsynced'
            $remove.flush.file|Should Be $true;$remove.flush.directory|Should Be $true;$remove.flush.transactionDirectory|Should Be $true;$remove.durability|Should Be confirmed
        } finally {foreach($lease in @($removeTarget,$stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$removeParent.Dispose();$publishParent.Dispose()}
    }

    # Scenario: Transaction-directory fsync fails after target-to-backup rename and before stage publication.
    # Purpose: Return mutation evidence and retain the original inode either durably restored at target or safely named by DisplacedLeaf.
    It 'InterT625_never_loses_original_inode_when_backup_fsync_fails' {
        $parent=New-P7cDirectory 'backup-fsync-failure';$txn=New-P7cTransaction;$target=$null;$stage=$null;$originalLease=$null
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$originalInode=[uint64]$state.identity.fileId;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'publication-before-backup-transaction-fsync'){throw [IO.IOException]::new('injected backup transaction fsync failure')}})
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformMutationException;$caught.Capability|Should Be publication-durability;$caught.Receipt.durability|Should Be unconfirmed
            (@($caught.Receipt.completedSteps)-contains 'target-displaced')|Should Be $true
            (@($caught.Receipt.completedSteps)-contains 'backup-transaction-directory-fsynced')|Should Be $false
            (@($caught.Receipt.completedSteps)-contains 'stage-published')|Should Be $false
            (@($caught.Receipt.completedSteps)-contains 'rollback-displaced-to-target')|Should Be $true
            (@($caught.Receipt.completedSteps)-contains 'rollback-transaction-directory-fsynced')|Should Be $true
            (@($caught.Receipt.completedSteps)-contains 'rollback-parent-directory-fsynced')|Should Be $true
            $targetPath=Join-Path $script:P7cRoot 'backup-fsync-failure/target';$backupPath=Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup"
            $targetExists=Test-Path -LiteralPath $targetPath -PathType Leaf;$backupExists=Test-Path -LiteralPath $backupPath -PathType Leaf
            ($targetExists-xor$backupExists)|Should Be $true
            if($targetExists){$originalLease=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting}else{$originalLease=Open-PlatformFile -ParentLease $txn.Lease -Leaf backup -Access Read -CreateMode OpenExisting}
            $originalLease.Observation.Inode|Should Be $originalInode
            (Read-P7cText $txn.Lease stage)|Should Be replacement
        } finally {$field.SetValue($null,$null);foreach($lease in @($originalLease,$stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: A same-account actor replaces the private tombstone name with a different inode immediately before cleanup unlinkat.
    # Purpose: Revalidate dev/inode, regular-file type, and single-link ownership at the final mutation boundary without unlinking the replacement.
    It 'InterT630_rejects_replaced_tombstone_inode_immediately_before_unlink' {
        $txn=New-P7cTransaction;$target=$null;$txnPath=Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)";$tombstonePath=Join-Path $txnPath tombstone;$originalPath=Join-Path $txnPath original-retained
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $txn.Lease tombstone owned;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'removal-cleanup-before-unlink'){[IO.File]::Move($tombstonePath,$originalPath);[IO.File]::WriteAllText($tombstonePath,'replacement')}})
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf tombstone -ExpectedState $state|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformVerificationException;$caught.Capability|Should Be owned-file-removal
            [IO.File]::ReadAllText($tombstonePath)|Should Be replacement
            [IO.File]::ReadAllText($originalPath)|Should Be owned
        } finally {$field.SetValue($null,$null);if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose()}
    }

    # Scenario: The final transaction-directory fsync fails after all destination-preflight probe leaves are removed.
    # Purpose: Fail before target/stage mutation, leave no live probe name, and report the unavailable durability primitive as typed evidence.
    It 'InterT635_fails_after_preflight_probe_cleanup_without_moving_target_or_stage' {
        $parent=New-P7cDirectory 'preflight-cleanup-fsync';$txn=New-P7cTransaction;$target=$null;$stage=$null
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'destination-preflight-after-probe-cleanup-before-transaction-fsync'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('directory-fsync: EINVAL',[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem())}})
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformCapabilityUnavailableException;$caught.Capability|Should Match directory-fsync
            (Read-P7cText $parent target)|Should Be original;(Read-P7cText $txn.Lease stage)|Should Be replacement
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
            @([IO.Directory]::EnumerateFileSystemEntries((Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)"))|Where-Object{[IO.Path]::GetFileName($_)-like'.ai-instructions-preflight-*'}).Count|Should Be 0
        } finally {$field.SetValue($null,$null);foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Replacement publication fails after stage-to-target rename and rolls both names back.
    # Purpose: Persist each rollback rename destination before its source and restore the original target inode.
    It 'InterT640_orders_publication_rollback_destination_fsync_before_source' {
        $parent=New-P7cDirectory 'publication-rollback-order';$txn=New-P7cTransaction;$target=$null;$stage=$null;$restored=$null
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$originalInode=[uint64]$state.identity.fileId;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'publication-before-parent-fsync'){throw [IO.IOException]::new('injected failure after stage rename')}})
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformMutationException;$caught.Capability|Should Be publication-durability;$caught.Receipt.durability|Should Be unconfirmed
            $rollbackOrder=@($caught.Receipt.completedSteps|Where-Object{$_-in @('stage-published','rollback-stage-to-transaction','rollback-stage-transaction-directory-fsynced','rollback-stage-parent-directory-fsynced','rollback-displaced-to-target','rollback-parent-directory-fsynced','rollback-transaction-directory-fsynced')}) -join '|'
            $rollbackOrder|Should Be 'stage-published|rollback-stage-to-transaction|rollback-stage-transaction-directory-fsynced|rollback-stage-parent-directory-fsynced|rollback-displaced-to-target|rollback-parent-directory-fsynced|rollback-transaction-directory-fsynced'
            $restored=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting
            $restored.Observation.Inode|Should Be $originalInode
            (Read-P7cText $parent target)|Should Be original;(Read-P7cText $txn.Lease stage)|Should Be replacement
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
        } finally {$field.SetValue($null,$null);foreach($lease in @($restored,$stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Tombstone removal fails after target-to-tombstone rename and restores the target.
    # Purpose: Persist the rollback target name before tombstone removal and preserve the original inode identity.
    It 'InterT645_orders_removal_rollback_destination_fsync_before_source' {
        $parent=New-P7cDirectory 'removal-rollback-order';$txn=New-P7cTransaction;$target=$null;$restored=$null
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$originalInode=[uint64]$state.identity.fileId;$target.Dispose();$target=$null
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'removal-before-transaction-fsync'){throw [IO.IOException]::new('injected failure after tombstone rename')}})
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $parent -Leaf target -ExpectedState $state -TransactionLease $txn.Lease -TombstoneLeaf tombstone|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformMutationException;$caught.Capability|Should Be owned-file-removal-durability;$caught.Receipt.durability|Should Be unconfirmed
            $rollbackOrder=@($caught.Receipt.completedSteps|Where-Object{$_-in @('target-tombstoned','rollback-tombstone-to-target','rollback-parent-directory-fsynced','rollback-transaction-directory-fsynced')}) -join '|'
            $rollbackOrder|Should Be 'target-tombstoned|rollback-tombstone-to-target|rollback-parent-directory-fsynced|rollback-transaction-directory-fsynced'
            $restored=Open-PlatformFile -ParentLease $parent -Leaf target -Access Read -CreateMode OpenExisting
            $restored.Observation.Inode|Should Be $originalInode
            (Read-P7cText $parent target)|Should Be original
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/tombstone")|Should Be $false
        } finally {$field.SetValue($null,$null);foreach($lease in @($restored,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: A same-account writer rewrites the stage inode after destination preflight and before publication mutation.
    # Purpose: Revalidate the retained stage descriptor's identity, length, SHA-256, and publication permissions before either name moves.
    It 'InterT650_rejects_in_place_stage_drift_after_preflight_without_moving_names' {
        $parent=New-P7cDirectory 'post-preflight-stage';$txn=New-P7cTransaction;$target=$null;$stage=$null
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        $stagePath=Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/stage"
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'publication-after-preflight-before-revalidation'){[IO.File]::WriteAllText($stagePath,'tampered-stage')}})
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage $stageState|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformVerificationException
            (Read-P7cText $parent target)|Should Be original
            (Read-P7cText $txn.Lease stage)|Should Be 'tampered-stage'
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
        } finally {$field.SetValue($null,$null);foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: A same-account writer rewrites target bytes or changes target mode after destination preflight.
    # Purpose: Revalidate the complete expected target state and snapshot permissions before target displacement while leaving the stage name intact.
    It 'InterT655_rejects_in_place_target_or_mode_drift_after_preflight_without_moving_names' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        foreach($variant in @('content','mode')){
            $parent=New-P7cDirectory "post-preflight-target-$variant";$txn=New-P7cTransaction;$target=$null;$stage=$null
            $targetPath=Join-Path $script:P7cRoot "post-preflight-target-$variant/target"
            try {
                $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
                $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
                $hookVariant=$variant
                $hook={param($point)if($point-ceq'publication-after-preflight-before-revalidation'){if($hookVariant-ceq'content'){[IO.File]::WriteAllText($targetPath,'tampered-target')}else{[IO.File]::SetUnixFileMode($targetPath,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::GroupRead))}}}.GetNewClosure()
                $field.SetValue($null,[Action[string]]$hook)
                $caught=$null
                try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage $stageState|Out-Null}catch{$caught=$_.Exception}
                $caught.GetType().Name|Should Be PlatformVerificationException
                if($variant-ceq'content'){[IO.File]::ReadAllText($targetPath)|Should Be 'tampered-target'}else{[int][IO.File]::GetUnixFileMode($targetPath)|Should Be 416}
                (Read-P7cText $txn.Lease stage)|Should Be replacement
                Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false
            } finally {$field.SetValue($null,$null);foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
        }
    }

    # Scenario: A same-account writer rewrites the removal target inode after destination preflight.
    # Purpose: Revalidate full target state and permissions immediately before tombstone rename so no stale snapshot is removed.
    It 'InterT660_rejects_in_place_removal_target_drift_after_preflight_without_tombstoning' {
        $parent=New-P7cDirectory 'post-preflight-remove';$txn=New-P7cTransaction;$target=$null
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        $targetPath=Join-Path $script:P7cRoot 'post-preflight-remove/target'
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'removal-after-preflight-before-revalidation'){[IO.File]::WriteAllText($targetPath,'tampered-removal-target')}})
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $parent -Leaf target -ExpectedState $state -TransactionLease $txn.Lease -TombstoneLeaf tombstone|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformVerificationException
            [IO.File]::ReadAllText($targetPath)|Should Be 'tampered-removal-target'
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/tombstone")|Should Be $false
        } finally {$field.SetValue($null,$null);if($null-ne$target){$target.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Each host capability probe directory is renamed and replaced by an unrelated empty directory immediately before cleanup.
    # Purpose: Compare the held directory fd with fstatat ownership evidence, preserve the replacement, and report that capability unavailable.
    It 'InterT665_preserves_replaced_host_probe_directories_and_reports_capabilities_unavailable' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('ProbeTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        foreach($case in @(
            [pscustomobject]@{Prefix='publication-probe-before-directory-cleanup:';Capability='publication'},
            [pscustomobject]@{Prefix='permissions-probe-before-directory-cleanup:';Capability='permissions'}
        )){
            $paths=[Collections.Generic.List[string]]::new();$prefix=$case.Prefix
            try {
                $hook={param($point)if($point.StartsWith($prefix,[StringComparison]::Ordinal)){$path=$point.Substring($prefix.Length);$moved=$path+'-held';[IO.Directory]::Move($path,$moved);[IO.Directory]::CreateDirectory($path)|Out-Null;$paths.Add($path);$paths.Add($moved)}}.GetNewClosure()
                $field.SetValue($null,[Action[string]]$hook)
                $receipt=Get-PlatformCapabilities -Required @()
                $capability=$receipt.capabilities|Where-Object name -eq $case.Capability
                $capability.status|Should Be unavailable
                ($capability.evidence-join' ')|Should Match 'probe directory identity changed before cleanup'
                foreach($legacy in @('directory-lease','file-lease','file-identity','lock')){
                    ($receipt.capabilities|Where-Object name -eq $legacy).status|Should Be available
                }
                [IO.Directory]::Exists($paths[0])|Should Be $true
                [IO.Directory]::Exists($paths[1])|Should Be $true
            } finally {
                $field.SetValue($null,$null)
                foreach($path in @($paths)){if([IO.Directory]::Exists($path)){Remove-Item -LiteralPath $path -Recurse -Force}}
            }
        }
    }

    if ($IsMacOS) {
    # Scenario: Ordinary APFS files and directories have no extended ACL, so acl_get_fd_np reports ENOENT.
    # Purpose: Treat ENOENT as an empty ACL while keeping permission, publication, and legacy lease probes available.
    It 'InterT670_accepts_macos_objects_without_extended_acls' {
        $parent=New-P7cDirectory 'macos-no-acl';$txn=New-P7cTransaction;$file=$null;$stage=$null;$published=$null
        try {
            $file=New-P7cFile $parent ordinary content
            (Get-PlatformPermissions -Lease $file).mode|Should Be '600'
            (Get-PlatformPermissions -Lease $parent).mode|Should Be '700'
            $stage=New-P7cFile $txn.Lease stage replacement
            Publish-PlatformFile -ParentLease $parent -Leaf published -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage (Get-P7cStageState $stage)|Out-Null
            $published=Open-PlatformFile -ParentLease $parent -Leaf published -Access Read -CreateMode OpenExisting
            (Read-P7cText $parent published)|Should Be replacement
            $receipt=Get-PlatformCapabilities -Required @('permissions','publication','directory-lease')
            foreach($name in @('permissions','publication','directory-lease','file-lease','file-identity','lock')){
                ($receipt.capabilities|Where-Object name -eq $name).status|Should Be available
            }
        } finally {foreach($lease in @($published,$stage,$file)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: A macOS target carries an explicit deny-delete extended ACL.
    # Purpose: Preserve fail-closed permission and publication behavior for a real non-empty ACL and remove the fixture ACL afterward.
    It 'InterT675_rejects_macos_targets_with_extended_acls' {
        $parent=New-P7cDirectory 'macos-extended-acl';$txn=New-P7cTransaction;$target=$null;$stage=$null
        $targetPath=Join-Path $script:P7cRoot 'macos-extended-acl/target'
        try {
            $target=New-P7cFile $parent target original;$state=Get-P7cState $target
            & /bin/chmod '+a' 'everyone deny delete' $targetPath
            $LASTEXITCODE|Should Be 0
            $caught=$null
            try{Get-PlatformPermissions -Lease $target|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformCapabilityUnavailableException
            $caught.Capability|Should Be 'permissions: macOS extended ACL is present'
            $target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage (Get-P7cStageState $stage)|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformCapabilityUnavailableException
            (Read-P7cText $parent target)|Should Be original
            (Read-P7cText $txn.Lease stage)|Should Be replacement
        } finally {
            if([IO.File]::Exists($targetPath)){& /bin/chmod '-N' $targetPath 2>$null|Out-Null}
            foreach($lease in @($stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()
        }
    }
    }

    if ($IsLinux) {
    # Scenario: Ordinary Linux files and directories have no POSIX ACL xattrs.
    # Purpose: Treat missing ACL data as empty and keep both P7c and legacy filesystem capabilities available.
    It 'InterT680_accepts_linux_objects_without_acl_xattrs' {
        $parent=New-P7cDirectory 'linux-no-acl';$file=$null
        try {
            $file=New-P7cFile $parent ordinary content
            (Get-PlatformPermissions -Lease $file).mode|Should Be '600'
            (Get-PlatformPermissions -Lease $parent).mode|Should Be '700'
            $receipt=Get-PlatformCapabilities -Required @('permissions','publication','owned-file-removal','directory-lease','file-lease','file-identity','lock')
            foreach($name in @('permissions','publication','owned-file-removal','directory-lease','file-lease','file-identity','lock')){
                ($receipt.capabilities|Where-Object name -eq $name).status|Should Be available
            }
        } finally {if($null-ne$file){$file.Dispose()};$parent.Dispose()}
    }
    }

    # Scenario: Original-file fsync fails before replacement publication or tombstone removal can rename the target.
    # Purpose: Return the typed fsync failure and preserve every original name and the staged replacement without mutation.
    It 'InterT685_rejects_original_file_fsync_failure_before_any_rename' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        $publishParent=New-P7cDirectory 'original-fsync-publish';$removeParent=New-P7cDirectory 'original-fsync-remove';$txn=New-P7cTransaction;$target=$null;$stage=$null;$removeTarget=$null
        try {
            $target=New-P7cFile $publishParent target original;$state=Get-P7cState $target;$target.Dispose();$target=$null
            $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'publication-before-original-file-fsync'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException]::new('fsync-publication-original-file',5,'EIO')}})
            $caught=$null
            try{Publish-PlatformFile -ParentLease $publishParent -Leaf target -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $state -DisplacedLeaf backup -ExpectedStage $stageState|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformErrnoException;$caught.Operation|Should Be 'fsync-publication-original-file'
            (Read-P7cText $publishParent target)|Should Be original;(Read-P7cText $txn.Lease stage)|Should Be replacement
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/backup")|Should Be $false

            $removeTarget=New-P7cFile $removeParent target owned;$removeState=Get-P7cState $removeTarget;$removeTarget.Dispose();$removeTarget=$null
            $field.SetValue($null,[Action[string]]{param($point)if($point-ceq'removal-before-original-file-fsync'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException]::new('fsync-removal-original-file',5,'EIO')}})
            $caught=$null
            try{Remove-PlatformOwnedFile -ParentLease $removeParent -Leaf target -ExpectedState $removeState -TransactionLease $txn.Lease -TombstoneLeaf tombstone|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be PlatformErrnoException;$caught.Operation|Should Be 'fsync-removal-original-file'
            (Read-P7cText $removeParent target)|Should Be owned;(Read-P7cText $txn.Lease stage)|Should Be replacement
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/tombstone")|Should Be $false
        } finally {$field.SetValue($null,$null);foreach($lease in @($removeTarget,$stage,$target)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$removeParent.Dispose();$publishParent.Dispose()}
    }
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ($IsLinux -or $IsMacOS) {
    # Scenario: A validated Unix journal names a same-content inode other than the retained stage, then names the correct stage identity.
    # Purpose: Reject the mismatched durable identity without moving target or stage, and publish successfully when the fd identity matches.
    It 'InterT700_binds_unix_journal_applied_identity_to_the_published_stage' {
        $parent=New-P7cDirectory 'journal-applied-identity';$txn=New-P7cTransaction;$stage=$null;$other=$null;$published=$null
        try {
            $stage=New-P7cFile $txn.Lease stage same-bytes;$stageState=Get-P7cStageState $stage
            $other=New-P7cFile $txn.Lease other same-bytes;$otherState=Get-P7cStageState $other
            $missing=Get-P7cAbsentState
            $wrongOperation=New-P7cJournalOperation -TargetRelativePath 'journal-applied-identity/created' -Kind create-file -Method stage-rename -StageLeaf stage -BackupLeaf $null -Original $missing -Applied (New-P7cAppliedState $otherState) -Permissions $null
            $caught=$null
            try { Publish-PlatformFile -ParentLease $parent -Leaf created -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stageState -NoReplace -Journal $wrongOperation | Out-Null } catch { $caught=$_.Exception }
            $caught.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Capability | Should Be 'publication'
            Test-Path -LiteralPath (Join-Path $script:P7cRoot 'journal-applied-identity/created') | Should Be $false
            (Read-P7cText $txn.Lease stage) | Should Be same-bytes
            (Read-P7cText $txn.Lease other) | Should Be same-bytes

            $correctOperation=New-P7cJournalOperation -TargetRelativePath 'journal-applied-identity/created' -Kind create-file -Method stage-rename -StageLeaf stage -BackupLeaf $null -Original $missing -Applied (New-P7cAppliedState $stageState) -Permissions $null
            $receipt=Publish-PlatformFile -ParentLease $parent -Leaf created -TransactionLease $txn.Lease -StageLease $stage -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stageState -NoReplace -Journal $correctOperation
            $published=Open-PlatformFile -ParentLease $parent -Leaf created -Access Read -CreateMode OpenExisting
            (Read-P7cText $parent created) | Should Be same-bytes
            $receipt.appliedIdentity.device | Should Be $stageState.identity.device
            $receipt.appliedIdentity.fileId | Should Be $stageState.identity.fileId
            $published.Observation.Inode | Should Be ([uint64]$stageState.identity.fileId)
        } finally { foreach($lease in @($published,$other,$stage)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose() }
    }

    # Scenario: A create-file journal supplies an explicit Unix mode snapshot, then permission readback is faulted before publication.
    # Purpose: Apply and verify non-null create permissions on the stage before rename while preserving zero-publication failure behavior.
    It 'InterT710_applies_and_preverifies_unix_create_permissions_before_rename' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        $parent=New-P7cDirectory 'create-permissions';$txn=New-P7cTransaction;$stage=$null;$faultStage=$null;$published=$null
        try {
            $stage=New-P7cFile $txn.Lease stage explicit;$stageState=Get-P7cStageState $stage
            $permissions=[pscustomobject][ordered]@{kind='unix-mode';mode='640';uid=[uint64]$stage.Observation.Uid;gid=[uint64]$stage.Observation.Gid}
            $operation=New-P7cJournalOperation -TargetRelativePath 'create-permissions/created' -Kind create-file -Method stage-rename -StageLeaf stage -BackupLeaf $null -Original (Get-P7cAbsentState) -Applied (New-P7cAppliedState $stageState) -Permissions $permissions
            $receipt=Publish-PlatformFile -ParentLease $parent -Leaf created -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $stageState -NoReplace -Journal $operation
            $published=Open-PlatformFile -ParentLease $parent -Leaf created -Access Read -CreateMode OpenExisting
            $receipt.permissions.mode|Should Be '640';[int][IO.File]::GetUnixFileMode((Join-Path $script:P7cRoot 'create-permissions/created'))|Should Be 416

            $faultStage=New-P7cFile $txn.Lease fault.stage fault;$faultState=Get-P7cStageState $faultStage
            $faultPermissions=[pscustomobject][ordered]@{kind='unix-mode';mode='640';uid=[uint64]$faultStage.Observation.Uid;gid=[uint64]$faultStage.Observation.Gid}
            $faultOperation=New-P7cJournalOperation -TargetRelativePath 'create-permissions/faulted' -Kind create-file -Method stage-rename -StageLeaf fault.stage -BackupLeaf $null -Original (Get-P7cAbsentState) -Applied (New-P7cAppliedState $faultState) -Permissions $faultPermissions
            $faultStagePath=Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/fault.stage"
            $hook={param($point)if($point-ceq'publication-after-permission-apply-before-readback'){[IO.File]::SetUnixFileMode($faultStagePath,[IO.UnixFileMode]::UserRead)}}.GetNewClosure()
            $field.SetValue($null,[Action[string]]$hook)
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf faulted -TransactionLease $txn.Lease -StageLease $faultStage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $faultState -NoReplace -Journal $faultOperation|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformVerificationException';$caught.Capability|Should Be 'publication'
            Test-Path -LiteralPath (Join-Path $script:P7cRoot 'create-permissions/faulted')|Should Be $false
            (Read-P7cText $txn.Lease fault.stage)|Should Be fault
        } finally {$field.SetValue($null,$null);foreach($lease in @($published,$faultStage,$stage)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: A noncooperating writer changes explicit create permissions after rename and durability flushes.
    # Purpose: Return recovery evidence, preserve the published location, and never rename the target back automatically.
    It 'InterT715_preserves_post_rename_unix_create_permission_mismatches_for_recovery' {
        $field=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative].GetField('MutationTestHook',[Reflection.BindingFlags]'NonPublic,Static')
        $parent=New-P7cDirectory 'create-permissions-postcheck';$txn=New-P7cTransaction;$stage=$null
        $targetPath=Join-Path $script:P7cRoot 'create-permissions-postcheck/created'
        try {
            $stage=New-P7cFile $txn.Lease stage explicit;$stageState=Get-P7cStageState $stage
            $permissions=[pscustomobject][ordered]@{kind='unix-mode';mode='640';uid=[uint64]$stage.Observation.Uid;gid=[uint64]$stage.Observation.Gid}
            $operation=New-P7cJournalOperation -TargetRelativePath 'create-permissions-postcheck/created' -Kind create-file -Method stage-rename -StageLeaf stage -BackupLeaf $null -Original (Get-P7cAbsentState) -Applied (New-P7cAppliedState $stageState) -Permissions $permissions
            $hook={param($point)if($point-ceq'publication-after-fsync-before-postcheck'){[IO.File]::SetUnixFileMode($targetPath,[IO.UnixFileMode]::UserRead)}}.GetNewClosure()
            $field.SetValue($null,[Action[string]]$hook)
            $caught=$null
            try{Publish-PlatformFile -ParentLease $parent -Leaf created -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $stageState -NoReplace -Journal $operation|Out-Null}catch{$caught=$_.Exception}
            $caught.GetType().Name|Should Be 'PlatformMutationException';$caught.Capability|Should Be 'publication-post-verification';$caught.Receipt|Should Not BeNullOrEmpty
            $caught.Receipt.completedSteps|Should Contain 'stage-published'
            Test-Path -LiteralPath $targetPath|Should Be $true
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/stage")|Should Be $false
        } finally {$field.SetValue($null,$null);if($null-ne$stage){$stage.Dispose()};$txn.Lease.Dispose();$parent.Dispose()}
    }

    # Scenario: Unjournaled Unix publication and tombstone removal address the reserved container or another transaction directory.
    # Purpose: Reject every reserved target before permissions, unlink, or rename and retain all staged and target identities.
    It 'InterT720_rejects_reserved_unix_targets_without_mutation' {
        $root=Open-PlatformDirectory -Root $script:P7cRoot -RootOnly;$txn=New-P7cTransaction;$other=New-P7cTransaction;$stage=$null;$target=$null
        try {
            $stage=New-P7cFile $txn.Lease stage replacement;$stageState=Get-P7cStageState $stage
            $target=New-P7cFile $other.Lease target owned;$targetState=Get-P7cState $target;$target.Dispose();$target=$null
            foreach($action in @(
                {Publish-PlatformFile -ParentLease $root -Leaf '.ai-instructions-txn' -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $stageState -NoReplace|Out-Null},
                {Publish-PlatformFile -ParentLease $other.Lease -Leaf created -TransactionLease $txn.Lease -StageLease $stage -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $stageState -NoReplace|Out-Null},
                {Remove-PlatformOwnedFile -ParentLease $root -Leaf '.ai-instructions-txn' -ExpectedState (Get-P7cAbsentState) -TransactionLease $txn.Lease -TombstoneLeaf container.backup|Out-Null},
                {Remove-PlatformOwnedFile -ParentLease $other.Lease -Leaf target -ExpectedState $targetState -TransactionLease $txn.Lease -TombstoneLeaf target.backup|Out-Null}
            )){
                $caught=$null;try{&$action}catch{$caught=$_.Exception}
                $caught.GetType().Name|Should Be 'PlatformVerificationException';$caught.Message|Should Match 'must stay outside \.ai-instructions-txn'
            }
            (Read-P7cText $txn.Lease stage)|Should Be replacement;(Read-P7cText $other.Lease target)|Should Be owned
            Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($other.Id)/created")|Should Be $false
            foreach($leaf in @('container.backup','target.backup')){Test-Path -LiteralPath (Join-Path $script:P7cRoot ".ai-instructions-txn/$($txn.Id)/$leaf")|Should Be $false}
        } finally {foreach($lease in @($target,$stage)){if($null-ne$lease){$lease.Dispose()}};$other.Lease.Dispose();$txn.Lease.Dispose();$root.Dispose()}
    }

    # Scenario: Unix journal.json publication uses the exact transaction lease and cleanup removes its private artifacts.
    # Purpose: Preserve D9 while rejecting recursive Journal intent for journal-store operations.
    It 'InterT725_allows_only_unjournaled_unix_journal_store_operations' {
        $txn=New-P7cTransaction;$first=$null;$second=$null;$cleanup=$null;$third=$null
        try {
            $first=New-P7cFile $txn.Lease journal.stage first;$firstStage=Get-P7cStageState $first
            $firstReceipt=Publish-PlatformFile -ParentLease $txn.Lease -Leaf journal.json -TransactionLease $txn.Lease -StageLease $first -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $firstStage -NoReplace
            $firstState=[pscustomobject][ordered]@{exists=$true;sha256=$firstStage.sha256;length=$firstStage.length;identity=$firstReceipt.appliedIdentity}
            $second=New-P7cFile $txn.Lease journal.stage second;$secondStage=Get-P7cStageState $second
            Publish-PlatformFile -ParentLease $txn.Lease -Leaf journal.json -TransactionLease $txn.Lease -StageLease $second -ExpectedState $firstState -DisplacedLeaf journal.prev -ExpectedStage $secondStage|Out-Null
            (Read-P7cText $txn.Lease journal.json)|Should Be second;(Read-P7cText $txn.Lease journal.prev)|Should Be first

            $cleanup=New-P7cFile $txn.Lease journal.stage temporary;$cleanupState=Get-P7cState $cleanup;$cleanup.Dispose();$cleanup=$null
            (Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf journal.prev -ExpectedState $firstState).deleted|Should Be $true
            (Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf journal.stage -ExpectedState $cleanupState).deleted|Should Be $true

            $third=New-P7cFile $txn.Lease journal.stage third;$thirdState=Get-P7cStageState $third
            $operation=New-P7cJournalOperation -TargetRelativePath 'ordinary/created' -Kind create-file -Method stage-rename -StageLeaf stage -BackupLeaf $null -Original (Get-P7cAbsentState) -Applied (New-P7cAppliedState $thirdState) -Permissions $null
            {Publish-PlatformFile -ParentLease $txn.Lease -Leaf journal.json -TransactionLease $txn.Lease -StageLease $third -ExpectedState (Get-P7cAbsentState) -DisplacedLeaf $null -ExpectedStage $thirdState -NoReplace -Journal $operation}|Should Throw 'must not supply Journal'
            {Remove-PlatformOwnedFile -ParentLease $txn.Lease -Leaf journal.stage -ExpectedState (Get-P7cState $third) -Journal $null}|Should Throw 'Journal is forbidden'
            $third.Dispose();$third=$null
        } finally {foreach($lease in @($third,$cleanup,$second,$first)){if($null-ne$lease){$lease.Dispose()}};$txn.Lease.Dispose()}
    }
    }
}

Describe 'Platform P7 Windows publication, removal and permission snapshots' {
    $script:P7CreatorOwnerParentOwnerSid = $null
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        $creatorOwnerProbe = Join-Path ([IO.Path]::GetTempPath()) ('p7-creator-owner-capability-' + [Guid]::NewGuid().ToString('N'))
        try {
            [IO.Directory]::CreateDirectory($creatorOwnerProbe) | Out-Null
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $effectiveOwnerSid = $identity.Owner.Value } finally { $identity.Dispose() }
            foreach ($candidateSid in @('S-1-5-32-544','S-1-5-18')) {
                if ($candidateSid -ceq $effectiveOwnerSid) { continue }
                try {
                    $security = [Security.AccessControl.DirectorySecurity]::new()
                    $security.SetOwner([Security.Principal.SecurityIdentifier]::new($candidateSid))
                    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($creatorOwnerProbe),$security)
                    $ownerSecurity = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($creatorOwnerProbe),[Security.AccessControl.AccessControlSections]::Owner)
                    $observed = $ownerSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value
                    if ($observed -ceq $candidateSid) {
                        $script:P7CreatorOwnerParentOwnerSid = $candidateSid
                        break
                    }
                } catch {}
            }
        } finally {
            if ([IO.Directory]::Exists($creatorOwnerProbe)) { [IO.Directory]::Delete($creatorOwnerProbe,$true) }
        }
    }
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        $script:P7RuntimeContractModule = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/ai-instructions-runtime-contract.psm1') -PassThru -Force -Scope Local
        $script:P7WindowsDaclModule = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/WindowsDacl.psm1') -PassThru -Scope Local
        function Get-P7Hash([byte[]]$Bytes) {
            $sha=[Security.Cryptography.SHA256]::Create()
            try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        }
        function Get-P7Identity($Observation) {
            [pscustomobject]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$Observation.Device);fileId=('0x{0:x}' -f [uint64]$Observation.Inode)}
        }
        function Get-P7NamedFileState($Parent,[string]$Leaf,[object]$LeaseOwner=$null) {
            $reopen=$null -ne $LeaseOwner -and $null -ne $LeaseOwner.Lease
            if($reopen){$LeaseOwner.Lease.Dispose();$LeaseOwner.Lease=$null}
            $lease=Open-PlatformFile -ParentLease $Parent -Leaf $Leaf -Access Read -CreateMode OpenExisting
            try {
                $observed=Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -SingleLink
                $permissions=Get-PlatformPermissions $lease
                [pscustomobject]@{identity=(Get-P7Identity $observed);bytes=[Convert]::ToBase64String($lease.ReadAllBytes(1048576));sddl=[string]$permissions.sddl;readOnly=[bool]$permissions.readOnly}
            } finally {
                $lease.Dispose()
                if($reopen){$access=if([bool]$permissions.readOnly){'Read'}else{'ReadWrite'};$LeaseOwner.Lease=Open-PlatformFile -ParentLease $Parent -Leaf $Leaf -Access $access -CreateMode OpenExisting}
            }
        }
        function Test-P7DaclProtected([string]$Sddl) {
            $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
            return ($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
        }
        function Get-P7DaclControl([string]$Sddl) {
            return [int]([Security.AccessControl.RawSecurityDescriptor]::new($Sddl).ControlFlags)
        }
        function Test-P7EquivalentDacl([string]$First,[string]$Second) {
            return & $script:P7WindowsDaclModule.ExportedCommands['Test-WindowsDaclEquivalent'] -FirstSddl $First -SecondSddl $Second
        }
        function Set-P7InheritanceFixture($Fixture) {
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try { $sid=$identity.User.Value } finally { $identity.Dispose() }
            $transactionSddl='D:P(A;OICI;FA;;;'+$sid+')(A;OICI;FA;;;SY)'
            $Fixture.Parent.Dispose()
            $icacls=Join-Path $env:SystemRoot 'System32\icacls.exe'
            & $icacls (Join-Path $Fixture.Root 'target') '/inheritance:e' '/grant:r' ("*$sid`:(OI)(CI)(F)") '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-545:(OI)(CI)(R)' | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Failed to configure the unprotected target-parent fixture DACL.'}
            $Fixture.Parent=Open-PlatformDirectory -Root $Fixture.Root -RelativePath 'target'
            [void](Set-PlatformPermissions -Lease $Fixture.Transaction -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$transactionSddl;readOnly=$false}))
            $parentSddl=(Get-PlatformPermissions $Fixture.Parent).sddl
            if(Test-P7DaclProtected $parentSddl){throw 'The target-parent fixture DACL remained protected.'}
            return [pscustomobject]@{Sid=$sid;ParentSddl=$parentSddl;TransactionSddl=$transactionSddl}
        }
        function Set-P7CreatorOwnerFixture($Fixture,[string]$ParentOwnerSid) {
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try {
                $effectiveOwnerSid=$identity.Owner.Value
                $effectiveUserSid=$identity.User.Value
            } finally {$identity.Dispose()}
            if($ParentOwnerSid -ceq $effectiveOwnerSid){throw 'The parent owner fixture must differ from the effective token owner.'}
            $Fixture.Parent.Dispose()
            $path=Join-Path $Fixture.Root 'target'
            $security=[Security.AccessControl.DirectorySecurity]::new()
            $security.SetAccessRuleProtection($true,$false)
            $allow=[Security.AccessControl.AccessControlType]::Allow
            $full=[Security.AccessControl.FileSystemRights]::FullControl
            $none=[Security.AccessControl.InheritanceFlags]::None
            $noPropagation=[Security.AccessControl.PropagationFlags]::None
            $objectInherit=[Security.AccessControl.InheritanceFlags]::ObjectInherit
            $inheritOnly=[Security.AccessControl.PropagationFlags]::InheritOnly
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($effectiveUserSid),$full,$none,$noPropagation,$allow))
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-0'),$full,$objectInherit,$inheritOnly,$allow))
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-1'),$full,$objectInherit,$inheritOnly,$allow))
            $security.SetOwner([Security.Principal.SecurityIdentifier]::new($ParentOwnerSid))
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($path),$security)
            $Fixture.Parent=Open-PlatformDirectory -Root $Fixture.Root -RelativePath 'target'
            $ownerSecurity=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($path),[Security.AccessControl.AccessControlSections]::Owner)
            $observedOwner=$ownerSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if($observedOwner -cne $ParentOwnerSid){throw 'The target-parent owner fixture was not applied.'}
            return [pscustomobject]@{EffectiveOwnerSid=$effectiveOwnerSid;ParentOwnerSid=$observedOwner}
        }
        function New-P7Fixture([string]$Name) {
            $root=Join-Path $TestDrive $Name
            [IO.Directory]::CreateDirectory($root)|Out-Null
            $parent=Open-PlatformDirectory -Root $root -RelativePath 'target' -CreatePrivate
            $transactionRoot=Open-PlatformDirectory -Root $root -RelativePath '.ai-instructions-txn' -CreatePrivate
            $transactionId=[Guid]::NewGuid().ToString('N')
            $transaction=Open-PlatformDirectory -Root (Join-Path $root '.ai-instructions-txn') -RelativePath $transactionId -CreatePrivate
            [pscustomobject]@{Root=$root;Parent=$parent;TransactionRoot=$transactionRoot;Transaction=$transaction;TransactionId=$transactionId;TransactionIdentity=(Get-P7Identity $transaction.Observation)}
        }
        function Close-P7Fixture($Fixture,[object[]]$Leases=@()) {
            foreach($lease in @($Leases)){
                if($null -ne $lease){try{$lease.Dispose()} catch [ObjectDisposedException] {}
                }
            }
            foreach($lease in @($Fixture.Transaction,$Fixture.TransactionRoot,$Fixture.Parent)){
                if($null -ne $lease){try{$lease.Dispose()} catch [ObjectDisposedException] {}
                }
            }
        }
        function New-P7File($Parent,[string]$Leaf,[byte[]]$Bytes) {
            $lease=Open-PlatformFile -ParentLease $Parent -Leaf $Leaf -Access ReadWrite -CreateMode CreateNew
            $lease.WriteNewBytes($Bytes)
            $observed=Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation -SingleLink
            [pscustomobject]@{Lease=$lease;State=[pscustomobject]@{exists=$true;sha256=(Get-P7Hash $Bytes);length=[int64]$Bytes.Length;identity=(Get-P7Identity $observed)};Expected=[pscustomobject]@{sha256=(Get-P7Hash $Bytes);length=[int64]$Bytes.Length}}
        }
        function New-P7Directory($Fixture,[ValidateSet('Parent','Transaction')][string]$Location,[string]$Leaf,[string]$Content='content') {
            $relative=if($Location -ceq 'Parent'){"target/$Leaf"}else{".ai-instructions-txn/$($Fixture.TransactionId)/$Leaf"}
            $path=Join-Path $Fixture.Root $relative
            [void][IO.Directory]::CreateDirectory($path)
            [IO.File]::WriteAllText((Join-Path $path 'marker.txt'),$Content,[Text.UTF8Encoding]::new($false))
            $parent=if($Location -ceq 'Parent'){$Fixture.Parent}else{$Fixture.Transaction}
            $state=Get-PlatformDirectoryState -ParentLease $parent -Leaf $Leaf
            [pscustomobject]@{Path=$path;Identity=$state.identity;State=$state}
        }
        function New-P7JournalOperation {
            param([string]$Kind,[string]$Method,[string]$TargetRelativePath,$StageLeaf,$BackupLeaf,$Original,$Applied,$Permissions,$QuarantineLeaf=$null)
            $operation=[pscustomobject][ordered]@{
                sequence=1;kind=$Kind;method=$Method;targetRelativePath=$TargetRelativePath;stageLeaf=$StageLeaf;backupLeaf=$BackupLeaf
                quarantineLeaf=$QuarantineLeaf;original=$Original;backupIdentity=$(if([bool]$Original.exists){$Original.identity}else{$null});applied=$Applied;permissions=$Permissions;state='pending'
            }
            $journal=New-AiInstructionsInstallJournalV1 -OwnerComponent installer -OwnerProcessId 1 -OwnerProcessStartIdentity 'p7-test' -PlatformOs windows -PlatformArchitecture x64 -LockPrimitive windows-fileshare -LockLeaf install.lock -CandidateBundleSha256 ('a'*64) -Phase prepared -Operations @($operation)
            $json=$journal | ConvertTo-Json -Depth 20 -Compress
            return (ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json -ExpectedTransactionId $journal.transactionId).operations[0]
        }
        function Set-P7WindowsPostRenameHook([AllowNull()][scriptblock]$Hook) {
            $runtimeModule=@(Get-Module platform-runtime)[0]
            if($null -eq $runtimeModule){throw 'The platform runtime module is not loaded.'}
            & $runtimeModule {
                param($Value)
                $windowsModule=@(Get-Module -All Windows)[0]
                if($null -eq $windowsModule){throw 'The nested Windows platform module is not loaded.'}
                & $windowsModule { param($NestedValue) $script:WindowsPublicationPostRenameTestHook=$NestedValue } $Value
            } $Hook
        }
        function Set-P7WindowsDurabilityHook([AllowNull()][scriptblock]$Hook) {
            $runtimeModule=@(Get-Module platform-runtime)[0]
            if($null -eq $runtimeModule){throw 'The platform runtime module is not loaded.'}
            & $runtimeModule {
                param($Value)
                $windowsModule=@(Get-Module -All Windows)[0]
                if($null -eq $windowsModule){throw 'The nested Windows platform module is not loaded.'}
                & $windowsModule { param($NestedValue) $script:WindowsPublicationDurabilityTestHook=$NestedValue } $Value
            } $Hook
        }
        function Set-P7WindowsPreReopenHook([AllowNull()][scriptblock]$Hook) {
            $runtimeModule=@(Get-Module platform-runtime)[0]
            if($null -eq $runtimeModule){throw 'The platform runtime module is not loaded.'}
            & $runtimeModule {
                param($Value)
                $windowsModule=@(Get-Module -All Windows)[0]
                if($null -eq $windowsModule){throw 'The nested Windows platform module is not loaded.'}
                & $windowsModule { param($NestedValue) $script:WindowsPublicationPreReopenTestHook=$NestedValue } $Value
            } $Hook
        }
        function Set-P7WindowsPostRenamePermissionReadbackHook([AllowNull()][scriptblock]$Hook) {
            $runtimeModule=@(Get-Module platform-runtime)[0]
            if($null -eq $runtimeModule){throw 'The platform runtime module is not loaded.'}
            & $runtimeModule {
                param($Value)
                $windowsModule=@(Get-Module -All Windows)[0]
                if($null -eq $windowsModule){throw 'The nested Windows platform module is not loaded.'}
                & $windowsModule { param($NestedValue) $script:WindowsPostRenamePermissionReadbackTestHook=$NestedValue } $Value
            } $Hook
        }
        function Set-P7WindowsPermissionMutationHook([AllowNull()][scriptblock]$Hook) {
            $field=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative].GetField('PermissionsMutationTestHook',[Reflection.BindingFlags]'Static,NonPublic')
            if($null -eq $field){throw 'The internal Windows permission mutation hook is unavailable.'}
            $value=if($null -eq $Hook){$null}else{[Action[string]]{param($Point)& $Hook $Point}.GetNewClosure()}
            $field.SetValue($null,$value)
        }
        function Set-P7WindowsPublicationDaclHook([AllowNull()][scriptblock]$Hook) {
            $field=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative].GetField('PublicationDaclTestHook',[Reflection.BindingFlags]'Static,NonPublic')
            if($null -eq $field){throw 'The internal Windows publication DACL hook is unavailable.'}
            $value=if($null -eq $Hook){$null}else{[Action[string]]{param($Point)& $Hook $Point}.GetNewClosure()}
            $field.SetValue($null,$value)
        }
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    # Scenario: A read-only target with an explicit DACL is replaced through two no-replace renames.
    # Purpose: Preserve DACL/read-only and move the original file to backup without changing identity.
    It 'InterT100_publishes_over_an_existing_target_and_preserves_permissions_and_identity' {
        $f=New-P7Fixture 'p7-write';$target=$null;$stage=$null;$backup=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $before=Set-PlatformPermissions -Lease $target.Lease -Policy @{Sddl=$sddl;ReadOnly=$true}
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $receipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected
            $receipt.displacedIdentity.fileId | Should Be $target.State.identity.fileId
            $receipt.permissions.readOnly | Should Be $true
            $receipt.permissions.sddl | Should Be $before.sddl
            (Test-P7DaclProtected $receipt.permissions.sddl) | Should Be $true
            $stage.Lease.Dispose();$stage.Lease=$null
            $backup=Open-PlatformFile -ParentLease $f.Transaction -Leaf 'old.backup' -Access Read -CreateMode OpenExisting
            (Get-P7Identity $backup.Observation).fileId | Should Be $target.State.identity.fileId
            (Test-P7DaclProtected (Get-PlatformPermissions $backup).sddl) | Should Be $true
        } finally { Close-P7Fixture $f @($backup,$stage.Lease,$target.Lease) }
    }

    # Scenario: An existing target has an unprotected inherited DACL before publication.
    # Purpose: Preserve the target's unprotected inheritance boundary on the published file and displaced backup.
    It 'InterT105_preserves_an_unprotected_existing_target_dacl_during_publication' {
        $f=New-P7Fixture 'p7-write-unprotected';$target=$null;$stage=$null;$backup=$null;$published=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $before=Get-PlatformPermissions $target.Lease
            (Test-P7DaclProtected $before.sddl) | Should Be $false
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $receipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected
            (Test-P7DaclProtected $receipt.permissions.sddl) | Should Be $false
            $stage.Lease.Dispose();$stage.Lease=$null
            $published=Open-PlatformFile -ParentLease $f.Parent -Leaf 'data' -Access Read -CreateMode OpenExisting
            $backup=Open-PlatformFile -ParentLease $f.Transaction -Leaf 'old.backup' -Access Read -CreateMode OpenExisting
            (Test-P7EquivalentDacl (Get-PlatformPermissions $published).sddl $before.sddl) | Should Be $true
            (Test-P7EquivalentDacl (Get-PlatformPermissions $backup).sddl $before.sddl) | Should Be $true
            (Test-P7DaclProtected (Get-PlatformPermissions $published).sddl) | Should Be $false
            (Test-P7DaclProtected (Get-PlatformPermissions $backup).sddl) | Should Be $false
        } finally { Close-P7Fixture $f @($published,$backup,$stage.Lease,$target.Lease) }
    }

    # Scenario: A missing target receives a staged file from a private transaction directory.
    # Purpose: Match the DACL inherited by a direct CreateNew in the target parent, not the transaction DACL.
    It 'InterT110_creates_with_the_target_parent_inherited_dacl' {
        $f=New-P7Fixture 'p7-create';$stage=$null;$control=$null;$published=$null
        try {
            $control=New-P7File $f.Parent 'control' ([byte[]]@(1));$controlPermissions=Get-PlatformPermissions $control.Lease;$control.Lease.Dispose();$control.Lease=$null
            $stage=New-P7File $f.Transaction 'create.stage' ([Text.Encoding]::UTF8.GetBytes('created'))
            Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState ([pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}) -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace | Out-Null
            $stage.Lease.Dispose();$stage.Lease=$null;$published=Open-PlatformFile -ParentLease $f.Parent -Leaf 'created' -Access Read -CreateMode OpenExisting
            (Test-P7EquivalentDacl (Get-PlatformPermissions $published).sddl $controlPermissions.sddl) | Should Be $true
        } finally { Close-P7Fixture $f @($published,$stage.Lease,$control.Lease) }
    }

    # Scenario: Expected target metadata, stage metadata, backup availability, or NoReplace preconditions differ.
    # Purpose: Reject before publication and keep both named identities and bytes unchanged.
    It 'InterT120_rejects_mismatches_existing_backup_and_noreplace_without_mutation' {
        $f=New-P7Fixture 'p7-reject';$target=$null;$stage=$null;$occupied=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'));$target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $targetBefore=Get-P7NamedFileState $f.Parent 'data'
            $stageBefore=Get-P7NamedFileState $f.Transaction 'stage' $stage
            $stagePermissionsBefore=Get-PlatformPermissions $stage.Lease
            $badIdentity=[pscustomobject]@{kind='windows-file-id';device=$target.State.identity.device;fileId='0x0'}
            foreach($bad in @(
                [pscustomobject]@{exists=$true;sha256=('0'*64);length=$target.State.length;identity=$target.State.identity},
                [pscustomobject]@{exists=$true;sha256=$target.State.sha256;length=($target.State.length+1);identity=$target.State.identity},
                [pscustomobject]@{exists=$true;sha256=$target.State.sha256;length=$target.State.length;identity=$badIdentity}
            )) {
                { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $bad -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected } | Should Throw
            }
            $occupied=New-P7File $f.Transaction 'backup' ([byte[]]@(9));$occupied.Lease.Dispose();$occupied.Lease=$null
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected } | Should Throw
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'other.backup' -ExpectedStage $stage.Expected -NoReplace } | Should Throw 'NoReplace'
            $targetAfter=Get-P7NamedFileState $f.Parent 'data'
            $stageAfter=Get-P7NamedFileState $f.Transaction 'stage' $stage
            $targetAfter.bytes | Should Be $targetBefore.bytes
            $targetAfter.identity.device | Should Be $targetBefore.identity.device
            $targetAfter.identity.fileId | Should Be $targetBefore.identity.fileId
            $stageAfter.bytes | Should Be $stageBefore.bytes
            $stageAfter.identity.device | Should Be $stageBefore.identity.device
            $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId
        } finally { Close-P7Fixture $f @($stage.Lease,$target.Lease,$occupied.Lease) }
    }

    # Scenario: Stage placement/hash or target ownership shape is unsafe (hard link, reparse point, or directory).
    # Purpose: Fail before rename and preserve the stage and every target name.
    It 'InterT125_rejects_unsafe_stages_and_target_shapes_without_rename' {
        $f=New-P7Fixture 'p7-shapes';$stage=$null;$outside=$null;$target=$null
        try {
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $outside=New-P7File $f.Parent 'outside.stage' ([Text.Encoding]::UTF8.GetBytes('outside'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'missing' -TransactionLease $f.Transaction -StageLease $outside.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $outside.Expected } | Should Throw 'immediate child'
            $badStage=[pscustomobject]@{sha256='0'*64;length=$stage.Expected.length}
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'missing' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $badStage } | Should Throw 'Stage hash'
            $target=New-P7File $f.Parent 'linked' ([Text.Encoding]::UTF8.GetBytes('old'));$target.Lease.Dispose();$target.Lease=$null
            New-Item -ItemType HardLink -Path (Join-Path $f.Root 'target/alias') -Target (Join-Path $f.Root 'target/linked') | Out-Null
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'linked' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected } | Should Throw
            [IO.Directory]::CreateDirectory((Join-Path $f.Root 'target/directory'))|Out-Null
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'directory' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'directory.backup' -ExpectedStage $stage.Expected } | Should Throw
            $junctionTarget=Join-Path $f.Root 'junction-target';[IO.Directory]::CreateDirectory($junctionTarget)|Out-Null
            New-Item -ItemType Junction -Path (Join-Path $f.Root 'target/reparse') -Target $junctionTarget | Out-Null
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'reparse' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'reparse.backup' -ExpectedStage $stage.Expected } | Should Throw
            [Text.Encoding]::UTF8.GetString($stage.Lease.ReadAllBytes(1024)) | Should Be 'new'
        } finally { Close-P7Fixture $f @($stage.Lease,$outside.Lease,$target.Lease) }
    }

    # Scenario: The applied file is displaced and the original backup is supplied as the next stage.
    # Purpose: Prove the same publication primitive performs rollback while preserving original identity.
    It 'InterT130_uses_symmetric_publication_to_restore_the_original_identity' {
        $f=New-P7Fixture 'p7-rollback';$original=$null;$stage=$null;$backup=$null
        try {
            $original=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'));$original.Lease.Dispose();$original.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $applied=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $original.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected
            $stage.Lease.Dispose();$stage.Lease=$null;$backup=Open-PlatformFile -ParentLease $f.Transaction -Leaf 'old.backup' -Access ReadWrite -CreateMode OpenExisting
            $appliedState=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$applied.appliedIdentity}
            $rollbackJournal=New-P7JournalOperation write-file stage-rename 'target/data' 'old.backup' 'new.stage' $appliedState $original.State $applied.permissions
            Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $backup -ExpectedState $appliedState -DisplacedLeaf 'new.stage' -ExpectedStage ([pscustomobject]@{sha256=$original.State.sha256;length=$original.State.length}) -Journal $rollbackJournal | Out-Null
            (Get-P7Identity $backup.Observation).fileId | Should Be $original.State.identity.fileId
            [IO.File]::ReadAllText((Join-Path $f.Root 'target/data')) | Should Be 'old'
        } finally { Close-P7Fixture $f @($backup,$stage.Lease,$original.Lease) }
    }

    # Scenario: A validated journal operation disagrees with its publication parameters.
    # Purpose: Refuse stale durable intent before any rename.
    It 'UnitT140_rejects_a_mismatched_journal_operation' {
        $f=New-P7Fixture 'p7-journal';$stage=$null
        try {
            $stage=New-P7File $f.Transaction 'stage' ([byte[]]@(1,2,3))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $journal=New-P7JournalOperation create-file stage-rename 'wrong' 'stage' $null $missing $applied $null
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $journal.original -DisplacedLeaf $null -ExpectedStage $stage.Expected -Journal $journal } | Should Throw 'Journal'
        } finally { Close-P7Fixture $f @($stage.Lease) }
    }

    # Scenario: File publication/removal receives a journal kind incompatible with the requested operation or target existence.
    # Purpose: Reject the durable intent before mutation and preserve every named file's live identity and bytes.
    It 'InterT145_rejects_non_file_and_existence_mismatched_journal_kinds_without_mutation' {
        $f=New-P7Fixture 'p7-journal-kind';$target=$null;$removeTarget=$null;$stage=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $permissions=Get-PlatformPermissions $target.Lease;$target.Lease.Dispose();$target.Lease=$null
            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('remove-old'))
            $removePermissions=Get-PlatformPermissions $removeTarget.Lease;$removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $targetBefore=Get-P7NamedFileState $f.Parent 'data'
            $removeBefore=Get-P7NamedFileState $f.Parent 'remove'
            $stageBefore=Get-P7NamedFileState $f.Transaction 'stage' $stage

            $directoryOriginal=[pscustomobject]@{exists=$true;identity=$target.State.identity;inventorySha256=('1'*64);entryCount=1}
            $directoryApplied=[pscustomobject]@{exists=$true;identity=$stage.State.identity;inventorySha256=('2'*64);entryCount=1}
            $swap=New-P7JournalOperation swap-directory stage-rename 'target/data' 'stage' 'swap.backup' $directoryOriginal $directoryApplied $permissions 'swap.quarantine'
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'swap.backup' -ExpectedStage $stage.Expected -Journal $swap } | Should Throw 'Journal'
            $writeMissing=New-P7JournalOperation write-file stage-rename 'target/created' 'stage' 'write.backup' $target.State $applied $permissions
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -Journal $writeMissing } | Should Throw 'Journal'
            $createExisting=New-P7JournalOperation create-file stage-rename 'target/data' 'stage' $null $missing $applied $null
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'create.backup' -ExpectedStage $stage.Expected -Journal $createExisting } | Should Throw 'Journal'
            $writeRemove=New-P7JournalOperation write-file stage-rename 'target/remove' 'stage' 'remove.backup' $removeTarget.State $applied $removePermissions
            { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'remove.backup' -Journal $writeRemove } | Should Throw 'Journal'

            $targetAfter=Get-P7NamedFileState $f.Parent 'data'
            $removeAfter=Get-P7NamedFileState $f.Parent 'remove'
            $stageAfter=Get-P7NamedFileState $f.Transaction 'stage' $stage
            foreach($pair in @(@($targetBefore,$targetAfter),@($removeBefore,$removeAfter),@($stageBefore,$stageAfter))) {
                $pair[1].bytes | Should Be $pair[0].bytes
                $pair[1].identity.device | Should Be $pair[0].identity.device
                $pair[1].identity.fileId | Should Be $pair[0].identity.fileId
            }
            Test-Path -LiteralPath (Join-Path $f.Root 'target/created') | Should Be $false
            foreach($leaf in @('swap.backup','swap.quarantine','write.backup','create.backup','remove.backup')) {
                Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/$leaf") | Should Be $false
            }
        } finally { Close-P7Fixture $f @($stage.Lease,$target.Lease,$removeTarget.Lease) }
    }

    # Scenario: Removal uses a tombstone transaction and cleanup later deletes only inside that transaction.
    # Purpose: Preserve identity across tombstone rename and reject half-specified or outside cleanup requests.
    It 'InterT150_tombstones_with_identity_and_restricts_cleanup_to_transactions' {
        $f=New-P7Fixture 'p7-remove';$target=$null;$tombstone=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('owned'));$target.Lease.Dispose();$target.Lease=$null
            { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'data' -ExpectedState $target.State -TransactionLease $f.Transaction } | Should Throw
            $receipt=Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'data' -ExpectedState $target.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup'
            $receipt.backupIdentity.fileId | Should Be $target.State.identity.fileId
            $tombstone=Open-PlatformFile -ParentLease $f.Transaction -Leaf 'removed.backup' -Access Read -CreateMode OpenExisting
            $tombstoneState=[pscustomobject]@{exists=$true;sha256=$target.State.sha256;length=$target.State.length;identity=(Get-P7Identity $tombstone.Observation)};$tombstone.Dispose();$tombstone=$null
            Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'removed.backup' -ExpectedState $tombstoneState | Out-Null
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/removed.backup") | Should Be $false
            { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'unknown' -ExpectedState $tombstoneState } | Should Throw 'transaction-private'
        } finally { Close-P7Fixture $f @($tombstone,$target.Lease) }
    }

    # Scenario: Permission restoration crosses protected and unprotected inheritance boundaries in both directions.
    # Purpose: Preserve DACL protection/auto-inheritance flags while rejecting incompatible snapshots.
    It 'UnitT160_restores_windows_dacl_protection_in_both_directions_and_rejects_invalid_snapshots' {
        $f=New-P7Fixture 'p7-permissions';$file=$null
        try {
            $file=New-P7File $f.Parent 'data' ([byte[]]@(1));$unprotected=Get-PlatformPermissions $file.Lease
            (Test-P7DaclProtected $unprotected.sddl) | Should Be $false
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$protectedSddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $protected=Set-PlatformPermissions -Lease $file.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$protectedSddl;readOnly=$false})
            (Test-P7DaclProtected $protected.sddl) | Should Be $true
            $restoredUnprotected=Set-PlatformPermissions -Lease $file.Lease -Snapshot $unprotected
            $restoredUnprotected.sddl | Should Be $unprotected.sddl
            (Test-P7DaclProtected $restoredUnprotected.sddl) | Should Be $false
            Set-PlatformPermissions -Lease $file.Lease -Snapshot $unprotected | Out-Null
            $restoredProtected=Set-PlatformPermissions -Lease $file.Lease -Snapshot $protected
            $restoredProtected.sddl | Should Be $protected.sddl
            (Test-P7DaclProtected $restoredProtected.sddl) | Should Be $true
            { Set-PlatformPermissions -Lease $file.Lease -Snapshot ([pscustomobject]@{kind='unix-mode';mode='600';uid=0;gid=0}) } | Should Throw
            { Set-PlatformPermissions -Lease $file.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl='O:SYD:(A;;FA;;;SY)';readOnly=$false}) } | Should Throw
        } finally { Close-P7Fixture $f @($file.Lease) }
    }

    # Scenario: The compatibility wrapper is imported alone and after platform-runtime in fresh processes.
    # Purpose: Keep legacy functions usable without defining InstallerNativeMutation twice.
    It 'InterT170_loads_the_installer_wrapper_alone_and_with_platform_runtime' {
        $shell=Join-Path $PSHOME 'pwsh.exe';$wrapper=Join-Path $script:RepositoryRoot 'scripts/installer-safe-mutation.psm1';$runtime=Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1'
        foreach($code in @("Import-Module '$($wrapper.Replace("'","''"))' -Force; [bool]('CodexAiInstructions.InstallerNativeMutation' -as [type])","Import-Module '$($runtime.Replace("'","''"))' -Force; Import-Module '$($wrapper.Replace("'","''"))' -Force; [bool]('CodexAiInstructions.InstallerNativeMutation' -as [type])")) {
            @(& $shell -NoProfile -Command $code)[-1] | Should Be 'True';$LASTEXITCODE | Should Be 0
        }
    }

    # Scenario: A copied scripts tree is reached through a junction ancestor in a fresh PowerShell process.
    # Purpose: Reject every reparse-point ancestor before reading the manifest or compiling native source.
    It 'InterT172_rejects_an_installer_wrapper_junction_ancestor' {
        $shell=Join-Path $PSHOME 'pwsh.exe';$physicalRoot=Join-Path $TestDrive 'wrapper-junction-physical';$junctionRoot=Join-Path $TestDrive 'wrapper-junction-alias'
        [IO.Directory]::CreateDirectory($physicalRoot)|Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination (Join-Path $physicalRoot 'scripts') -Recurse
        New-Item -ItemType Junction -Path $junctionRoot -Target $physicalRoot | Out-Null
        $wrapper=Join-Path $junctionRoot 'scripts/installer-safe-mutation.psm1'
        $code="try { Import-Module '$($wrapper.Replace("'","''"))' -Force -ErrorAction Stop; exit 91 } catch { `$_.Exception.GetType().FullName; `$_.Exception.Message; if (`$_.Exception -isnot [IO.InvalidDataException]) { exit 92 } }"
        $output=@(& $shell -NoProfile -Command $code)
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'System.IO.InvalidDataException'
        ($output -join "`n") | Should Match 'path safety'
    }

    # Scenario: The copied native source has a second hard link when the wrapper is imported in a fresh process.
    # Purpose: Bind compilation to a regular source file whose handle reports exactly one link.
    It 'InterT174_rejects_a_hard_linked_installer_native_source' {
        $shell=Join-Path $PSHOME 'pwsh.exe';$copyRoot=Join-Path $TestDrive 'wrapper-hard-link'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination $copyRoot -Recurse
        $source=Join-Path $copyRoot 'platform/WindowsInstallerMutation.cs'
        New-Item -ItemType HardLink -Path (Join-Path $copyRoot 'platform/WindowsInstallerMutation.alias.cs') -Target $source | Out-Null
        $wrapper=Join-Path $copyRoot 'installer-safe-mutation.psm1'
        $code="try { Import-Module '$($wrapper.Replace("'","''"))' -Force -ErrorAction Stop; exit 93 } catch { `$_.Exception.GetType().FullName; `$_.Exception.Message; if (`$_.Exception -isnot [IO.InvalidDataException]) { exit 94 } }"
        $output=@(& $shell -NoProfile -Command $code)
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'System.IO.InvalidDataException'
        ($output -join "`n") | Should Match 'link count'
    }

    # Scenario: One byte in the copied native source differs from the manifest inventory in a fresh process.
    # Purpose: Compile only the exact sha256-utf8-lf bytes bound by platform-runtime.psd1.
    It 'InterT176_rejects_an_installer_native_source_hash_mismatch' {
        $shell=Join-Path $PSHOME 'pwsh.exe';$copyRoot=Join-Path $TestDrive 'wrapper-hash-drift'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination $copyRoot -Recurse
        $source=Join-Path $copyRoot 'platform/WindowsInstallerMutation.cs'
        [IO.File]::AppendAllText($source,'x',[Text.UTF8Encoding]::new($false))
        $wrapper=Join-Path $copyRoot 'installer-safe-mutation.psm1'
        $code="try { Import-Module '$($wrapper.Replace("'","''"))' -Force -ErrorAction Stop; exit 95 } catch { `$_.Exception.GetType().FullName; `$_.Exception.Message; if (`$_.Exception -isnot [IO.InvalidDataException]) { exit 96 } }"
        $output=@(& $shell -NoProfile -Command $code)
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'System.IO.InvalidDataException'
        ($output -join "`n") | Should Match 'hash mismatch'
    }

    # Scenario: Two journal operations use the same leaf under different target parents.
    # Purpose: Bind exactly one operation to ParentLease instead of searching a journal by basename.
    It 'InterT180_binds_one_same_leaf_journal_operation_to_its_verified_parent' {
        $f=New-P7Fixture 'p7-journal-parent';$parentA=$null;$target=$null;$stage=$null;$validation=$null
        try {
            $parentA=Open-PlatformDirectory -Root $f.Root -RelativePath 'a' -CreatePrivate
            $target=New-P7File $parentA 'SKILL.md' ([Text.Encoding]::UTF8.GetBytes('old'))
            $permissions=Get-PlatformPermissions $target.Lease;$target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'skill.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $operationA=New-P7JournalOperation write-file stage-rename 'a/SKILL.md' 'skill.stage' 'skill.backup' $target.State $applied $permissions
            $operationB=New-P7JournalOperation write-file stage-rename 'b/SKILL.md' 'skill.stage' 'skill.backup' $target.State $applied $permissions
            $targetBefore=Get-P7NamedFileState $parentA 'SKILL.md'
            $stageBefore=Get-P7NamedFileState $f.Transaction 'skill.stage' $stage

            { Publish-PlatformFile -ParentLease $parentA -Leaf 'SKILL.md' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'skill.backup' -ExpectedStage $stage.Expected -Journal $operationB } | Should Throw 'Journal'
            $targetAfter=Get-P7NamedFileState $parentA 'SKILL.md'
            $stageAfter=Get-P7NamedFileState $f.Transaction 'skill.stage' $stage
            $targetAfter.bytes | Should Be $targetBefore.bytes
            $targetAfter.identity.device | Should Be $targetBefore.identity.device
            $targetAfter.identity.fileId | Should Be $targetBefore.identity.fileId
            $stageAfter.bytes | Should Be $stageBefore.bytes
            $stageAfter.identity.device | Should Be $stageBefore.identity.device
            $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId

            $receipt=Publish-PlatformFile -ParentLease $parentA -Leaf 'SKILL.md' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'skill.backup' -ExpectedStage $stage.Expected -Journal $operationA
            $receipt.displacedIdentity.fileId | Should Be $target.State.identity.fileId
        } finally { Close-P7Fixture $f @($validation,$stage.Lease,$target.Lease,$parentA) }
    }

    # Scenario: Durable journal permissions differ from the live publish and remove targets.
    # Purpose: Reject both operations before any rename or permission mutation.
    It 'InterT190_rejects_journal_permission_drift_before_publish_or_remove' {
        $f=New-P7Fixture 'p7-journal-permissions';$publishTarget=$null;$removeTarget=$null;$stage=$null
        try {
            $publishTarget=New-P7File $f.Parent 'publish' ([Text.Encoding]::UTF8.GetBytes('publish-old'))
            $publishPermissions=Get-PlatformPermissions $publishTarget.Lease
            Set-PlatformPermissions -Lease $publishTarget.Lease -Policy @{ReadOnly=$true} | Out-Null
            $publishTarget.Lease.Dispose();$publishTarget.Lease=$null
            $stage=New-P7File $f.Transaction 'publish.stage' ([Text.Encoding]::UTF8.GetBytes('publish-new'))
            $publishApplied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $publishJournal=New-P7JournalOperation write-file stage-rename 'target/publish' 'publish.stage' 'publish.backup' $publishTarget.State $publishApplied $publishPermissions

            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'publish' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $publishTarget.State -DisplacedLeaf 'publish.backup' -ExpectedStage $stage.Expected -Journal $publishJournal } | Should Throw 'Journal permissions'
            [IO.File]::ReadAllText((Join-Path $f.Root 'target/publish')) | Should Be 'publish-old'
            [Text.Encoding]::UTF8.GetString($stage.Lease.ReadAllBytes(1024)) | Should Be 'publish-new'
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/publish.backup") | Should Be $false

            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('remove-old'))
            $removePermissions=Get-PlatformPermissions $removeTarget.Lease
            Set-PlatformPermissions -Lease $removeTarget.Lease -Policy @{ReadOnly=$true} | Out-Null
            $removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $removeJournal=New-P7JournalOperation remove-file tombstone-rename 'target/remove' $null 'remove.backup' $removeTarget.State $removed $removePermissions

            { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'remove.backup' -Journal $removeJournal } | Should Throw 'Journal permissions'
            [IO.File]::ReadAllText((Join-Path $f.Root 'target/remove')) | Should Be 'remove-old'
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/remove.backup") | Should Be $false
        } finally { Close-P7Fixture $f @($stage.Lease,$publishTarget.Lease,$removeTarget.Lease) }
    }

    # Scenario: The target parent is moved after publication rename and flush but before pathname revalidation.
    # Purpose: Return recovery evidence without deleting the applied file or renaming it back to stage.
    It 'InterT200_preserves_applied_publication_with_receipt_after_parent_move' {
        $f=New-P7Fixture 'p7-post-publish-move';$stage=$null;$caught=$null
        try {
            $stage=New-P7File $f.Transaction 'create.stage' ([Text.Encoding]::UTF8.GetBytes('created'))
            Set-P7WindowsPostRenameHook {
                param($phase,$parentPath,$transactionPath,$parentLease,$transactionLease,$stageLease,$targetLease)
                $stageLease.Dispose();$parentLease.Dispose();[IO.Directory]::Move($parentPath,$parentPath+'-moved')
            }
            try {
                Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState ([pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}) -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace | Out-Null
            } catch { $caught=$_ } finally { Set-P7WindowsPostRenameHook $null }

            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $receipt=$caught.Exception.Data['Receipt'];$receipt | Should Not BeNullOrEmpty
            $receipt.appliedIdentity.fileId | Should Be (Get-P7Identity $stage.Lease.Observation).fileId
            Test-Path -LiteralPath (Join-Path $f.Root 'target-moved/created') | Should Be $true
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/create.stage") | Should Be $false
        } finally { Set-P7WindowsPostRenameHook $null;Close-P7Fixture $f @($stage.Lease) }
    }

    # Scenario: The target parent is moved after a tombstone rename and flush but before pathname revalidation.
    # Purpose: Keep the tombstone for journal recovery and attach the completed removal receipt.
    It 'InterT210_preserves_tombstone_with_receipt_after_parent_move' {
        $f=New-P7Fixture 'p7-post-remove-move';$target=$null;$caught=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('owned'));$target.Lease.Dispose();$target.Lease=$null
            Set-P7WindowsPostRenameHook {
                param($phase,$parentPath,$transactionPath,$parentLease,$transactionLease,$stageLease,$targetLease)
                $targetLease.Dispose();$parentLease.Dispose();[IO.Directory]::Move($parentPath,$parentPath+'-moved')
            }
            try {
                Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'data' -ExpectedState $target.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup' | Out-Null
            } catch { $caught=$_ } finally { Set-P7WindowsPostRenameHook $null }

            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $receipt=$caught.Exception.Data['Receipt'];$receipt | Should Not BeNullOrEmpty
            $receipt.displacedIdentity.fileId | Should Be $target.State.identity.fileId
            $receipt.permissionsDrift.beforeSddl|Should Not BeNullOrEmpty
            $receipt.permissionsDrift.afterSddl|Should Not BeNullOrEmpty
            $caught.Exception.Message|Should Match 'before SDDL=.*after SDDL='
            Test-Path -LiteralPath (Join-Path $f.Root 'target-moved/data') | Should Be $false
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/removed.backup") | Should Be $true
        } finally { Set-P7WindowsPostRenameHook $null;Close-P7Fixture $f @($target.Lease) }
    }

    # Scenario: Cleanup of a transaction-private tombstone is mistakenly supplied a journal operation.
    # Purpose: Keep durable intent exclusive to the tombstone rename and leave cleanup bytes untouched.
    It 'InterT220_rejects_a_journal_in_cleanup_mode_without_mutation' {
        $f=New-P7Fixture 'p7-cleanup-journal';$tombstone=$null
        try {
            $tombstone=New-P7File $f.Transaction 'cleanup.backup' ([Text.Encoding]::UTF8.GetBytes('kept'))
            $permissions=Get-PlatformPermissions $tombstone.Lease
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $journal=New-P7JournalOperation remove-file tombstone-rename 'target/data' $null 'cleanup.backup' $tombstone.State $removed $permissions
            $before=Get-P7NamedFileState $f.Transaction 'cleanup.backup' $tombstone

            { Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'cleanup.backup' -ExpectedState $tombstone.State -Journal $journal } | Should Throw 'Journal'
            $after=Get-P7NamedFileState $f.Transaction 'cleanup.backup' $tombstone
            $after.bytes | Should Be $before.bytes
            $after.identity.device | Should Be $before.identity.device
            $after.identity.fileId | Should Be $before.identity.fileId
        } finally { Close-P7Fixture $f @($tombstone.Lease) }
    }

    # Scenario: A legal DACL snapshot contains generic read and all-access rights before Windows expands them.
    # Purpose: Canonicalize generic masks before mutation and preserve the same DACL semantics through publication.
    It 'InterT230_canonicalizes_generic_rights_before_permission_apply_and_publication' {
        $f=New-P7Fixture 'p7-generic-rights';$target=$null;$stage=$null;$published=$null;$removeTarget=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try{$genericSddl='D:P(A;;GA;;;'+$identity.User.Value+')(A;;GR;;;SY)'}finally{$identity.Dispose()}
            $canonical=Set-PlatformPermissions -Lease $target.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$genericSddl;readOnly=$false})
            $canonical.sddl | Should Not Match ';;(?:GA|GR);;;'
            (Get-PlatformPermissions $target.Lease).sddl | Should Be $canonical.sddl
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'generic.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $genericSnapshot=[pscustomobject]@{kind='windows-sddl';sddl=$genericSddl;readOnly=$false}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $journal=New-P7JournalOperation write-file stage-rename 'target/data' 'generic.stage' 'generic.backup' $target.State $applied $genericSnapshot

            $receipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'generic.backup' -ExpectedStage $stage.Expected -Journal $journal
            $receipt.permissions.sddl | Should Be $canonical.sddl
            $stage.Lease.Dispose();$stage.Lease=$null
            $published=Open-PlatformFile -ParentLease $f.Parent -Leaf 'data' -Access Read -CreateMode OpenExisting
            (Get-PlatformPermissions $published).sddl | Should Be $canonical.sddl

            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('owned'))
            Set-PlatformPermissions -Lease $removeTarget.Lease -Snapshot $genericSnapshot | Out-Null
            $removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $removeJournal=New-P7JournalOperation remove-file tombstone-rename 'target/remove' $null 'removed.backup' $removeTarget.State $removed $genericSnapshot
            (Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup' -Journal $removeJournal).permissions.sddl | Should Be $canonical.sddl
        } finally { Close-P7Fixture $f @($published,$stage.Lease,$target.Lease,$removeTarget.Lease) }
    }

    # Scenario: Stage or removal bytes are rewritten on the same inode after the caller lease is disposed and before the mutation handle reopens.
    # Purpose: Reject both races with typed failures before permission mutation or rename while preserving each raced identity at its original leaf.
    It 'InterT235_revalidates_reopened_stage_and_tombstone_content_before_rename' {
        $f=New-P7Fixture 'p7-reopen-content';$stage=$null;$removeTarget=$null;$publishCaught=$null;$removeCaught=$null
        try {
            $stage=New-P7File $f.Transaction 'publish.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $stageBefore=Get-P7NamedFileState $f.Transaction 'publish.stage' $stage
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $journal=New-P7JournalOperation create-file stage-rename 'target/created' 'publish.stage' $null $missing $applied $null
            Set-P7WindowsPreReopenHook {param($point,$operation,$role,$path)if($operation -ceq 'publication' -and $role -ceq 'stage'){[IO.File]::WriteAllText($path,'raced-stage',[Text.UTF8Encoding]::new($false))}}
            try { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $journal | Out-Null } catch {$publishCaught=$_} finally {Set-P7WindowsPreReopenHook $null}

            $publishCaught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $publishCaught.Exception.Capability | Should Be 'publication'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/created') | Should Be $false
            $stageAfter=Get-P7NamedFileState $f.Transaction 'publish.stage' $stage
            $stageAfter.bytes | Should Be ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('raced-stage')))
            $stageAfter.identity.device | Should Be $stageBefore.identity.device
            $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId

            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('owned'));$removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $removeBefore=Get-P7NamedFileState $f.Parent 'remove'
            Set-P7WindowsPreReopenHook {param($point,$operation,$role,$path)if($operation -ceq 'owned-file-removal' -and $role -ceq 'target'){[IO.File]::WriteAllText($path,'raced-remove',[Text.UTF8Encoding]::new($false))}}
            try { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup' | Out-Null } catch {$removeCaught=$_} finally {Set-P7WindowsPreReopenHook $null}

            $removeCaught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $removeCaught.Exception.Capability | Should Be 'owned-file-removal'
            $removeAfter=Get-P7NamedFileState $f.Parent 'remove'
            $removeAfter.bytes | Should Be ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('raced-remove')))
            $removeAfter.identity.device | Should Be $removeBefore.identity.device
            $removeAfter.identity.fileId | Should Be $removeBefore.identity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/removed.backup") | Should Be $false
        } finally { Set-P7WindowsPreReopenHook $null;Close-P7Fixture $f @($stage.Lease,$removeTarget.Lease) }
    }

    # Scenario: The final staged bytes cannot be flushed after permission/read-only readback but before rename.
    # Purpose: Return a typed durability failure while preserving every target, stage, and backup name and identity.
    It 'InterT240_rejects_stage_flush_failure_before_any_rename' {
        $f=New-P7Fixture 'p7-stage-flush';$target=$null;$stage=$null;$caught=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'));$target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $targetBefore=Get-P7NamedFileState $f.Parent 'data'
            $stageBefore=Get-P7NamedFileState $f.Transaction 'stage' $stage
            $stagePermissionsBefore=Get-PlatformPermissions $stage.Lease
            Set-P7WindowsDurabilityHook { param($point,$operation,$role,$lease) if($point -ceq 'stage-flush'){throw 'injected stage flush failure'} }
            try {
                Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected | Out-Null
            } catch { $caught=$_ } finally { Set-P7WindowsDurabilityHook $null }

            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Capability | Should Be 'publication-durability'
            $targetAfter=Get-P7NamedFileState $f.Parent 'data'
            $stageAfter=Get-P7NamedFileState $f.Transaction 'stage' $stage
            foreach($pair in @(@($targetBefore,$targetAfter),@($stageBefore,$stageAfter))){$pair[1].bytes|Should Be $pair[0].bytes;$pair[1].identity.fileId|Should Be $pair[0].identity.fileId}
            (Get-PlatformPermissions $stage.Lease).sddl | Should Be $stagePermissionsBefore.sddl
            (Get-PlatformPermissions $stage.Lease).readOnly | Should Be $stagePermissionsBefore.readOnly
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/backup") | Should Be $false
        } finally { Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f @($stage.Lease,$target.Lease) }
    }

    # Scenario: NTFS publication and tombstone removal complete every required file and directory flush.
    # Purpose: Report confirmed durability only after the file, parent directory, and transaction directory all flush.
    It 'InterT250_reports_confirmed_file_and_directory_flushes_for_publish_and_remove' {
        $f=New-P7Fixture 'p7-confirmed-flush';$target=$null;$stage=$null;$removeTarget=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'));$target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $publishReceipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected
            $publishReceipt.durability | Should Be 'confirmed'
            $publishReceipt.flush.file | Should Be $true
            $publishReceipt.flush.directory | Should Be $true
            $publishReceipt.flush.transactionDirectory | Should Be $true
            $publishReceipt.completedSteps | Should Contain 'directory-flush'

            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('owned'));$removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $removeReceipt=Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup'
            $removeReceipt.durability | Should Be 'confirmed'
            $removeReceipt.flush.file | Should Be $true
            $removeReceipt.flush.directory | Should Be $true
            $removeReceipt.flush.transactionDirectory | Should Be $true
            $removeReceipt.completedSteps | Should Contain 'directory-flush'

            $cleanupState=[pscustomobject]@{exists=$true;sha256=$removeTarget.State.sha256;length=$removeTarget.State.length;identity=$removeReceipt.backupIdentity}
            $cleanupReceipt=Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'removed.backup' -ExpectedState $cleanupState
            $cleanupReceipt.durability | Should Be 'confirmed'
            $cleanupReceipt.flush.fileNotRequired | Should Be $true
            $cleanupReceipt.flush.directory | Should Be $true
            $cleanupReceipt.flush.transactionDirectory | Should BeNullOrEmpty
        } finally { Close-P7Fixture $f @($stage.Lease,$target.Lease,$removeTarget.Lease) }
    }

    # Scenario: The dedicated parent-directory durability preflight is unavailable for publish and remove.
    # Purpose: Reject both operations before rename while preserving target, stage, backup, and tombstone state.
    It 'InterT260_rejects_preflight_directory_flush_failure_without_mutation' {
        $f=New-P7Fixture 'p7-preflight-flush';$target=$null;$stage=$null;$removeTarget=$null;$cleanupTarget=$null;$publishCaught=$null;$removeCaught=$null;$cleanupCaught=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'));$target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('owned'));$removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $cleanupTarget=New-P7File $f.Transaction 'cleanup.backup' ([Text.Encoding]::UTF8.GetBytes('cleanup'));$cleanupTarget.Lease.Dispose();$cleanupTarget.Lease=$null
            $targetBefore=Get-P7NamedFileState $f.Parent 'data';$stageBefore=Get-P7NamedFileState $f.Transaction 'stage' $stage;$removeBefore=Get-P7NamedFileState $f.Parent 'remove';$cleanupBefore=Get-P7NamedFileState $f.Transaction 'cleanup.backup'
            Set-P7WindowsDurabilityHook { param($point,$operation,$role,$lease) if($point -ceq 'preflight'){throw 'injected preflight failure'} }
            try { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected | Out-Null } catch { $publishCaught=$_ }
            try { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup' | Out-Null } catch { $removeCaught=$_ }
            try { Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'cleanup.backup' -ExpectedState $cleanupTarget.State | Out-Null } catch { $cleanupCaught=$_ }
            Set-P7WindowsDurabilityHook $null

            foreach($caught in @($publishCaught,$removeCaught,$cleanupCaught)) {
                $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
                $caught.Exception.Capability | Should Be 'publication-durability'
                $caught.Exception.Data['Receipt'] | Should BeNullOrEmpty
            }

            $targetAfter=Get-P7NamedFileState $f.Parent 'data';$stageAfter=Get-P7NamedFileState $f.Transaction 'stage' $stage;$removeAfter=Get-P7NamedFileState $f.Parent 'remove';$cleanupAfter=Get-P7NamedFileState $f.Transaction 'cleanup.backup'
            foreach($pair in @(@($targetBefore,$targetAfter),@($stageBefore,$stageAfter),@($removeBefore,$removeAfter),@($cleanupBefore,$cleanupAfter))){$pair[1].bytes|Should Be $pair[0].bytes;$pair[1].identity.fileId|Should Be $pair[0].identity.fileId}
            foreach($leaf in @('backup','removed.backup')){Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/$leaf") | Should Be $false}
        } finally { Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f @($stage.Lease,$target.Lease,$removeTarget.Lease,$cleanupTarget.Lease) }
    }

    # Scenario: A directory flush unexpectedly fails after publish or tombstone rename has completed.
    # Purpose: Preserve the renamed identities without compensation and attach an unconfirmed recovery receipt.
    It 'InterT270_preserves_post_rename_state_with_unconfirmed_durability_receipts' {
        $f=New-P7Fixture 'p7-post-flush';$target=$null;$stage=$null;$removeTarget=$null;$cleanupTarget=$null;$publishCaught=$null;$removeCaught=$null;$cleanupCaught=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'));$target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            Set-P7WindowsDurabilityHook { param($point,$operation,$role,$lease) if($point -ceq 'post-rename'){throw 'injected post-rename failure'} }
            try { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'backup' -ExpectedStage $stage.Expected | Out-Null } catch { $publishCaught=$_ }
            Set-P7WindowsDurabilityHook $null
            $publishReceipt=$publishCaught.Exception.Data['Receipt']
            $publishCaught.Exception.Capability | Should Be 'publication-durability'
            $publishReceipt.durability | Should Be 'unconfirmed'
            $publishReceipt.completedSteps | Should Not Contain 'directory-flush'
            (Get-P7NamedFileState $f.Parent 'data').identity.fileId | Should Be $stage.State.identity.fileId
            (Get-P7NamedFileState $f.Transaction 'backup').identity.fileId | Should Be $target.State.identity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/stage") | Should Be $false

            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('owned'));$removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            Set-P7WindowsDurabilityHook { param($point,$operation,$role,$lease) if($point -ceq 'post-rename'){throw 'injected post-rename failure'} }
            try { Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'removed.backup' | Out-Null } catch { $removeCaught=$_ }
            Set-P7WindowsDurabilityHook $null
            $removeReceipt=$removeCaught.Exception.Data['Receipt']
            $removeCaught.Exception.Capability | Should Be 'publication-durability'
            $removeReceipt.durability | Should Be 'unconfirmed'
            $removeReceipt.completedSteps | Should Not Contain 'directory-flush'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/remove') | Should Be $false
            (Get-P7NamedFileState $f.Transaction 'removed.backup').identity.fileId | Should Be $removeTarget.State.identity.fileId

            $cleanupTarget=New-P7File $f.Transaction 'cleanup.backup' ([Text.Encoding]::UTF8.GetBytes('cleanup'));$cleanupTarget.Lease.Dispose();$cleanupTarget.Lease=$null
            Set-P7WindowsDurabilityHook { param($point,$operation,$role,$lease) if($point -ceq 'post-delete'){throw 'injected post-delete failure'} }
            try { Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'cleanup.backup' -ExpectedState $cleanupTarget.State | Out-Null } catch { $cleanupCaught=$_ }
            Set-P7WindowsDurabilityHook $null
            $cleanupReceipt=$cleanupCaught.Exception.Data['Receipt']
            $cleanupCaught.Exception.Capability | Should Be 'publication-durability'
            $cleanupReceipt.durability | Should Be 'unconfirmed'
            $cleanupReceipt.completedSteps | Should Not Contain 'directory-flush'
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/cleanup.backup") | Should Be $false
        } finally { Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f @($stage.Lease,$target.Lease,$removeTarget.Lease,$cleanupTarget.Lease) }
    }

    # Scenario: Effective-token lookup, CreatePrivateObjectSecurityEx, or the low-level publication DACL write fails for a missing target.
    # Purpose: Return a typed failure without creating a target or changing stage bytes, identity, or DACL.
    It 'InterT280_leaves_no_residue_when_create_dacl_preparation_or_write_fails' {
        $cases=@('before-open-effective-token','before-create-private-object-security','before-low-level-dacl-write')
        for($index=0;$index -lt $cases.Count;$index++){
            $f=New-P7Fixture ('p7-create-dacl-failure-'+$index);$stage=$null;$caught=$null;$failurePoint=$cases[$index]
            try {
                $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('new'))
                $stageBefore=Get-P7NamedFileState $f.Transaction 'stage' $stage
                Set-P7WindowsPublicationDaclHook {param($point)if($point -ceq $failurePoint){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('publication-dacl','windows',('injected '+$point+' failure'))}}
                try { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState ([pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}) -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace | Out-Null } catch {$caught=$_}
                $caught | Should Not BeNullOrEmpty
                $typedFailure=$caught.Exception
                if($typedFailure -is [Management.Automation.MethodInvocationException] -and $null -ne $typedFailure.InnerException){$typedFailure=$typedFailure.InnerException}
                $typedFailure.GetType().Name | Should Be 'PlatformVerificationException'
                Test-Path -LiteralPath (Join-Path $f.Root 'target/created') | Should Be $false
                @(Get-ChildItem -LiteralPath (Join-Path $f.Root 'target') -Force).Count | Should Be 0
                $stageAfter=Get-P7NamedFileState $f.Transaction 'stage' $stage
                $stageAfter.bytes | Should Be $stageBefore.bytes
                $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId
                (Test-P7EquivalentDacl $stageAfter.sddl $stageBefore.sddl) | Should Be $true
            } finally { Set-P7WindowsPublicationDaclHook $null;Close-P7Fixture $f @($stage.Lease) }
        }
    }

    # Scenario: A caller supplies the transaction directory itself, or its private container, as the target parent.
    # Purpose: Reject publish and tombstone removal before touching target, stage, or tombstone bytes.
    It 'InterT290_rejects_transaction_and_transaction_container_target_parents_without_mutation' {
        $f=New-P7Fixture 'p7-private-parent';$stage=$null;$transactionTarget=$null;$containerTarget=$null
        try {
            $stage=New-P7File $f.Transaction 'stage' ([Text.Encoding]::UTF8.GetBytes('stage'))
            $transactionTarget=New-P7File $f.Transaction 'remove' ([Text.Encoding]::UTF8.GetBytes('transaction-target'))
            $containerTarget=New-P7File $f.TransactionRoot 'remove' ([Text.Encoding]::UTF8.GetBytes('container-target'))
            $stageBefore=Get-P7NamedFileState $f.Transaction 'stage' $stage
            $transactionBefore=Get-P7NamedFileState $f.Transaction 'remove' $transactionTarget
            $containerBefore=Get-P7NamedFileState $f.TransactionRoot 'remove' $containerTarget
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}

            { Publish-PlatformFile -ParentLease $f.Transaction -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace } | Should Throw 'outside'
            { Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'remove' -ExpectedState $transactionTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'transaction.backup' } | Should Throw 'outside'
            { Publish-PlatformFile -ParentLease $f.TransactionRoot -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace } | Should Throw 'outside'
            { Remove-PlatformOwnedFile -ParentLease $f.TransactionRoot -Leaf 'remove' -ExpectedState $containerTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'container.backup' } | Should Throw 'outside'

            $stageAfter=Get-P7NamedFileState $f.Transaction 'stage' $stage
            $transactionAfter=Get-P7NamedFileState $f.Transaction 'remove' $transactionTarget
            $containerAfter=Get-P7NamedFileState $f.TransactionRoot 'remove' $containerTarget
            foreach($pair in @(@($stageBefore,$stageAfter),@($transactionBefore,$transactionAfter),@($containerBefore,$containerAfter))){
                $pair[1].bytes|Should Be $pair[0].bytes;$pair[1].identity.fileId|Should Be $pair[0].identity.fileId;$pair[1].sddl|Should Be $pair[0].sddl;$pair[1].readOnly|Should Be $pair[0].readOnly
            }
            foreach($leaf in @('transaction.backup','container.backup')){Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/$leaf")|Should Be $false}
        } finally { Close-P7Fixture $f @($stage.Lease,$transactionTarget.Lease,$containerTarget.Lease) }
    }

    # Scenario: Native permission readback fails after applying both a DACL and read-only state.
    # Purpose: Restore the exact pre-call SDDL/read-only state for direct snapshots and publication stages.
    It 'InterT300_rolls_back_permissions_when_post_apply_readback_fails' {
        $f=New-P7Fixture 'p7-permission-rollback';$direct=$null;$target=$null;$stage=$null;$directCaught=$null;$publishCaught=$null
        try {
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$changedSddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $direct=New-P7File $f.Parent 'direct' ([Text.Encoding]::UTF8.GetBytes('direct'))
            $directBefore=Get-P7NamedFileState $f.Parent 'direct' $direct
            Set-P7WindowsPermissionMutationHook {param($point)if($point -ceq 'after-apply-before-readback'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('permissions-snapshot','windows','injected permission readback failure')}}
            try { Set-PlatformPermissions -Lease $direct.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$changedSddl;readOnly=(-not $directBefore.readOnly)}) | Out-Null } catch {$directCaught=$_} finally {Set-P7WindowsPermissionMutationHook $null}
            $directCaught | Should Not BeNullOrEmpty
            $directAfter=Get-P7NamedFileState $f.Parent 'direct' $direct
            $directAfter.sddl|Should Be $directBefore.sddl;$directAfter.readOnly|Should Be $directBefore.readOnly;$directAfter.bytes|Should Be $directBefore.bytes;$directAfter.identity.fileId|Should Be $directBefore.identity.fileId

            $target=New-P7File $f.Parent 'publish' ([Text.Encoding]::UTF8.GetBytes('old'))
            Set-PlatformPermissions -Lease $target.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$changedSddl;readOnly=$true}) | Out-Null
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'publish.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $targetBefore=Get-P7NamedFileState $f.Parent 'publish';$stageBefore=Get-P7NamedFileState $f.Transaction 'publish.stage' $stage
            Set-P7WindowsPermissionMutationHook {param($point)if($point -ceq 'after-apply-before-readback'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('permissions-snapshot','windows','injected publication permission readback failure')}}
            try { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'publish' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'publish.backup' -ExpectedStage $stage.Expected | Out-Null } catch {$publishCaught=$_} finally {Set-P7WindowsPermissionMutationHook $null}
            $publishCaught | Should Not BeNullOrEmpty
            $targetAfter=Get-P7NamedFileState $f.Parent 'publish';$stageAfter=Get-P7NamedFileState $f.Transaction 'publish.stage' $stage
            foreach($pair in @(@($targetBefore,$targetAfter),@($stageBefore,$stageAfter))){$pair[1].bytes|Should Be $pair[0].bytes;$pair[1].identity.fileId|Should Be $pair[0].identity.fileId;(Test-P7EquivalentDacl $pair[1].sddl $pair[0].sddl)|Should Be $true;$pair[1].readOnly|Should Be $pair[0].readOnly}
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/publish.backup")|Should Be $false
        } finally { Set-P7WindowsPermissionMutationHook $null;Close-P7Fixture $f @($direct.Lease,$target.Lease,$stage.Lease) }
    }

    # Scenario: Cleanup clears a read-only tombstone and delete-on-close then fails.
    # Purpose: Preserve its bytes and identity while restoring read-only through the same verified handle.
    It 'InterT310_restores_readonly_when_cleanup_delete_on_close_fails' {
        $f=New-P7Fixture 'p7-cleanup-readonly';$tombstone=$null;$caught=$null
        try {
            $tombstone=New-P7File $f.Transaction 'cleanup.backup' ([Text.Encoding]::UTF8.GetBytes('kept'))
            Set-PlatformPermissions -Lease $tombstone.Lease -Policy @{ReadOnly=$true}|Out-Null
            $before=Get-P7NamedFileState $f.Transaction 'cleanup.backup' $tombstone
            Set-P7WindowsDurabilityHook {param($point,$operation,$role,$lease)if($point -ceq 'delete-on-close'){throw 'injected delete-on-close failure'}}
            try {Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'cleanup.backup' -ExpectedState $tombstone.State|Out-Null}catch{$caught=$_}finally{Set-P7WindowsDurabilityHook $null}
            $caught | Should Not BeNullOrEmpty
            $after=Get-P7NamedFileState $f.Transaction 'cleanup.backup' $tombstone
            $after.bytes|Should Be $before.bytes;$after.identity.device|Should Be $before.identity.device;$after.identity.fileId|Should Be $before.identity.fileId;$after.sddl|Should Be $before.sddl;$after.readOnly|Should Be $true
        } finally { Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f @($tombstone.Lease) }
    }

    # Scenario: A non-read-only file receives only a DACL SDDL policy.
    # Purpose: The dedicated permission handle can snapshot and read back basic attributes without changing read-only.
    It 'InterT320_applies_sddl_only_to_a_non_readonly_file' {
        $f=New-P7Fixture 'p7-sddl-only';$file=$null
        try {
            $file=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('data'))
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $applied=Set-PlatformPermissions -Lease $file.Lease -Policy @{Sddl=$sddl}
            $observed=Get-PlatformPermissions $file.Lease
            $applied.sddl|Should Be $observed.sddl;$applied.readOnly|Should Be $false;$observed.readOnly|Should Be $false;(Test-P7DaclProtected $observed.sddl)|Should Be $true
        } finally { Close-P7Fixture $f @($file.Lease) }
    }

    # Scenario: A windows-sddl snapshot explicitly keeps a non-read-only file writable.
    # Purpose: Applying readOnly false together with a DACL succeeds and returns the exact normalized snapshot.
    It 'InterT330_applies_a_writable_windows_sddl_snapshot' {
        $f=New-P7Fixture 'p7-writable-snapshot';$file=$null
        try {
            $file=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('data'))
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $applied=Set-PlatformPermissions -Lease $file.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$sddl;readOnly=$false})
            $observed=Get-PlatformPermissions $file.Lease
            $applied.sddl|Should Be $observed.sddl;$applied.readOnly|Should Be $false;$observed.readOnly|Should Be $false;(Test-P7DaclProtected $observed.sddl)|Should Be $true
        } finally { Close-P7Fixture $f @($file.Lease) }
    }

    # Scenario: Publication replaces an existing writable target that has a custom DACL.
    # Purpose: Copy only the target DACL to the stage before rename and preserve writable state after publication.
    It 'InterT340_publishes_over_a_non_readonly_target_with_its_custom_dacl' {
        $f=New-P7Fixture 'p7-publish-sddl-only';$target=$null;$stage=$null;$published=$null
        try {
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $targetPermissions=Set-PlatformPermissions -Lease $target.Lease -Policy @{Sddl=$sddl}
            $targetPermissions.readOnly|Should Be $false
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $receipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected
            $receipt.permissions.sddl|Should Be $targetPermissions.sddl;$receipt.permissions.readOnly|Should Be $false
            $stage.Lease.Dispose();$stage.Lease=$null
            $published=Open-PlatformFile -ParentLease $f.Parent -Leaf 'data' -Access ReadWrite -CreateMode OpenExisting
            $publishedPermissions=Get-PlatformPermissions $published
            $publishedPermissions.sddl|Should Be $targetPermissions.sddl;$publishedPermissions.readOnly|Should Be $false;(Test-P7DaclProtected $publishedPermissions.sddl)|Should Be $true
        } finally { Close-P7Fixture $f @($published,$stage.Lease,$target.Lease) }
    }

    # Scenario: A writable file receives only a ReadOnly policy.
    # Purpose: Preserve its DACL while the dedicated permission handle updates and verifies basic attributes.
    It 'InterT350_applies_readonly_only_without_changing_the_dacl' {
        $f=New-P7Fixture 'p7-readonly-only';$file=$null
        try {
            $file=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('data'))
            $before=Get-PlatformPermissions $file.Lease
            $applied=Set-PlatformPermissions -Lease $file.Lease -Policy @{ReadOnly=$true}
            $observed=Get-PlatformPermissions $file.Lease
            $applied.sddl|Should Be $before.sddl;$observed.sddl|Should Be $before.sddl;$applied.readOnly|Should Be $true;$observed.readOnly|Should Be $true
        } finally { Close-P7Fixture $f @($file.Lease) }
    }

    # Scenario: A target containing only inherited ACEs is published from a transaction directory with different inheritable ACEs.
    # Purpose: Preserve the target ACE sequence, ID flags, P state, and displaced identity while accepting the documented AI clear.
    It 'InterT360_preserves_an_inherited_only_target_dacl_and_clears_AI' {
        $f=New-P7Fixture 'p7-inherited-only';$target=$null;$stage=$null
        try {
            [void](Set-P7InheritanceFixture $f)
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $targetBefore=Get-P7NamedFileState $f.Parent 'data' $target
            $targetDescriptor=[Security.AccessControl.RawSecurityDescriptor]::new($targetBefore.sddl)
            @($targetDescriptor.DiscretionaryAcl | Where-Object {-not $_.IsInherited}).Count | Should Be 0
            @($targetDescriptor.DiscretionaryAcl | Where-Object {$_.IsInherited}).Count | Should Not Be 0
            ((Get-P7DaclControl $targetBefore.sddl) -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) | Should Not Be 0
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected)
            $published=Get-P7NamedFileState $f.Parent 'data'
            $displaced=Get-P7NamedFileState $f.Transaction 'old.backup'
            (Test-P7EquivalentDacl $published.sddl $targetBefore.sddl) | Should Be $true
            ((Get-P7DaclControl $published.sddl) -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) | Should Be 0
            (Test-P7EquivalentDacl $displaced.sddl $targetBefore.sddl) | Should Be $true
            $displaced.identity.fileId | Should Be $target.State.identity.fileId
        } finally { Close-P7Fixture $f @($stage.Lease,$target.Lease) }
    }

    # Scenario: A target combines an explicit ACE with inherited ACEs before publication from a differently protected transaction directory.
    # Purpose: Preserve explicit/inherited ordering and every ID flag while documenting that low-level DACL write clears only AI.
    It 'InterT370_preserves_a_mixed_explicit_and_inherited_target_dacl_and_clears_AI' {
        $f=New-P7Fixture 'p7-mixed-dacl';$target=$null;$stage=$null
        try {
            $aclFixture=Set-P7InheritanceFixture $f
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $inherited=(Get-PlatformPermissions $target.Lease).sddl
            $mixed='D:AI(A;;FW;;;'+$aclFixture.Sid+')'+$inherited.Substring($inherited.IndexOf('('))
            [void](Set-PlatformPermissions -Lease $target.Lease -Snapshot ([pscustomobject]@{kind='windows-sddl';sddl=$mixed;readOnly=$false}))
            $targetBefore=Get-P7NamedFileState $f.Parent 'data' $target
            $targetDescriptor=[Security.AccessControl.RawSecurityDescriptor]::new($targetBefore.sddl)
            @($targetDescriptor.DiscretionaryAcl | Where-Object {-not $_.IsInherited}).Count | Should Not Be 0
            @($targetDescriptor.DiscretionaryAcl | Where-Object {$_.IsInherited}).Count | Should Not Be 0
            ((Get-P7DaclControl $targetBefore.sddl) -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) | Should Not Be 0
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected)
            $published=Get-P7NamedFileState $f.Parent 'data'
            $displaced=Get-P7NamedFileState $f.Transaction 'old.backup'
            (Test-P7EquivalentDacl $published.sddl $targetBefore.sddl) | Should Be $true
            ((Get-P7DaclControl $published.sddl) -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) | Should Be 0
            (Test-P7EquivalentDacl $displaced.sddl $targetBefore.sddl) | Should Be $true
            $displaced.identity.fileId | Should Be $target.State.identity.fileId
        } finally { Close-P7Fixture $f @($stage.Lease,$target.Lease) }
    }

    # Scenario: A missing target is published from a protected transaction directory into an unprotected parent with a distinct inheritable ACE.
    # Purpose: Match a direct CreateNew file's ACE sequence and P state while accepting the observed low-level AI clear.
    It 'InterT380_derives_create_permissions_from_the_target_parent_and_clears_AI' {
        $f=New-P7Fixture 'p7-create-derived-dacl';$control=$null;$stage=$null
        try {
            [void](Set-P7InheritanceFixture $f)
            $control=New-P7File $f.Parent 'control' ([byte[]]@(1))
            $controlPermissions=Get-PlatformPermissions $control.Lease
            ((Get-P7DaclControl $controlPermissions.sddl) -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) | Should Not Be 0
            $stage=New-P7File $f.Transaction 'create.stage' ([Text.Encoding]::UTF8.GetBytes('created'))
            [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState ([pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}) -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace)
            $published=Get-P7NamedFileState $f.Parent 'created'
            (Test-P7EquivalentDacl $published.sddl $controlPermissions.sddl) | Should Be $true
            ((Get-P7DaclControl $published.sddl) -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited) | Should Be 0
        } finally { Close-P7Fixture $f @($control.Lease,$stage.Lease) }
    }

    # Scenario: Publication fails after moving an inherited-ACL original aside but before the applied stage rename.
    # Purpose: Move the original identity back symmetrically and restore both original and stage DACLs without inheriting from the transaction directory.
    It 'InterT390_restores_the_original_identity_and_dacls_on_pre_applied_rename_failure' {
        $f=New-P7Fixture 'p7-dacl-rollback';$target=$null;$stage=$null;$caught=$null
        try {
            [void](Set-P7InheritanceFixture $f)
            $target=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('old'))
            $targetBefore=Get-P7NamedFileState $f.Parent 'data' $target
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'new.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $stageBefore=Get-P7NamedFileState $f.Transaction 'new.stage' $stage
            Set-P7WindowsDurabilityHook {param($point,$operation,$role,$lease)if($point -ceq 'before-applied-rename'){throw 'injected pre-applied rename failure'}}
            try { [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'data' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'old.backup' -ExpectedStage $stage.Expected) } catch {$caught=$_} finally {Set-P7WindowsDurabilityHook $null}
            $caught | Should Not BeNullOrEmpty
            $targetAfter=Get-P7NamedFileState $f.Parent 'data'
            $stageAfter=Get-P7NamedFileState $f.Transaction 'new.stage'
            $targetAfter.identity.fileId | Should Be $targetBefore.identity.fileId
            $targetAfter.bytes | Should Be $targetBefore.bytes
            (Test-P7EquivalentDacl $targetAfter.sddl $targetBefore.sddl) | Should Be $true
            $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId
            $stageAfter.bytes | Should Be $stageBefore.bytes
            (Test-P7EquivalentDacl $stageAfter.sddl $stageBefore.sddl) | Should Be $true
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/old.backup") | Should Be $false
        } finally { Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f @($stage.Lease,$target.Lease) }
    }

    # Scenario: The file owner is denied WRITE_DAC but retains read-control and attribute read/write access.
    # Purpose: ReadOnly-only mutation must not request WRITE_DAC, while an SDDL mutation fails with a typed native error before changing the file.
    It 'InterT400_requests_only_the_access_required_by_each_permission_dimension' {
        $f=New-P7Fixture 'p7-minimum-permission-access';$file=$null;$caught=$null
        try {
            $file=New-P7File $f.Parent 'data' ([Text.Encoding]::UTF8.GetBytes('data'))
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()}
            $delegatedSddl='D:P(D;;WD;;;OW)(A;;0x00130189;;;'+$sid+')'
            [void](Set-PlatformPermissions -Lease $file.Lease -Policy @{Sddl=$delegatedSddl})

            $readOnlyResult=Set-PlatformPermissions -Lease $file.Lease -Policy @{ReadOnly=$true}
            $readOnlyResult.readOnly | Should Be $true
            $before=Get-P7NamedFileState $f.Parent 'data' $file
            try { Set-PlatformPermissions -Lease $file.Lease -Policy @{Sddl=('D:P(A;;FA;;;'+$sid+')')} | Out-Null } catch {$caught=$_}
            $caught | Should Not BeNullOrEmpty
            $typedFailure=$caught.Exception
            if($typedFailure -is [Management.Automation.MethodInvocationException] -and $null -ne $typedFailure.InnerException){$typedFailure=$typedFailure.InnerException}
            $typedFailure.GetType().Name | Should Be 'PlatformWin32Exception'
            $after=Get-P7NamedFileState $f.Parent 'data' $file
            $after.bytes | Should Be $before.bytes
            $after.identity.fileId | Should Be $before.identity.fileId
            $after.sddl | Should Be $before.sddl
            $after.readOnly | Should Be $before.readOnly
        } finally { Close-P7Fixture $f @($file.Lease) }
    }

    # Scenario: Injected permission readback failure follows a ReadOnly-only call and then an SDDL-only call.
    # Purpose: Roll back only the dimension that the call could mutate, using no unrequested write access for the other dimension.
    It 'InterT410_rolls_back_only_the_permission_dimension_that_was_mutated' {
        $f=New-P7Fixture 'p7-dimension-rollback';$readOnlyFile=$null;$daclFile=$null;$readOnlyCaught=$null;$daclCaught=$null
        try {
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$changedSddl='D:P(A;;FA;;;'+$identity.User.Value+')'}finally{$identity.Dispose()}
            $readOnlyFile=New-P7File $f.Parent 'readonly' ([Text.Encoding]::UTF8.GetBytes('readonly'))
            [void](Set-PlatformPermissions -Lease $readOnlyFile.Lease -Policy @{Sddl=$changedSddl})
            $readOnlyBefore=Get-P7NamedFileState $f.Parent 'readonly' $readOnlyFile
            Set-P7WindowsPermissionMutationHook {param($point)if($point -ceq 'after-apply-before-readback'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('permissions-snapshot','windows','injected ReadOnly-only readback failure')}}
            try { Set-PlatformPermissions -Lease $readOnlyFile.Lease -Policy @{ReadOnly=(-not $readOnlyBefore.readOnly)} | Out-Null } catch {$readOnlyCaught=$_} finally {Set-P7WindowsPermissionMutationHook $null}
            $readOnlyCaught | Should Not BeNullOrEmpty
            $readOnlyAfter=Get-P7NamedFileState $f.Parent 'readonly' $readOnlyFile
            $readOnlyAfter.sddl | Should Be $readOnlyBefore.sddl
            $readOnlyAfter.readOnly | Should Be $readOnlyBefore.readOnly

            $daclFile=New-P7File $f.Parent 'dacl' ([Text.Encoding]::UTF8.GetBytes('dacl'))
            [void](Set-PlatformPermissions -Lease $daclFile.Lease -Policy @{ReadOnly=$true})
            $daclBefore=Get-P7NamedFileState $f.Parent 'dacl' $daclFile
            Set-P7WindowsPermissionMutationHook {param($point)if($point -ceq 'after-apply-before-readback'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('permissions-snapshot','windows','injected DACL-only readback failure')}}
            try { Set-PlatformPermissions -Lease $daclFile.Lease -Policy @{Sddl=$changedSddl} | Out-Null } catch {$daclCaught=$_} finally {Set-P7WindowsPermissionMutationHook $null}
            $daclCaught | Should Not BeNullOrEmpty
            $daclAfter=Get-P7NamedFileState $f.Parent 'dacl' $daclFile
            $daclAfter.sddl | Should Be $daclBefore.sddl
            $daclAfter.readOnly | Should Be $daclBefore.readOnly
        } finally { Set-P7WindowsPermissionMutationHook $null;Close-P7Fixture $f @($readOnlyFile.Lease,$daclFile.Lease) }
    }

    # Scenario: A parent owned by another principal exposes an inheritable CREATOR OWNER ACE for new files.
    # Purpose: Derive publication create permissions from the effective token owner, exactly like a direct CreateNew file, rather than from the parent owner.
    if ($null -ne $script:P7CreatorOwnerParentOwnerSid) {
    It 'InterT420_replaces_CREATOR_OWNER_with_the_effective_token_owner' {
        $f=New-P7Fixture 'p7-create-creator-owner';$control=$null;$stage=$null
        try {
            $fixture=Set-P7CreatorOwnerFixture $f $script:P7CreatorOwnerParentOwnerSid
            $fixture.ParentOwnerSid | Should Not Be $fixture.EffectiveOwnerSid
            $control=New-P7File $f.Parent 'control' ([byte[]]@(1))
            $controlPermissions=Get-PlatformPermissions $control.Lease
            $stage=New-P7File $f.Transaction 'create.stage' ([Text.Encoding]::UTF8.GetBytes('created'))
            [void](Set-PlatformPermissions -Lease $stage.Lease -Snapshot $controlPermissions)
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.State.sha256;length=$stage.State.length;identity=$stage.State.identity}
            $operation=New-P7JournalOperation create-file stage-rename 'target/created' 'create.stage' $null $missing $applied $controlPermissions
            [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $operation)
            $published=Get-P7NamedFileState $f.Parent 'created'
            (Test-P7EquivalentDacl $published.sddl $controlPermissions.sddl) | Should Be $true
            $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($published.sddl)
            $creatorOwnerAces=@($descriptor.DiscretionaryAcl | Where-Object {
                $_ -is [Security.AccessControl.KnownAce] -and
                $_.SecurityIdentifier.Value -ceq $fixture.EffectiveOwnerSid -and
                ($_.AceFlags -band [Security.AccessControl.AceFlags]::Inherited) -ne 0
            })
            $creatorOwnerAces.Count | Should Be 1
            @($descriptor.DiscretionaryAcl | Where-Object { $_ -is [Security.AccessControl.KnownAce] -and $_.SecurityIdentifier.Value -ceq 'S-1-3-0' }).Count | Should Be 0
        } finally { Close-P7Fixture $f @($control.Lease,$stage.Lease) }
    }
    }

    # Scenario: Strict journal v1 reader output is passed unchanged to all three Windows file mutation shapes.
    # Purpose: Keep the platform operation contract synchronized with every property emitted by the durable reader.
    It 'InterT430_accepts_strict_reader_write_create_and_remove_file_operations' {
        $f=New-P7Fixture 'p7-strict-journal';$writeTarget=$null;$writeStage=$null;$createStage=$null;$removeTarget=$null
        try {
            $writeTarget=New-P7File $f.Parent 'write' ([Text.Encoding]::UTF8.GetBytes('write-old'))
            $writePermissions=Get-PlatformPermissions $writeTarget.Lease;$writeTarget.Lease.Dispose();$writeTarget.Lease=$null
            $writeStage=New-P7File $f.Transaction 'write.stage' ([Text.Encoding]::UTF8.GetBytes('write-new'))
            $writeApplied=[pscustomobject]@{exists=$true;sha256=$writeStage.State.sha256;length=$writeStage.State.length;identity=$writeStage.State.identity}
            $writeOperation=New-P7JournalOperation write-file stage-rename 'target/write' 'write.stage' 'write.backup' $writeTarget.State $writeApplied $writePermissions
            $writeReceipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'write' -TransactionLease $f.Transaction -StageLease $writeStage.Lease -ExpectedState $writeTarget.State -DisplacedLeaf 'write.backup' -ExpectedStage $writeStage.Expected -Journal $writeOperation
            $writeReceipt.appliedIdentity.fileId | Should Be $writeStage.State.identity.fileId
            [IO.File]::ReadAllText((Join-Path $f.Root 'target/write')) | Should Be 'write-new'

            $createStage=New-P7File $f.Transaction 'create.stage' ([Text.Encoding]::UTF8.GetBytes('created'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $createApplied=[pscustomobject]@{exists=$true;sha256=$createStage.State.sha256;length=$createStage.State.length;identity=$createStage.State.identity}
            $createOperation=New-P7JournalOperation create-file stage-rename 'target/created' 'create.stage' $null $missing $createApplied $null
            $createReceipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $createStage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $createStage.Expected -NoReplace -Journal $createOperation
            $createReceipt.appliedIdentity.fileId | Should Be $createStage.State.identity.fileId
            [IO.File]::ReadAllText((Join-Path $f.Root 'target/created')) | Should Be 'created'

            $removeTarget=New-P7File $f.Parent 'remove' ([Text.Encoding]::UTF8.GetBytes('remove-old'))
            $removePermissions=Get-PlatformPermissions $removeTarget.Lease;$removeTarget.Lease.Dispose();$removeTarget.Lease=$null
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $removeOperation=New-P7JournalOperation remove-file tombstone-rename 'target/remove' $null 'remove.backup' $removeTarget.State $removed $removePermissions
            $removeReceipt=Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'remove' -ExpectedState $removeTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'remove.backup' -Journal $removeOperation
            $removeReceipt.backupIdentity.fileId | Should Be $removeTarget.State.identity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root 'target/remove') | Should Be $false
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/remove.backup") | Should Be $true
        } finally { Close-P7Fixture $f @($writeStage.Lease,$createStage.Lease,$writeTarget.Lease,$removeTarget.Lease) }
    }

    # Scenario: A file journal operation carries the directory-only quarantine leaf after strict validation.
    # Purpose: Reject the schema-incompatible durable intent before permissions or names change.
    It 'InterT440_rejects_a_non_null_file_quarantine_leaf_without_mutation' {
        $f=New-P7Fixture 'p7-journal-quarantine';$stage=$null
        try {
            $stage=New-P7File $f.Transaction 'create.stage' ([Text.Encoding]::UTF8.GetBytes('created'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.State.sha256;length=$stage.State.length;identity=$stage.State.identity}
            $operation=New-P7JournalOperation create-file stage-rename 'target/created' 'create.stage' $null $missing $applied $null
            $operation.quarantineLeaf='unexpected.quarantine'
            $stageBefore=Get-P7NamedFileState $f.Transaction 'create.stage' $stage
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $operation } | Should Throw 'Journal'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/created') | Should Be $false
            $stageAfter=Get-P7NamedFileState $f.Transaction 'create.stage' $stage
            $stageAfter.bytes | Should Be $stageBefore.bytes
            $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId
        } finally { Close-P7Fixture $f @($stage.Lease) }
    }

    # Scenario: Durable applied identity names another same-content file instead of the bound stage.
    # Purpose: Reject before DACL/readOnly mutation or rename even when hash and length still match.
    It 'InterT450_rejects_journal_applied_identity_mismatch_without_mutation' {
        $f=New-P7Fixture 'p7-journal-identity';$stage=$null;$other=$null
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes('same-bytes')
            $stage=New-P7File $f.Transaction 'create.stage' $bytes
            $other=New-P7File $f.Transaction 'other.stage' $bytes
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.State.sha256;length=$stage.State.length;identity=$other.State.identity}
            $operation=New-P7JournalOperation create-file stage-rename 'target/created' 'create.stage' $null $missing $applied $null
            $stageBefore=Get-P7NamedFileState $f.Transaction 'create.stage' $stage
            $stagePermissionsBefore=Get-PlatformPermissions $stage.Lease
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $operation } | Should Throw 'Journal'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/created') | Should Be $false
            $stageAfter=Get-P7NamedFileState $f.Transaction 'create.stage' $stage
            $stageAfter.bytes | Should Be $stageBefore.bytes
            $stageAfter.identity.fileId | Should Be $stageBefore.identity.fileId
            (Get-PlatformPermissions $stage.Lease).sddl | Should Be $stagePermissionsBefore.sddl
            (Get-PlatformPermissions $stage.Lease).readOnly | Should Be $stagePermissionsBefore.readOnly
        } finally { Close-P7Fixture $f @($stage.Lease,$other.Lease) }
    }

    # Scenario: The stage name is replaced by a different same-content identity between caller validation and mutation reopen.
    # Purpose: Reject identity substitution despite matching bytes and leave the target absent.
    It 'InterT460_rejects_a_same_bytes_replacement_stage_identity' {
        $f=New-P7Fixture 'p7-replaced-stage';$stage=$null;$replacement=$null
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes('same-bytes')
            $stage=New-P7File $f.Transaction 'create.stage' $bytes
            $replacement=New-P7File $f.Transaction 'replacement.stage' $bytes
            $replacement.Lease.Dispose();$replacement.Lease=$null
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.State.sha256;length=$stage.State.length;identity=$stage.State.identity}
            $operation=New-P7JournalOperation create-file stage-rename 'target/created' 'create.stage' $null $missing $applied $null
            $transactionPath=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)"
            Set-P7WindowsPreReopenHook ({
                param($point,$operationName,$role,$path)
                if($operationName -ceq 'publication' -and $role -ceq 'stage'){
                    [IO.File]::Move($path,(Join-Path $transactionPath 'original.stage'))
                    [IO.File]::Move((Join-Path $transactionPath 'replacement.stage'),$path)
                }
            }.GetNewClosure())
            { Publish-PlatformFile -ParentLease $f.Parent -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $operation } | Should Throw
            Set-P7WindowsPreReopenHook $null
            Test-Path -LiteralPath (Join-Path $f.Root 'target/created') | Should Be $false
            $replaced=Get-P7NamedFileState $f.Transaction 'create.stage'
            $preserved=Get-P7NamedFileState $f.Transaction 'original.stage'
            $replaced.bytes | Should Be $preserved.bytes
            $replaced.identity.fileId | Should Be $replacement.State.identity.fileId
            $preserved.identity.fileId | Should Be $stage.State.identity.fileId
        } finally { Set-P7WindowsPreReopenHook $null;Close-P7Fixture $f @($stage.Lease,$replacement.Lease) }
    }

    # Scenario: An owned target directory is moved to transaction backup and then restored to its target name.
    # Purpose: Preserve directory identity and contents in both rename directions without traversing the tree.
    It 'InterT730_moves_owned_directories_in_both_directions_with_identity_and_content_preserved' {
        $f=New-P7Fixture 'p7d2-roundtrip'
        try{
            $directory=New-P7Directory $f Parent 'runtime' 'original-content'
            $toReceipt=Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'runtime' -TransactionLease $f.Transaction -DestinationLeaf 'runtime.backup' -ExpectedIdentity $directory.Identity -Direction ToTransaction -ExpectedState $directory.State
            (@($toReceipt.PSObject.Properties.Name)-join ',')|Should Be 'capability,sourceLeaf,destinationLeaf,direction,identity'
            $toReceipt.capability|Should Be 'directory-publication'
            $toReceipt.identity.fileId|Should Be $directory.Identity.fileId
            Test-Path -LiteralPath $directory.Path|Should Be $false
            [IO.File]::ReadAllText((Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/runtime.backup/marker.txt"))|Should Be 'original-content'

            $fromReceipt=Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'runtime.backup' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $directory.Identity -Direction FromTransaction -ExpectedState $directory.State
            $fromReceipt.identity.fileId|Should Be $directory.Identity.fileId
            [IO.File]::ReadAllText((Join-Path $directory.Path 'marker.txt'))|Should Be 'original-content'
        }finally{Close-P7Fixture $f}
    }

    # Scenario: A stage directory is published while the destination name already exists.
    # Purpose: Require native no-replace failure and leave both source and destination trees unchanged.
    It 'InterT735_rejects_an_existing_directory_destination_without_mutation' {
        $f=New-P7Fixture 'p7d2-existing-destination'
        try{
            $stage=New-P7Directory $f Transaction 'stage' 'stage-content'
            $existing=New-P7Directory $f Parent 'runtime' 'existing-content'
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $stage.Identity -Direction FromTransaction}|Should Throw
            [IO.File]::ReadAllText((Join-Path $stage.Path 'marker.txt'))|Should Be 'stage-content'
            [IO.File]::ReadAllText((Join-Path $existing.Path 'marker.txt'))|Should Be 'existing-content'
        }finally{Close-P7Fixture $f}
    }

    # Scenario: The source name is a directory junction that points outside the transaction target tree.
    # Purpose: Reject reparse sources before rename and preserve the outside directory.
    It 'InterT740_rejects_a_reparse_directory_source_without_mutation' {
        $f=New-P7Fixture 'p7d2-reparse-source'
        try{
            $outside=Join-Path $f.Root 'outside';[void][IO.Directory]::CreateDirectory($outside);[IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'),'outside')
            $ordinary=New-P7Directory $f Parent 'identity-source'
            $link=Join-Path $f.Root 'target/runtime';New-Item -ItemType Junction -Path $link -Target $outside|Out-Null
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'runtime' -TransactionLease $f.Transaction -DestinationLeaf 'runtime.backup' -ExpectedIdentity $ordinary.Identity -Direction ToTransaction}|Should Throw 'directory-publication'
            [IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt'))|Should Be 'outside'
            Test-Path -LiteralPath $link|Should Be $true
        }finally{Close-P7Fixture $f}
    }

    # Scenario: A caller binds a real source directory to a different directory identity.
    # Purpose: Stop before rename when ExpectedIdentity does not identify the source handle.
    It 'InterT745_rejects_a_directory_identity_mismatch_without_mutation' {
        $f=New-P7Fixture 'p7d2-identity-mismatch'
        try{
            $stage=New-P7Directory $f Transaction 'stage' 'stage-content'
            $other=New-P7Directory $f Transaction 'other' 'other-content'
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $other.Identity -Direction FromTransaction}|Should Throw 'identity'
            [IO.File]::ReadAllText((Join-Path $stage.Path 'marker.txt'))|Should Be 'stage-content'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/runtime')|Should Be $false
        }finally{Close-P7Fixture $f}
    }

    # Scenario: The target lease is inside the transaction store, or the transaction leaf is not a lowercase transaction ID.
    # Purpose: Enforce transaction topology before opening or renaming a source directory.
    It 'InterT750_rejects_transaction_targets_and_invalid_transaction_names_without_mutation' {
        $f=New-P7Fixture 'p7d2-topology';$badLease=$null
        try{
            $stage=New-P7Directory $f Transaction 'stage' 'stage-content'
            {Move-PlatformOwnedDirectory -ParentLease $f.Transaction -Leaf 'stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $stage.Identity -Direction FromTransaction}|Should Throw 'outside'
            $badLease=Open-PlatformDirectory -Root (Join-Path $f.Root '.ai-instructions-txn') -RelativePath 'BAD' -CreatePrivate
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'stage' -TransactionLease $badLease -DestinationLeaf 'runtime' -ExpectedIdentity $stage.Identity -Direction FromTransaction}|Should Throw '32 lowercase hex'
            [IO.File]::ReadAllText((Join-Path $stage.Path 'marker.txt'))|Should Be 'stage-content'
        }finally{if($null -ne $badLease){$badLease.Dispose()};Close-P7Fixture $f}
    }

    # Scenario: Directory journal intent disagrees with the bound target leaf, identity, or operation kind.
    # Purpose: Reject every mismatch before any source or destination name changes.
    It 'InterT755_rejects_directory_journal_mismatches_without_mutation' {
        $f=New-P7Fixture 'p7d2-journal-mismatch'
        try{
            $original=New-P7Directory $f Parent 'runtime' 'original-content'
            $stage=New-P7Directory $f Transaction 'stage' 'stage-content'
            $originalLease=Open-PlatformDirectory -Root $f.Root -RelativePath 'target/runtime'
            try{$originalPermissions=Get-PlatformPermissions $originalLease}finally{$originalLease.Dispose()}
            $operation=New-P7JournalOperation swap-directory stage-rename 'target/runtime' 'stage' 'runtime.backup' $original.State $stage.State $originalPermissions 'runtime.quarantine'
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'runtime' -TransactionLease $f.Transaction -DestinationLeaf 'runtime.backup' -ExpectedIdentity $original.Identity -Direction ToTransaction -Journal $operation}|Should Throw 'ExpectedState'
            $wrongState=($original.State|ConvertTo-Json -Depth 10|ConvertFrom-Json);$wrongState.inventorySha256='b'*64
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'runtime' -TransactionLease $f.Transaction -DestinationLeaf 'runtime.backup' -ExpectedIdentity $original.Identity -Direction ToTransaction -ExpectedState $wrongState -Journal $operation}|Should Throw 'Journal'
            $cases=@(
                {param($x)$x.targetRelativePath='target/other'},
                {param($x)$x.original.identity=$stage.Identity;$x.backupIdentity=$stage.Identity},
                {param($x)$x.kind='write-file'}
            )
            foreach($change in $cases){
                $copy=($operation|ConvertTo-Json -Depth 20|ConvertFrom-Json);& $change $copy
                {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'runtime' -TransactionLease $f.Transaction -DestinationLeaf 'runtime.backup' -ExpectedIdentity $original.Identity -Direction ToTransaction -ExpectedState $original.State -Journal $copy}|Should Throw 'Journal'
                [IO.File]::ReadAllText((Join-Path $original.Path 'marker.txt'))|Should Be 'original-content'
                Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/runtime.backup")|Should Be $false
            }
        }finally{Close-P7Fixture $f}
    }

    # Scenario: A complete transaction directory contains nested directories and files.
    # Purpose: Remove every owned entry and report the exact transaction leaf through the directory-tree primitive.
    It 'InterT760_removes_a_nested_transaction_directory_tree' {
        $f=New-P7Fixture 'p7d2-remove-tree'
        try{
            $nested=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/one/two";[void][IO.Directory]::CreateDirectory($nested);[IO.File]::WriteAllText((Join-Path $nested 'data.txt'),'data')
            $f.Transaction.Dispose();$f.Transaction=$null
            $receipt=Remove-PlatformOwnedDirectoryTree -TransactionRootLease $f.TransactionRoot -Leaf $f.TransactionId -ExpectedIdentity $f.TransactionIdentity
            (@($receipt.PSObject.Properties.Name)-join ',')|Should Be 'capability,removedEntryCount,leaf'
            $receipt.capability|Should Be 'owned-file-removal'
            $receipt.removedEntryCount|Should BeGreaterThan 2
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)")|Should Be $false
        }finally{Close-P7Fixture $f}
    }

    # Scenario: An owned backup tree contains a junction to a directory outside the transaction store.
    # Purpose: Delete the junction itself without following it or changing the outside sentinel.
    It 'InterT765_removes_an_internal_junction_without_following_its_target' {
        $f=New-P7Fixture 'p7d2-remove-junction'
        try{
            $outside=Join-Path $f.Root 'outside';[void][IO.Directory]::CreateDirectory($outside);[IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'),'outside')
            $backup=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/runtime.backup";[void][IO.Directory]::CreateDirectory($backup)
            $backupState=Get-PlatformDirectoryState -ParentLease $f.Transaction -Leaf 'runtime.backup'
            New-Item -ItemType Junction -Path (Join-Path $backup 'external') -Target $outside|Out-Null
            $receipt=Remove-PlatformOwnedDirectoryTree -TransactionLease $f.Transaction -Leaf 'runtime.backup' -ExpectedIdentity $backupState.identity
            $receipt.removedEntryCount|Should Be 2
            Test-Path -LiteralPath $backup|Should Be $false
            [IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt'))|Should Be 'outside'
        }finally{Close-P7Fixture $f}
    }

    # Scenario: Cleanup is requested with a non-transaction leaf or with a lease outside the reserved transaction container.
    # Purpose: Fail before recursive deletion and preserve every directory and file.
    It 'InterT770_rejects_invalid_directory_tree_cleanup_boundaries_without_mutation' {
        $f=New-P7Fixture 'p7d2-remove-boundary'
        try{
            $nested=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/backup";[void][IO.Directory]::CreateDirectory($nested);[IO.File]::WriteAllText((Join-Path $nested 'data.txt'),'data')
            $backupState=Get-PlatformDirectoryState -ParentLease $f.Transaction -Leaf 'backup'
            {Remove-PlatformOwnedDirectoryTree -TransactionRootLease $f.TransactionRoot -Leaf 'not-a-transaction' -ExpectedIdentity $backupState.identity}|Should Throw '32 lowercase'
            {Remove-PlatformOwnedDirectoryTree -TransactionRootLease $f.Parent -Leaf $f.TransactionId -ExpectedIdentity $f.TransactionIdentity}|Should Throw '.ai-instructions-txn'
            [IO.File]::ReadAllText((Join-Path $nested 'data.txt'))|Should Be 'data'
        }finally{Close-P7Fixture $f}
    }

    # Scenario: Create-file journals either omit permissions or bind an explicit snapshot, including a corrupted post-write readback.
    # Purpose: Derive null permissions from the target parent, apply non-null permissions before rename, and roll back a mismatched readback with no publication.
    It 'InterT775_applies_create_file_permission_semantics_before_rename' {
        $f=New-P7Fixture 'p7d2-create-permissions';$control=$null;$inheritedStage=$null;$boundStage=$null;$mismatchStage=$null;$caught=$null
        try{
            [void](Set-P7InheritanceFixture $f)
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $control=New-P7File $f.Parent 'control' ([byte[]]@(1));$controlPermissions=Get-PlatformPermissions $control.Lease
            $inheritedStage=New-P7File $f.Transaction 'inherited.stage' ([Text.Encoding]::UTF8.GetBytes('inherited'))
            $inheritedApplied=[pscustomobject]@{exists=$true;sha256=$inheritedStage.State.sha256;length=$inheritedStage.State.length;identity=$inheritedStage.State.identity}
            $inheritedOperation=New-P7JournalOperation create-file stage-rename 'target/inherited' 'inherited.stage' $null $missing $inheritedApplied $null
            [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'inherited' -TransactionLease $f.Transaction -StageLease $inheritedStage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $inheritedStage.Expected -NoReplace -Journal $inheritedOperation)
            $inheritedPublished=Get-P7NamedFileState $f.Parent 'inherited'
            (Test-P7EquivalentDacl $inheritedPublished.sddl $controlPermissions.sddl)|Should Be $true

            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$snapshot=[pscustomobject]@{kind='windows-sddl';sddl=('D:P(A;;FA;;;'+$identity.User.Value+')');readOnly=$false}}finally{$identity.Dispose()}
            $boundStage=New-P7File $f.Transaction 'bound.stage' ([Text.Encoding]::UTF8.GetBytes('bound'))
            $boundApplied=[pscustomobject]@{exists=$true;sha256=$boundStage.State.sha256;length=$boundStage.State.length;identity=$boundStage.State.identity}
            $boundOperation=New-P7JournalOperation create-file stage-rename 'target/bound' 'bound.stage' $null $missing $boundApplied $snapshot
            [void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'bound' -TransactionLease $f.Transaction -StageLease $boundStage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $boundStage.Expected -NoReplace -Journal $boundOperation)
            $boundPublished=Get-P7NamedFileState $f.Parent 'bound'
            (Test-P7EquivalentDacl $boundPublished.sddl $snapshot.sddl)|Should Be $true

            $mismatchStage=New-P7File $f.Transaction 'mismatch.stage' ([Text.Encoding]::UTF8.GetBytes('mismatch'))
            $mismatchBefore=Get-P7NamedFileState $f.Transaction 'mismatch.stage' $mismatchStage
            $mismatchApplied=[pscustomobject]@{exists=$true;sha256=$mismatchStage.State.sha256;length=$mismatchStage.State.length;identity=$mismatchStage.State.identity}
            $mismatchOperation=New-P7JournalOperation create-file stage-rename 'target/mismatch' 'mismatch.stage' $null $missing $mismatchApplied $snapshot
            $hookState=@{Injected=$false}
            Set-P7WindowsPublicationDaclHook ({param($point)if($point -ceq 'after-low-level-dacl-write-before-readback' -and -not $hookState.Injected){$hookState.Injected=$true;$field=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative].GetField('PublicationDaclReadbackSddlTestOverride',[Reflection.BindingFlags]'Static,NonPublic');$field.SetValue($null,[string]$mismatchBefore.sddl)}}.GetNewClosure())
            try{[void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'mismatch' -TransactionLease $f.Transaction -StageLease $mismatchStage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $mismatchStage.Expected -NoReplace -Journal $mismatchOperation)}catch{$caught=$_}finally{Set-P7WindowsPublicationDaclHook $null}
            $hookState.Injected|Should Be $true
            $caught|Should Not BeNullOrEmpty
            $typed=$caught.Exception;if($typed -is [Management.Automation.MethodInvocationException] -and $null -ne $typed.InnerException){$typed=$typed.InnerException};$typed.GetType().Name|Should Be 'PlatformVerificationException'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/mismatch')|Should Be $false
            $mismatchAfter=Get-P7NamedFileState $f.Transaction 'mismatch.stage' $mismatchStage
            $mismatchAfter.bytes|Should Be $mismatchBefore.bytes;$mismatchAfter.identity.fileId|Should Be $mismatchBefore.identity.fileId;(Test-P7EquivalentDacl $mismatchAfter.sddl $mismatchBefore.sddl)|Should Be $true;$mismatchAfter.readOnly|Should Be $mismatchBefore.readOnly
        }finally{Set-P7WindowsPublicationDaclHook $null;Close-P7Fixture $f @($control.Lease,$boundStage.Lease,$inheritedStage.Lease,$mismatchStage.Lease)}
    }

    # Scenario: A same-user writer changes a create-file target DACL after its applied rename but before permission readback.
    # Purpose: Preserve the published target for journal recovery and attach a receipt instead of attempting an unjournaled rename-back.
    It 'InterT780_preserves_post_rename_create_file_permission_mismatches_for_recovery' {
        $f=New-P7Fixture 'p7d2-create-permissions-post-rename';$stage=$null;$caught=$null
        try{
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try{
                $expectedPermissions=[pscustomobject]@{kind='windows-sddl';sddl=('D:P(A;;FA;;;'+$identity.User.Value+')');readOnly=$false}
                $changedSddl='D:P(A;;FA;;;'+$identity.User.Value+')(A;;FR;;;WD)'
            }finally{$identity.Dispose()}
            $stage=New-P7File $f.Transaction 'post-rename.stage' ([Text.Encoding]::UTF8.GetBytes('published'))
            $stageIdentity=$stage.State.identity
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.State.sha256;length=$stage.State.length;identity=$stageIdentity}
            $operation=New-P7JournalOperation create-file stage-rename 'target/post-rename' 'post-rename.stage' $null $missing $applied $expectedPermissions
            $hookState=@{Injected=$false}
            Set-P7WindowsDurabilityHook ({param($point,$operationName,$role,$lease)if($point -ceq 'after-applied-rename-before-permission-readback' -and -not $hookState.Injected){$hookState.Injected=$true;[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ApplyPublicationDacl($lease,$changedSddl)}}.GetNewClosure())
            try{[void](Publish-PlatformFile -ParentLease $f.Parent -Leaf 'post-rename' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $operation)}catch{$caught=$_}finally{Set-P7WindowsDurabilityHook $null}

            $hookState.Injected|Should Be $true
            $caught|Should Not BeNullOrEmpty
            $typed=$caught.Exception;if($typed -is [Management.Automation.MethodInvocationException] -and $null -ne $typed.InnerException){$typed=$typed.InnerException}
            $typed.GetType().Name|Should Be 'PlatformVerificationException';$typed.Capability|Should Be 'publication'
            $receipt=$typed.Data['Receipt'];$receipt|Should Not BeNullOrEmpty;$receipt.completedSteps|Should Contain 'applied-rename';$receipt.appliedIdentity.fileId|Should Be $stageIdentity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/post-rename.stage")|Should Be $false
            $published=Get-P7NamedFileState $f.Parent 'post-rename'
            $published.bytes|Should Be ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('published')));$published.identity.fileId|Should Be $stageIdentity.fileId
        }finally{Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f @($stage.Lease)}
    }

    # Scenario: A directory state contains every file and empty directory, including runtime-bundle.json, and rejects a junction.
    # Purpose: Match the journal v1 ordinal inventory digest while detecting every complete-tree mutation without following reparses.
    It 'InterT785_captures_complete_directory_inventory_state' {
        $f=New-P7Fixture 'p7d2-directory-state'
        try{
            $path=Join-Path $f.Root 'target/runtime';[void][IO.Directory]::CreateDirectory($path)
            $bundleBytes=[Text.UTF8Encoding]::new($false).GetBytes('bundle-one');[IO.File]::WriteAllBytes((Join-Path $path 'runtime-bundle.json'),$bundleBytes)
            $initial=Get-PlatformDirectoryState -ParentLease $f.Parent -Leaf 'runtime'
            $bundleBytes=[Text.UTF8Encoding]::new($false).GetBytes('bundle-two');[IO.File]::WriteAllBytes((Join-Path $path 'runtime-bundle.json'),$bundleBytes)
            $changedBundle=Get-PlatformDirectoryState -ParentLease $f.Parent -Leaf 'runtime';$changedBundle.inventorySha256|Should Not Be $initial.inventorySha256
            [void][IO.Directory]::CreateDirectory((Join-Path $path 'empty'))
            $withEmpty=Get-PlatformDirectoryState -ParentLease $f.Parent -Leaf 'runtime';$withEmpty.inventorySha256|Should Not Be $changedBundle.inventorySha256;$withEmpty.entryCount|Should Be ($changedBundle.entryCount+1)
            $extraBytes=[Text.UTF8Encoding]::new($false).GetBytes('extra');[IO.File]::WriteAllBytes((Join-Path $path 'extra.txt'),$extraBytes)
            $withFile=Get-PlatformDirectoryState -ParentLease $f.Parent -Leaf 'runtime';$withFile.inventorySha256|Should Not Be $withEmpty.inventorySha256;$withFile.entryCount|Should Be ($withEmpty.entryCount+1)
            $inventory=@(
                [pscustomobject]@{path='empty/';sha256=(Get-P7Hash ([byte[]]@()));length=[int64]0},
                [pscustomobject]@{path='extra.txt';sha256=(Get-P7Hash $extraBytes);length=[int64]$extraBytes.Length},
                [pscustomobject]@{path='runtime-bundle.json';sha256=(Get-P7Hash $bundleBytes);length=[int64]$bundleBytes.Length}
            )
            $journalState=& $script:P7RuntimeContractModule.ExportedCommands['Get-AiInstructionsInstallJournalDirectoryState'] -Inventory $inventory -Identity $withFile.identity
            $withFile.inventorySha256|Should Be $journalState.inventorySha256;$withFile.entryCount|Should Be $journalState.entryCount
            $missing=Get-PlatformDirectoryState -ParentLease $f.Parent -Leaf 'missing'
            (@($missing.PSObject.Properties.Name)-join ',')|Should Be 'exists,identity,inventorySha256,entryCount';$missing.exists|Should Be $false;$missing.identity|Should BeNullOrEmpty;$missing.inventorySha256|Should BeNullOrEmpty;$missing.entryCount|Should BeNullOrEmpty
            $outside=Join-Path $f.Root 'outside';[void][IO.Directory]::CreateDirectory($outside);New-Item -ItemType Junction -Path (Join-Path $path 'junction') -Target $outside|Out-Null
            {Get-PlatformDirectoryState -ParentLease $f.Parent -Leaf 'runtime'}|Should Throw 'directory-publication'
        }finally{Close-P7Fixture $f}
    }

    # Scenario: A held source directory keeps its root identity while a child changes or an empty child directory appears.
    # Purpose: Refuse both renames by comparing complete-tree state immediately before the native rename.
    It 'InterT790_rejects_directory_tree_changes_with_zero_rename_mutation' {
        $f=New-P7Fixture 'p7d2-directory-state-mismatch'
        try{
            $content=New-P7Directory $f Transaction 'content-stage' 'before';[IO.File]::WriteAllText((Join-Path $content.Path 'marker.txt'),'after',[Text.UTF8Encoding]::new($false))
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'content-stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $content.Identity -Direction FromTransaction -ExpectedState $content.State}|Should Throw 'complete-tree'
            [IO.File]::ReadAllText((Join-Path $content.Path 'marker.txt'))|Should Be 'after';Test-Path -LiteralPath (Join-Path $f.Root 'target/runtime')|Should Be $false

            $empty=New-P7Directory $f Transaction 'empty-stage' 'stable';[void][IO.Directory]::CreateDirectory((Join-Path $empty.Path 'new-empty'))
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'empty-stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $empty.Identity -Direction FromTransaction -ExpectedState $empty.State}|Should Throw 'complete-tree'
            Test-Path -LiteralPath (Join-Path $empty.Path 'new-empty')|Should Be $true;Test-Path -LiteralPath (Join-Path $f.Root 'target/runtime')|Should Be $false
        }finally{Close-P7Fixture $f}
    }

    # Scenario: Failure injection fires before a directory source reopen and immediately before its native rename.
    # Purpose: Register the directory-publication hook points and prove both stop with zero mutation.
    It 'InterT795_exposes_directory_publication_preopen_and_prerename_failure_hooks' {
        $f=New-P7Fixture 'p7d2-directory-hooks'
        try{
            $stage=New-P7Directory $f Transaction 'stage' 'stage-content'
            $points=New-Object Collections.Generic.List[string]
            Set-P7WindowsPreReopenHook {param($point,$operation,$role,$path)$points.Add("$operation/$point")|Out-Null;throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('directory-publication','windows','injected preopen failure')}
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $stage.Identity -Direction FromTransaction}|Should Throw 'preopen'
            Set-P7WindowsPreReopenHook $null
            $points|Should Contain 'directory-publication/before-directory-open'
            [IO.File]::ReadAllText((Join-Path $stage.Path 'marker.txt'))|Should Be 'stage-content'

            Set-P7WindowsDurabilityHook {param($point,$operation,$role,$lease)if($point -ceq 'before-directory-rename'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('directory-publication','windows','injected prerename failure')}}
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $stage.Identity -Direction FromTransaction}|Should Throw 'prerename'
            [IO.File]::ReadAllText((Join-Path $stage.Path 'marker.txt'))|Should Be 'stage-content'
            Test-Path -LiteralPath (Join-Path $f.Root 'target/runtime')|Should Be $false
        }finally{Set-P7WindowsPreReopenHook $null;Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f}
    }

    # Scenario: A non-cooperating same-user writer adds an empty destination child after rename but before the post-check.
    # Purpose: Return a typed error with the completed-rename receipt and leave rollback to the journal caller.
    It 'InterT800_rejects_post_rename_directory_changes_without_automatic_compensation' {
        $f=New-P7Fixture 'p7d2-directory-postcheck';$caught=$null
        try{
            $stage=New-P7Directory $f Transaction 'stage' 'stage-content'
            $destinationPath=Join-Path $f.Root 'target/runtime'
            $hookState=@{Injected=$false}
            Set-P7WindowsDurabilityHook ({param($point,$operation,$role,$lease)if($operation -ceq 'directory-publication' -and $point -ceq 'post-rename' -and -not $hookState.Injected){$hookState.Injected=$true;[void][IO.Directory]::CreateDirectory((Join-Path $destinationPath 'raced-empty'))}}.GetNewClosure())
            try{[void](Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf 'stage' -TransactionLease $f.Transaction -DestinationLeaf 'runtime' -ExpectedIdentity $stage.Identity -Direction FromTransaction -ExpectedState $stage.State)}catch{$caught=$_}
            $hookState.Injected|Should Be $true
            $caught|Should Not BeNullOrEmpty
            $typed=$caught.Exception;if($typed -is [Management.Automation.MethodInvocationException] -and $null -ne $typed.InnerException){$typed=$typed.InnerException}
            $typed.GetType().Name|Should Be 'PlatformVerificationException';$typed.Capability|Should Be 'directory-publication'
            $receipt=$typed.Data['Receipt'];$receipt|Should Not BeNullOrEmpty
            $receipt.capability|Should Be 'directory-publication';$receipt.sourceLeaf|Should Be 'stage';$receipt.destinationLeaf|Should Be 'runtime';$receipt.direction|Should Be 'FromTransaction';$receipt.identity.fileId|Should Be $stage.Identity.fileId
            Test-Path -LiteralPath $stage.Path|Should Be $false
            Test-Path -LiteralPath $destinationPath|Should Be $true
            Test-Path -LiteralPath (Join-Path $destinationPath 'raced-empty')|Should Be $true
        }finally{Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f}
    }

    # Scenario: Failure injection fires before recursive deletion of an owned transaction subtree.
    # Purpose: Register the owned-directory-tree cleanup hook and preserve every entry when it rejects the operation.
    It 'InterT805_exposes_the_owned_directory_tree_predelete_failure_hook' {
        $f=New-P7Fixture 'p7d2-tree-hook'
        try{
            $backup=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/backup";[void][IO.Directory]::CreateDirectory($backup);[IO.File]::WriteAllText((Join-Path $backup 'data.txt'),'data')
            $backupState=Get-PlatformDirectoryState -ParentLease $f.Transaction -Leaf 'backup'
            Set-P7WindowsDurabilityHook {param($point,$operation,$role,$lease)if($point -ceq 'before-owned-directory-tree-delete'){throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new('owned-file-removal','windows','injected tree cleanup failure')}}
            {Remove-PlatformOwnedDirectoryTree -TransactionLease $f.Transaction -Leaf 'backup' -ExpectedIdentity $backupState.identity}|Should Throw 'tree cleanup'
            [IO.File]::ReadAllText((Join-Path $backup 'data.txt'))|Should Be 'data'
        }finally{Set-P7WindowsDurabilityHook $null;Close-P7Fixture $f}
    }

    # Scenario: An owned transaction subtree contains read-only files and read-only directories.
    # Purpose: Delete the entire tree with disposition-ex ignore-readonly semantics or its legacy fallback.
    It 'InterT810_removes_readonly_owned_directory_trees' {
        $f=New-P7Fixture 'p7d2-readonly-tree'
        try{
            $backup=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/backup";$nested=Join-Path $backup 'nested';[void][IO.Directory]::CreateDirectory($nested)
            $file=Join-Path $nested 'data.txt';[IO.File]::WriteAllText($file,'data',[Text.UTF8Encoding]::new($false))
            [IO.File]::SetAttributes($file,[IO.File]::GetAttributes($file)-bor[IO.FileAttributes]::ReadOnly)
            [IO.File]::SetAttributes($nested,[IO.File]::GetAttributes($nested)-bor[IO.FileAttributes]::ReadOnly)
            [IO.File]::SetAttributes($backup,[IO.File]::GetAttributes($backup)-bor[IO.FileAttributes]::ReadOnly)
            $backupState=Get-PlatformDirectoryState -ParentLease $f.Transaction -Leaf 'backup'
            $receipt=Remove-PlatformOwnedDirectoryTree -TransactionLease $f.Transaction -Leaf 'backup' -ExpectedIdentity $backupState.identity
            $receipt.removedEntryCount|Should Be 3;Test-Path -LiteralPath $backup|Should Be $false
        }finally{Close-P7Fixture $f}
    }

    # Scenario: An owned transaction tree contains a hard link to a read-only file outside the tree.
    # Purpose: Refuse cleanup before clearing attributes or deleting links so the shared external inode remains unchanged.
    It 'InterT815_rejects_hard_linked_owned_tree_files_before_attribute_mutation' {
        $f=New-P7Fixture 'p7d2-hardlink-tree';$backupLease=$null
        $external=Join-Path $f.Root 'external.txt';$backup=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/backup"
        try{
            [IO.File]::WriteAllText($external,'outside',[Text.UTF8Encoding]::new($false))
            [IO.File]::SetAttributes($external,[IO.File]::GetAttributes($external)-bor[IO.FileAttributes]::ReadOnly)
            [void][IO.Directory]::CreateDirectory($backup)
            New-Item -ItemType HardLink -Path (Join-Path $backup 'linked.txt') -Target $external|Out-Null
            $backupLease=Open-PlatformDirectory -Root (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)") -RelativePath backup
            $backupIdentity=Get-P7Identity $backupLease.Observation
            $backupLease.Dispose();$backupLease=$null

            $caught=$null
            try{Remove-PlatformOwnedDirectoryTree -TransactionLease $f.Transaction -Leaf backup -ExpectedIdentity $backupIdentity|Out-Null}catch{$caught=$_}

            $caught|Should Not BeNullOrEmpty
            $typed=$caught.Exception;if($typed -is [Management.Automation.MethodInvocationException] -and $null-ne$typed.InnerException){$typed=$typed.InnerException}
            $typed.GetType().Name|Should Be 'PlatformVerificationException';$typed.Capability|Should Be 'owned-file-removal';$typed.Message|Should Match 'exactly one link'
            [IO.File]::ReadAllText($external)|Should Be 'outside'
            ([IO.File]::GetAttributes($external)-band[IO.FileAttributes]::ReadOnly)|Should Be ([IO.FileAttributes]::ReadOnly)
            Test-Path -LiteralPath (Join-Path $backup 'linked.txt')|Should Be $true
        }finally{
            if($null-ne$backupLease){$backupLease.Dispose()}
            if(Test-Path -LiteralPath $external){[IO.File]::SetAttributes($external,[IO.FileAttributes]::Normal)}
            if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Recurse -Force}
            Close-P7Fixture $f
        }
    }

    # Scenario: The caller releases a transaction lease and a same-user writer replaces the UUID directory before whole-tree cleanup.
    # Purpose: Bind recursive cleanup to the recorded root identity and preserve every entry in the replacement directory on mismatch.
    It 'InterT820_rejects_replaced_transaction_directory_identity_without_deletion' {
        $f=New-P7Fixture 'p7d2-replaced-transaction-tree';$caught=$null
        try{
            $transactionPath=Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)"
            $originalPath=$transactionPath+'.original'
            [IO.File]::WriteAllText((Join-Path $transactionPath 'original.txt'),'original')
            $f.Transaction.Dispose();$f.Transaction=$null
            [IO.Directory]::Move($transactionPath,$originalPath)
            [void][IO.Directory]::CreateDirectory($transactionPath)
            [IO.File]::WriteAllText((Join-Path $transactionPath 'replacement.txt'),'replacement')

            try{[void](Remove-PlatformOwnedDirectoryTree -TransactionRootLease $f.TransactionRoot -Leaf $f.TransactionId -ExpectedIdentity $f.TransactionIdentity)}catch{$caught=$_}

            $caught|Should Not BeNullOrEmpty
            $typed=$caught.Exception;if($typed -is [Management.Automation.MethodInvocationException] -and $null -ne $typed.InnerException){$typed=$typed.InnerException}
            $typed.GetType().Name|Should Be 'PlatformVerificationException';$typed.Capability|Should Be 'owned-file-removal';$typed.Message|Should Match 'identity'
            [IO.File]::ReadAllText((Join-Path $transactionPath 'replacement.txt'))|Should Be 'replacement'
            [IO.File]::ReadAllText((Join-Path $originalPath 'original.txt'))|Should Be 'original'
        }finally{Close-P7Fixture $f}
    }

    # Scenario: Unjournaled file publication or tombstone removal targets the transaction container itself or a different transaction directory.
    # Purpose: Reject every reserved target before a file open, permission change, or rename while preserving all target and stage identities.
    It 'InterT825_rejects_reserved_file_targets_without_mutation' {
        $f=New-P7Fixture 'p7d2-reserved-file-targets';$rootLease=$null;$otherTransaction=$null;$stage=$null;$otherTarget=$null
        try{
            $rootLease=Open-PlatformDirectory -Root $f.Root -RootOnly
            $otherId=[Guid]::NewGuid().ToString('N')
            $otherTransaction=Open-PlatformDirectory -Root (Join-Path $f.Root '.ai-instructions-txn') -RelativePath $otherId -CreatePrivate
            $stage=New-P7File $f.Transaction 'publish.stage' ([Text.Encoding]::UTF8.GetBytes('new'))
            $otherTarget=New-P7File $otherTransaction 'data' ([Text.Encoding]::UTF8.GetBytes('owned'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $stageBefore=Get-P7NamedFileState $f.Transaction 'publish.stage' $stage
            $targetBefore=Get-P7NamedFileState $otherTransaction 'data' $otherTarget

            {Publish-PlatformFile -ParentLease $rootLease -Leaf '.ai-instructions-txn' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace}|Should Throw '.ai-instructions-txn'
            {Remove-PlatformOwnedFile -ParentLease $rootLease -Leaf '.ai-instructions-txn' -ExpectedState $missing -TransactionLease $f.Transaction -TombstoneLeaf 'container.backup'}|Should Throw '.ai-instructions-txn'
            {Publish-PlatformFile -ParentLease $otherTransaction -Leaf 'created' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace}|Should Throw '.ai-instructions-txn'
            {Remove-PlatformOwnedFile -ParentLease $otherTransaction -Leaf 'data' -ExpectedState $otherTarget.State -TransactionLease $f.Transaction -TombstoneLeaf 'other.backup'}|Should Throw '.ai-instructions-txn'

            $stageAfter=Get-P7NamedFileState $f.Transaction 'publish.stage' $stage
            $targetAfter=Get-P7NamedFileState $otherTransaction 'data' $otherTarget
            $stageAfter.bytes|Should Be $stageBefore.bytes;$stageAfter.identity.fileId|Should Be $stageBefore.identity.fileId
            $targetAfter.bytes|Should Be $targetBefore.bytes;$targetAfter.identity.fileId|Should Be $targetBefore.identity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root '.ai-instructions-txn')|Should Be $true
            foreach($leaf in @('container.backup','other.backup')){Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/$leaf")|Should Be $false}
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$otherId/created")|Should Be $false
        }finally{if($null -ne $rootLease){$rootLease.Dispose()};if($null -ne $otherTransaction){$otherTransaction.Dispose()};Close-P7Fixture $f @($stage.Lease,$otherTarget.Lease)}
    }

    # Scenario: D9 creates and replaces journal.json, then removes journal.prev and journal.stage as transaction-private cleanup.
    # Purpose: Preserve the narrowly scoped journal-store exception while retaining ordinary cleanup of its temporary artifacts.
    It 'InterT830_allows_only_unjournaled_journal_store_publication_and_cleanup' {
        $f=New-P7Fixture 'p7d2-journal-store';$firstStage=$null;$secondStage=$null;$cleanupStage=$null
        try{
            $firstBytes=[Text.Encoding]::UTF8.GetBytes('journal-v1');$secondBytes=[Text.Encoding]::UTF8.GetBytes('journal-v2')
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $firstStage=New-P7File $f.Transaction 'journal.stage' $firstBytes
            $firstReceipt=Publish-PlatformFile -ParentLease $f.Transaction -Leaf 'journal.json' -TransactionLease $f.Transaction -StageLease $firstStage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $firstStage.Expected -NoReplace
            $firstState=[pscustomobject]@{exists=$true;sha256=(Get-P7Hash $firstBytes);length=[int64]$firstBytes.Length;identity=$firstReceipt.appliedIdentity}
            [IO.File]::ReadAllText((Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/journal.json"))|Should Be 'journal-v1'

            $secondStage=New-P7File $f.Transaction 'journal.stage' $secondBytes
            $secondReceipt=Publish-PlatformFile -ParentLease $f.Transaction -Leaf 'journal.json' -TransactionLease $f.Transaction -StageLease $secondStage.Lease -ExpectedState $firstState -DisplacedLeaf 'journal.prev' -ExpectedStage $secondStage.Expected
            $secondReceipt.displacedLeaf|Should Be 'journal.prev'
            [IO.File]::ReadAllText((Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/journal.json"))|Should Be 'journal-v2'
            [IO.File]::ReadAllText((Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/journal.prev"))|Should Be 'journal-v1'

            $cleanupStage=New-P7File $f.Transaction 'journal.stage' ([Text.Encoding]::UTF8.GetBytes('temporary'))
            $cleanupStage.Lease.Dispose();$cleanupStage.Lease=$null
            (Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'journal.prev' -ExpectedState $firstState).deleted|Should Be $true
            (Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'journal.stage' -ExpectedState $cleanupStage.State).deleted|Should Be $true
            foreach($leaf in @('journal.prev','journal.stage')){Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/$leaf")|Should Be $false}
            [IO.File]::ReadAllText((Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/journal.json"))|Should Be 'journal-v2'
        }finally{Close-P7Fixture $f @($firstStage.Lease,$secondStage.Lease,$cleanupStage.Lease)}
    }

    # Scenario: A caller supplies Journal while publishing journal.json or deleting journal.prev in cleanup mode.
    # Purpose: Keep the journal store self-contained and reject recursive durable intent with zero mutation.
    It 'InterT835_rejects_journal_store_operations_that_supply_Journal' {
        $f=New-P7Fixture 'p7d2-journal-store-journal';$stage=$null;$previous=$null
        try{
            $stage=New-P7File $f.Transaction 'journal.stage' ([Text.Encoding]::UTF8.GetBytes('new-journal'))
            $previous=New-P7File $f.Transaction 'journal.prev' ([Text.Encoding]::UTF8.GetBytes('previous-journal'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.State.sha256;length=$stage.State.length;identity=$stage.State.identity}
            $legalPublishJournal=New-P7JournalOperation create-file stage-rename 'target/created' 'publish.stage' $null $missing $applied $null
            $publishJournal=($legalPublishJournal|ConvertTo-Json -Depth 20|ConvertFrom-Json);$publishJournal.stageLeaf='journal.stage'
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $legalRemoveJournal=New-P7JournalOperation remove-file tombstone-rename 'target/data' $null 'remove.backup' $previous.State $removed (Get-PlatformPermissions $previous.Lease)
            $removeJournal=($legalRemoveJournal|ConvertTo-Json -Depth 20|ConvertFrom-Json);$removeJournal.backupLeaf='journal.prev'
            $stageBefore=Get-P7NamedFileState $f.Transaction 'journal.stage' $stage
            $previousBefore=Get-P7NamedFileState $f.Transaction 'journal.prev' $previous

            {Publish-PlatformFile -ParentLease $f.Transaction -Leaf 'journal.json' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $publishJournal}|Should Throw 'must not supply Journal'
            {Publish-PlatformFile -ParentLease $f.Transaction -Leaf 'journal.json' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace -Journal $null}|Should Throw 'must not supply Journal'
            {Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'journal.prev' -ExpectedState $previous.State -Journal $removeJournal}|Should Throw 'Journal is forbidden'
            {Remove-PlatformOwnedFile -ParentLease $f.Transaction -Leaf 'journal.prev' -ExpectedState $previous.State -Journal $null}|Should Throw 'Journal is forbidden'

            $stageAfter=Get-P7NamedFileState $f.Transaction 'journal.stage' $stage
            $previousAfter=Get-P7NamedFileState $f.Transaction 'journal.prev' $previous
            $stageAfter.bytes|Should Be $stageBefore.bytes;$stageAfter.identity.fileId|Should Be $stageBefore.identity.fileId
            $previousAfter.bytes|Should Be $previousBefore.bytes;$previousAfter.identity.fileId|Should Be $previousBefore.identity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/journal.json")|Should Be $false
        }finally{Close-P7Fixture $f @($stage.Lease,$previous.Lease)}
    }

    # Scenario: The ParentLease side of either directory-move direction is a reserved transaction path or reserved leaf.
    # Purpose: Apply the same physical target boundary to directory publication before any source directory is opened or renamed.
    It 'InterT840_rejects_reserved_directory_move_targets_without_mutation' {
        $f=New-P7Fixture 'p7d2-reserved-directory-targets';$otherTransaction=$null
        try{
            $otherId=[Guid]::NewGuid().ToString('N')
            $otherTransaction=Open-PlatformDirectory -Root (Join-Path $f.Root '.ai-instructions-txn') -RelativePath $otherId -CreatePrivate
            $fromSource=New-P7Directory $f Transaction 'from-stage' 'from-content'
            $otherSourcePath=Join-Path $f.Root ".ai-instructions-txn/$otherId/to-source";[void][IO.Directory]::CreateDirectory($otherSourcePath);[IO.File]::WriteAllText((Join-Path $otherSourcePath 'marker.txt'),'to-content')
            $otherSource=Get-PlatformDirectoryState -ParentLease $otherTransaction -Leaf 'to-source'
            $reservedSource=New-P7Directory $f Parent '.ai-instructions-txn' 'reserved-content'

            {Move-PlatformOwnedDirectory -ParentLease $otherTransaction -Leaf 'to-source' -TransactionLease $f.Transaction -DestinationLeaf 'to.backup' -ExpectedIdentity $otherSource.identity -Direction ToTransaction -ExpectedState $otherSource}|Should Throw '.ai-instructions-txn'
            {Move-PlatformOwnedDirectory -ParentLease $otherTransaction -Leaf 'from-stage' -TransactionLease $f.Transaction -DestinationLeaf 'published' -ExpectedIdentity $fromSource.Identity -Direction FromTransaction -ExpectedState $fromSource.State}|Should Throw '.ai-instructions-txn'
            {Move-PlatformOwnedDirectory -ParentLease $f.Parent -Leaf '.ai-instructions-txn' -TransactionLease $f.Transaction -DestinationLeaf 'reserved.backup' -ExpectedIdentity $reservedSource.Identity -Direction ToTransaction -ExpectedState $reservedSource.State}|Should Throw '.ai-instructions-txn'

            Test-Path -LiteralPath $otherSourcePath|Should Be $true
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/from-stage")|Should Be $true
            Test-Path -LiteralPath (Join-Path $f.Root 'target/.ai-instructions-txn')|Should Be $true
            foreach($leaf in @('to.backup','reserved.backup')){Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/$leaf")|Should Be $false}
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$otherId/published")|Should Be $false
        }finally{if($null -ne $otherTransaction){$otherTransaction.Dispose()};Close-P7Fixture $f}
    }

    # Scenario: journal.json is addressed through a second lease to the same physical transaction directory.
    # Purpose: Keep the D9 exception restricted to the exact TransactionLease object, not merely a matching pathname or identity.
    It 'InterT845_requires_the_exact_TransactionLease_for_journal_store_publication' {
        $f=New-P7Fixture 'p7d2-journal-store-exact-lease';$secondLease=$null;$stage=$null
        try{
            $secondLease=Open-PlatformDirectory -Root (Join-Path $f.Root '.ai-instructions-txn') -RelativePath $f.TransactionId
            $stage=New-P7File $f.Transaction 'journal.stage' ([Text.Encoding]::UTF8.GetBytes('journal'))
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $before=Get-P7NamedFileState $f.Transaction 'journal.stage' $stage

            {Publish-PlatformFile -ParentLease $secondLease -Leaf 'journal.json' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $stage.Expected -NoReplace}|Should Throw '.ai-instructions-txn'

            $after=Get-P7NamedFileState $f.Transaction 'journal.stage' $stage
            $after.bytes|Should Be $before.bytes;$after.identity.fileId|Should Be $before.identity.fileId
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/journal.json")|Should Be $false
        }finally{if($null -ne $secondLease){$secondLease.Dispose()};Close-P7Fixture $f @($stage.Lease)}
    }

    # Scenario: A file inherits its DACL from the target parent, is tombstoned into the private transaction directory, and is then restored by rollback.
    # Purpose: Accept transaction-directory inheritance drift after rename while restoring the durable journal permission snapshot on the original target.
    It 'InterT850_restores_an_inherited_DACL_after_tombstone_rollback' {
        $f=New-P7Fixture 'p7d2-inherited-tombstone-rollback';$target=$null;$tombstone=$null;$restored=$null
        try{
            [void](Set-P7InheritanceFixture $f)
            $target=New-P7File $f.Parent 'inherited.txt' ([Text.Encoding]::UTF8.GetBytes('inherited-content'))
            $snapshot=Get-PlatformPermissions $target.Lease
            $target.Lease.Dispose();$target.Lease=$null
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $journal=New-P7JournalOperation remove-file tombstone-rename 'target/inherited.txt' $null 'inherited.backup' $target.State $removed $snapshot

            $receipt=Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'inherited.txt' -ExpectedState $target.State -TransactionLease $f.Transaction -TombstoneLeaf 'inherited.backup' -Journal $journal
            Test-Path -LiteralPath (Join-Path $f.Root 'target/inherited.txt')|Should Be $false
            $receipt.backupIdentity.fileId|Should Be $target.State.identity.fileId

            $tombstone=Open-PlatformFile -ParentLease $f.Transaction -Leaf 'inherited.backup' -Access ReadWrite -CreateMode OpenExisting
            $missing=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            Publish-PlatformFile -ParentLease $f.Parent -Leaf 'inherited.txt' -TransactionLease $f.Transaction -StageLease $tombstone -ExpectedState $missing -DisplacedLeaf $null -ExpectedStage $target.State -NoReplace|Out-Null
            $tombstone=$null
            $restored=Open-PlatformFile -ParentLease $f.Parent -Leaf 'inherited.txt' -Access ReadWrite -CreateMode OpenExisting
            Set-PlatformPermissions -Lease $restored -Snapshot $snapshot|Out-Null
            $restoredSnapshot=Get-PlatformPermissions $restored

            (Test-P7EquivalentDacl $restoredSnapshot.sddl $snapshot.sddl)|Should Be $true
            $restoredSnapshot.readOnly|Should Be $snapshot.readOnly
            (Get-P7Identity (Assert-PlatformFileIdentity -Lease $restored -Expected $restored.Observation -SingleLink -VerifyPath)).fileId|Should Be $target.State.identity.fileId
        }finally{Set-P7WindowsPostRenamePermissionReadbackHook $null;Close-P7Fixture $f @($restored,$tombstone,$target.Lease)}
    }

    # Scenario: The rename-after readback hook reports a different tombstone DACL while identity, bytes, and link count remain unchanged.
    # Purpose: Keep removal successful and record before/after permission evidence for later journal rollback instead of rejecting the tombstone.
    It 'InterT855_records_post_rename_tombstone_DACL_drift_without_failing_removal' {
        $f=New-P7Fixture 'p7d2-tombstone-dacl-drift';$target=$null
        try{
            $target=New-P7File $f.Parent 'drift.txt' ([Text.Encoding]::UTF8.GetBytes('drift-content'))
            $snapshot=Get-PlatformPermissions $target.Lease
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try{$changedSddl='D:P(A;;FA;;;'+$identity.User.Value+')(A;;FR;;;WD)'}finally{$identity.Dispose()}
            if(Test-P7EquivalentDacl $snapshot.sddl $changedSddl){throw 'The drift fixture must differ from the original DACL.'}
            $target.Lease.Dispose();$target.Lease=$null
            $removed=[pscustomobject]@{exists=$false;sha256=$null;length=$null;identity=$null}
            $journal=New-P7JournalOperation remove-file tombstone-rename 'target/drift.txt' $null 'drift.backup' $target.State $removed $snapshot
            Set-P7WindowsPostRenamePermissionReadbackHook ({
                param($operation,$role,$actual)
                if($operation -ceq 'owned-file-removal' -and $role -ceq 'tombstone'){
                    return [pscustomobject][ordered]@{kind='windows-sddl';sddl=$changedSddl;readOnly=[bool]$actual.readOnly}
                }
                return $actual
            }.GetNewClosure())

            $receipt=Remove-PlatformOwnedFile -ParentLease $f.Parent -Leaf 'drift.txt' -ExpectedState $target.State -TransactionLease $f.Transaction -TombstoneLeaf 'drift.backup' -Journal $journal

            Test-Path -LiteralPath (Join-Path $f.Root 'target/drift.txt')|Should Be $false
            Test-Path -LiteralPath (Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/drift.backup")|Should Be $true
            $receipt.backupIdentity.fileId|Should Be $target.State.identity.fileId
            $receipt.permissionsDrift.detected|Should Be $true
            $receipt.permissionsDrift.beforeSddl|Should Be $snapshot.sddl
            $receipt.permissionsDrift.afterSddl|Should Be $changedSddl
            $receipt.permissionsDrift.beforeSddl|Should Not Match ([regex]::Escape($f.Root))
            $receipt.permissionsDrift.afterSddl|Should Not Match ([regex]::Escape($f.Root))
        }finally{Set-P7WindowsPostRenamePermissionReadbackHook $null;Close-P7Fixture $f @($target.Lease)}
    }

    # Scenario: The rename-after readback hook reports DACL drift for an original file displaced by publication.
    # Purpose: Apply the same diagnostic-only permission rule to original-to-backup renames while keeping applied target verification strict.
    It 'InterT860_records_displaced_publication_DACL_drift_without_failing_publication' {
        $f=New-P7Fixture 'p7d2-displaced-dacl-drift';$target=$null;$stage=$null
        try{
            $target=New-P7File $f.Parent 'published.txt' ([Text.Encoding]::UTF8.GetBytes('original'))
            $snapshot=Get-PlatformPermissions $target.Lease
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try{$changedSddl='D:P(A;;FA;;;'+$identity.User.Value+')(A;;FR;;;WD)'}finally{$identity.Dispose()}
            if(Test-P7EquivalentDacl $snapshot.sddl $changedSddl){throw 'The displaced drift fixture must differ from the original DACL.'}
            $target.Lease.Dispose();$target.Lease=$null
            $stage=New-P7File $f.Transaction 'published.stage' ([Text.Encoding]::UTF8.GetBytes('applied'))
            $applied=[pscustomobject]@{exists=$true;sha256=$stage.Expected.sha256;length=$stage.Expected.length;identity=$stage.State.identity}
            $journal=New-P7JournalOperation write-file stage-rename 'target/published.txt' 'published.stage' 'published.backup' $target.State $applied $snapshot
            Set-P7WindowsPostRenamePermissionReadbackHook ({
                param($operation,$role,$actual)
                if($operation -ceq 'publication' -and $role -ceq 'displaced'){
                    return [pscustomobject][ordered]@{kind='windows-sddl';sddl=$changedSddl;readOnly=[bool]$actual.readOnly}
                }
                return $actual
            }.GetNewClosure())

            $receipt=Publish-PlatformFile -ParentLease $f.Parent -Leaf 'published.txt' -TransactionLease $f.Transaction -StageLease $stage.Lease -ExpectedState $target.State -DisplacedLeaf 'published.backup' -ExpectedStage $stage.Expected -Journal $journal

            [IO.File]::ReadAllText((Join-Path $f.Root 'target/published.txt'))|Should Be 'applied'
            [IO.File]::ReadAllText((Join-Path $f.Root ".ai-instructions-txn/$($f.TransactionId)/published.backup"))|Should Be 'original'
            $receipt.displacedIdentity.fileId|Should Be $target.State.identity.fileId
            $receipt.permissionsDrift.detected|Should Be $true
            $receipt.permissionsDrift.beforeSddl|Should Be $snapshot.sddl
            $receipt.permissionsDrift.afterSddl|Should Be $changedSddl
        }finally{Set-P7WindowsPostRenamePermissionReadbackHook $null;Close-P7Fixture $f @($stage.Lease,$target.Lease)}
    }
    }
}

Describe 'Platform probe cleanup evidence' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
    }

    # Scenario: Cleanup reports a failure after the primitives themselves succeeded.
    # Purpose: The returned receipt must include finally-stage evidence, not an earlier copy.
    It 'UnitT10_includes_cleanup_failures_in_the_returned_receipt' {
        InModuleScope platform-runtime {
            $script:P2OriginalProbeCleanup = ${function:Clear-PlatformProbe}
            try {
                Mock Clear-PlatformProbe {
                    param($Directory,$Path,$Entries,$Evidence)
                    & $script:P2OriginalProbeCleanup -Directory $Directory -Path $Path -Entries $Entries -Evidence $Evidence
                    $Evidence['cleanupFailure'] = 'fixture-cleanup-evidence'
                }
                $receipt = Test-PlatformPrimitives
                $receipt.status | Should Be 'available'
                $receipt.evidence.cleanupFailure | Should Be 'fixture-cleanup-evidence'
            } finally { Remove-Variable P2OriginalProbeCleanup -Scope Script -ErrorAction SilentlyContinue }
        }
    }

    # Scenario: The directory-publication probe finishes or fails after creating a nested transaction and published directory.
    # Purpose: Bind cleanup to owned-directory and leased-identity primitives instead of recursively deleting a released pathname.
    It 'UnitT20_binds_directory_publication_probe_cleanup_to_owned_identities' {
        InModuleScope platform-runtime {
            $body=${function:Test-PlatformDirectoryPublication}.Ast.Extent.Text
            $body|Should Match 'Move-PlatformOwnedDirectory'
            $body|Should Match 'Remove-PlatformOwnedDirectoryTree'
            $body|Should Match 'Remove-PlatformOwnedDirectoryTree[^\r\n]+-ExpectedIdentity \$transactionIdentity'
            $body|Should Match 'Clear-PlatformProbe'
            $body|Should Not Match '\[IO\.Directory\]::Delete\([^\r\n]*,\$true\)'
        }
    }

    # Register only on the native host because the directory-publication probe is intentionally unavailable on Unix.
    if ($IsWindows) {
        # Scenario: Native directory publication succeeds but exact probe cleanup reports a failure.
        # Purpose: Refuse capability availability when the probe cannot prove that its owned residue was removed.
        It 'UnitT30_marks_directory_publication_unavailable_when_probe_cleanup_fails' {
            InModuleScope platform-runtime {
                $script:P7dOriginalProbeCleanup=${function:Clear-PlatformProbe}
                try{
                    Mock Clear-PlatformProbe {
                        param($Directory,$Path,$Entries,$Evidence)
                        & $script:P7dOriginalProbeCleanup -Directory $Directory -Path $Path -Entries $Entries -Evidence $Evidence
                        $Evidence['cleanupFailure']='fixture-directory-cleanup-failure'
                    }
                    $receipt=Test-PlatformDirectoryPublication
                    $receipt.status|Should Be unavailable
                    $receipt.evidence.cleanupFailure|Should Match 'fixture-directory-cleanup-failure'
                }
                finally{Remove-Variable P7dOriginalProbeCleanup -Scope Script -ErrorAction SilentlyContinue}
            }
        }
    }
}

Describe 'Platform P4 verified PowerShell and Pester preparation' {
    $p4IsWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
    $p4IsUnix =
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux) -or
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)
    $p4MkfifoForRegistration = if ($p4IsUnix) {
        @(Get-Command mkfifo -CommandType Application -All -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Source } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Select-Object -First 1)
    } else { @() }
    $p4Pester4101ForRegistration = @(Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -eq [version]'4.10.1' } |
        Select-Object -First 1)
    $p4NativeCompilerForRegistration = @(if ($p4IsUnix) {
        @(Get-Command clang,cc -CommandType Application -All -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Source } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Select-Object -First 1)
    } else { @() })

    BeforeAll {
        $script:P4RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:P4Manifest = Join-Path $script:P4RepositoryRoot 'scripts/platform-runtime.psd1'
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        if(-not $IsWindows){Add-Type -AssemblyName System.Formats.Tar -ErrorAction Stop}
        Import-Module $script:P4Manifest -Force
        $script:P4Platform = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { throw 'Unsupported test platform.' }
        $script:P4Architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        $script:P4Preparation = @(Import-Module (Join-Path $script:P4RepositoryRoot 'scripts/platform/RuntimePreparation.psm1') -PassThru)[0]
        $script:P4Pester4101 = @(Get-Module -ListAvailable Pester |
            Where-Object { $_.Version -eq [version]'4.10.1' } |
            Select-Object -First 1) | Select-Object -First 1
        $script:P4Root = [IO.Path]::GetFullPath($TestDrive)
        if (-not $IsWindows) {
            # Match P2: resolve only the trusted fixture anchor (macOS /var),
            # never normalize a suspicious archive member or preparation target.
            $physical = '/'
            foreach ($part in $script:P4Root.Trim('/').Split('/')) {
                $item = [IO.DirectoryInfo]::new((Join-Path $physical $part))
                $target = $item.ResolveLinkTarget($true)
                $physical = if ($null -eq $target) { $item.FullName } else { $target.FullName }
            }
            $script:P4Root = $physical
        }

        function New-P4DestinationLease {
            param([string]$Name)
            return Open-PlatformDirectory -Root $script:P4Root -RelativePath $Name -CreatePrivate
        }

        function Select-P4ApplicationPath {
            param([string[]]$Candidates)
            foreach($candidate in $Candidates) {
                if(-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return [string]$candidate }
            }
            return $null
        }
        $script:P4Mkfifo = if ($IsLinux -or $IsMacOS) {
            $candidates=@(Get-Command mkfifo -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
            Select-P4ApplicationPath $candidates
        } else { $null }

        function Test-P4KnownRuntimeLinkRejection {
            param([string]$Root=$PSHOME)
            # Independent filesystem evidence decides the expectation. Never
            # reinterpret an arbitrary closure failure as a passing Store test.
            $pending=[Collections.Generic.Queue[string]]::new(); $pending.Enqueue($Root)
            $hasLink=$false
            while($pending.Count -gt 0 -and -not $hasLink) {
                $directory=$pending.Dequeue()
                $item=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { $hasLink=$true; break }
                foreach($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                    if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $child.LinkType) { $hasLink=$true; break }
                    if($child.PSIsContainer) { $pending.Enqueue($child.FullName) }
                }
            }
            if(-not $hasLink) { return $false }
            $caught=$null
            try { & $script:P4Preparation {param($root,$platform) Get-PlatformRuntimeClosure $root $platform} $Root $script:P4Platform | Out-Null } catch { $caught=$_ }
            $caught | Should Not BeNullOrEmpty
            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Capability | Should Be 'powershell-runtime'
            $caught.Exception.Message | Should Match 'Runtime closure (contains a link|requires physical directories)'
            return $true
        }

        function Get-P4KnownRuntimeReceipt {
            $path=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
            $closure=& $script:P4Preparation { param($root,$platform) Get-PlatformRuntimeClosure $root $platform } $PSHOME $script:P4Platform
            return [pscustomobject]@{version=$PSVersionTable.PSVersion.ToString();os=$script:P4Platform;architecture=$script:P4Architecture;executablePath=$path;executableSha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();runtimeClosure=$closure}
        }

        function Invoke-P4WithShadowUserModule {
            param([string]$Name,[scriptblock]$Action)
            # Model a caller's user module directory entirely inside TestDrive.
            $profile=Join-Path $TestDrive $Name
            $data=Join-Path $profile '.local/share'
            $moduleRoot=if($IsWindows){Join-Path $profile 'Documents/PowerShell/Modules'}else{Join-Path $data 'powershell/Modules'}
            $shadow=Join-Path $moduleRoot 'Microsoft.PowerShell.Utility'
            [void][IO.Directory]::CreateDirectory($shadow)
            $marker=Join-Path $profile 'shadow.marker'
            [IO.File]::WriteAllText((Join-Path $shadow 'Microsoft.PowerShell.Utility.psd1'),"@{RootModule='Microsoft.PowerShell.Utility.psm1';ModuleVersion='99.0.0';FunctionsToExport=@('ConvertTo-Json')}")
            [IO.File]::WriteAllText((Join-Path $shadow 'Microsoft.PowerShell.Utility.psm1'),("[IO.File]::WriteAllText('"+$marker.Replace("'","''")+"','loaded');function ConvertTo-Json { 'shadow' };Export-ModuleMember -Function ConvertTo-Json"))
            $values=@{HOME=$profile;USERPROFILE=$profile;XDG_CONFIG_HOME=(Join-Path $profile '.config');XDG_DATA_HOME=$data;XDG_CACHE_HOME=(Join-Path $profile '.cache');XDG_STATE_HOME=(Join-Path $profile '.local/state');XDG_RUNTIME_DIR=(Join-Path $profile 'run');APPDATA=(Join-Path $profile 'AppData/Roaming');LOCALAPPDATA=(Join-Path $profile 'AppData/Local');PSModulePath=($moduleRoot+[IO.Path]::PathSeparator+$env:PSModulePath)}
            $previous=@{}
            foreach($name in $values.Keys){$previous[$name]=[Environment]::GetEnvironmentVariable($name)}
            try {
                foreach($name in $values.Keys){[Environment]::SetEnvironmentVariable($name,$values[$name])}
                $executable=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
                $control=@(& $executable -NoLogo -NoProfile -NonInteractive -Command 'ConvertTo-Json -InputObject 1' 2>&1)
                $LASTEXITCODE | Should Be 0
                Test-Path -LiteralPath $marker | Should Be $true
                Remove-Item -LiteralPath $marker -Force
                & $Action ([pscustomobject]@{Profile=$profile;Marker=$marker})
                Test-Path -LiteralPath $marker | Should Be $false
            } finally { foreach($name in $previous.Keys){[Environment]::SetEnvironmentVariable($name,$previous[$name])} }
        }

        function Get-P4StartupHookFixture {
            $marker=Join-Path $TestDrive 'dotnet-startup-hook.marker'
            $hook=Join-Path $TestDrive 'P4.StartupHook.dll'
            if(-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
                $encodedMarker=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($marker))
                $source=@"
using System;
using System.IO;
using System.Text;
public class StartupHook {
    public static void Initialize() {
        File.WriteAllText(Encoding.UTF8.GetString(Convert.FromBase64String("$encodedMarker")), "loaded");
    }
}
"@
                Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $hook -OutputType Library -ErrorAction Stop
            }
            return [pscustomobject]@{Hook=$hook;Marker=$marker}
        }

        function Invoke-P4FixturePowerShellIdentity {
            param($Runtime)
            return & $script:P4Preparation {
                param($Runtime)
                $original=(Get-Command Start-PlatformVerifiedProcess -CommandType Function).ScriptBlock
                try {
                    Set-Item Function:script:Start-PlatformVerifiedProcess -Value {
                        param([string]$Executable,[string]$Probe,$Environment,[string]$Platform)
                        $output=@(& $Executable -NoLogo -NoProfile -NonInteractive -Command $Probe 2>&1)
                        if($LASTEXITCODE -ne 0 -or $output.Count -ne 1){throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Fixture runtime process failed.')}
                        return $output[0]
                    }
                    Test-PlatformPowerShellIdentity $Runtime.executablePath $Runtime.version $Runtime.os $Runtime.architecture $Runtime.runtimeClosure
                } finally { Set-Item Function:script:Start-PlatformVerifiedProcess -Value $original }
            } $Runtime
        }

        function New-P4ProbeRuntime {
            param([string]$Name)
            $root=Join-Path $script:P4Root $Name; [void][IO.Directory]::CreateDirectory($root)
            $marker=Join-Path $script:P4Root ($Name+'.launches')
            $path=Join-Path $root $(if($IsWindows){'probe.ps1'}else{'pwsh'})
            $identity=@{version='9.9.52';os=$script:P4Platform;architecture=$script:P4Architecture} | ConvertTo-Json -Compress
            $body=if($IsWindows){ "[IO.File]::AppendAllText('$($marker.Replace("'","''"))', 'launch'+[Environment]::NewLine);`$global:LASTEXITCODE=0;'$identity'" }
                else { "#!/bin/sh`nprintf 'launch\n' >> '$($marker.Replace("'","'\''"))'`nprintf '%s\n' '$identity'" }
            [IO.File]::WriteAllText($path,$body,[Text.UTF8Encoding]::new($false))
            if(-not $IsWindows){[IO.File]::SetUnixFileMode($path,[IO.UnixFileMode]448)}
            [IO.File]::WriteAllText((Join-Path $root 'System.Management.Automation.dll'),'approved dependency')
            $closure=& $script:P4Preparation {param($root,$platform) Get-PlatformRuntimeClosure $root $platform} $root $script:P4Platform
            return [pscustomobject]@{Marker=$marker;Root=$root;Receipt=[pscustomobject]@{version='9.9.52';os=$script:P4Platform;architecture=$script:P4Architecture;executablePath=$path;executableSha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();runtimeClosure=$closure}}
        }

        function New-P4Archive {
            param([string]$Path,[ValidateSet('safe','symlink','parent','absolute','dot-prefix','dot-duplicate','inner-dot','prefixed-parent','prefixed-absolute','empty-file')][string]$Kind,[string]$Version)
            if ($IsWindows) {
                $archive = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
                try {
                    $name = if ($Kind -ceq 'parent') { '../pwsh.exe' } elseif ($Kind -ceq 'absolute') { '/pwsh.exe' } else { 'pwsh.exe' }
                    $entry = $archive.CreateEntry($name)
                    $entry.ExternalAttributes = [BitConverter]::ToInt32([byte[]]@(0,0,164,129),0) # regular 0100644
                    # Hex literals above Int32.MaxValue are signed in PowerShell.
                    # Build the exact four bytes, rather than casting that negative literal.
                    if ($Kind -ceq 'symlink') { $entry.ExternalAttributes = [BitConverter]::ToInt32([byte[]]@(0,0,255,161),0) }
                    $stream = $entry.Open()
                    try { $bytes=[Text.Encoding]::UTF8.GetBytes('fixture'); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
                    if ($Kind -ceq 'safe') {
                        $stream=$archive.CreateEntry('System.Management.Automation.dll').Open()
                        try { $bytes=[Text.Encoding]::UTF8.GetBytes('approved-runtime-dependency'); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
                    }
                } finally { $archive.Dispose() }
            }
            else {
                $file = [IO.File]::Create($Path); $gzip=[IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionMode]::Compress,$false); $writer=[System.Formats.Tar.TarWriter]::new($gzip,$false)
                try {
                    $name = if ($Kind -ceq 'parent') { '../pwsh' } elseif ($Kind -ceq 'absolute') { '/pwsh' } else { 'pwsh' }
                    if ($Kind -in @('dot-prefix','dot-duplicate')) {
                        $writer.WriteEntry([System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::Directory,'./'))
                        $name='./pwsh'
                    }
                    if ($Kind -eq 'inner-dot') { $name='./nested/./pwsh' }
                    if ($Kind -eq 'prefixed-parent') { $name='./../pwsh' }
                    if ($Kind -eq 'prefixed-absolute') { $name='.//pwsh' }
                    $type = if ($Kind -ceq 'symlink') { [System.Formats.Tar.TarEntryType]::SymbolicLink } else { [System.Formats.Tar.TarEntryType]::RegularFile }
                    $entry = [System.Formats.Tar.PaxTarEntry]::new($type,$name)
                    if ($Kind -ceq 'symlink') { $entry.LinkName='target' } else {
                        $json = "{`"version`":`"$Version`",`"architecture`":`"$script:P4Architecture`",`"os`":`"$script:P4Platform`"}"
                        $body = "#!/bin/sh`nprintf '%s\n' '$json'"
                        $entry.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($body))
                    }
                    $writer.WriteEntry($entry)
                    if ($Kind -in @('safe','dot-prefix','empty-file')) {
                        $dependencyName=if($Kind -eq 'dot-prefix'){'./System.Management.Automation.dll'}else{'System.Management.Automation.dll'}
                        $dependency=[System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,$dependencyName)
                        $dependency.DataStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('approved-runtime-dependency'))
                        $writer.WriteEntry($dependency)
                    }
                    if ($Kind -eq 'empty-file') {
                        # No DataStream: TarReader returns null for this ordinary zero-byte entry.
                        $writer.WriteEntry([System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,'empty.txt'))
                    }
                    if ($Kind -eq 'dot-duplicate') {
                        $duplicate=[System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile,'pwsh')
                        $duplicate.DataStream=[IO.MemoryStream]::new([byte[]]@(1))
                        $writer.WriteEntry($duplicate)
                    }
                } finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
            }
        }

        function New-P4PowerShellPolicy {
            param([string]$Version,[string]$ArchivePath,[string]$Hash)
            $token = if ($IsWindows) { "win-$script:P4Architecture" } elseif ($IsLinux) { "linux-$script:P4Architecture" } else { "osx-$script:P4Architecture" }
            $name = if ($IsWindows) { "PowerShell-$Version-$token.zip" } else { "powershell-$Version-$token.tar.gz" }
            if (-not [string]::Equals([IO.Path]::GetFileName($ArchivePath),$name,[StringComparison]::Ordinal)) { Move-Item -LiteralPath $ArchivePath -Destination (Join-Path ([IO.Path]::GetDirectoryName($ArchivePath)) $name); $ArchivePath=Join-Path ([IO.Path]::GetDirectoryName($ArchivePath)) $name }
            return [pscustomobject]@{ Path=$ArchivePath; Policy=@{ version=$Version; assets=@(@{name=$name;sha256=$Hash}) } }
        }

        function Get-P4PesterPayloadHash {
            param([string]$ManifestPath,[string]$WorkRoot)
            $version = '4.10.1'; $installRoot=Join-Path $WorkRoot 'install'; $target=Join-Path (Join-Path $installRoot 'Pester') $version
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath (Split-Path -Parent $ManifestPath) -Destination $target -Recurse
            return & $script:P4Preparation {
                param($resolverPath,$root,$version)
                $resolver=Import-VerifiedPesterResolverModule $resolverPath 'windows'
                try { $closure=& $resolver.ExportedCommands['Get-DirectoryClosureIdentity'] -Path $root; & $resolver.ExportedCommands['Get-ApprovedPesterPayloadSha256'] -Closure $closure -Version $version }
                finally { Remove-Module $resolver -Force -ErrorAction SilentlyContinue }
            } (Join-Path $script:P4RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1') $installRoot $version
        }
    }

    AfterAll {
        Remove-Module $script:P4Preparation -Force -ErrorAction SilentlyContinue
        Remove-Module platform-runtime -Force -ErrorAction SilentlyContinue
    }

    # Scenario: The offline archive bytes differ from the policy binding.
    # Purpose: Ensure a cache hit never bypasses the immutable SHA-256 decision.
    It 'InterT10_rejects_an_offline_archive_hash_mismatch_with_a_typed_failure' {
        $version='9.9.10'; $raw=Join-Path $TestDrive 'hash.fixture'; New-P4Archive $raw safe $version
        $fixture=New-P4PowerShellPolicy $version $raw ('0'*64); $lease=New-P4DestinationLease 'p4-hash-destination'
        try { $caught=$null; try { Resolve-PlatformPowerShell -Policy $fixture.Policy -DestinationLease $lease -OfflineCache $fixture.Path | Out-Null } catch { $caught=$_ }; $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'; $caught.Exception.Capability | Should Be 'powershell-runtime' }
        finally { $lease.Dispose() }
    }

    # Scenario: An archive snapshot is offered to hashing/extraction after the cache was copied.
    # Purpose: Expose readable bytes without a writable stream or publicly accessible backing array.
    It 'UnitT12_keeps_the_archive_snapshot_read_only_and_its_buffer_private' {
        $path=Join-Path $TestDrive 'snapshot-bytes'; [IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3))
        $expected=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
        & $script:P4Preparation {
            param($path,$expected)
            $snapshot=New-PlatformArchiveSnapshot $path
            try {
                $snapshot.CanRead | Should Be $true
                $snapshot.CanWrite | Should Be $false
                { $snapshot.WriteByte(4) } | Should Throw
                { $snapshot.GetBuffer() } | Should Throw
                [IO.File]::WriteAllBytes($path,[byte[]]@(4,5,6))
                Get-PlatformArchiveSha256 $snapshot | Should Be $expected
                $snapshot.Position | Should Be 0
            } finally { $snapshot.Dispose() }
            $snapshot.CanRead | Should Be $false
        } $path $expected
    }

    # Scenario: The offline cache is replaced after its approved hash passes, before extraction.
    # Purpose: Extract only the immutable verified snapshot and keep receipt hashes bound to its bytes.
    It 'InterT15_extracts_the_verified_snapshot_after_the_cache_path_is_replaced' {
        $version='9.9.15'; $raw=Join-Path $TestDrive 'snapshot.fixture'; New-P4Archive $raw safe $version
        $approvedHash=(Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant()
        $fixture=New-P4PowerShellPolicy $version $raw $approvedHash
        $replacement=Join-Path $TestDrive 'replacement.fixture'; New-P4Archive $replacement symlink $version
        $lease=New-P4DestinationLease 'p4-snapshot-destination'
        try {
            $receipt=& $script:P4Preparation {
                param($policy,$path,$replacement,$owned,$platform)
                $originalLeasePath=(Get-Command Get-VerifiedPlatformLeasePath -CommandType Function).ScriptBlock
                $originalProbe=(Get-Command Test-PlatformPowerShellIdentity -CommandType Function).ScriptBlock
                $script:P4CacheReplaced=$false
                try {
                    Set-Item Function:script:Get-VerifiedPlatformLeasePath -Value {
                        param($Lease,$Platform)
                        if (-not $script:P4CacheReplaced) {
                            # Resolve calls this only after the archive SHA-256 check.
                            [IO.File]::Move($path,($path+'.original'))
                            [IO.File]::Move($replacement,$path)
                            $script:P4CacheReplaced=$true
                        }
                        & $originalLeasePath $Lease $Platform
                    }
                    if ($platform -eq 'windows') {
                        # This fixture is not a real PE executable. Identity probing is
                        # covered separately with $PSHOME; this test checks archive bytes.
                        Set-Item Function:script:Test-PlatformPowerShellIdentity -Value { }
                    }
                    Resolve-VerifiedPlatformPowerShell -Policy $policy -DestinationLease $owned -OfflineCache $path -Platform $platform
                } finally {
                    Set-Item Function:script:Get-VerifiedPlatformLeasePath -Value $originalLeasePath
                    Set-Item Function:script:Test-PlatformPowerShellIdentity -Value $originalProbe
                    Remove-Variable P4CacheReplaced -Scope Script -ErrorAction SilentlyContinue
                }
            } $fixture.Policy $fixture.Path $replacement $lease $script:P4Platform
            $receipt.archiveSha256 | Should Be $approvedHash
            $receipt.runtimeClosure.files.Count | Should Be 2
            $receipt.runtimeClosure.files.path | Should Contain 'System.Management.Automation.dll'
            $receipt.runtimeClosure.sha256 | Should Match '^[a-f0-9]{64}$'
            $receipt.warningCount | Should Be 0
            $receipt.warnings -is [array] | Should Be $true
            @($receipt.warnings).Count | Should Be 0
            $receipt.environmentAllowlist | Should Contain 'PATH'
            $receipt.environmentAllowlist | Should Contain 'PSModulePath'
            @($receipt.environmentAllowlist | Where-Object { $_ -cmatch '^(LD_|DYLD_|DOTNET_|COREHOST_)' }).Count | Should Be 0
            $expectedAllowlist='PATH,PSModulePath,HOME,USERPROFILE,XDG_CONFIG_HOME,XDG_DATA_HOME,XDG_CACHE_HOME,XDG_STATE_HOME,XDG_RUNTIME_DIR,TMP,TEMP'
            $expectedAllowlist+=if($IsWindows){',SystemRoot,APPDATA,LOCALAPPDATA'}else{',TMPDIR,LANG'}
            (@($receipt.environmentAllowlist) -join ',') | Should Be $expectedAllowlist
            (Get-FileHash $fixture.Path -Algorithm SHA256).Hash.ToLowerInvariant() | Should Not Be $approvedHash
            Test-Path -LiteralPath ($fixture.Path+'.original') | Should Be $true
            $receipt.executableSha256 | Should Be (Get-FileHash $receipt.executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($IsWindows) { [IO.File]::ReadAllText($receipt.executablePath) | Should Be 'fixture' }
            else { $receipt.version | Should Be $version }
        } finally { $lease.Dispose() }
    }

    # Scenario: PATH discovery returns multiple application candidates, including a stale path.
    # Purpose: Select one existing scalar path, never concatenate application paths into a command.
    It 'UnitT17_selects_one_existing_application_or_reports_no_candidate' {
        $first=Join-Path $TestDrive 'first-mkfifo'; $second=Join-Path $TestDrive 'second-mkfifo'
        [IO.File]::WriteAllText($first,'fixture'); [IO.File]::WriteAllText($second,'fixture')
        $selected=Select-P4ApplicationPath @((Join-Path $TestDrive 'missing-mkfifo'),$first,$second)
        $selected -is [string] | Should Be $true
        $selected | Should Be $first
        Select-P4ApplicationPath @((Join-Path $TestDrive 'missing-mkfifo')) | Should BeNullOrEmpty
    }

    # Scenario: A correctly named Unix cache entry is a FIFO with no writer; mkfifo must be available.
    # Purpose: Reject its native type without blocking, including the snapshot read itself.
    # Not registered on Windows, where FIFO filesystem semantics do not apply, or when no physical mkfifo tool can create the fixture.
    if ($p4IsUnix -and $p4MkfifoForRegistration.Count -gt 0) {
    It 'InterT18_rejects_fifo_cache_and_snapshot_reads_within_a_deadline' {
        $token=if($IsLinux){'linux'}else{'osx'}
        $name="powershell-9.9.18-$token-$script:P4Architecture.tar.gz"
        $fifo=Join-Path $script:P4Root $name
        & $script:P4Mkfifo $fifo
        $LASTEXITCODE | Should Be 0
        $code=@'
$ErrorActionPreference='Stop'
Import-Module '__MANIFEST__' -Force
$lease=Open-PlatformDirectory -Root '__ROOT__' -RelativePath 'fifo-output' -CreatePrivate
try {
    try { Resolve-PlatformPowerShell -Policy @{version='9.9.18';assets=@(@{name='__NAME__';sha256=('0'*64)})} -DestinationLease $lease -OfflineCache '__FIFO__'; exit 61 }
    catch { if($_.Exception.GetType().Name -ne 'PlatformVerificationException' -or $_.Exception.Message -notmatch 'regular file'){throw} }
    $prep=Import-Module '__PREP__' -PassThru
    try { & $prep {param($path) New-PlatformArchiveSnapshot $path} '__FIFO__'; exit 62 }
    catch { if($_.Exception.Message -notmatch 'regular file'){throw} }
    'fifo-rejected'
} finally { $lease.Dispose() }
'@
        foreach($pair in @(@('__MANIFEST__',$script:P4Manifest),@('__ROOT__',$script:P4Root),@('__NAME__',$name),@('__FIFO__',$fifo),@('__PREP__',(Join-Path $script:P4RepositoryRoot 'scripts/platform/RuntimePreparation.psm1')))) { $code=$code.Replace($pair[0],$pair[1].Replace("'","''")) }
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        $start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.ArgumentList.Add('-NoProfile'); $start.ArgumentList.Add('-EncodedCommand'); $start.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
        $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
        try {
            [void]$process.Start()
            $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            $finished=$process.WaitForExit(15000)
            if(-not $finished){$process.Kill($true); [void]$process.WaitForExit(5000)}
            $finished | Should Be $true
            $process.ExitCode | Should Be 0
            $stdout.GetAwaiter().GetResult().Trim() | Should Be 'fifo-rejected'
            $stderr.GetAwaiter().GetResult() | Should BeNullOrEmpty
        } finally { $process.Dispose(); [IO.File]::Delete($fifo) }
    }
    }

    # Scenario: An archive contains a link, parent traversal, or absolute member.
    # Purpose: Reject every archive representation that can escape or redirect extraction.
    It 'InterT20_rejects_links_parent_traversal_and_absolute_archive_members' {
        $case=20
        foreach($kind in @('symlink','parent','absolute')) {
            $case++; $version="9.9.$case"; $raw=Join-Path $TestDrive "$kind.fixture"; New-P4Archive $raw $kind $version
            $hash=(Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant(); $fixture=New-P4PowerShellPolicy $version $raw $hash; $lease=New-P4DestinationLease "p4-$kind-destination"
            try {
                $caught=$null; try { Resolve-PlatformPowerShell -Policy $fixture.Policy -DestinationLease $lease -OfflineCache $fixture.Path | Out-Null } catch { $caught=$_ }
                $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
                if($kind -eq 'symlink'){ $caught.Exception.Message | Should Match '(link|forbidden type)' }
                else { $caught.Exception.Message | Should Match 'unsafe path' }
            }
            finally { $lease.Dispose() }
        }
    }

    # Scenario: Policy declares no official asset for the actual process architecture.
    # Purpose: Prevent an x64/arm64 archive from being relabeled for the current host.
    It 'UnitT30_rejects_an_architecture_asset_mismatch_with_a_typed_failure' {
        $other=if($script:P4Architecture -ceq 'x64'){'arm64'}else{'x64'}; $version='9.9.30'; $lease=New-P4DestinationLease 'p4-arch-destination'
        $name=if($IsWindows){"PowerShell-$version-win-$other.zip"}elseif($IsLinux){"powershell-$version-linux-$other.tar.gz"}else{"powershell-$version-osx-$other.tar.gz"}
        try { $caught=$null; try { Resolve-PlatformPowerShell -Policy @{version=$version;assets=@(@{name=$name;sha256=('0'*64)})} -DestinationLease $lease -OfflineCache $TestDrive | Out-Null } catch { $caught=$_ }; $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException' }
        finally { $lease.Dispose() }
    }

    # Scenario: A small fixture executable reports the exact selected version, OS, and architecture.
    # Purpose: Cover safe extraction and the Unix executable-mode boundary without a network download.
    It 'InterT40_extracts_a_verified_fixture_and_sets_unix_pwsh_mode_0700' {
        $version='9.9.40'; $raw=Join-Path $TestDrive 'safe.fixture'; New-P4Archive $raw safe $version; $hash=(Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant(); $fixture=New-P4PowerShellPolicy $version $raw $hash; $lease=New-P4DestinationLease 'p4-safe-destination'
        try {
            if($IsWindows){ & $script:P4Preparation { param($archive,$owned) $snapshot=New-PlatformArchiveSnapshot $archive; try { Expand-VerifiedPlatformZip $snapshot $owned 'windows' } finally { $snapshot.Dispose() } } $fixture.Path $lease; Test-Path -LiteralPath (Join-Path $TestDrive 'p4-safe-destination/pwsh.exe') -PathType Leaf | Should Be $true }
            else {
                $receipt=Resolve-PlatformPowerShell -Policy $fixture.Policy -DestinationLease $lease -OfflineCache $fixture.Path
                $receipt.version | Should Be $version
                [uint32][IO.File]::GetUnixFileMode($receipt.executablePath) | Should Be 448
                $receipt.protectionBoundary | Should Match 'A1:.*same-account uncooperative writers'
            }
        }
        finally { $lease.Dispose() }
    }

    # Scenario: An ordinary tar file has zero length and TarReader exposes no DataStream.
    # Purpose: Create the empty file, rather than rejecting or silently omitting the member.
    # Not registered on Windows because the Windows runtime asset is ZIP, not tar.gz.
    if ($p4IsUnix) {
    It 'InterT41_extracts_zero_length_tar_members_as_physical_empty_files' {
        $version='9.9.41'; $raw=Join-Path $TestDrive 'empty-file.fixture'; New-P4Archive $raw 'empty-file' $version
        $fixture=New-P4PowerShellPolicy $version $raw (Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant()
        $lease=New-P4DestinationLease 'p4-empty-file'
        try {
            $receipt=Resolve-PlatformPowerShell -Policy $fixture.Policy -DestinationLease $lease -OfflineCache $fixture.Path
            $empty=Get-Item -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($receipt.executablePath)) 'empty.txt') -Force
            $empty.PSIsContainer | Should Be $false
            $empty.Length | Should Be 0
            ($empty.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should Be 0
            $empty.LinkType | Should BeNullOrEmpty
            $receipt.version | Should Be $version
        } finally { $lease.Dispose() }
    }

    # Scenario: A tarball created from '.' contains a root entry and ./-prefixed files.
    # Purpose: Normalize only leading ./ before duplicate checks, retaining traversal rejection.
    It 'InterT42_normalizes_tar_root_prefixes_without_accepting_aliases_or_traversal' {
        $version='9.9.42'; $raw=Join-Path $TestDrive 'dot-prefix.fixture'; New-P4Archive $raw 'dot-prefix' $version
        $fixture=New-P4PowerShellPolicy $version $raw (Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant()
        $lease=New-P4DestinationLease 'p4-dot-prefix'
        try {
            $receipt=Resolve-PlatformPowerShell -Policy $fixture.Policy -DestinationLease $lease -OfflineCache $fixture.Path
            $receipt.version | Should Be $version
            [uint32][IO.File]::GetUnixFileMode($receipt.executablePath) | Should Be 448
        } finally { $lease.Dispose() }
        foreach($kind in @('dot-duplicate','inner-dot','prefixed-parent','prefixed-absolute')) {
            $raw=Join-Path $TestDrive "$kind.fixture"; New-P4Archive $raw $kind $version
            $lease=New-P4DestinationLease "p4-$kind"
            try {
                $caught=$null
                try { & $script:P4Preparation { param($path,$owned,$platform) $snapshot=New-PlatformArchiveSnapshot $path; try { Expand-VerifiedPlatformTarGz $snapshot $owned $platform } finally { $snapshot.Dispose() } } $raw $lease $script:P4Platform } catch { $caught=$_ }
                $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
                $caught.Exception.Message | Should Match $(if($kind -eq 'dot-duplicate'){'duplicate member'}else{'unsafe path'})
            } finally { $lease.Dispose() }
        }
    }
    }

    # Scenario: Extraction creates a directory which is replaced by a junction before the next entry.
    # Purpose: Re-guard every destination component before writing, refusing an outside target.
    # Not registered on Unix because junctions and Windows ZIP directory guards are Windows-specific.
    if ($p4IsWindows) {
    It 'InterT43_rejects_a_nested_junction_inserted_during_zip_extraction' {
        $raw=Join-Path $TestDrive 'junction.zip'; $archive=[IO.Compression.ZipFile]::Open($raw,[IO.Compression.ZipArchiveMode]::Create)
        try {
            [void]$archive.CreateEntry('nested/')
            $stream=$archive.CreateEntry('nested/deeper/payload').Open()
            try { $stream.WriteByte(42) } finally { $stream.Dispose() }
        } finally { $archive.Dispose() }
        $lease=New-P4DestinationLease 'p4-junction-extract'
        $outside=Join-Path $script:P4Root 'p4-junction-outside'; [void][IO.Directory]::CreateDirectory($outside)
        $junction=Join-Path $script:P4Root 'p4-junction-extract/nested'
        try {
            $caught=& $script:P4Preparation {
                param($path,$owned,$outside,$junction)
                $original=(Get-Command New-PlatformPreparationDirectory -CommandType Function).ScriptBlock
                try {
                    # Deterministic inter-entry race: no timing or background process required.
                    Set-Item Function:script:New-PlatformPreparationDirectory -Value {
                        param($DestinationLease,$RelativePath,$Platform)
                        & $original $DestinationLease $RelativePath $Platform
                        [IO.Directory]::Move($junction,($junction+'-moved'))
                        New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop | Out-Null
                    }
                    $snapshot=New-PlatformArchiveSnapshot $path
                    try { Expand-VerifiedPlatformZip $snapshot $owned 'windows'; return $null } catch { return $_ } finally { $snapshot.Dispose() }
                } finally { Set-Item Function:script:New-PlatformPreparationDirectory -Value $original }
            } $raw $lease $outside $junction
            $caught | Should Not BeNullOrEmpty
            $caught.Exception.Message | Should Match '(reparse|directory|guard)'
            (Get-Item -LiteralPath $junction -Force).LinkType | Should Be 'Junction'
            @(Get-ChildItem -LiteralPath $outside -Force -Recurse).Count | Should Be 0
        } finally {
            $lease.Dispose()
            # Delete only the junction itself; never recurse through the outside target.
            $item=Get-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and $item.LinkType -eq 'Junction') { [IO.Directory]::Delete($junction) }
        }
    }

    # Scenario: A source stream attempts to replace both nested parents while a file is being written.
    # Purpose: Keep all no-reparse directory guards alive until the output stream closes.
    It 'InterT44_holds_all_windows_nested_directory_guards_through_file_writes' {
        if($null -eq ('P4CallbackReadStream' -as [type])) {
            Add-Type -TypeDefinition @'
public sealed class P4CallbackReadStream : System.IO.Stream {
    private System.Action callback;
    private readonly System.IO.MemoryStream data=new System.IO.MemoryStream(new byte[] { 1, 2, 3 });
    public P4CallbackReadStream(System.Action callback) { this.callback=callback; }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { return data.Length; } }
    public override long Position { get { return data.Position; } set { throw new System.NotSupportedException(); } }
    public override int Read(byte[] buffer, int offset, int count) {
        if (callback != null) { var action=callback; callback=null; action(); }
        return data.Read(buffer,offset,count);
    }
    public override void Flush() { }
    public override long Seek(long offset, System.IO.SeekOrigin origin) { throw new System.NotSupportedException(); }
    public override void SetLength(long value) { throw new System.NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new System.NotSupportedException(); }
    protected override void Dispose(bool disposing) { if (disposing) data.Dispose(); base.Dispose(disposing); }
}
'@
        }
        $lease=New-P4DestinationLease 'p4-nested-guards'; $blocked=[Collections.Generic.List[string]]::new()
        $root=Join-Path $script:P4Root 'p4-nested-guards'
        $stream=[P4CallbackReadStream]::new([Action]{
            foreach($relative in @('nested/deeper','nested')) {
                $path=Join-Path $root $relative
                try { [IO.Directory]::Move($path,($path+'-moved')) } catch { $blocked.Add($relative) }
            }
        })
        try {
            & $script:P4Preparation { param($owned,$source) Write-PlatformPreparationFile $owned 'nested/deeper/payload' $source 'windows' } $lease $stream
            $blocked.Count | Should Be 2
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'nested/deeper/payload'))) | Should Be 'AQID'
            [IO.Directory]::Move((Join-Path $root 'nested'),(Join-Path $root 'released'))
        } finally { $stream.Dispose(); $lease.Dispose() }
    }
    }

    # Scenario: An ancestor is renamed and a replacement tree occupies the cached lease path.
    # Purpose: Refuse path-based receipt reads and keep tar/Pester writes out of the replacement.
    # Not registered on Windows because it exercises Unix descriptor and tar preparation semantics.
    if ($p4IsUnix) {
    It 'InterT45_rejects_replaced_unix_ancestors_before_preparation' {
        $root=Join-Path $script:P4Root 'p4-ancestor'; New-Item -ItemType Directory -Path $root | Out-Null
        $lease=Open-PlatformDirectory -Root $root -RelativePath 'owned' -CreatePrivate
        $moved=Join-Path $script:P4Root 'p4-ancestor-moved'
        try {
            [IO.Directory]::Move($root,$moved)
            New-Item -ItemType Directory -Path (Join-Path $root 'owned') -Force | Out-Null
            { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($lease) } | Should Throw
            $raw=Join-Path $TestDrive 'ancestor.fixture'; New-P4Archive $raw safe '9.9.45'
            { & $script:P4Preparation { param($archive,$owned) $snapshot=New-PlatformArchiveSnapshot $archive; try { Expand-VerifiedPlatformTarGz $snapshot $owned 'linux' } finally { $snapshot.Dispose() } } $raw $lease } | Should Throw
            $source=Join-Path $TestDrive 'p4-copy-source'; New-Item -ItemType Directory -Path $source | Out-Null
            [IO.File]::WriteAllText((Join-Path $source 'payload'),'source')
            { & $script:P4Preparation { param($source,$owned) Copy-PhysicalPesterPayload $source $owned 'Pester/4.10.1' 'linux' } $source $lease } | Should Throw
            @(Get-ChildItem -LiteralPath (Join-Path $root 'owned') -Force -Recurse).Count | Should Be 0
        } finally { $lease.Dispose() }
    }
    }

    # Scenario: Empty nested directories are held before any output file has been opened.
    # Purpose: Directory guards themselves must arbitrate delete sharing, not rely on a child file handle.
    # Not registered on Unix because Windows delete-sharing directory guards do not apply there.
    if ($p4IsWindows) {
    It 'InterT46_blocks_windows_directory_renames_without_a_child_file_handle' {
        $lease=New-P4DestinationLease 'p4-empty-directory-guards'
        try {
            & $script:P4Preparation {
                param($owned)
                $session=New-PlatformPreparationSession
                $root=Get-VerifiedPlatformLeasePath $owned 'windows'
                try {
                    New-PlatformPreparationDirectory $owned 'a/b' 'windows' $session
                    foreach($relative in @('a/b','a')) {
                        $path=Join-Path $root $relative
                        { [IO.Directory]::Move($path,($path+'-moved')) } | Should Throw
                    }
                } finally { Close-PlatformPreparationSession $session }
                [IO.Directory]::Move((Join-Path $root 'a'),(Join-Path $root 'released'))
            } $lease
        } finally { $lease.Dispose() }
    }
    }

    # Scenario: The source stream replaces an ancestor after the destination file is opened.
    # Purpose: Prove writes use the retained descriptor and never follow the replacement pathname.
    # Not registered on Windows because these cases exercise Unix descriptor-relative writes and inode ancestry.
    if ($p4IsUnix) {
    It 'InterT47_keeps_descriptor_writes_out_of_an_ancestor_replacement' {
        if($null -eq ('P4RenameOnReadStream' -as [type])) {
            Add-Type -TypeDefinition @'
public sealed class P4RenameOnReadStream : System.IO.MemoryStream {
    private readonly string original, moved;
    private bool renamed;
    public P4RenameOnReadStream(string original, string moved) : base(new byte[] { 1, 2, 3 }) { this.original=original; this.moved=moved; }
    public override int Read(byte[] buffer, int offset, int count) {
        if (!renamed) {
            System.IO.Directory.Move(original, moved);
            System.IO.Directory.CreateDirectory(System.IO.Path.Combine(original, "owned/nested"));
            renamed=true;
        }
        return base.Read(buffer,offset,count);
    }
}
'@
        }
        $root=Join-Path $script:P4Root 'p4-during-write'; New-Item -ItemType Directory -Path $root | Out-Null
        $lease=Open-PlatformDirectory -Root $root -RelativePath 'owned' -CreatePrivate
        $stream=[P4RenameOnReadStream]::new($root,(Join-Path $script:P4Root 'p4-during-write-moved'))
        try {
            { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::WritePreparationFile($lease,'nested/payload',$stream) } | Should Throw
            Test-Path -LiteralPath (Join-Path $root 'owned/nested/payload') | Should Be $false
            $ownedFile=Join-Path $TestDrive 'p4-during-write-moved/owned/nested/payload'
            (Get-Item -LiteralPath $ownedFile).Length | Should Be 0
        } finally { $stream.Dispose(); $lease.Dispose() }
    }

    # Scenario: A middle ancestor is renamed during Read, at EOF, or replaced while b/c retain their inodes.
    # Purpose: Validate every root-relative ancestor, not only the final directory and its immediate parent.
    It 'InterT48_rejects_moved_or_replaced_intermediate_unix_ancestors' {
        if($null -eq ('P4MoveIntermediateOnReadStream' -as [type])) {
            Add-Type -TypeDefinition @'
public sealed class P4MoveIntermediateOnReadStream : System.IO.MemoryStream {
    private readonly string original, moved, mode;
    public bool Renamed { get; private set; }
    public P4MoveIntermediateOnReadStream(string original, string moved, string mode) : base(new byte[] { 1, 2, 3 }) {
        this.original=original; this.moved=moved; this.mode=mode;
    }
    public override int Read(byte[] buffer, int offset, int count) {
        int read=base.Read(buffer,offset,count);
        if (!Renamed && (mode != "eof" || read == 0)) {
            System.IO.Directory.Move(original,moved);
            System.IO.Directory.CreateDirectory(original);
            if (mode == "splice")
                System.IO.Directory.Move(System.IO.Path.Combine(moved,"b"),System.IO.Path.Combine(original,"b"));
            else System.IO.Directory.CreateDirectory(System.IO.Path.Combine(original,"b/c"));
            Renamed=true;
        }
        return read;
    }
}
'@
        }
        foreach($mode in @('read','eof','splice')) {
            $name='p4-middle-'+$mode; $lease=New-P4DestinationLease $name
            $owned=Join-Path $script:P4Root $name; $original=Join-Path $owned 'a'
            $moved=Join-Path $script:P4Root ($name+'-outside')
            $stream=[P4MoveIntermediateOnReadStream]::new($original,$moved,$mode)
            try {
                { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::WritePreparationFile($lease,'a/b/c/payload',$stream) } | Should Throw
                $stream.Renamed | Should Be $true
                if($mode -eq 'splice') {
                    (Get-Item -LiteralPath (Join-Path $original 'b/c/payload')).Length | Should Be 0
                } else {
                    Test-Path -LiteralPath (Join-Path $original 'b/c/payload') | Should Be $false
                    (Get-Item -LiteralPath (Join-Path $moved 'b/c/payload')).Length | Should Be $(if($mode -eq 'eof'){3}else{0})
                }
            } finally { $stream.Dispose(); $lease.Dispose() }
        }
    }
    }

    # Scenario: A caller spells the runtime executable with a different filename case.
    # Purpose: Windows binding follows filesystem case rules while inventory bytes and Unix binding remain ordinal.
    It 'UnitT48_binds_executable_case_using_platform_path_rules' {
        $root=Join-Path $script:P4Root 'p4-executable-case'
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText((Join-Path $root 'PwSh.ExE'),'fixture bytes')
        $closure=& $script:P4Preparation {param($r,$p) Get-PlatformRuntimeClosure $r $p} $root $script:P4Platform
        $closure.files[0].path | Should BeExactly 'PwSh.ExE'
        $command=Join-Path $root 'pwsh.exe'
        if($IsWindows){
            & $script:P4Preparation {param($c,$e,$p) Assert-PlatformRuntimeClosure $c $e $p} $command $closure $script:P4Platform
        } else {
            {& $script:P4Preparation {param($c,$e,$p) Assert-PlatformRuntimeClosure $c $e $p} $command $closure $script:P4Platform} | Should Throw 'does not bind the executable'
        }
    }

    # Scenario: An otherwise physical runtime fixture gains a directory link, as Store layouts may contain.
    # Purpose: Exercise both layout branches while keeping the production typed link rejection unchanged.
    It 'InterT49_classifies_linked_layouts_and_asserts_the_typed_rejection' {
        $root=Join-Path $script:P4Root 'p4-linked-layout'; [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText((Join-Path $root 'dependency.dll'),'physical')
        Test-P4KnownRuntimeLinkRejection $root | Should Be $false
        $outside=Join-Path $script:P4Root 'p4-linked-layout-target'; [void][IO.Directory]::CreateDirectory($outside)
        $link=Join-Path $root 'alias'
        try {
            New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $outside -ErrorAction Stop | Out-Null
            Test-P4KnownRuntimeLinkRejection $root | Should Be $true
            $failure=$null
            try {& $script:P4Preparation {param($r,$p) Get-PlatformRuntimeClosure $r $p} $root $script:P4Platform|Out-Null} catch {$failure=$_.Exception.Message}
            $failure | Should Match "contains a link: 'alias'"
            $failure.Contains($root) | Should Be $false
            $failure.Contains($outside) | Should Be $false
        } finally { if(Test-Path -LiteralPath $link){[IO.Directory]::Delete($link)} }
    }

    # Scenario: The current PSHOME is either physical or a linked/Store runtime layout.
    # Purpose: Probe physical layouts; explicitly assert typed rejection of linked layouts without weakening policy.
    It 'InterT50_matches_the_current_physical_pwsh_identity' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $runtime=Get-P4KnownRuntimeReceipt
        $identity=& ($script:P4Preparation.ExportedCommands['Test-PlatformPowerShellIdentity']) $runtime.executablePath $runtime.version $runtime.os $runtime.architecture $runtime.runtimeClosure
        $identity.version | Should Be $PSVersionTable.PSVersion.ToString()
    }

    # Scenario: A runtime dependency changes, disappears, or is added after the receipt is issued.
    # Purpose: Reject the closure before even the identity probe can execute; refuse legacy receipts too.
    It 'InterT52_refuses_changed_runtime_dependencies_before_launch' {
        foreach($change in @('changed','removed','added','missing-receipt')) {
            $fixture=New-P4ProbeRuntime ('p4-runtime-'+$change); $runtime=$fixture.Receipt
            $identity=Invoke-P4FixturePowerShellIdentity $runtime
            $identity.version | Should Be $runtime.version
            [IO.File]::Delete($fixture.Marker)
            switch($change) {
                'changed' { [IO.File]::WriteAllText((Join-Path $fixture.Root 'System.Management.Automation.dll'),'changed dependency') }
                'removed' { [IO.File]::Delete((Join-Path $fixture.Root 'System.Management.Automation.dll')) }
                'added' { [IO.File]::WriteAllText((Join-Path $fixture.Root 'coreclr.dll'),'extra dependency') }
                'missing-receipt' { $runtime.PSObject.Properties.Remove('runtimeClosure') }
            }
            $caught=$null
            try { Initialize-PlatformPester -Policy @{} -RuntimeReceipt $runtime -DestinationLease 'not-reached' | Out-Null } catch { $caught=$_ }
            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Message | Should Match 'runtime closure'
            Test-Path -LiteralPath $fixture.Marker | Should Be $false
        }
    }

    # Scenario: A DLL is targeted after extraction and before the initial closure/probe.
    # Purpose: Keep Windows output guards live; never bless a Unix mutation as the initial baseline.
    It 'InterT53_binds_the_initial_closure_to_archive_bytes_and_retains_output_guards' {
        $version='9.9.53'; $raw=Join-Path $TestDrive 'guarded.fixture'; New-P4Archive $raw safe $version
        $fixture=New-P4PowerShellPolicy $version $raw (Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant()
        $lease=New-P4DestinationLease 'p4-guarded-output'
        try {
            $result=& $script:P4Preparation {
                param($policy,$path,$owned,$platform)
                $name=if($platform -eq 'windows'){'Expand-VerifiedPlatformZip'}else{'Expand-VerifiedPlatformTarGz'}
                $original=(Get-Command $name -CommandType Function).ScriptBlock
                $probe=(Get-Command Test-PlatformPowerShellIdentity -CommandType Function).ScriptBlock
                $script:P4WriteDenied=$false; $script:P4ProbeReached=$false
                try {
                    Set-Item ('Function:script:'+ $name) -Value {
                        param($Snapshot,$DestinationLease,$Platform,$Session)
                        & $original $Snapshot $DestinationLease $Platform $Session
                        $dll=Join-Path (Get-VerifiedPlatformLeasePath $DestinationLease $Platform) 'System.Management.Automation.dll'
                        try { [IO.File]::WriteAllText($dll,'unapproved dependency') } catch { $script:P4WriteDenied=$true }
                        if($Platform -eq 'windows') {
                            { [IO.File]::Delete($dll) } | Should Throw
                        }
                    }
                    Set-Item Function:script:Test-PlatformPowerShellIdentity -Value {
                        param($ExecutablePath,$ExpectedVersion,$ExpectedPlatform,$ExpectedArchitecture,$RuntimeClosure)
                        Assert-PlatformRuntimeClosure $ExecutablePath $RuntimeClosure $ExpectedPlatform
                        $script:P4ProbeReached=$true
                    }
                    $errorRecord=$null; $receipt=$null
                    try { $receipt=Resolve-VerifiedPlatformPowerShell $policy $owned $path $null $platform } catch { $errorRecord=$_ }
                    [pscustomobject]@{Denied=$script:P4WriteDenied;Probed=$script:P4ProbeReached;Error=$errorRecord;Receipt=$receipt}
                } finally {
                    Set-Item ('Function:script:'+ $name) -Value $original
                    Set-Item Function:script:Test-PlatformPowerShellIdentity -Value $probe
                }
            } $fixture.Policy $fixture.Path $lease $script:P4Platform
            if($IsWindows) {
                $result.Denied | Should Be $true; $result.Probed | Should Be $true
                $result.Error | Should BeNullOrEmpty
                $result.Receipt.protectionBoundary | Should Match 'deny-write-delete.*process exit'
                $result.Receipt.warningCount | Should Be 0
                $result.Receipt.warnings -is [array] | Should Be $true
                @($result.Receipt.warnings).Count | Should Be 0
                # Guards are scoped to preparation/execution, not leaked into receipts.
                [IO.File]::WriteAllText((Join-Path $script:P4Root 'p4-guarded-output/System.Management.Automation.dll'),'after release')
            } else {
                $result.Denied | Should Be $false; $result.Probed | Should Be $false
                $result.Error.Exception.GetType().Name | Should Be 'PlatformVerificationException'
                $result.Error.Exception.Message | Should Match 'closure'
            }
        } finally { $lease.Dispose() }
    }

    # Scenario: Code invoked by the probe itself attempts to change a runtime DLL.
    # Purpose: Keep receipt guards live through execution, and release them after it returns.
    # Not registered on Unix because deny-write FileShare guards are Windows-specific.
    if ($p4IsWindows) {
    It 'InterT54_holds_windows_runtime_guards_until_the_probe_returns' {
        $fixture=New-P4ProbeRuntime 'p4-probe-write'
        $dll=Join-Path $fixture.Root 'System.Management.Automation.dll'
        $denied=Join-Path $script:P4Root 'p4-probe-denied'
        $prefix="try{[IO.File]::WriteAllText('$($dll.Replace("'","''"))','unapproved')}catch{[IO.File]::WriteAllText('$($denied.Replace("'","''"))','denied')};"
        $path=$fixture.Receipt.executablePath
        [IO.File]::WriteAllText($path,($prefix+[IO.File]::ReadAllText($path)))
        $closure=& $script:P4Preparation {param($root) Get-PlatformRuntimeClosure $root 'windows'} $fixture.Root
        $identity=Invoke-P4FixturePowerShellIdentity ([pscustomobject]@{executablePath=$path;version=$fixture.Receipt.version;os='windows';architecture=$script:P4Architecture;runtimeClosure=$closure})
        $identity.version | Should Be $fixture.Receipt.version
        [IO.File]::ReadAllText($denied) | Should Be 'denied'
        [IO.File]::ReadAllText($dll) | Should Be 'approved dependency'
        [IO.File]::WriteAllText($dll,'after execution')
    }
    }

    # Scenario: The process boundary receives one JSON line, empty output, or multiple lines.
    # Purpose: Preserve the complete line and private profile while rejecting invalid output with typed failures.
    It 'InterT51_preserves_full_process_output_and_isolates_each_profile' {
        $executable=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        $environment=& $script:P4Preparation.ExportedCommands['New-PlatformVerifiedProcessEnvironment'] $executable $null $script:P4Platform
        $probe='$temporaryFile=[IO.Path]::GetTempFileName();[pscustomobject]@{version=$PSVersionTable.PSVersion.ToString();auto=[string]$PSModuleAutoLoadingPreference;modules=$env:PSModulePath;utility=(Get-Module Microsoft.PowerShell.Utility).Path;home=$env:HOME;user=$env:USERPROFILE;config=$env:XDG_CONFIG_HOME;data=$env:XDG_DATA_HOME;cache=$env:XDG_CACHE_HOME;state=$env:XDG_STATE_HOME;run=$env:XDG_RUNTIME_DIR;temp=[IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar);temporaryFile=$temporaryFile;exists=[IO.Directory]::Exists($env:HOME);mode=if($IsWindows){0}else{[int][IO.File]::GetUnixFileMode($env:HOME)}}|ConvertTo-Json -Compress'
        $profiles=@()
        foreach($attempt in 1..2) {
            $output=& $script:P4Preparation.ExportedCommands['Start-PlatformVerifiedProcess'] $executable $probe $environment $script:P4Platform
            $evidence=$output | ConvertFrom-Json
            $evidence.version | Should Be $PSVersionTable.PSVersion.ToString()
            $evidence.warnings.count | Should Be 0
            $evidence.warnings.summaries -is [array] | Should Be $true
            @($evidence.warnings.summaries).Count | Should Be 0
            $evidence.auto | Should Be 'None'
            $evidence.modules | Should Be (Join-Path $PSHOME 'Modules')
            ([IO.Path]::GetFullPath($evidence.utility).StartsWith(([IO.Path]::GetFullPath($PSHOME)+[IO.Path]::DirectorySeparatorChar),$(if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}))) | Should Be $true
            $evidence.exists | Should Be $true
            if(-not $IsWindows){$evidence.mode | Should Be 448}
            $evidence.home | Should Not Be ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
            foreach($property in @('user','config','data','cache','state','run','temp')){$evidence.$property | Should Be $evidence.home}
            [IO.Path]::GetDirectoryName($evidence.temporaryFile) | Should Be $evidence.home
            Test-Path -LiteralPath $evidence.temporaryFile | Should Be $false
            Test-Path -LiteralPath $evidence.home | Should Be $false
            $profiles+=$evidence.home
        }
        $profiles[0] | Should Not Be $profiles[1]
        $warningPath=Join-Path $PSHOME 'private-warning-detail.txt'
        $warningProbe="Write-Warning 'fixture warning $($warningPath.Replace("'","''"))';[pscustomobject]@{ok=`$true}|ConvertTo-Json -Compress"
        $warningOutput=& $script:P4Preparation.ExportedCommands['Start-PlatformVerifiedProcess'] $executable $warningProbe $environment $script:P4Platform
        @($warningOutput).Count | Should Be 1
        $warningEvidence=$warningOutput | ConvertFrom-Json
        $warningEvidence.ok | Should Be $true
        $warningEvidence.warnings.count | Should Be 1
        ($warningEvidence.warnings.summaries -join ' ') | Should Match 'fixture warning.*\[path:private-warning-detail\.txt\]'
        ($warningEvidence.warnings.summaries -join ' ') | Should Not Match ([regex]::Escape([IO.Path]::GetDirectoryName($warningPath)))
        $profileEvidence=Join-Path $TestDrive 'failed-process-profile.txt'
        foreach($badProbe in @('$null',"'one';'two'","throw 'fixture failure'")) {
            $probe="[IO.File]::WriteAllText('$($profileEvidence.Replace("'","''"))',`$env:HOME);"+$badProbe
            $caught=$null
            try { & $script:P4Preparation.ExportedCommands['Start-PlatformVerifiedProcess'] $executable $probe $environment $script:P4Platform | Out-Null } catch { $caught=$_ }
            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Capability | Should Be 'powershell-runtime'
            if($badProbe -like 'throw*'){$caught.Exception.Message | Should Match 'stderr:.*fixture failure'}
            if($badProbe -eq "'one';'two'"){$caught.Exception.Message | Should Match 'exactly one JSON value'}
            Test-Path -LiteralPath ([IO.File]::ReadAllText($profileEvidence)) | Should Be $false
        }
        $diagnosticPath=Join-Path $PSHOME 'sensitive-diagnostic.txt'
        $summary=& $script:P4Preparation {
            param($text)
            Get-PlatformProcessStdoutSummary ([Threading.Tasks.Task]::FromResult([string]$text))
        } ($diagnosticPath+"`nsecond line")
        $summary | Should Match '\[path:sensitive-diagnostic\.txt\] \| second line'
        $summary | Should Not Match ([regex]::Escape([IO.Path]::GetDirectoryName($diagnosticPath)))
    }

    # Scenario: A caller's user module path contains a marker-writing Utility shadow.
    # Purpose: Prove the fixture can auto-load, but neither identity nor capability probing loads it.
    It 'InterT59_excludes_shadow_user_modules_from_identity_and_capability_probes' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $runtime=Get-P4KnownRuntimeReceipt
        Invoke-P4WithShadowUserModule 'identity-shadow-user' {
            param($shadow)
            $identity=& $script:P4Preparation.ExportedCommands['Test-PlatformPowerShellIdentity'] $runtime.executablePath $runtime.version $runtime.os $runtime.architecture $runtime.runtimeClosure
            $identity.version | Should Be $runtime.version
            Test-Path -LiteralPath $shadow.Marker | Should Be $false
            $receipt=Get-PlatformCapabilities -Required @('powershell-runtime')
            ($receipt.capabilities | Where-Object name -eq 'powershell-runtime').status | Should Be 'available'
        }
    }

    # Scenario: The host exposes a physical pwsh or a linked/Store runtime layout, plus a physical Pester manifest.
    # Purpose: Report live capabilities while preserving fail-closed runtime rejection for non-physical layouts.
    It 'InterT55_reports_measured_powershell_runtime_and_pester_module_capabilities' {
        $hasKnownRuntimeLink=Test-P4KnownRuntimeLinkRejection
        $receipt=Get-PlatformCapabilities -Required @('pester-module')
        $powerShellCapability=$receipt.capabilities | Where-Object name -eq 'powershell-runtime'
        $pesterCapability=$receipt.capabilities | Where-Object name -eq 'pester-module'
        if($hasKnownRuntimeLink) {
            $powerShellCapability.status | Should Be 'unavailable'
            [string]::Join('; ',[string[]]$powerShellCapability.evidence) | Should Match '(not a physical regular file|Runtime closure (contains a link|requires physical directories))'
        } else {
            $powerShellCapability.status | Should Be 'available'
        }
        $pesterCapability.status | Should Be 'available'
    }

    # Scenario: A caller poisons .NET startup before a verified PowerShell identity probe.
    # Purpose: Start from an empty environment so startup hooks cannot execute outside the verified closure.
    It 'InterT56_excludes_dotnet_startup_hooks_from_verified_runtime_launches' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $runtime=Get-P4KnownRuntimeReceipt
        $fixture=Get-P4StartupHookFixture
        $marker=$fixture.Marker; $hook=$fixture.Hook
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $previous=[Environment]::GetEnvironmentVariable('DOTNET_STARTUP_HOOKS')
        try {
            [Environment]::SetEnvironmentVariable('DOTNET_STARTUP_HOOKS',$hook)
            $control=@(& $runtime.executablePath -NoLogo -NoProfile -NonInteractive -Command '$null' 2>&1)
            $LASTEXITCODE | Should Be 0
            Test-Path -LiteralPath $marker | Should Be $true
            Remove-Item -LiteralPath $marker -Force
            $capabilities=Get-PlatformCapabilities -Required @('file-identity')
            ($capabilities.capabilities | Where-Object name -eq 'powershell-runtime').status | Should Be 'available'
            Test-Path -LiteralPath $marker | Should Be $false
            $identity=& $script:P4Preparation.ExportedCommands['Test-PlatformPowerShellIdentity'] $runtime.executablePath $runtime.version $runtime.os $runtime.architecture $runtime.runtimeClosure
            $identity.version | Should Be $runtime.version
            Test-Path -LiteralPath $marker | Should Be $false
        } finally { [Environment]::SetEnvironmentVariable('DOTNET_STARTUP_HOOKS',$previous) }
    }

    # Scenario: A Unix caller supplies a native loader injection library before a verified probe.
    # Purpose: Conditionally register the platform loader regression while retaining zero skipped tests.
    if ($p4NativeCompilerForRegistration.Count -gt 0) {
    It 'InterT57_excludes_unix_loader_injection_from_verified_runtime_launches' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $runtime=Get-P4KnownRuntimeReceipt
        $marker=Join-Path $TestDrive 'native-loader-hook.marker'
        $sourcePath=Join-Path $TestDrive 'native-loader-hook.c'
        $libraryPath=Join-Path $TestDrive $(if($IsMacOS){'native-loader-hook.dylib'}else{'native-loader-hook.so'})
        $escapedMarker=$marker.Replace('\','\\').Replace('"','\"')
        [IO.File]::WriteAllText($sourcePath,"#include <stdio.h>`n__attribute__((constructor)) static void initialize(void) { FILE *f=fopen(`"$escapedMarker`",`"w`"); if(f){fputs(`"loaded`",f);fclose(f);} }`n",[Text.UTF8Encoding]::new($false))
        $compiler=$p4NativeCompilerForRegistration[0]
        $compilerArguments=if($IsMacOS){@('-dynamiclib','-o',$libraryPath,$sourcePath)}else{@('-shared','-fPIC','-o',$libraryPath,$sourcePath)}
        $compilerOutput=@(& $compiler @compilerArguments 2>&1)
        $LASTEXITCODE | Should Be 0
        Test-Path -LiteralPath $libraryPath | Should Be $true
        $name=if($IsMacOS){'DYLD_INSERT_LIBRARIES'}else{'LD_PRELOAD'}
        $previous=[Environment]::GetEnvironmentVariable($name)
        try {
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable($name,$libraryPath)
            $control=@(& $runtime.executablePath -NoLogo -NoProfile -NonInteractive -Command '$null' 2>&1)
            $LASTEXITCODE | Should Be 0
            Test-Path -LiteralPath $marker | Should Be $true
            Remove-Item -LiteralPath $marker -Force
            $capabilities=Get-PlatformCapabilities -Required @('file-identity')
            ($capabilities.capabilities | Where-Object name -eq 'powershell-runtime').status | Should Be 'available'
            Test-Path -LiteralPath $marker | Should Be $false
            $identity=& $script:P4Preparation.ExportedCommands['Test-PlatformPowerShellIdentity'] $runtime.executablePath $runtime.version $runtime.os $runtime.architecture $runtime.runtimeClosure
            $identity.version | Should Be $runtime.version
            Test-Path -LiteralPath $marker | Should Be $false
        } finally { [Environment]::SetEnvironmentVariable($name,$previous) }
    }
    }

    # Scenario: A regression manifest uses the legacy root-module key, or adds initialization hooks.
    # Purpose: Accept the actual 4.10.1 metadata without weakening hook or identity checks.
    It 'UnitT57_accepts_legacy_pester_metadata_but_rejects_conflicts_and_hooks' {
        $path=Join-Path $TestDrive 'legacy-Pester.psd1'
        foreach($suffix in @('',"; RootModule='other.psm1'","; ScriptsToProcess=@('evil.ps1')","; NestedModules=@('evil.psm1')","; RequiredModules=@('evil')","; RequiredAssemblies=@('evil.dll')")) {
            [IO.File]::WriteAllText($path,("@{ModuleVersion='4.10.1';ModuleToProcess='Pester.psm1';FunctionsToExport=@('Invoke-Pester')"+$suffix+'}'))
            $action={ & $script:P4Preparation { param($path) Assert-RegressionPesterManifest $path } $path }
            if($suffix -eq ''){ & $action } else { $action | Should Throw }
        }
    }

    # Scenario: A standalone resolver is loaded, then changed after the bundle was imported.
    # Purpose: Avoid repository policy lookup and bind validator parsing to the same verified snapshot.
    It 'InterT58_loads_resolver_validators_without_a_repository_policy' {
        $standalone=Join-Path $TestDrive 'standalone-resolver.ps1'
        Copy-Item -LiteralPath (Join-Path $script:P4RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1') -Destination $standalone
        Push-Location $TestDrive
        try {
            $count=& $script:P4Preparation {
                param($path,$platform)
                $resolver=Import-VerifiedPesterResolverModule $path $platform
                try { @($resolver.ExportedCommands.Keys).Count } finally { Remove-Module $resolver -Force -ErrorAction SilentlyContinue }
            } $standalone $script:P4Platform
            $count | Should Be 3
            [IO.File]::AppendAllText($standalone,"`n# changed after bundle import`n")
            $caught=$null
            try {
                & $script:P4Preparation {
                    param($path,$platform)
                    $resolver=Import-VerifiedPesterResolverModule $path $platform
                    Remove-Module $resolver -Force -ErrorAction SilentlyContinue
                } $standalone $script:P4Platform
            } catch { $caught=$_ }
            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Capability | Should Be 'pester-module'
            $caught.Exception.Message | Should Match 'snapshot differs'
        } finally { Pop-Location }
    }

    # Scenario: Import returns a root module path, or the same leaf in a different module base.
    # Purpose: Bind both PSModuleInfo.Path and ModuleBase, rather than comparing Path to a manifest.
    It 'UnitT59_binds_import_to_the_verified_root_module_and_base' {
        $base=Join-Path $TestDrive 'import-identity/Pester/4.10.1'
        $invoke={ param($evidence) & $script:P4Preparation { param($evidence,$base,$platform) Assert-PlatformPesterImportIdentity $evidence '4.10.1' $base $platform } $evidence $base $script:P4Platform }
        & $invoke @{version='4.10.1';path=(Join-Path $base 'Pester.psm1');moduleBase=$base}
        { & $invoke @{version='4.10.1';path=(Join-Path $base 'Pester.psd1');moduleBase=$base} } | Should Throw
        { & $invoke @{version='4.10.1';path=(Join-Path $base 'Pester.psm1');moduleBase=(Join-Path $TestDrive 'other')} } | Should Throw
        { & $invoke @{version='4.10.1';path=(Join-Path $TestDrive 'other/Pester.psm1');moduleBase=$base} } | Should Throw
    }

    # Scenario: Local Pester 4.10.1 is staged with hostile user modules/startup hooks, or the host layout contains links.
    # Purpose: Preserve initialization and tamper checks without loading the proven user-module shadow or startup hook.
    # Not registered when Pester 4.10.1 is absent because this integration fixture validates that exact approved payload.
    if ($p4Pester4101ForRegistration.Count -gt 0) {
    It 'InterT60_initializes_local_pester_4_10_1_and_rejects_a_tampered_manifest' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $pester=$script:P4Pester4101
        $hash=Get-P4PesterPayloadHash $pester.Path (Join-Path $TestDrive 'pester-hash'); $runtime=Get-P4KnownRuntimeReceipt
        $lease=New-P4DestinationLease 'p4-pester-good'
        $startupHook=Get-P4StartupHookFixture
        Remove-Item -LiteralPath $startupHook.Marker -Force -ErrorAction SilentlyContinue
        $previousStartupHook=[Environment]::GetEnvironmentVariable('DOTNET_STARTUP_HOOKS')
        try {
            Invoke-P4WithShadowUserModule 'pester-shadow-user' {
                param($shadow)
                [Environment]::SetEnvironmentVariable('DOTNET_STARTUP_HOOKS',$startupHook.Hook)
                $receipt=Initialize-PlatformPester -Policy @{pesterPurpose='regression';pesterModulePath=$pester.Path;approvedPayload=@{version='4.10.1';sha256=$hash}} -RuntimeReceipt $runtime -DestinationLease $lease
                $receipt.version | Should Be '4.10.1'
                $receipt.purpose | Should Be 'regression'
                $receipt.warningCount | Should BeGreaterThan -1
                $receipt.warnings -is [array] | Should Be $true
                $receipt.environmentAllowlist | Should Contain 'PSModulePath'
                @($receipt.environmentAllowlist | Where-Object { $_ -cmatch '^(LD_|DYLD_|DOTNET_|COREHOST_)' }).Count | Should Be 0
                Test-Path -LiteralPath $startupHook.Marker | Should Be $false
            }
        }
        finally { [Environment]::SetEnvironmentVariable('DOTNET_STARTUP_HOOKS',$previousStartupHook); $lease.Dispose() }
        $tamperedRoot=Join-Path $TestDrive 'tampered-pester/4.10.1'; New-Item -ItemType Directory -Path (Split-Path -Parent $tamperedRoot) -Force | Out-Null; Copy-Item -LiteralPath $pester.ModuleBase -Destination $tamperedRoot -Recurse
        $manifest=Join-Path $tamperedRoot 'Pester.psd1'; (Get-Content $manifest -Raw).Replace("ModuleVersion     = '4.10.1'","ModuleVersion     = '4.10.2'") | Set-Content $manifest -Encoding UTF8
        $tamperedHash=Get-P4PesterPayloadHash $manifest (Join-Path $TestDrive 'tampered-hash'); $lease=New-P4DestinationLease 'p4-pester-tampered'
        try { $caught=$null; try { Initialize-PlatformPester -Policy @{pesterPurpose='regression';pesterModulePath=$manifest;approvedPayload=@{version='4.10.1';sha256=$tamperedHash}} -RuntimeReceipt $runtime -DestinationLease $lease | Out-Null } catch { $caught=$_ }; $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException' }
        finally { $lease.Dispose() }
    }
    }

    # Scenario: Pester source bytes change after snapshot approval but before copying.
    # Purpose: Deploy only captured bytes, and bind every deployed member to that inventory.
    It 'InterT61_copies_pester_from_the_approved_snapshot_not_the_source_path' {
        $root=Join-Path $script:P4Root 'p4-snapshot-pester'; [void][IO.Directory]::CreateDirectory($root)
        $path=Join-Path $root 'Pester.psm1'; [IO.File]::WriteAllText($path,'approved module')
        $lease=New-P4DestinationLease 'p4-snapshot-pester-copy'
        try {
            & $script:P4Preparation {
                param($root,$path,$owned,$platform)
                $destination=Get-VerifiedPlatformLeasePath $owned $platform
                $snapshot=New-PlatformPesterSnapshot $root 'Pester/4.10.1' $destination $platform
                $session=New-PlatformPreparationSession
                try {
                    [IO.File]::WriteAllText($path,'changed source')
                    Copy-PhysicalPesterPayload $root $owned 'Pester/4.10.1' $platform $snapshot $session
                    Assert-PlatformPesterClosure $destination $snapshot.Closure $platform
                    $target=Join-Path $destination 'Pester/4.10.1/Pester.psm1'
                    [IO.File]::ReadAllText($target) | Should Be 'approved module'
                    if($platform -eq 'windows') {
                        { [IO.File]::WriteAllText($target,'unapproved') } | Should Throw
                        { [IO.Directory]::Move((Join-Path $destination 'Pester'),(Join-Path $destination 'moved')) } | Should Throw
                    } else {
                        [IO.File]::WriteAllText($target,'unapproved')
                        $caught=$null; try { Assert-PlatformPesterClosure $destination $snapshot.Closure $platform } catch { $caught=$_ }
                        $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
                        $caught.Exception.Capability | Should Be 'pester-module'
                    }
                } finally { Close-PlatformPreparationSession $session; Close-PlatformPesterSnapshot $snapshot }
            } $root $path $lease $script:P4Platform
        } finally { $lease.Dispose() }
    }

    # Scenario: A dependency is changed during Pester preparation, after the first identity probe.
    # Purpose: Recheck the receipt immediately before the second launch (physical module import).
    # Not registered when Pester 4.10.1 is absent because a physical import is required to reach the second launch.
    if ($p4Pester4101ForRegistration.Count -gt 0) {
    It 'InterT62_rechecks_runtime_closure_before_the_pester_import_launch' {
        $fixture=New-P4ProbeRuntime 'p4-runtime-before-import'
        $pester=$script:P4Pester4101
        $hash=Get-P4PesterPayloadHash $pester.Path (Join-Path $TestDrive 'pester-preimport-hash')
        $policy=@{pesterPurpose='regression';pesterModulePath=$pester.Path;approvedPayload=@{version='4.10.1';sha256=$hash}}
        $lease=New-P4DestinationLease 'p4-pester-before-import'
        try {
            $caught=& $script:P4Preparation {
                param($policy,$runtime,$owned,$platform,$resolverPath,$dependency)
                $original=(Get-Command Copy-PhysicalPesterPayload -CommandType Function).ScriptBlock
                $originalStart=(Get-Command Start-PlatformVerifiedProcess -CommandType Function).ScriptBlock
                try {
                    Set-Item Function:script:Start-PlatformVerifiedProcess -Value {
                        param([string]$Executable,[string]$Probe,$Environment,[string]$Platform)
                        $output=@(& $Executable -NoLogo -NoProfile -NonInteractive -Command $Probe 2>&1)
                        if($LASTEXITCODE -ne 0 -or $output.Count -ne 1){throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Fixture runtime process failed.')}
                        return $output[0]
                    }
                    Set-Item Function:script:Copy-PhysicalPesterPayload -Value {
                        param($SourceVersionRoot,$DestinationLease,$VersionRelativePath,$Platform,$Snapshot,$Session)
                        & $original $SourceVersionRoot $DestinationLease $VersionRelativePath $Platform $Snapshot $Session
                        if($Platform -eq 'windows') {
                            $denied=$false
                            try { [IO.File]::WriteAllText($dependency,'changed after the first probe') } catch { $denied=$true }
                            $denied | Should Be $true
                            throw 'Runtime closure writer denied as expected.'
                        }
                        [IO.File]::WriteAllText($dependency,'changed after the first probe')
                    }
                    try { Initialize-VerifiedPlatformPester $policy $runtime $owned $platform $resolverPath | Out-Null; return $null } catch { return $_ }
                } finally { Set-Item Function:script:Copy-PhysicalPesterPayload -Value $original; Set-Item Function:script:Start-PlatformVerifiedProcess -Value $originalStart }
            } $policy $fixture.Receipt $lease $script:P4Platform (Join-Path $script:P4RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1') (Join-Path $fixture.Root 'System.Management.Automation.dll')
            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Message | Should Match 'runtime closure'
            @([IO.File]::ReadAllLines($fixture.Marker)).Count | Should Be 1
            [IO.File]::WriteAllText((Join-Path $fixture.Root 'System.Management.Automation.dll'),'released after failure')
        } finally { $lease.Dispose() }
    }
    }

    # Scenario: A Windows parent switches from Restricted to process-scoped Bypass before launching the child.
    # Purpose: Give the closure-verified child the same process-scoped Bypass so its verified Pester scripts can load.
    if ($p4IsWindows -and $p4Pester4101ForRegistration.Count -gt 0) {
    It 'InterT63_imports_pester_with_child_process_execution_policy_bypass' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $pester=$script:P4Pester4101
        $runtime=Get-P4KnownRuntimeReceipt
        $pesterClosure=& $script:P4Preparation {param($root) Get-PlatformRuntimeClosure $root 'windows'} $pester.ModuleBase
        $escapedManifest=$pester.Path.Replace("'","''")
        $probe="`$module=@(Import-Module -Name '$escapedManifest' -Force -PassThru -ErrorAction Stop);if(`$module.Count-ne 1){throw 'Pester import count differs'};[pscustomobject]@{policy=`$env:PSExecutionPolicyPreference;version=`$module[0].Version.ToString()}|ConvertTo-Json -Compress"
        $previousPolicy=Get-ExecutionPolicy -Scope Process
        try {
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Restricted -Force | Out-Null
            (Get-ExecutionPolicy -Scope Process) | Should Be 'Restricted'
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force | Out-Null
            (Get-ExecutionPolicy -Scope Process) | Should Be 'Bypass'
            $output=& $script:P4Preparation {
                param($runtime,$probe,$pesterClosure)
                Invoke-PlatformVerifiedProcess $runtime.executablePath $runtime.runtimeClosure 'windows' $probe $pesterClosure
            } $runtime $probe $pesterClosure
            $evidence=$output | ConvertFrom-Json
            $evidence.policy | Should Be 'Bypass'
            $evidence.version | Should Be '4.10.1'
            $evidence.warnings.count | Should BeGreaterThan -1
            (Get-ExecutionPolicy -Scope Process) | Should Be 'Bypass'
        } finally { Set-ExecutionPolicy -Scope Process -ExecutionPolicy $previousPolicy -Force | Out-Null }
    }
    }

    # Scenario: Pester.psm1 is changed during the final runtime check, after payload validation.
    # Purpose: Windows must deny the write; Unix must revalidate Pester after the runtime check, before import.
    # Not registered when Pester 4.10.1 is absent because the late-mutation boundary uses its physical payload.
    if ($p4Pester4101ForRegistration.Count -gt 0) {
    It 'InterT64_protects_pester_between_payload_validation_and_import' {
        $fixture=New-P4ProbeRuntime 'p4-late-pester'; $pester=$script:P4Pester4101
        $hash=Get-P4PesterPayloadHash $pester.Path (Join-Path $TestDrive 'pester-late-hash')
        $policy=@{pesterPurpose='regression';pesterModulePath=$pester.Path;approvedPayload=@{version='4.10.1';sha256=$hash}}
        $lease=New-P4DestinationLease 'p4-late-pester-copy'
        $moduleBase=Join-Path $script:P4Root 'p4-late-pester-copy/Pester/4.10.1'
        $rootModule=Join-Path $moduleBase 'Pester.psm1'
        $import=@{version='4.10.1';path=$rootModule;moduleBase=$moduleBase} | ConvertTo-Json -Compress
        $identity=@{version=$fixture.Receipt.version;os=$script:P4Platform;architecture=$script:P4Architecture} | ConvertTo-Json -Compress
        # This deterministic process fixture emits identity/import evidence only.
        # Real Pester import remains covered by InterT60 and InterT70.
        $body=if($IsWindows) {
            "[IO.File]::AppendAllText('$($fixture.Marker.Replace("'","''"))','launch'+[Environment]::NewLine);`$global:LASTEXITCODE=0;if((`$args -join ' ') -match 'Import-Module'){'$($import.Replace("'","''"))'}else{'$identity'}"
        } else {
            "#!/bin/sh`nprintf 'launch\n' >> '$($fixture.Marker)'`ncase `"`$4`" in *Import-Module*) printf '%s\n' '$import';; *) printf '%s\n' '$identity';; esac"
        }
        [IO.File]::WriteAllText($fixture.Receipt.executablePath,$body,[Text.UTF8Encoding]::new($false))
        $fixture.Receipt.executableSha256=(Get-FileHash $fixture.Receipt.executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $fixture.Receipt.runtimeClosure=& $script:P4Preparation {param($root,$platform) Get-PlatformRuntimeClosure $root $platform} $fixture.Root $script:P4Platform
        try {
            $result=& $script:P4Preparation {
                param($policy,$runtime,$owned,$platform,$resolverPath,$rootModule)
                $originalCopy=(Get-Command Copy-PhysicalPesterPayload -CommandType Function).ScriptBlock
                $originalAssert=(Get-Command Assert-PlatformRuntimeClosure -CommandType Function).ScriptBlock
                $originalStart=(Get-Command Start-PlatformVerifiedProcess -CommandType Function).ScriptBlock
                $script:P4Copied=$false; $script:P4Attempted=$false; $script:P4Denied=$false
                try {
                    Set-Item Function:script:Start-PlatformVerifiedProcess -Value {
                        param([string]$Executable,[string]$Probe,$Environment,[string]$Platform)
                        $output=@(& $Executable -NoLogo -NoProfile -NonInteractive -Command $Probe 2>&1)
                        if($LASTEXITCODE -ne 0 -or $output.Count -ne 1){throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Fixture runtime process failed.')}
                        return $output[0]
                    }
                    Set-Item Function:script:Copy-PhysicalPesterPayload -Value {
                        param($SourceVersionRoot,$DestinationLease,$VersionRelativePath,$Platform,$Snapshot,$Session)
                        & $originalCopy $SourceVersionRoot $DestinationLease $VersionRelativePath $Platform $Snapshot $Session
                        $script:P4Copied=$true
                    }
                    Set-Item Function:script:Assert-PlatformRuntimeClosure -Value {
                        param($ExecutablePath,$Expected,$Platform)
                        & $originalAssert $ExecutablePath $Expected $Platform
                        if($script:P4Copied -and -not $script:P4Attempted) {
                            $script:P4Attempted=$true
                            try { [IO.File]::WriteAllText($rootModule,'unapproved module') } catch { $script:P4Denied=$true }
                        }
                    }
                    $caught=$null; $receipt=$null
                    try { $receipt=Initialize-VerifiedPlatformPester $policy $runtime $owned $platform $resolverPath } catch { $caught=$_ }
                    [pscustomobject]@{Attempted=$script:P4Attempted;Denied=$script:P4Denied;Error=$caught;Receipt=$receipt}
                } finally {
                    Set-Item Function:script:Copy-PhysicalPesterPayload -Value $originalCopy
                    Set-Item Function:script:Assert-PlatformRuntimeClosure -Value $originalAssert
                    Set-Item Function:script:Start-PlatformVerifiedProcess -Value $originalStart
                }
            } $policy $fixture.Receipt $lease $script:P4Platform (Join-Path $script:P4RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1') $rootModule
            $result.Attempted | Should Be $true
            if($IsWindows) {
                $result.Denied | Should Be $true; $result.Error | Should BeNullOrEmpty
                $result.Receipt.version | Should Be '4.10.1'
                $result.Receipt.moduleClosure.files.Count | Should BeGreaterThan 0
                $result.Receipt.warningCount | Should Be 0
                $result.Receipt.warnings -is [array] | Should Be $true
                @($result.Receipt.warnings).Count | Should Be 0
                $result.Receipt.protectionBoundary | Should Match 'deny-write-delete.*process exit'
                @([IO.File]::ReadAllLines($fixture.Marker)).Count | Should Be 2
                [IO.File]::WriteAllText($rootModule,'released after import')
            } else {
                $result.Denied | Should Be $false
                $result.Error.Exception.GetType().Name | Should Be 'PlatformVerificationException'
                $result.Error.Exception.Capability | Should Be 'pester-module'
                @([IO.File]::ReadAllLines($fixture.Marker)).Count | Should Be 1
            }
        } finally { $lease.Dispose() }
    }
    }

    # Scenario: A launched probe hangs after recording its PID and private profile.
    # Purpose: Bound runtime preparation, kill the owned process and reclaim its private files on timeout.
    It 'InterT65_bounds_execution_and_terminates_the_owned_probe' {
        $executable=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        $environment=& $script:P4Preparation.ExportedCommands['New-PlatformVerifiedProcessEnvironment'] $executable $null $script:P4Platform
        $marker=Join-Path $TestDrive 'hung-probe.txt'
        $probe="[IO.File]::WriteAllText('$($marker.Replace("'","''"))',([string]`$PID+[Environment]::NewLine+`$env:HOME));[Threading.Thread]::Sleep(60000)"
        $timer=[Diagnostics.Stopwatch]::StartNew();$caught=$null
        try { & $script:P4Preparation.ExportedCommands['Start-PlatformVerifiedProcess'] $executable $probe $environment $script:P4Platform -TimeoutMilliseconds 5000 | Out-Null } catch {$caught=$_}
        $timer.Elapsed.TotalSeconds | Should BeLessThan 15
        $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
        $caught.Exception.Capability | Should Be 'powershell-runtime'
        $caught.Exception.Message | Should Match 'execution deadline exceeded'
        $evidence=[IO.File]::ReadAllLines($marker)
        $owned=Get-Process -Id ([int]$evidence[0]) -ErrorAction SilentlyContinue
        try { ($null -eq $owned -or $owned.HasExited) | Should Be $true } finally {if($null -ne $owned){$owned.Dispose()}}
        Test-Path -LiteralPath $evidence[1] | Should Be $false
    }

    # Scenario: A Unix probe exits while its own descendant retains stdout/stderr pipes.
    # Purpose: Apply the same deadline to output draining instead of waiting indefinitely for EOF.
    if ($p4IsUnix) {
    It 'InterT66_bounds_output_when_a_descendant_retains_the_pipes' {
        $executable=Join-Path $PSHOME 'pwsh'
        $environment=& $script:P4Preparation.ExportedCommands['New-PlatformVerifiedProcessEnvironment'] $executable $null $script:P4Platform
        $marker=Join-Path $TestDrive 'pipe-descendant.txt'
        $probe=@'
$start=[Diagnostics.ProcessStartInfo]::new('/bin/sleep')
$start.UseShellExecute=$false
$start.ArgumentList.Add('60')
$child=[Diagnostics.Process]::Start($start)
[IO.File]::WriteAllText('__MARKER__',([string]$child.Id+[Environment]::NewLine+$env:HOME))
$child.Dispose()
'complete'
'@
        $probe=$probe.Replace('__MARKER__',$marker.Replace("'","''"))
        $timer=[Diagnostics.Stopwatch]::StartNew();$caught=$null
        try {
            try { & $script:P4Preparation.ExportedCommands['Start-PlatformVerifiedProcess'] $executable $probe $environment $script:P4Platform -TimeoutMilliseconds 5000 | Out-Null } catch {$caught=$_}
            $timer.Elapsed.TotalSeconds | Should BeLessThan 15
            $caught.Exception.GetType().Name | Should Be 'PlatformVerificationException'
            $caught.Exception.Capability | Should Be 'powershell-runtime'
            $caught.Exception.Message | Should Match 'output deadline exceeded'
            $caught.Exception.Message | Should Match 'ConvertFrom-Json'
            $evidence=[IO.File]::ReadAllLines($marker)
            Test-Path -LiteralPath $evidence[1] | Should Be $false
        } finally {
            # The direct child has exited; clean up the exact descendant created
            # by this fixture (P3 process-group ownership is outside this boundary).
            if([IO.File]::Exists($marker)){
                $descendant=Get-Process -Id ([int][IO.File]::ReadAllLines($marker)[0]) -ErrorAction SilentlyContinue
                if($null -ne $descendant){try{if(-not $descendant.HasExited){$descendant.Kill();[void]$descendant.WaitForExit(2000)}}finally{$descendant.Dispose()}}
            }
        }
    }
    }

    # Scenario: A probe emits invalid JSON and both streams close normally.
    # Purpose: Payload failures remain diagnostic errors when no output deadline expires.
    It 'InterT67_preserves_json_failure_without_an_inherited_pipe' {
        $executable=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        $environment=& $script:P4Preparation.ExportedCommands['New-PlatformVerifiedProcessEnvironment'] $executable $null $script:P4Platform
        $failure=$null
        try {& $script:P4Preparation.ExportedCommands['Start-PlatformVerifiedProcess'] $executable "'complete'" $environment $script:P4Platform -TimeoutMilliseconds 15000|Out-Null} catch {$failure=$_}
        $failure.Exception.GetType().Name | Should Be 'PlatformVerificationException'
        $failure.Exception.Message | Should Match 'ConvertFrom-Json'
        $failure.Exception.Message | Should Not Match 'deadline exceeded'
    }

    # Scenario: A physical pwsh receives only the declared bundle closure, or the host layout contains links.
    # Purpose: Verify standalone initialization on physical hosts and typed rejection on linked hosts.
    # Not registered when Pester 4.10.1 is absent because standalone initialization requires that approved local payload.
    if ($p4Pester4101ForRegistration.Count -gt 0) {
    It 'InterT70_initializes_pester_from_only_the_declared_runtime_closure' {
        if(Test-P4KnownRuntimeLinkRejection){ return }
        $bundle=Join-Path $script:P4Root 'p4-standalone-bundle'
        $manifest=Import-PowerShellDataFile -LiteralPath $script:P4Manifest
        foreach($relative in $manifest.FileList) {
            $target=Join-Path $bundle $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $script:P4Manifest) $relative) -Destination $target
        }
        @(Get-ChildItem -LiteralPath $bundle -File -Recurse).Count | Should Be $manifest.FileList.Count
        Test-Path -LiteralPath (Join-Path $bundle 'docs') | Should Be $false
        $pester=$script:P4Pester4101
        $hash=Get-P4PesterPayloadHash $pester.Path (Join-Path $TestDrive 'standalone-pester-hash')
        $runtimePath=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        $config=@{
            bundle=$bundle; root=$script:P4Root
            policy=@{pesterPurpose='regression';pesterModulePath=$pester.Path;approvedPayload=@{version='4.10.1';sha256=$hash}}
            runtime=(Get-P4KnownRuntimeReceipt)
        }
        # The full PSHOME closure can exceed Windows' command-line length limit.
        $configPath=Join-Path $TestDrive 'standalone-config.json'
        [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
        $encodedConfig=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($configPath))
        $code=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$config=ConvertFrom-Json ([IO.File]::ReadAllText([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG__'))))
$module=Import-Module (Join-Path $config.bundle 'platform-runtime.psd1') -Force -PassThru
$lease=& $module.ExportedCommands['Open-PlatformDirectory'] -Root $config.root -RelativePath 'p4-standalone-pester' -CreatePrivate
try {
    $receipt=& $module.ExportedCommands['Initialize-PlatformPester'] -Policy $config.policy -RuntimeReceipt $config.runtime -DestinationLease $lease
    $receipt | ConvertTo-Json -Depth 8 -Compress
} finally { $lease.Dispose(); Remove-Module $module -Force }
'@
        $encodedCommand=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code.Replace('__CONFIG__',$encodedConfig)))
        $output=@(& $runtimePath -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>&1)
        $LASTEXITCODE | Should Be 0
        $output.Count | Should Be 1
        $receipt=[string]$output[0] | ConvertFrom-Json
        $receipt.version | Should Be '4.10.1'
        $receipt.purpose | Should Be 'regression'
    }
    }
}

Describe 'Platform owned process probe failure cleanup' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/platform-runtime.psd1') -Force
        function Invoke-P3ProbeFailureFixture([string]$Mode,[int]$FailPass=1) {
            & (Get-Module platform-runtime) {
                param($Mode,$FailPass)
                # Only process execution is substituted. Creation, identity checks,
                # finally cleanup and non-recursive directory removal are real P2 APIs.
                $state = @{ Mode=$Mode; FailPass=$FailPass; Pass=0; Path=$null; Created=[Collections.Generic.List[object]]::new(); Disposed=0 }
                $originalDirectory = ${function:Open-PlatformDirectory}
                $originalFile = ${function:Open-PlatformFile}
                function Open-PlatformDirectory {
                    param($Root,$RelativePath,[switch]$CreatePrivate)
                    if ($CreatePrivate) { $state.Path = Join-Path $Root $RelativePath }
                    & $originalDirectory @PSBoundParameters
                }
                function Open-PlatformFile {
                    param($ParentLease,$Leaf,$Access,$CreateMode)
                    if ($CreateMode -eq 'CreateNew' -and $Leaf -eq 'err' -and $state.Mode -eq 'partial-create') { throw 'fixture-second-capture-failure' }
                    $file = & $originalFile @PSBoundParameters
                    if ($CreateMode -eq 'CreateNew') { $state.Created.Add(@($Leaf,$file.Observation)) }
                    return $file
                }
                function Start-PlatformCapturedProcess {
                    param($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes)
                    $state.Pass++
                    if ($state.Mode -eq 'start' -and $state.Pass -eq $state.FailPass) { throw 'fixture-native-start-failure' }
                    # This fake process has finished writing and closed its capture handles.
                    $StdoutLease.Dispose(); $StderrLease.Dispose()
                    if ($state.Pass -eq 1) {
                        [IO.File]::WriteAllText((Join-Path $state.Path 'out'),'probe-out')
                        [IO.File]::WriteAllText((Join-Path $state.Path 'err'),'probe-err')
                    }
                    $process = [pscustomobject]@{
                        ExitCode=7; UnixObservation=$null; State=$state
                        TimedOut=($state.Mode -eq 'timeout' -and $state.Pass -eq $state.FailPass)
                        CleanedUp= -not ($state.Mode -eq 'cleanup' -and $state.Pass -eq $state.FailPass)
                    }
                    $process | Add-Member ScriptMethod WaitForExit { param($Timeout) return -not $this.TimedOut }
                    $process | Add-Member ScriptMethod Dispose {
                        $this.State.Disposed++
                        if ($this.State.Mode -eq 'dispose') { throw 'fixture-process-dispose-failure' }
                    }
                    return $process
                }
                function Stop-PlatformOwnedProcess {
                    param($Lease)
                    [pscustomobject]@{ CleanedUp=$Lease.CleanedUp; SignalsSent=1 }
                }
                try {
                    $receipt = Test-PlatformOwnedProcess
                    $receipt.status | Should Be $(if ($state.Mode -eq 'success') { 'available' } else { 'unavailable' })
                    $state.Path | Should Not BeNullOrEmpty
                    $expectedCount = if ($state.Mode -eq 'success') { 4 } elseif ($state.Mode -eq 'partial-create') { 1 } else { 2 * $state.FailPass }
                    $state.Created.Count | Should Be $expectedCount
                    # Assert before fixture fallback: production must have removed
                    # all files and the directory even when no process lease returned.
                    [IO.Directory]::Exists($state.Path) | Should Be $false
                    @($receipt.evidence.PSObject.Properties.Name) | Should Not Contain 'cleanupFailure'
                    if ($state.Mode -eq 'success') { @($receipt.evidence.PSObject.Properties.Name) | Should Not Contain 'executableLeaseBinding' }
                    elseif ($state.Mode -eq 'dispose') { $receipt.evidence.processDisposeFailure | Should Match 'fixture-process-dispose-failure' }
                    elseif ($state.Mode -eq 'start') { $receipt.evidence.failure | Should Match 'fixture-native-start-failure' }
                    elseif ($state.Mode -eq 'timeout') { $receipt.evidence.failure | Should Match 'timed out' }
                    elseif ($state.Mode -eq 'partial-create') { $receipt.evidence.failure | Should Match 'fixture-second-capture-failure' }
                    else { $receipt.evidence.failure | Should Match 'cleanup|clean up' }
                } finally {
                    # Exact fixture-owned observations only; never recursively delete.
                    if ($null -ne $state.Path -and [IO.Directory]::Exists($state.Path)) {
                        $root = [IO.Path]::GetDirectoryName($state.Path)
                        $directory = & $originalDirectory -Root $root -RelativePath ([IO.Path]::GetFileName($state.Path))
                        $fallback = [ordered]@{}
                        Clear-PlatformProbe -Directory $directory -Path $state.Path -Entries $state.Created.ToArray() -Evidence $fallback
                    }
                }
            } $Mode $FailPass
        }
    }

    # Scenario: Native start fails after capture creation, in either probe phase.
    # Purpose: Ownership must be recorded before a process lease can be returned.
    It 'UnitT10_removes_probe_captures_after_start_failure' {
        foreach ($pass in @(1,2)) { Invoke-P3ProbeFailureFixture start $pass }
    }

    # Scenario: The first probe cannot observe process exit before its deadline.
    # Purpose: Timeout must still release the process lease and all probe files.
    It 'UnitT20_removes_probe_captures_after_timeout' { Invoke-P3ProbeFailureFixture timeout }

    # Scenario: Either normal-exit or termination cleanup reports incomplete cleanup.
    # Purpose: Failure receipts must not skip capture ownership registration or removal.
    It 'UnitT30_removes_probe_captures_after_cleanup_failure' {
        foreach ($pass in @(1,2)) { Invoke-P3ProbeFailureFixture cleanup $pass }
    }

    # Scenario: Opening stderr fails after stdout has already been created.
    # Purpose: Capture ownership is journaled individually, not after the pair succeeds.
    It 'UnitT40_removes_the_first_capture_when_the_second_creation_fails' { Invoke-P3ProbeFailureFixture partial-create }

    # Scenario: Process lease disposal itself throws during the failure path.
    # Purpose: Preserve disposal evidence and execute file cleanup regardless.
    It 'UnitT50_cleans_probe_files_even_when_process_disposal_throws' { Invoke-P3ProbeFailureFixture dispose }

    # Scenario: Path execution succeeds; executable-lease execution has not been measured.
    # Purpose: An available path probe must not claim lease binding capability.
    It 'UnitT60_does_not_claim_unmeasured_executable_lease_binding' { Invoke-P3ProbeFailureFixture success }

}
