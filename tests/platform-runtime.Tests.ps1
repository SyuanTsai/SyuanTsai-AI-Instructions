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

    # Scenario: A caller requires a P2 primitive while only the P1 skeleton is installed.
    # Purpose: Prevent partial-success receipts from authorizing an unavailable mutation path.
    It 'UnitT20_throws_a_typed_failure_when_a_required_capability_is_not_available' {
        $caught = $null
        try { Get-PlatformCapabilities -Required @('directory-lease') | Out-Null }
        catch { $caught = $_ }

        $caught | Should Not BeNullOrEmpty
        $caught.Exception.GetType().Name | Should Be 'PlatformCapabilityUnavailableException'
        $caught.Exception.Capability | Should Be 'directory-lease'
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

    # Scenario: Linux and macOS adapters are loaded directly before their P2 primitives exist.
    # Purpose: Require typed fail-closed behavior instead of a Unix no-op or fabricated lease.
    It 'UnitT30_rejects_unimplemented_unix_primitives_with_typed_failures' {
        foreach ($adapter in @('Linux','MacOS')) {
            $adapterPath = Join-Path $script:RepositoryRoot "scripts/platform/$adapter.psm1"
            Import-Module $adapterPath -Force
            $command = "Open-$($adapter)PlatformDirectory"
            $caught = $null
            try { & $command -Root 'fixture-root' -RelativePath 'child' | Out-Null }
            catch { $caught = $_ }

            $caught | Should Not BeNullOrEmpty
            $caught.Exception.GetType().Name | Should Be 'PlatformNotImplementedException'
            $caught.Exception.ImplementationStep | Should Be 'P2'
            Remove-Module $adapter -Force -ErrorAction SilentlyContinue
        }
    }

    # Scenario: The Windows adapter wraps the retained safe directory guard.
    # Purpose: Preserve the existing function name and exact parameter mapping during P1 extraction.
    It 'UnitT40_delegates_windows_directory_arguments_to_the_existing_installer_function' -Skip:($script:ExpectedOs -ne 'windows') {
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
    It 'UnitT42_ignores_an_ambient_same_name_installer_function' -Skip:($script:ExpectedOs -ne 'windows') {
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

    # Scenario: A path is replaced by another ordinary single-link file after an Expected identity was recorded.
    # Purpose: Never report identity success when P1 cannot compare the replacement's volume and file identifiers.
    It 'InterT45_rejects_a_replaced_single_link_file_with_the_same_expected_identity' -Skip:($script:ExpectedOs -ne 'windows') {
        $path = Join-Path $TestDrive 'identity-target.txt'
        Set-Content -LiteralPath $path -Value 'original' -Encoding UTF8
        $expected = [pscustomobject]@{ volumeSerial = 1; fileIndex = 1 }
        Remove-Item -LiteralPath $path -Force
        Set-Content -LiteralPath $path -Value 'replacement' -Encoding UTF8

        Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform/Windows.psm1') -Force
        $caught = $null
        try { Assert-WindowsPlatformFileIdentity -Lease $path -Expected $expected -SingleLink }
        catch { $caught = $_ }

        $caught | Should Not BeNullOrEmpty
        $caught.Exception.GetType().Name | Should Be 'PlatformNotImplementedException'
        $caught.Exception.Capability | Should Be 'file-identity'
        $caught.Exception.ImplementationStep | Should Be 'P2'
        Remove-Module Windows -Force
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
