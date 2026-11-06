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
        'Move-PlatformOwnedDirectory',
        'Remove-PlatformOwnedDirectoryTree',
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
        'WindowsDacl.psm1',
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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = '6312032ac138a7c3411f82e0c25d687738993e469f7f1e3f9f5dd4f21e568607' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = '7724e2a3c46a28d6af19d4b0cb04761b4ebbd7d0df78058b412815898e71d954' },
                @{ Path = 'platform/WindowsInstallerMutation.cs'; Sha256 = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = 'c726488e7627115a58e73fff199cd6f74d9a83e9260977f2d2df4451e5315516' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = '4e41234a31c35e2cf4630825a2e3d1dfc70abd93fbc98cc5f2fd846b5bccc272' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293' },
                @{ Path = 'WindowsDacl.psm1'; Sha256 = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = 'dfa98eaba33cf22664320d79446f8ddc62417e88954bf61554df31c76c71eef9' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = 'd30ad3bc5625898efe665499577978108c5a68f093ece57a5f5ede8c0857b935' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = 'c2fa74ea2bc9d30ec038e0e97d98dc08cef62656a3a3f85144d38bca140c3397' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'e51c78847aa706dd4bed92fa1e91e1c992e0b1e8d938aaa605c4c7389b66b8f5' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            )
        }
    }
}
