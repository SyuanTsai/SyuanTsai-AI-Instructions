# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1') -Scope Local -ErrorAction Stop

if ($null -eq ('SyuanTsai.AIInstructions.TrustAnchor.SecretBridge' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace SyuanTsai.AIInstructions.TrustAnchor {
    public static class SecretBridge {
        public static bool FixedTimeEquals(char[] left, char[] right) {
            if (left == null || right == null || left.Length != right.Length) return false;
            int difference = 0;
            for (int i = 0; i < left.Length; i++) difference |= left[i] ^ right[i];
            return difference == 0;
        }
        public static void Zero(char[] value) {
            if (value == null) return;
            CryptographicOperations.ZeroMemory(MemoryMarshal.AsBytes(value.AsSpan()));
        }
        public static string ExportEncryptedPem(RSA rsa, char[] password) {
            PbeParameters pbe = new PbeParameters(PbeEncryptionAlgorithm.Aes256Cbc, HashAlgorithmName.SHA256, 600000);
            return rsa.ExportEncryptedPkcs8PrivateKeyPem(password.AsSpan(), pbe);
        }
        public static void ImportEncryptedPem(RSA rsa, string pem, char[] password) {
            rsa.ImportFromEncryptedPem(pem.AsSpan(), password.AsSpan());
        }
        [DllImport("libc", EntryPoint="geteuid", SetLastError=false)]
        private static extern uint getEuid();
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="geteuid", SetLastError=false)]
        private static extern uint getEuidDarwin();
        public static ulong EffectiveUid() {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) throw new PlatformNotSupportedException();
            return RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? getEuidDarwin() : getEuid();
        }
    }

    public sealed class WindowsAclEvidence {
        public string OwnerSid { get; internal set; }
        public bool DaclPresent { get; internal set; }
        public bool DaclProtected { get; internal set; }
        public string[] AllowSids { get; internal set; }
        public bool HasInheritedAllow { get; internal set; }
    }

    public static class WindowsAclInspector {
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
            public System.Runtime.InteropServices.ComTypes.FILETIME Access; public System.Runtime.InteropServices.ComTypes.FILETIME Write;
            public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow;
        }
        private const int SeFileObject = 1;
        private const uint OwnerSecurityInformation = 0x00000001;
        private const uint DaclSecurityInformation = 0x00000004;
        private const ushort SeDaclProtected = 0x1000;
        [DllImport("advapi32.dll", SetLastError=false, EntryPoint="GetSecurityInfo")]
        private static extern uint GetSecurityInfo(SafeFileHandle handle, int objectType, uint securityInfo,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll", SetLastError=true, EntryPoint="GetSecurityDescriptorControl")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorControl(IntPtr descriptor, out ushort control, out uint revision);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr LocalFree(IntPtr memory);
        [StructLayout(LayoutKind.Sequential)]
        private struct FileDispositionInfo { [MarshalAs(UnmanagedType.Bool)] public bool DeleteFile; }
        [DllImport("kernel32.dll", SetLastError=true, EntryPoint="SetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileDispositionByHandle(SafeFileHandle handle, int informationClass,
            ref FileDispositionInfo information, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CreateFileW")]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);

        public static WindowsAclEvidence Inspect(SafeFileHandle handle) {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(handle, SeFileObject, OwnerSecurityInformation | DaclSecurityInformation,
                out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new Win32Exception((int)error, "GetSecurityInfo failed for the trust-anchor key handle.");
            try {
                ushort control; uint revision;
                if (!GetSecurityDescriptorControl(descriptor, out control, out revision))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetSecurityDescriptorControl failed for the trust-anchor key handle.");
                var allow = new System.Collections.Generic.List<string>();
                bool inherited = false;
                if (dacl != IntPtr.Zero) {
                    int aclSize = (ushort)Marshal.ReadInt16(dacl, 2);
                    if (aclSize < 8) throw new InvalidDataException("The trust-anchor key handle returned an invalid DACL.");
                    byte[] aclBytes = new byte[aclSize];
                    Marshal.Copy(dacl, aclBytes, 0, aclBytes.Length);
                    RawAcl acl = new RawAcl(aclBytes, 0);
                    foreach (GenericAce ace in acl) {
                        KnownAce known = ace as KnownAce;
                        if (known == null) continue;
                        if (ace.AceType == AceType.AccessAllowed || ace.AceType == AceType.AccessAllowedObject ||
                            ace.AceType == AceType.AccessAllowedCallback || ace.AceType == AceType.AccessAllowedCallbackObject) {
                            allow.Add(known.SecurityIdentifier.Value);
                            if ((ace.AceFlags & AceFlags.Inherited) != 0) inherited = true;
                        }
                    }
                }
                return new WindowsAclEvidence {
                    OwnerSid = owner == IntPtr.Zero ? null : new SecurityIdentifier(owner).Value,
                    DaclPresent = dacl != IntPtr.Zero,
                    DaclProtected = (control & SeDaclProtected) != 0,
                    AllowSids = allow.ToArray(), HasInheritedAllow = inherited
                };
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }
        public static void MarkDeleteOnClose(SafeFileHandle handle) {
            FileDispositionInfo information = new FileDispositionInfo { DeleteFile = true };
            uint size = (uint)Marshal.SizeOf(typeof(FileDispositionInfo));
            if (!SetFileDispositionByHandle(handle, 4, ref information, size))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to mark the exact trust-anchor file handle for deletion.");
        }
        public static void DeleteExact(string path, ulong expectedDevice, ulong expectedInode) {
            using (SafeFileHandle handle = CreateFile(path, 0x00010080, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to reopen the trust-anchor rollback target.");
                ByHandleFileInformation value;
                if (!GetFileInformationByHandle(handle, out value)) throw new Win32Exception(Marshal.GetLastWin32Error());
                ulong inode = ((ulong)value.IndexHigh << 32) | value.IndexLow;
                if (value.Volume != expectedDevice || inode != expectedInode || value.Links != 1 ||
                    (value.Attributes & 0x410) != 0) throw new IOException("The trust-anchor rollback target identity changed.");
                MarkDeleteOnClose(handle);
            }
        }
    }
}
'@
}

function New-TrustAnchorError {
    param([string]$Message,[string]$Id)
    $exception=[InvalidOperationException]::new($Message)
    return [Management.Automation.ErrorRecord]::new($exception,$Id,[Management.Automation.ErrorCategory]::SecurityError,$null)
}

function Assert-TrustAnchorInteractiveHost {
    [CmdletBinding()] param()
    foreach($name in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw (New-TrustAnchorError "Trust-anchor key tools cannot run while $name is set." 'TrustAnchor.NonInteractive')
        }
    }
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        throw (New-TrustAnchorError 'Trust-anchor key tools require an interactive host with non-redirected stdin.' 'TrustAnchor.NonInteractive')
    }
}

function Use-TrustAnchorPassword {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $buffer=[IntPtr]::Zero; $characters=$null; $pin=[Runtime.InteropServices.GCHandle]::new()
    try {
        $buffer=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        $characters=[char[]]::new($Password.Length)
        $pin=[Runtime.InteropServices.GCHandle]::Alloc($characters,[Runtime.InteropServices.GCHandleType]::Pinned)
        [Runtime.InteropServices.Marshal]::Copy($buffer,$characters,0,$characters.Length)
        return & $Action $characters
    }
    finally {
        if($buffer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($buffer)}
        if($null -ne $characters){[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($characters)}
        if($pin.IsAllocated){$pin.Free()}
    }
}

function Read-TrustAnchorPassword {
    [CmdletBinding()] param([switch]$Confirm)
    $first=Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString
    try {
        if($first.Length -lt 16){throw (New-TrustAnchorError 'The private-key password must contain at least 16 characters.' 'TrustAnchor.WeakPassword')}
        if($Confirm){
            $second=Read-Host 'Confirm private-key password' -AsSecureString
            try {
                if($second.Length -ne $first.Length){throw (New-TrustAnchorError 'The password confirmation does not match.' 'TrustAnchor.PasswordMismatch')}
                $equal=Use-TrustAnchorPassword $first { param([char[]]$left) Use-TrustAnchorPassword $second { param([char[]]$right) [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::FixedTimeEquals($left,$right) } }
                if(-not $equal){throw (New-TrustAnchorError 'The password confirmation does not match.' 'TrustAnchor.PasswordMismatch')}
            } finally {$second.Dispose()}
        }
        return $first
    } catch {$first.Dispose(); throw}
}

function Export-TrustAnchorEncryptedPrivateKey {
    [CmdletBinding()] param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa,[Parameter(Mandatory)][Security.SecureString]$Password)
    Use-TrustAnchorPassword $Password { param([char[]]$characters) [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::ExportEncryptedPem($Rsa,$characters) }
}

function Import-TrustAnchorEncryptedPrivateKey {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Pem,[Parameter(Mandatory)][Security.SecureString]$Password)
    if($Pem -notmatch '\A-----BEGIN ENCRYPTED PRIVATE KEY-----\r?\n' -or $Pem -notmatch '\r?\n-----END ENCRYPTED PRIVATE KEY-----\s*\z'){
        throw (New-TrustAnchorError 'Only encrypted PKCS#8 PEM input is supported.' 'TrustAnchor.UnsupportedKeyFormat')
    }
    $rsa=[Security.Cryptography.RSA]::Create()
    try { Use-TrustAnchorPassword $Password { param([char[]]$characters) [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::ImportEncryptedPem($rsa,$Pem,$characters) }; return $rsa }
    catch {$rsa.Dispose(); throw}
}

function Get-TrustAnchorPhysicalParent {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $parent=Split-Path -Parent $full
    if([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)){throw "The target parent directory must already exist: $parent"}
    $physical=Resolve-PlatformPhysicalPath -Path $parent
    if([IO.Path]::GetFullPath([string]$physical) -cne [IO.Path]::GetFullPath($parent)){throw 'The target parent must not traverse a symlink, junction, or reparse point.'}
    return [IO.Path]::GetFullPath($parent)
}

function Assert-TrustAnchorOutsideWorktree {
    param([Parameter(Mandatory)][string]$Parent)
    $cursor=$Parent
    while(-not [string]::IsNullOrWhiteSpace($cursor)){
        if([IO.Directory]::Exists((Join-Path $cursor '.git')) -or [IO.File]::Exists((Join-Path $cursor '.git'))){throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'}
        $next=Split-Path -Parent $cursor; if($next -ceq $cursor){break}; $cursor=$next
    }
    $git=@(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)[0]
    if($null -ne $git){
        $root=& $git.Source -C $Parent rev-parse --show-toplevel 2>$null
        if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($root -join ''))){throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'}
    }
}

function Assert-TrustAnchorKeyPath {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][ValidateSet('PrivateKey','PublicOutput')][string]$Purpose)
    $full=[IO.Path]::GetFullPath($Path); $parent=Get-TrustAnchorPhysicalParent $full
    Assert-TrustAnchorOutsideWorktree $parent
    if([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)){throw "The $Purpose target already exists; create-new is required: $full"}
    [pscustomobject][ordered]@{Path=$full;Parent=$parent;Leaf=[IO.Path]::GetFileName($full);Purpose=$Purpose}
}

function Get-TrustAnchorWindowsHandle {
    param($Lease)
    $field=$Lease.GetType().GetField('Handle',[Reflection.BindingFlags]'Instance,NonPublic')
    if($null -eq $field){throw 'The platform lease did not expose its verified SafeFileHandle to the trust-anchor inspector.'}
    return [Microsoft.Win32.SafeHandles.SafeFileHandle]$field.GetValue($Lease)
}

function Assert-TrustAnchorPrivatePermissions {
    param([Parameter(Mandatory)]$Lease)
    if($IsWindows){
        $handle=Get-TrustAnchorWindowsHandle $Lease
        $evidence=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect($handle)
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {$owner=$identity.User.Value} finally {$identity.Dispose()}
        $allowed=@($owner,'S-1-5-18','S-1-5-32-544')
        if($evidence.OwnerSid -cne $owner -or -not $evidence.DaclPresent -or -not $evidence.DaclProtected -or $evidence.HasInheritedAllow -or @($evidence.AllowSids|Where-Object{$_ -cnotin $allowed}).Count -gt 0){throw 'The private-key handle owner or protected DACL is not sufficiently restrictive.'}
        return $evidence
    }
    $permissions=Get-PlatformPermissions -Lease $Lease
    if([string]$permissions.mode -cne '600' -or [uint64]$permissions.uid -ne [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::EffectiveUid()){throw 'The private-key handle must be owned by the effective user with mode 0600.'}
    return $permissions
}

function New-TrustAnchorKeyFile {
    [CmdletBinding()] param([Parameter(Mandatory)]$PathEvidence,[Parameter(Mandatory)][byte[]]$Bytes)
    $parent=$null;$file=$null
    try {
        $parent=Open-PlatformDirectory -Root $PathEvidence.Parent -RootOnly
        $file=Open-PlatformFile -ParentLease $parent -Leaf $PathEvidence.Leaf -Access ReadWrite -CreateMode CreateNew
        $expected=$file.Observation
        if($PathEvidence.Purpose -ceq 'PrivateKey'){
            if($IsWindows){
                $identity=[Security.Principal.WindowsIdentity]::GetCurrent(); try{$sid=$identity.User.Value}finally{$identity.Dispose()}
                Set-PlatformPermissions -Lease $file -Policy @{Sddl="D:P(A;;FA;;;$sid)";ReadOnly=$false}|Out-Null
            } else {Set-PlatformPermissions -Lease $file -Policy @{Mode=384}|Out-Null}
            Assert-TrustAnchorPrivatePermissions $file|Out-Null
        }
        $file.WriteNewBytes($Bytes)
        Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        if($PathEvidence.Purpose -ceq 'PrivateKey'){Assert-TrustAnchorPrivatePermissions $file|Out-Null}
        return [pscustomobject]@{Path=$PathEvidence.Path;ParentLease=$parent;FileLease=$file;Expected=$expected;Purpose=$PathEvidence.Purpose}
    } catch {if($null-ne$file){$file.Dispose()};if($null-ne$parent){$parent.Dispose()};throw}
}

function Remove-TrustAnchorCreatedFile {
    param([Parameter(Mandatory)]$Lease)
    try {
        Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath|Out-Null
        if($IsWindows){
            $Lease.FileLease.Dispose()
            [SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::DeleteExact($Lease.Path,[uint64]$Lease.Expected.Device,[uint64]$Lease.Expected.Inode)
        } else {[IO.File]::Delete($Lease.Path)}
    }
    finally {$Lease.FileLease.Dispose();$Lease.ParentLease.Dispose()}
}
function Close-TrustAnchorCreatedFile {param($Lease) if($null-ne$Lease){$Lease.FileLease.Dispose();$Lease.ParentLease.Dispose()}}

function Open-TrustAnchorPrivateKey {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$parentPath=Get-TrustAnchorPhysicalParent $full;Assert-TrustAnchorOutsideWorktree $parentPath
    $parent=$null;$file=$null
    try{
        $parent=Open-PlatformDirectory -Root $parentPath -RootOnly
        $file=Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access Read -CreateMode OpenExisting
        $expected=$file.Observation
        Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        Assert-TrustAnchorPrivatePermissions $file|Out-Null
        $bytes=$file.ReadAllBytes(1048576)
        Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        Assert-TrustAnchorPrivatePermissions $file|Out-Null
        return $bytes
    } finally {if($null-ne$file){$file.Dispose()};if($null-ne$parent){$parent.Dispose()}}
}

function ConvertTo-TrustAnchorCanonicalXml {
    [CmdletBinding()] param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)
    $parameters=$Rsa.ExportParameters($false)
    $text='<RSAKeyValue><Modulus>'+[Convert]::ToBase64String($parameters.Modulus)+'</Modulus><Exponent>'+[Convert]::ToBase64String($parameters.Exponent)+'</Exponent></RSAKeyValue>'+"`n"
    return [Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Assert-TrustAnchorPublicKey {
    [CmdletBinding()] param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa,[int]$MinimumBits=3072)
    $parameters=$Rsa.ExportParameters($false)
    $exponent=[System.Numerics.BigInteger]::new($parameters.Exponent,$true,$true)
    if($Rsa.KeySize -lt $MinimumBits -or $exponent -ne 65537){throw "The trust-anchor public key must be at least $MinimumBits bits with exponent 65537."}
}

function Get-TrustAnchorFingerprint {
    [CmdletBinding()] param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)
    $xml=ConvertTo-TrustAnchorCanonicalXml $Rsa;$spki=$Rsa.ExportSubjectPublicKeyInfo()
    try{[pscustomobject][ordered]@{xmlSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($xml)).ToLowerInvariant();spkiSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($spki)).ToLowerInvariant()}}
    finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($spki)}
}

function Import-TrustAnchorPublicXml {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    if($text -match '<(D|P|Q|DP|DQ|InverseQ)>' -or $text -notmatch '\A<RSAKeyValue><Modulus>([^<]+)</Modulus><Exponent>([^<]+)</Exponent></RSAKeyValue>\r?\n?\z'){throw 'The XML input is not a public RSAKeyValue document.'}
    $rsa=[Security.Cryptography.RSA]::Create()
    try{$rsa.ImportParameters([Security.Cryptography.RSAParameters]@{Modulus=[Convert]::FromBase64String($Matches[1]);Exponent=[Convert]::FromBase64String($Matches[2])});return $rsa}catch{$rsa.Dispose();throw}
}

Export-ModuleMember -Function Assert-TrustAnchorInteractiveHost,Read-TrustAnchorPassword,Use-TrustAnchorPassword,Export-TrustAnchorEncryptedPrivateKey,Import-TrustAnchorEncryptedPrivateKey,Assert-TrustAnchorKeyPath,New-TrustAnchorKeyFile,Open-TrustAnchorPrivateKey,ConvertTo-TrustAnchorCanonicalXml,Get-TrustAnchorFingerprint,Assert-TrustAnchorPublicKey
