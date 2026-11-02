# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function Set-UnixPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot)
    if ($null -ne $Snapshot -or $Policy -isnot [System.Collections.IDictionary] -or
        $Policy.Count -ne 1 -or -not $Policy.Contains('Mode')) {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new(
            'permissions-policy: only Mode is supported; ACL/ownership/flags/snapshot are unavailable',
            [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem())
    }
    # Mode is numeric (e.g. 448 = 0700); never silently reinterpret a string as octal.
    if ($Policy.Mode -is [string] -or $Policy.Mode -is [bool] -or $null -eq $Policy.Mode -or
        [decimal]$Policy.Mode -ne [Math]::Truncate([decimal]$Policy.Mode)) {
        throw [ArgumentException]::new('Mode must be an integer from 0 through 4095.')
    }
    [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::SetPermissions($Lease,[uint32]$Policy.Mode)
}

Export-ModuleMember -Function Set-UnixPlatformPermissions
