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
                @{ Path = 'platform/UnixNative.cs'; Sha256 = 'e0fbc58a896ab9a3c297f02e78e571020056854e8eb91aa284ac777fc59ba7a6' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = 'aacffa2c0e5ea4ec9a5936d83d6132a9744aed0b689e43e2c657dae0798dffcf' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = '6199e45d01293d970f33195368cdef0630b1392a4eb00a289ef85c10eda1eef0' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'a3f4e9901437f8df27a9049ca938a451b82028daa006ced6cf6d5aff97f7022b' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'ac1e73ffb1b8ea1b95fdc3a177449442281d3d485f62ec42e464f6f5f38ba359' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = '1985ef1e6e44dd07ce4f7af420506749b7c464ae2701b369f296878972fc5c25' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = '737983e8e126e3c90549b660560cb7204e90b560c5c6dc16b07b447738508b52' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = '85d6343b18c28bc1c1da1f9ccd7f92d5cdc6165c9304a8a413cafdf53a010132' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = '2aa3aad77336740881767737e3a48c208a235145d92dabf457f556c194db97cd' }
            )
        }
    }
}
