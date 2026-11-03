# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

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
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1') -Destination $Destination
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psm1') -Destination $Destination
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/installer-safe-mutation.psm1') -Destination $Destination
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/platform') -Destination $Destination -Recurse
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

    # Scenario: A caller requires publication before P7 is installed.
    # Purpose: Prevent partial-success receipts from authorizing an unavailable mutation path.
    It 'UnitT20_throws_a_typed_failure_when_a_required_capability_is_not_available' {
        $caught = $null
        try { Get-PlatformCapabilities -Required @('publication') | Out-Null }
        catch { $caught = $_ }

        $caught | Should Not BeNullOrEmpty
        $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
        $caught.Exception.Capability | Should Be 'publication'
        $caught.Exception.Platform | Should Be $script:ExpectedOs
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

    # Scenario: Linux and macOS adapters are loaded directly before their P7 primitives exist.
    # Purpose: Require typed fail-closed behavior instead of a Unix no-op or fabricated lease.
    It 'UnitT30_rejects_unimplemented_unix_primitives_with_typed_failures' {
        foreach ($adapter in @('Linux','MacOS')) {
            $adapterPath = Join-Path $script:RepositoryRoot "scripts/platform/$adapter.psm1"
            Import-Module $adapterPath -Force
            $command = "Publish-$($adapter)PlatformFile"
            $caught = $null
            try { & $command -ParentLease 'fixture' -StageLease 'fixture' -ExpectedState 'fixture' | Out-Null }
            catch { $caught = $_ }

            $caught | Should Not BeNullOrEmpty
            $caught.Exception.GetType().Name | Should Be 'PlatformNotImplementedException'
            $caught.Exception.ImplementationStep | Should Be 'P7'
            Remove-Module $adapter -Force -ErrorAction SilentlyContinue
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
        { Import-Module (Join-Path $extraFixture 'platform-runtime.psd1') -Force } | Should Throw

        $changedFixture = Join-Path $TestDrive 'changed'
        Copy-PlatformRuntimeFixture -Destination $changedFixture
        Add-Content -LiteralPath (Join-Path $changedFixture 'platform/Linux.psm1') -Value '# tampered' -Encoding UTF8
        { Import-Module (Join-Path $changedFixture 'platform-runtime.psd1') -Force } | Should Throw
        foreach ($leaf in @('UnixNative.cs','WindowsNative.cs','Unix.psm1')) {
            $nativeFixture = Join-Path $TestDrive ('changed-' + $leaf)
            Copy-PlatformRuntimeFixture -Destination $nativeFixture
            Add-Content -LiteralPath (Join-Path $nativeFixture "platform/$leaf") -Value 'tampered' -Encoding UTF8
            { Import-Module (Join-Path $nativeFixture 'platform-runtime.psd1') -Force } | Should Throw
        }
    }

    # Scenario: The retained Windows mutation dependency is absent from a distributed runtime closure.
    # Purpose: Refuse import before the adapter can resolve an unbound external implementation.
    It 'InterT55_rejects_a_missing_installer_mutation_dependency' {
        $fixture = Join-Path $TestDrive 'missing-installer-dependency'
        Copy-PlatformRuntimeFixture -Destination $fixture
        Remove-Item -LiteralPath (Join-Path $fixture 'installer-safe-mutation.psm1') -Force

        { Import-Module (Join-Path $fixture 'platform-runtime.psd1') -Force } | Should Throw
    }

    # Scenario: The retained Windows mutation dependency changes after its runtime inventory was reviewed.
    # Purpose: Refuse import when delegated code no longer matches the bound SHA-256.
    It 'InterT60_rejects_a_tampered_installer_mutation_dependency' {
        $fixture = Join-Path $TestDrive 'tampered-installer-dependency'
        Copy-PlatformRuntimeFixture -Destination $fixture
        Add-Content -LiteralPath (Join-Path $fixture 'installer-safe-mutation.psm1') -Value '# tampered' -Encoding UTF8

        { Import-Module (Join-Path $fixture 'platform-runtime.psd1') -Force } | Should Throw
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
            else { $permissions.Kind | Should Be 'directory'; ($permissions.Mode -band 4095) | Should Be 448 }
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
                ((Set-PlatformPermissions -Lease $file -Policy @{ Mode=416 }).Mode -band 4095) | Should Be 416
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
        $abi | Should Match 'stat/fstatat size, type, mode, uid, gid, inode and nlink self-test passed'
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
}
