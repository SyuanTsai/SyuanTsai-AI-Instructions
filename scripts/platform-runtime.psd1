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
        'platform/PlatformNative.cs',
        'platform/UnixNative.cs',
        'platform/WindowsNative.cs',
        'platform/WindowsInstallerMutation.cs',
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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = 'dd95835adcc4c19509fab6df017ad8f9db1aa7d61468c3dc687547cd2cb11b79' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = '58eb05436ddb3bf4650fdaf2d83b6be2dddc029917602005e0faf3e3b5e106e9' },
                @{ Path = 'platform/WindowsInstallerMutation.cs'; Sha256 = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = '6199e45d01293d970f33195368cdef0630b1392a4eb00a289ef85c10eda1eef0' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'ecc89c9852e70f476fdb0310478f7ffed8065b50ed31b4947e1f5d6a013ae014' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = '63648899e0171fad28294ed3d2c9398bac13a402de324ca5bbc1820fcd269c98' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = 'ac8c6c8950a419afce21c11fa8b6affbd70c1cb816382285aead7dc164038fed' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = 'd894a145f3189033a0ab0dc4b6c169a7fd23d229d223478437f117429bdf206b' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = 'a8b04f32e97fc939e62ee7da57b36fb2ca73f141c772bf9ecfe9c7393119535d' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'e51c78847aa706dd4bed92fa1e91e1c992e0b1e8d938aaa605c4c7389b66b8f5' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            )
        }
    }
}
