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
        'platform/UnixNative.cs',
        'platform/WindowsNative.cs',
        'platform/Unix.psm1',
        'platform/RuntimePreparation.psm1',
        'platform/Windows.psm1',
        'platform/Linux.psm1',
        'platform/MacOS.psm1',
        'Resolve-StandardValidationTool.ps1'
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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = 'c0f050edfd93efcd349528aa9d3f84d2a1fee32ef5df775e8fd49baa694d3a7d' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = 'df5f6efa11f66cedcfed9fae681b8364ddfbe66027869177b0a1f0771098c8ed' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = '6199e45d01293d970f33195368cdef0630b1392a4eb00a289ef85c10eda1eef0' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'c54218f115bdda7cc7429555874835b2e7c7f2f7a6a371429ba55ac1fc2dc335' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = '35404680843a0a2cb41d241c1e673ab82494ec61ab54bd817892484774a5ec18' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'ac1e73ffb1b8ea1b95fdc3a177449442281d3d485f62ec42e464f6f5f38ba359' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = '0680ec51c0458c5d87603c877f0056f8027c58178db8558e6eef09d6a21f5dc4' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = '15993739af3b2479c39ee01c6a63fb4cb95c73c622bf6315b524fa8151455997' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = 'f45b5baec758b48aae7c9dd39441fbc5bbbbf9d097f3711a6861e80e4c9267e1' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = '1beabd0381f53892dcc0a9768f6399418ca38a15f4b465560b083229836643f3' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'fbbc258b12ed24f257bc068399b76f9e58de4a02bd9d12301c01842a77c960c1' }
            )
        }
    }
}
