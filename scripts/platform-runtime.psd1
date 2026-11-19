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
        'Confirm-PlatformDirectoryDurability',
        'Publish-PlatformFile',
        'Remove-PlatformOwnedFile',
        'Get-PlatformDirectoryState',
        'Move-PlatformOwnedDirectory',
        'Remove-PlatformOwnedDirectoryTree',
        'Get-PlatformPermissions',
        'Set-PlatformPermissions',
        'Start-PlatformOwnedProcess',
        'Stop-PlatformOwnedProcess',
        'Resolve-PlatformPowerShell',
        'Assert-PlatformPowerShellRuntime',
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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = 'ba294833dcfaa25b2cc1a938e071a483e122e8548d23fc678d2f689641012084' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = '225a83d8aba1ba5bf11f495eceb4690a221778d8f0d315ccdf6091cc5dc92560' },
                @{ Path = 'platform/WindowsInstallerMutation.cs'; Sha256 = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = 'c55944c9ece57c9ba62b78d1bd563271fc9f660508d3725ab5821d5444cb5fd5' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'ba1965b9a80ec2084aa896e0d3e66b3bcefc83ff09bd50ac783d3e3f7b5727e4' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = '812b6243941208d51713ae8b1b0efae938f8934bfe293af2cd92ded69ada46a0' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293' },
                @{ Path = 'WindowsDacl.psm1'; Sha256 = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = '34caa5fd79612781a6d4eaab51a080edfa5b7a8ad9d9428673a0837e4312efee' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = '1532a2b68dba5a339b713011481be4aaac1911d1732529d88e443d05b447ab81' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = 'adcd69f255d9098a949870daa6f8d871e57ff12bb878802fd325fd29f22d8223' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            )
        }
    }
}
