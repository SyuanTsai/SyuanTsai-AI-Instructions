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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = 'a21212b9b6e8c0b7631b234b9f65068a3d6b06612dca21e06ccd87ea5fcb4cee' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = '7fd555e8a80cb16d762940cf593e757d91332df794a2731b5577517da5881047' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = '6199e45d01293d970f33195368cdef0630b1392a4eb00a289ef85c10eda1eef0' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'a916fceea0f178a2bb19aefb9c5db3817c453bd7b2835eef9dd0e171329d9a2b' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'def85d485fd202138eaf261c245678fe699fc0b6dc4459a64eafdbfc70473da1' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'ac1e73ffb1b8ea1b95fdc3a177449442281d3d485f62ec42e464f6f5f38ba359' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = '906dbdaf00098be8dc8a4e5f3666f774f5096340872eaf2df4ee2fe45ca8fe3f' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = 'd6b84b3d3df4b799811d82bf5963c72320a61608fdebd32871bccc7d73b40289' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = '75554397511f4727d361f784c59222130f3e282acf84a19aec81b651e6c67674' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = '4beb55532b18673e8fe1732effdd9354a38bb3f828b2c224ecf3c1d0e21abe76' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'fbbc258b12ed24f257bc068399b76f9e58de4a02bd9d12301c01842a77c960c1' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = 'c49a4a651281983f014f739a256560019894edf45a2483788ab7c4e8eee81ffe' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = 'ec6df237dcb79a60aecf9e76c9f1c1abd0b9a5319ebf8bb7899c8d5fee2062b7' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = 'd647029894a37e0599e7b053da8265bb4e04cbfa4a8148efbbb33d5cede8e6f0' }
            )
        }
    }
}
