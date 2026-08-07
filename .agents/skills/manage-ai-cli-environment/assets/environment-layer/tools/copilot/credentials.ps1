Set-StrictMode -Version Latest

function Initialize-AiCliCredentialStoreType {
    [CmdletBinding()]
    param()

    if ('AiCliEnvironment.CredentialStore' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AiCliEnvironment
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NativeCredential
    {
        public UInt32 Flags;
        public UInt32 Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }

    public static class CredentialStore
    {
        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Write(ref NativeCredential credential, UInt32 flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Read(string target, UInt32 type, UInt32 flags, out IntPtr credential);

        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = false)]
        public static extern void Free(IntPtr credential);
    }
}
'@
}

function Get-CopilotCredentialTargetName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('personal', 'company')]
        [string] $Profile
    )

    return "ai-cli/copilot/$Profile"
}

function Set-CopilotCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('personal', 'company')]
        [string] $Profile,

        [Parameter(Mandatory = $true)]
        [string] $Token
    )

    if (-not $IsWindows) {
        throw 'credential_store_unsupported'
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'credential_required'
    }

    Initialize-AiCliCredentialStoreType
    $targetName = Get-CopilotCredentialTargetName -Profile $Profile
    $tokenBytes = [System.Text.Encoding]::Unicode.GetBytes($Token)
    $tokenPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($tokenBytes.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy($tokenBytes, 0, $tokenPointer, $tokenBytes.Length)
        $credential = [AiCliEnvironment.NativeCredential]::new()
        $credential.Type = 1
        $credential.TargetName = $targetName
        $credential.CredentialBlobSize = $tokenBytes.Length
        $credential.CredentialBlob = $tokenPointer
        $credential.Persist = 2
        $credential.UserName = "copilot-$Profile"

        if (-not [AiCliEnvironment.CredentialStore]::Write([ref] $credential, 0)) {
            throw 'credential_store_write_failed'
        }
    }
    finally {
        if ($tokenPointer -ne [IntPtr]::Zero) {
            $zeroBytes = [byte[]]::new($tokenBytes.Length)
            [Runtime.InteropServices.Marshal]::Copy($zeroBytes, 0, $tokenPointer, $zeroBytes.Length)
            [Runtime.InteropServices.Marshal]::FreeHGlobal($tokenPointer)
            [Array]::Clear($zeroBytes, 0, $zeroBytes.Length)
        }
        [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
        $Token = $null
    }
}

function Get-CopilotCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('personal', 'company')]
        [string] $Profile
    )

    if (-not $IsWindows) {
        return $null
    }

    Initialize-AiCliCredentialStoreType
    $credentialPointer = [IntPtr]::Zero
    $targetName = Get-CopilotCredentialTargetName -Profile $Profile
    if (-not [AiCliEnvironment.CredentialStore]::Read($targetName, 1, 0, [ref] $credentialPointer)) {
        if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -eq 1168) {
            return $null
        }
        throw 'credential_store_read_failed'
    }

    try {
        $credential = [Runtime.InteropServices.Marshal]::PtrToStructure(
            $credentialPointer,
            [type] [AiCliEnvironment.NativeCredential]
        )
        if ($credential.CredentialBlobSize -eq 0 -or $credential.CredentialBlob -eq [IntPtr]::Zero) {
            return $null
        }
        return [Runtime.InteropServices.Marshal]::PtrToStringUni(
            $credential.CredentialBlob,
            [int] ($credential.CredentialBlobSize / 2)
        )
    }
    finally {
        if ($credentialPointer -ne [IntPtr]::Zero) {
            [AiCliEnvironment.CredentialStore]::Free($credentialPointer)
        }
    }
}

function Get-CopilotPersonalToken {
    [CmdletBinding()]
    param(
        [scriptblock] $CredentialReader = {
            param($TargetName)
            Get-CopilotCredential -Profile 'personal'
        },

        [scriptblock] $EnvironmentReader = {
            param($Name, $Target)
            [Environment]::GetEnvironmentVariable($Name, $Target)
        }
    )

    $token = & $CredentialReader (Get-CopilotCredentialTargetName -Profile 'personal')
    if (-not [string]::IsNullOrWhiteSpace([string] $token)) {
        return [string] $token
    }

    foreach ($target in @([EnvironmentVariableTarget]::Process, [EnvironmentVariableTarget]::User)) {
        $token = & $EnvironmentReader 'AI_CLI_COPILOT_PERSONAL_TOKEN' $target
        if (-not [string]::IsNullOrWhiteSpace([string] $token)) {
            return [string] $token
        }
    }
    return $null
}
