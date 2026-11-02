# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

@{
    RootModule = 'platform-runtime.psm1'
    ModuleVersion = '1.0.0'
    GUID = '896eea26-3fc0-4de1-bb21-6c2fb6a6c3ef'
    Author = 'SyuanTsai-AI-Instructions contributors'
    Copyright = 'Copyright 2026 SyuanTsai. Licensed under Apache-2.0.'
    Description = 'Fail-closed cross-platform capability and runtime adapter API.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Assert-PlatformRuntimeInventory',
        'Get-PlatformCapabilities',
        'Open-PlatformDirectory',
        'Open-PlatformFile',
        'Assert-PlatformFileIdentity',
        'Enter-PlatformLock',
        'Publish-PlatformFile',
        'Remove-PlatformOwnedFile',
        'Get-PlatformPermissions',
        'Set-PlatformPermissions',
        'Start-PlatformOwnedProcess',
        'Stop-PlatformOwnedProcess',
        'Resolve-PlatformPowerShell',
        'Initialize-PlatformPester',
        'Set-PlatformProcessEnvironment'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FileList = @(
        'platform-runtime.psd1',
        'platform-runtime.psm1',
        'installer-safe-mutation.psm1',
        'platform/PlatformNative.cs',
        'platform/Windows.psm1',
        'platform/Linux.psm1',
        'platform/MacOS.psm1'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('platform','runtime','capability')
            LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0'
        }
        PlatformRuntime = @{
            ApiVersion = '1.0'
            HashMode = 'sha256-utf8-lf'
            Inventory = @(
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'f486fea25db09e61545ce925a5b72dbe14e76bac7cd3771e6d397c32e909fce8' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'ac1e73ffb1b8ea1b95fdc3a177449442281d3d485f62ec42e464f6f5f38ba359' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = '1985ef1e6e44dd07ce4f7af420506749b7c464ae2701b369f296878972fc5c25' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = '27d669b8890928cd2b7fe865719fa74ce860caeb7fdd4213446f1a4f74c07167' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = 'a2daec4e390905becc1133f15f1e1654057042abbb28bf659dae8bfa72146cd5' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = '5bb16d867a0dfc7ce24c235cc361c3b50bb29c2f9006719ed7a6789486b5b90b' }
            )
        }
    }
}
