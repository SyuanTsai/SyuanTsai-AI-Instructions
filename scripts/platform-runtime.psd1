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
        'Resolve-PlatformPhysicalPath',
        'Initialize-PlatformAuthorityPester',
        'Assert-PlatformAuthorityPester',
        'New-PlatformPrivateRoot',
        'Invoke-PlatformPreparationCommand',
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
        'platform/OwnedProcess.cs',
        'platform/UnixProcess.cs',
        'platform/WindowsProcess.cs',
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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = '6312032ac138a7c3411f82e0c25d687738993e469f7f1e3f9f5dd4f21e568607' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = '3c4eca15ee608d72b3985db1ab34ad9558243385b2cbe84d909b8cd219482181' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = 'f4ddc352f5707f1a30dd9b99d8e5cd938d867f3b17a7dc6e764fe24839832db9' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'd372673ee29a9f6e3bbc9da2452e328e1207b01c29bd3ad6f846c3377aea4fdf' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'ac1e73ffb1b8ea1b95fdc3a177449442281d3d485f62ec42e464f6f5f38ba359' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = 'cae2197bc4d644f108e4f0722b2c76017981922618277efc101f9da472b61607' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = 'bb916f529ebf99c7893f541749e91ae7b4b22bd66f2c2f2efce91a8b4977d7cd' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = 'fb163b03980e9a5831d06e524849e61e4dc4b1d00ca844279ebe1d330353fca7' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = 'b9ffcf44579013c4b3ad4e394d2cf3f21976cff7d71d60bdcf09a085e215fe1f' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'e51c78847aa706dd4bed92fa1e91e1c992e0b1e8d938aaa605c4c7389b66b8f5' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            )
        }
    }
}
