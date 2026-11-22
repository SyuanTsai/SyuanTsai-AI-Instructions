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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = '8394fcccc82a841c165d61ec4f8d992ea175ef8e3b9f2de58a5ad808cd97c03a' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = 'e5ad7bf408ceba24a02fe3b74b8cd79c5705052493750e2e0620afb8e034dd8e' },
                @{ Path = 'platform/WindowsInstallerMutation.cs'; Sha256 = '33ab81de28b483e7b6a4f0ac586c29262752b090a54315bb78bfe959488fcf5d' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = '4dea3c5c79eac694ba9defa2906ff7d3fc118f538d3e5bdbb946ed91c57dcb25' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = '94eca51e9b74b388bae1dfcea4ac8e1e874ba05e263f3564817cbbd192716bef' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'af7949af2f2cf144606b5cafbecfa29dd713f6642ebdcfff3a565c92002b5e41' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293' },
                @{ Path = 'WindowsDacl.psm1'; Sha256 = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = '34caa5fd79612781a6d4eaab51a080edfa5b7a8ad9d9428673a0837e4312efee' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = 'bc0aa76c8ac95e3ccafd5198173c01add5e30dbe6e2500c245edc84d3198bb07' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = '9a07e650127ef05a22969169a54af4bcb5eacb084f9dc47ad95e6d22050869af' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'e0ca981a95525f44ac482424b370d0a4982760edd4e706ee7312562daef4ccec' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = '0864e48bc149ffb5f64e43eae39e89b6a9b9e172f5cfa8c636c54815e4470c06' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            )
        }
    }
}
