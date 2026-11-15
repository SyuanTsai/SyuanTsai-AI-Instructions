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
using System.Formats.Asn1;
using System.Numerics;
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
        public static void ValidateEncryptedPemProfile(string pem) {
            int start = pem.IndexOf("-----BEGIN ENCRYPTED PRIVATE KEY-----", StringComparison.Ordinal);
            int end = pem.IndexOf("-----END ENCRYPTED PRIVATE KEY-----", StringComparison.Ordinal);
            if (start != 0 || end < 0) throw new CryptographicException("Encrypted PKCS#8 PEM framing is invalid.");
            int bodyStart = pem.IndexOf('\n', start);
            if (bodyStart < 0) throw new CryptographicException("Encrypted PKCS#8 PEM framing is invalid.");
            string base64 = pem.Substring(bodyStart + 1, end - bodyStart - 1).Replace("\r", "").Replace("\n", "");
            byte[] der = Convert.FromBase64String(base64);
            try {
                var outerReader = new AsnReader(der, AsnEncodingRules.DER);
                var encryptedPrivateKeyInfo = outerReader.ReadSequence();
                var algorithm = encryptedPrivateKeyInfo.ReadSequence();
                if (algorithm.ReadObjectIdentifier() != "1.2.840.113549.1.5.13") throw new CryptographicException("PBES2 is required.");
                var pbes2 = algorithm.ReadSequence();
                algorithm.ThrowIfNotEmpty();

                var kdf = pbes2.ReadSequence();
                if (kdf.ReadObjectIdentifier() != "1.2.840.113549.1.5.12") throw new CryptographicException("PBKDF2 is required.");
                var pbkdf2 = kdf.ReadSequence();
                kdf.ThrowIfNotEmpty();
                byte[] salt = pbkdf2.ReadOctetString();
                try { if (salt.Length == 0) throw new CryptographicException("PBKDF2 salt is required."); }
                finally { CryptographicOperations.ZeroMemory(salt); }
                BigInteger iterations = pbkdf2.ReadInteger();
                if (iterations != 600000) throw new CryptographicException("PBKDF2 iteration count is unsupported.");
                if (pbkdf2.HasData && pbkdf2.PeekTag().HasSameClassAndValue(Asn1Tag.Integer)) {
                    if (pbkdf2.ReadInteger() != 32) throw new CryptographicException("PBKDF2 key length is unsupported.");
                }
                if (!pbkdf2.HasData) throw new CryptographicException("PBKDF2 HMAC-SHA256 PRF must be explicit.");
                var prf = pbkdf2.ReadSequence();
                if (prf.ReadObjectIdentifier() != "1.2.840.113549.2.9") throw new CryptographicException("PBKDF2 HMAC-SHA256 is required.");
                if (prf.HasData) prf.ReadNull();
                prf.ThrowIfNotEmpty(); pbkdf2.ThrowIfNotEmpty();

                var encryption = pbes2.ReadSequence();
                if (encryption.ReadObjectIdentifier() != "2.16.840.1.101.3.4.1.42") throw new CryptographicException("AES-256-CBC is required.");
                byte[] iv = encryption.ReadOctetString();
                try { if (iv.Length != 16) throw new CryptographicException("AES-256-CBC requires a 16-byte IV."); }
                finally { CryptographicOperations.ZeroMemory(iv); }
                encryption.ThrowIfNotEmpty(); pbes2.ThrowIfNotEmpty();
                byte[] encrypted = encryptedPrivateKeyInfo.ReadOctetString();
                try { if (encrypted.Length == 0) throw new CryptographicException("Encrypted PKCS#8 payload is empty."); }
                finally { CryptographicOperations.ZeroMemory(encrypted); }
                encryptedPrivateKeyInfo.ThrowIfNotEmpty(); outerReader.ThrowIfNotEmpty();
            }
            finally { CryptographicOperations.ZeroMemory(der); }
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
        public string DaclHex { get; internal set; }
    }

    public sealed class NativeMetadataEvidence {
        public ulong Device { get; internal set; }
        public ulong Inode { get; internal set; }
        public ulong LinkCount { get; internal set; }
        public uint Mode { get; internal set; }
        public uint Uid { get; internal set; }
        public uint Gid { get; internal set; }
        public long Size { get; internal set; }
        public long ModifiedSeconds { get; internal set; }
        public long ModifiedNanoseconds { get; internal set; }
        public long ChangedSeconds { get; internal set; }
        public long ChangedNanoseconds { get; internal set; }
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
        [StructLayout(LayoutKind.Sequential)]
        private struct FileBasicInformation { public long Creation, Access, Write, Change; public uint Attributes; }
        [DllImport("kernel32.dll", SetLastError=true, EntryPoint="GetFileInformationByHandleEx")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileBasicInformation(SafeFileHandle handle, int informationClass,
            out FileBasicInformation information, uint size);

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
                byte[] aclBytes = null;
                if (dacl != IntPtr.Zero) {
                    int aclSize = (ushort)Marshal.ReadInt16(dacl, 2);
                    if (aclSize < 8) throw new InvalidDataException("The trust-anchor key handle returned an invalid DACL.");
                    aclBytes = new byte[aclSize];
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
                    AllowSids = allow.ToArray(), HasInheritedAllow = inherited,
                    DaclHex = dacl == IntPtr.Zero ? null : Convert.ToHexString(aclBytes)
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
        public static NativeMetadataEvidence InspectMetadata(SafeFileHandle handle) {
            ByHandleFileInformation value;
            if (!GetFileInformationByHandle(handle, out value)) throw new Win32Exception(Marshal.GetLastWin32Error());
            FileBasicInformation basic;
            uint size = (uint)Marshal.SizeOf(typeof(FileBasicInformation));
            if (!GetFileBasicInformation(handle, 0, out basic, size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return new NativeMetadataEvidence {
                Device = value.Volume, Inode = ((ulong)value.IndexHigh << 32) | value.IndexLow,
                LinkCount = value.Links, Mode = value.Attributes, Size = ((long)value.SizeHigh << 32) | value.SizeLow,
                ModifiedSeconds = basic.Write, ChangedSeconds = basic.Change
            };
        }
    }

    public static class UnixMetadataInspector {
        [StructLayout(LayoutKind.Explicit, Size=144)]
        public struct LinuxX64Stat {
            [FieldOffset(0)] public ulong Dev; [FieldOffset(8)] public ulong Ino; [FieldOffset(16)] public ulong Links;
            [FieldOffset(24)] public uint Mode; [FieldOffset(28)] public uint Uid; [FieldOffset(32)] public uint Gid;
            [FieldOffset(48)] public long Size; [FieldOffset(88)] public long MTime; [FieldOffset(96)] public long MTimeNs;
            [FieldOffset(104)] public long CTime; [FieldOffset(112)] public long CTimeNs;
        }
        [StructLayout(LayoutKind.Explicit, Size=128)]
        public struct LinuxArm64Stat {
            [FieldOffset(0)] public ulong Dev; [FieldOffset(8)] public ulong Ino; [FieldOffset(16)] public uint Mode;
            [FieldOffset(20)] public uint Links; [FieldOffset(24)] public uint Uid; [FieldOffset(28)] public uint Gid;
            [FieldOffset(48)] public long Size; [FieldOffset(88)] public long MTime; [FieldOffset(96)] public long MTimeNs;
            [FieldOffset(104)] public long CTime; [FieldOffset(112)] public long CTimeNs;
        }
        [StructLayout(LayoutKind.Explicit, Size=144)]
        public struct DarwinStat {
            [FieldOffset(0)] public uint Dev; [FieldOffset(4)] public ushort Mode; [FieldOffset(6)] public ushort Links;
            [FieldOffset(8)] public ulong Ino; [FieldOffset(16)] public uint Uid; [FieldOffset(20)] public uint Gid;
            [FieldOffset(48)] public long MTime; [FieldOffset(56)] public long MTimeNs;
            [FieldOffset(64)] public long CTime; [FieldOffset(72)] public long CTimeNs; [FieldOffset(96)] public long Size;
        }
        [DllImport("libc", EntryPoint="fstat", SetLastError=true)] private static extern int fstatLinux(IntPtr fd, IntPtr value);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fstat$INODE64", SetLastError=true)] private static extern int fstatDarwinX64(IntPtr fd, IntPtr value);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fstat", SetLastError=true)] private static extern int fstatDarwin(IntPtr fd, IntPtr value);
        public static NativeMetadataEvidence Inspect(SafeHandle handle) {
            IntPtr buffer = Marshal.AllocHGlobal(512);
            try {
                for (int i=0; i<512; i+=8) Marshal.WriteInt64(buffer,i,0);
                bool mac = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
                int result = mac ? (RuntimeInformation.ProcessArchitecture == Architecture.X64 ? fstatDarwinX64(handle.DangerousGetHandle(),buffer) : fstatDarwin(handle.DangerousGetHandle(),buffer)) : fstatLinux(handle.DangerousGetHandle(),buffer);
                if (result != 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "fstat failed for the trust-anchor key handle.");
                if (mac) {
                    var s=(DarwinStat)Marshal.PtrToStructure(buffer,typeof(DarwinStat));
                    return new NativeMetadataEvidence {Device=s.Dev,Inode=s.Ino,LinkCount=s.Links,Mode=s.Mode,Uid=s.Uid,Gid=s.Gid,Size=s.Size,ModifiedSeconds=s.MTime,ModifiedNanoseconds=s.MTimeNs,ChangedSeconds=s.CTime,ChangedNanoseconds=s.CTimeNs};
                }
                if (RuntimeInformation.ProcessArchitecture == Architecture.X64) {
                    var s=(LinuxX64Stat)Marshal.PtrToStructure(buffer,typeof(LinuxX64Stat));
                    return new NativeMetadataEvidence {Device=s.Dev,Inode=s.Ino,LinkCount=s.Links,Mode=s.Mode,Uid=s.Uid,Gid=s.Gid,Size=s.Size,ModifiedSeconds=s.MTime,ModifiedNanoseconds=s.MTimeNs,ChangedSeconds=s.CTime,ChangedNanoseconds=s.CTimeNs};
                }
                var a=(LinuxArm64Stat)Marshal.PtrToStructure(buffer,typeof(LinuxArm64Stat));
                return new NativeMetadataEvidence {Device=a.Dev,Inode=a.Ino,LinkCount=a.Links,Mode=a.Mode,Uid=a.Uid,Gid=a.Gid,Size=a.Size,ModifiedSeconds=a.MTime,ModifiedNanoseconds=a.MTimeNs,ChangedSeconds=a.CTime,ChangedNanoseconds=a.CTimeNs};
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    public static class UnixExactRemover {
        [DllImport("libc", EntryPoint="fstatat", SetLastError=true)] private static extern int fstatatLinux(IntPtr fd,string leaf,IntPtr value,int flags);
        [DllImport("libc", EntryPoint="renameat2", SetLastError=true)] private static extern int renameat2(IntPtr oldFd,string oldLeaf,IntPtr newFd,string newLeaf,uint flags);
        [DllImport("libc", EntryPoint="unlinkat", SetLastError=true)] private static extern int unlinkatLinux(IntPtr fd,string leaf,int flags);
        [DllImport("libc", EntryPoint="fsync", SetLastError=true)] private static extern int fsyncLinux(IntPtr fd);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fstatat$INODE64", SetLastError=true)] private static extern int fstatatDarwinX64(IntPtr fd,string leaf,IntPtr value,int flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fstatat", SetLastError=true)] private static extern int fstatatDarwin(IntPtr fd,string leaf,IntPtr value,int flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="renameatx_np", SetLastError=true)] private static extern int renameatx(IntPtr oldFd,string oldLeaf,IntPtr newFd,string newLeaf,uint flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="unlinkat", SetLastError=true)] private static extern int unlinkatDarwin(IntPtr fd,string leaf,int flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fsync", SetLastError=true)] private static extern int fsyncDarwin(IntPtr fd);
        private static NativeMetadataEvidence Stat(SafeHandle parent,string leaf) {
            IntPtr buffer=Marshal.AllocHGlobal(512);
            try {
                for(int i=0;i<512;i+=8)Marshal.WriteInt64(buffer,i,0);
                bool mac=RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
                int result=mac?(RuntimeInformation.ProcessArchitecture==Architecture.X64?fstatatDarwinX64(parent.DangerousGetHandle(),leaf,buffer,0x20):fstatatDarwin(parent.DangerousGetHandle(),leaf,buffer,0x20)):fstatatLinux(parent.DangerousGetHandle(),leaf,buffer,0x100);
                if(result!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"fstatat failed for the trust-anchor rollback target.");
                if(mac){var s=(UnixMetadataInspector.DarwinStat)Marshal.PtrToStructure(buffer,typeof(UnixMetadataInspector.DarwinStat));return new NativeMetadataEvidence{Device=s.Dev,Inode=s.Ino,LinkCount=s.Links,Mode=s.Mode,Uid=s.Uid,Size=s.Size};}
                if(RuntimeInformation.ProcessArchitecture==Architecture.X64){var s=(UnixMetadataInspector.LinuxX64Stat)Marshal.PtrToStructure(buffer,typeof(UnixMetadataInspector.LinuxX64Stat));return new NativeMetadataEvidence{Device=s.Dev,Inode=s.Ino,LinkCount=s.Links,Mode=s.Mode,Uid=s.Uid,Size=s.Size};}
                var a=(UnixMetadataInspector.LinuxArm64Stat)Marshal.PtrToStructure(buffer,typeof(UnixMetadataInspector.LinuxArm64Stat));return new NativeMetadataEvidence{Device=a.Dev,Inode=a.Ino,LinkCount=a.Links,Mode=a.Mode,Uid=a.Uid,Size=a.Size};
            } finally {Marshal.FreeHGlobal(buffer);}
        }
        private static void Same(NativeMetadataEvidence value,ulong device,ulong inode){if(value.Device!=device||value.Inode!=inode||value.LinkCount!=1||(value.Mode&0xF000)!=0x8000)throw new IOException("The trust-anchor rollback target identity changed.");}
        public static void Remove(SafeHandle parent,string leaf,ulong device,ulong inode){
            NativeMetadataEvidence before=Stat(parent,leaf);Same(before,device,inode);
            string tombstone=".trust-anchor-rollback-"+Guid.NewGuid().ToString("N"); bool mac=RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
            int renamed=mac?renameatx(parent.DangerousGetHandle(),leaf,parent.DangerousGetHandle(),tombstone,0x4):renameat2(parent.DangerousGetHandle(),leaf,parent.DangerousGetHandle(),tombstone,1);
            if(renamed!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to atomically bind the trust-anchor rollback target.");
            NativeMetadataEvidence moved=Stat(parent,tombstone);
            if(moved.Device!=device||moved.Inode!=inode){
                int restored=mac?renameatx(parent.DangerousGetHandle(),tombstone,parent.DangerousGetHandle(),leaf,0x4):renameat2(parent.DangerousGetHandle(),tombstone,parent.DangerousGetHandle(),leaf,1);
                if(restored!=0)throw new IOException("Rollback target identity changed and the displaced entry could not be restored.");
                throw new IOException("The trust-anchor rollback target identity changed.");
            }
            int unlinked=mac?unlinkatDarwin(parent.DangerousGetHandle(),tombstone,0):unlinkatLinux(parent.DangerousGetHandle(),tombstone,0);
            if(unlinked!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to remove the exact trust-anchor rollback target.");
            int synced=mac?fsyncDarwin(parent.DangerousGetHandle()):fsyncLinux(parent.DangerousGetHandle());
            if(synced!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to confirm trust-anchor rollback directory durability.");
        }
    }
}
'@
}

$script:TrustAnchorOpenBeforePermissionTestHook = $null
$script:TrustAnchorAfterReadTestHook = $null
$script:TrustAnchorBeforePublicWriteTestHook = $null
$script:TrustAnchorBeforeRollbackRemovalTestHook = $null

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
    try {[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::ValidateEncryptedPemProfile($Pem)}
    catch {throw (New-TrustAnchorError 'The encrypted PKCS#8 input does not use PBES2 with PBKDF2-HMAC-SHA256, AES-256-CBC, and 600000 iterations.' 'TrustAnchor.UnsupportedKeyFormat')}
    $rsa=[Security.Cryptography.RSA]::Create()
    try { Use-TrustAnchorPassword $Password { param([char[]]$characters) [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::ImportEncryptedPem($rsa,$Pem,$characters) }; return $rsa }
    catch {$rsa.Dispose(); throw}
}

function Get-TrustAnchorPhysicalParent {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$parent=Split-Path -Parent $full
    if([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)){throw "The target parent directory must already exist: $parent"}
    $physical=Resolve-PlatformPhysicalPath -Path $parent
    if([IO.Path]::GetFullPath([string]$physical) -cne [IO.Path]::GetFullPath($parent)){throw 'The target parent must not traverse a symlink, junction, or reparse point.'}
    return [IO.Path]::GetFullPath($parent)
}

function Assert-TrustAnchorOutsideWorktree {
    param([Parameter(Mandatory)]$PathEvidence)
    Assert-PlatformFileIdentity -Lease $PathEvidence.ParentLease -Expected $PathEvidence.ParentExpected -VerifyPath|Out-Null
    $cursor=$PathEvidence.Parent
    while(-not [string]::IsNullOrWhiteSpace($cursor)){
        if([IO.Directory]::Exists((Join-Path $cursor '.git')) -or [IO.File]::Exists((Join-Path $cursor '.git'))){throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'}
        $next=Split-Path -Parent $cursor;if($next -ceq $cursor){break};$cursor=$next
    }
    $git=@(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)[0]
    if($null-ne$git){$root=& $git.Source -C $PathEvidence.Parent rev-parse --show-toplevel 2>$null;if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($root -join ''))){throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'}}
    Assert-PlatformFileIdentity -Lease $PathEvidence.ParentLease -Expected $PathEvidence.ParentExpected -VerifyPath|Out-Null
}

function New-TrustAnchorPathEvidence {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][ValidateSet('PrivateKey','PublicOutput')][string]$Purpose,[switch]$Existing)
    $full=[IO.Path]::GetFullPath($Path);$parentPath=Get-TrustAnchorPhysicalParent $full;$parentLease=$null
    try{
        $parentLease=Open-PlatformDirectory -Root $parentPath -RootOnly
        $evidence=[pscustomobject][ordered]@{Path=$full;Parent=$parentPath;Leaf=[IO.Path]::GetFileName($full);Purpose=$Purpose;ParentLease=$parentLease;ParentExpected=$parentLease.Observation}
        Assert-TrustAnchorOutsideWorktree $evidence
        if(-not$Existing -and ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full))){throw "The $Purpose target already exists; create-new is required: $full"}
        Assert-PlatformFileIdentity -Lease $parentLease -Expected $evidence.ParentExpected -VerifyPath|Out-Null
        return $evidence
    }catch{if($null-ne$parentLease){$parentLease.Dispose()};throw}
}

function Assert-TrustAnchorKeyPath {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][ValidateSet('PrivateKey','PublicOutput')][string]$Purpose)
    New-TrustAnchorPathEvidence -Path $Path -Purpose $Purpose
}
function Close-TrustAnchorPathEvidence {param($PathEvidence)if($null-ne$PathEvidence -and $null-ne$PathEvidence.ParentLease){$PathEvidence.ParentLease.Dispose()}}

function Get-TrustAnchorLeaseHandle {
    param($Lease)
    $field=$Lease.GetType().GetField($(if($IsWindows){'Handle'}else{'Fd'}),[Reflection.BindingFlags]'Instance,NonPublic')
    if($null-eq$field){throw 'The platform lease did not expose its verified native handle to the trust-anchor inspector.'}
    return [Runtime.InteropServices.SafeHandle]$field.GetValue($Lease)
}

function Get-TrustAnchorMetadataEvidence {
    param([Parameter(Mandatory)]$Lease)
    $handle=Get-TrustAnchorLeaseHandle $Lease
    if($IsWindows){
        $native=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::InspectMetadata([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle)
        $acl=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle)
        return [pscustomobject][ordered]@{device=[uint64]$native.Device;inode=[uint64]$native.Inode;links=[uint64]$native.LinkCount;mode=[uint32]$native.Mode;uid=[uint64]0;gid=[uint64]0;size=[int64]$native.Size;mtime=[int64]$native.ModifiedSeconds;mtimeNs=[int64]0;ctime=[int64]$native.ChangedSeconds;ctimeNs=[int64]0;owner=[string]$acl.OwnerSid;dacl=[string]$acl.DaclHex;protected=[bool]$acl.DaclProtected;inheritedAllow=[bool]$acl.HasInheritedAllow;allowSids=[string[]]$acl.AllowSids}
    }
    $native=[SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector]::Inspect($handle)
    [pscustomobject][ordered]@{device=[uint64]$native.Device;inode=[uint64]$native.Inode;links=[uint64]$native.LinkCount;mode=[uint32]$native.Mode;uid=[uint64]$native.Uid;gid=[uint64]$native.Gid;size=[int64]$native.Size;mtime=[int64]$native.ModifiedSeconds;mtimeNs=[int64]$native.ModifiedNanoseconds;ctime=[int64]$native.ChangedSeconds;ctimeNs=[int64]$native.ChangedNanoseconds;owner=$null;dacl=$null;protected=$null;inheritedAllow=$null;allowSids=$null}
}
function Test-TrustAnchorMetadataEqual {param($Before,$After)(($Before|ConvertTo-Json -Compress -Depth 5) -ceq ($After|ConvertTo-Json -Compress -Depth 5))}

function Assert-TrustAnchorPrivatePermissions {
    param([Parameter(Mandatory)]$Lease,$Evidence)
    if($null-eq$Evidence){$Evidence=Get-TrustAnchorMetadataEvidence $Lease}
    if($IsWindows){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$owner=$identity.User.Value}finally{$identity.Dispose()}
        $allowed=@($owner,'S-1-5-18','S-1-5-32-544')
        if($Evidence.owner -cne $owner -or [string]::IsNullOrEmpty([string]$Evidence.dacl) -or -not$Evidence.protected -or $Evidence.inheritedAllow -or @($Evidence.allowSids|Where-Object{$_ -cnotin $allowed}).Count -gt 0){throw 'The private-key handle owner or protected DACL is not sufficiently restrictive.'}
        return $Evidence
    }
    if(([uint32]$Evidence.mode -band 63) -ne 0 -or [uint64]$Evidence.uid -ne [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::EffectiveUid()){throw 'The private-key handle must be owned by the effective user and deny every group/other permission.'}
    return $Evidence
}

function New-TrustAnchorKeyFile {
    [CmdletBinding()] param([Parameter(Mandatory)]$PathEvidence,[Parameter(Mandatory)][byte[]]$Bytes)
    $parent=$PathEvidence.ParentLease;$file=$null
    try{
        Assert-PlatformFileIdentity -Lease $parent -Expected $PathEvidence.ParentExpected -VerifyPath|Out-Null
        $file=Open-PlatformFile -ParentLease $parent -Leaf $PathEvidence.Leaf -Access ReadWrite -CreateMode CreateNew;$expected=$file.Observation
        if($PathEvidence.Purpose -ceq 'PrivateKey'){
            if($IsWindows){$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()};Set-PlatformPermissions -Lease $file -Policy @{Sddl="D:P(A;;FA;;;$sid)";ReadOnly=$false}|Out-Null}else{Set-PlatformPermissions -Lease $file -Policy @{Mode=384}|Out-Null}
            Assert-TrustAnchorPrivatePermissions $file|Out-Null
        }
        $file.WriteNewBytes($Bytes);Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        if($PathEvidence.Purpose -ceq 'PrivateKey'){Assert-TrustAnchorPrivatePermissions $file|Out-Null}
        Assert-PlatformFileIdentity -Lease $parent -Expected $PathEvidence.ParentExpected -VerifyPath|Out-Null
        return [pscustomobject]@{Path=$PathEvidence.Path;Leaf=$PathEvidence.Leaf;ParentLease=$parent;FileLease=$file;Expected=$expected;Purpose=$PathEvidence.Purpose;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant();Length=[int64]$Bytes.Length}
    }catch{if($null-ne$file){$file.Dispose()};throw}
}

function Remove-TrustAnchorCreatedFile {
    param([Parameter(Mandatory)]$Lease)
    try{
        Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath|Out-Null
        if($IsWindows){
            $Lease.FileLease.Dispose()
            if($null-ne$script:TrustAnchorBeforeRollbackRemovalTestHook){& $script:TrustAnchorBeforeRollbackRemovalTestHook $Lease}
            [SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::DeleteExact($Lease.Path,[uint64]$Lease.Expected.Device,[uint64]$Lease.Expected.Inode)
        }else{
            if($null-ne$script:TrustAnchorBeforeRollbackRemovalTestHook){& $script:TrustAnchorBeforeRollbackRemovalTestHook $Lease}
            Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath|Out-Null
            [SyuanTsai.AIInstructions.TrustAnchor.UnixExactRemover]::Remove((Get-TrustAnchorLeaseHandle $Lease.ParentLease),$Lease.Leaf,[uint64]$Lease.Expected.Device,[uint64]$Lease.Expected.Inode)
        }
    }finally{$Lease.FileLease.Dispose();$Lease.ParentLease.Dispose()}
}
function Close-TrustAnchorCreatedFile {param($Lease)if($null-ne$Lease){$Lease.FileLease.Dispose();$Lease.ParentLease.Dispose()}}

function Open-TrustAnchorPrivateKey {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $pathEvidence=$null;$file=$null
    try{
        $pathEvidence=New-TrustAnchorPathEvidence -Path $Path -Purpose PrivateKey -Existing
        $file=Open-PlatformFile -ParentLease $pathEvidence.ParentLease -Leaf $pathEvidence.Leaf -Access Read -CreateMode OpenExisting;$expected=$file.Observation
        Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        if($null-ne$script:TrustAnchorOpenBeforePermissionTestHook){& $script:TrustAnchorOpenBeforePermissionTestHook $Path $file}
        $before=Get-TrustAnchorMetadataEvidence $file;Assert-TrustAnchorPrivatePermissions $file $before|Out-Null
        $bytes=$file.ReadAllBytes(1048576)
        if($null-ne$script:TrustAnchorAfterReadTestHook){& $script:TrustAnchorAfterReadTestHook $Path $file}
        Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        $after=Get-TrustAnchorMetadataEvidence $file;Assert-TrustAnchorPrivatePermissions $file $after|Out-Null
        if(-not(Test-TrustAnchorMetadataEqual $before $after)){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes);throw 'The private-key handle metadata changed while it was being read.'}
        return ,$bytes
    }finally{if($null-ne$file){$file.Dispose()};Close-TrustAnchorPathEvidence $pathEvidence}
}

function ConvertTo-TrustAnchorCanonicalXml {
    [CmdletBinding()] param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)
    $parameters=$Rsa.ExportParameters($false)
    $text='<RSAKeyValue><Modulus>'+[Convert]::ToBase64String($parameters.Modulus)+'</Modulus><Exponent>'+[Convert]::ToBase64String($parameters.Exponent)+'</Exponent></RSAKeyValue>'+"`n"
    return ,([Text.UTF8Encoding]::new($false).GetBytes($text))
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

function Import-TrustAnchorPublicPem {
    param([Parameter(Mandatory)][string]$Pem)
    if($Pem -notmatch '\A-----BEGIN PUBLIC KEY-----\r?\n' -or $Pem -notmatch '\r?\n-----END PUBLIC KEY-----\s*\z' -or $Pem -match 'PRIVATE KEY'){throw (New-TrustAnchorError 'Only a PUBLIC KEY PEM without private-key content is supported.' 'TrustAnchor.UnsupportedKeyFormat')}
    $rsa=[Security.Cryptography.RSA]::Create()
    try{$rsa.ImportFromPem($Pem);return $rsa}catch{$rsa.Dispose();throw}
}

function Invoke-NewTrustAnchorKeyPairAction {
    param([Parameter(Mandatory)][ValidateSet('humanApproval','supervisor')][string]$KeyId,[Parameter(Mandatory)][string]$PrivateKeyPath,[Parameter(Mandatory)][string]$PublicKeyXmlPath)
    Assert-TrustAnchorInteractiveHost
    $privateTarget=$null;$publicTarget=$null;$password=$null;$rsa=$null;$privateBytes=$null;$privateLease=$null;$publicLease=$null
    try{
        $privateTarget=Assert-TrustAnchorKeyPath -Path $PrivateKeyPath -Purpose PrivateKey
        $publicTarget=Assert-TrustAnchorKeyPath -Path $PublicKeyXmlPath -Purpose PublicOutput
        $password=Read-TrustAnchorPassword -Confirm
        $rsa=[Security.Cryptography.RSA]::Create(3072);Assert-TrustAnchorPublicKey $rsa
        $pem=Export-TrustAnchorEncryptedPrivateKey -Rsa $rsa -Password $password
        $privateBytes=[Text.UTF8Encoding]::new($false).GetBytes($pem+$(if($pem.EndsWith("`n")){''}else{"`n"}))
        $privateLease=New-TrustAnchorKeyFile -PathEvidence $privateTarget -Bytes $privateBytes
        try{
            if($null-ne$script:TrustAnchorBeforePublicWriteTestHook){& $script:TrustAnchorBeforePublicWriteTestHook $privateLease $publicTarget}
            $publicBytes=ConvertTo-TrustAnchorCanonicalXml $rsa
            try{$publicLease=New-TrustAnchorKeyFile -PathEvidence $publicTarget -Bytes $publicBytes}
            finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($publicBytes)}
        }catch{
            $publicFailure=$_
            try{Remove-TrustAnchorCreatedFile $privateLease;$privateLease=$null}
            catch{throw [IO.IOException]::new("Public-key output failed and private-key rollback failed closed. Public output: $($publicFailure.Exception.Message) Rollback: $($_.Exception.Message)",$_.Exception)}
            throw $publicFailure
        }
        $fingerprint=Get-TrustAnchorFingerprint $rsa
        [pscustomobject][ordered]@{keyId=$KeyId;xmlSha256=$fingerprint.xmlSha256;spkiSha256=$fingerprint.spkiSha256}
    }finally{
        Close-TrustAnchorCreatedFile $publicLease;Close-TrustAnchorCreatedFile $privateLease
        Close-TrustAnchorPathEvidence $publicTarget;Close-TrustAnchorPathEvidence $privateTarget
        if($null-ne$privateBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($privateBytes)}
        if($null-ne$rsa){$rsa.Dispose()};if($null-ne$password){$password.Dispose()}
    }
}

function Invoke-ConvertToTrustAnchorPublicKeyXmlAction {
    param([Parameter(Mandatory)][string]$PublicKeyPemPath,[Parameter(Mandatory)][string]$OutputPath)
    Assert-TrustAnchorInteractiveHost
    $target=$null;$rsa=$null;$lease=$null;$bytes=$null
    try{
        $target=Assert-TrustAnchorKeyPath -Path $OutputPath -Purpose PublicOutput
        $pem=[IO.File]::ReadAllText([IO.Path]::GetFullPath($PublicKeyPemPath),[Text.UTF8Encoding]::new($false,$true))
        $rsa=Import-TrustAnchorPublicPem $pem;Assert-TrustAnchorPublicKey $rsa
        $bytes=ConvertTo-TrustAnchorCanonicalXml $rsa;$lease=New-TrustAnchorKeyFile -PathEvidence $target -Bytes $bytes
        Get-TrustAnchorFingerprint $rsa
    }finally{
        Close-TrustAnchorCreatedFile $lease;Close-TrustAnchorPathEvidence $target
        if($null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};if($null-ne$rsa){$rsa.Dispose()}
    }
}

function Invoke-GetTrustAnchorFingerprintAction {
    param([string]$PublicKeyXmlPath,[string]$PublicKeyPemPath,[string]$EncryptedPrivateKeyPath)
    Assert-TrustAnchorInteractiveHost
    $selected=@(@($PublicKeyXmlPath,$PublicKeyPemPath,$EncryptedPrivateKeyPath)|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($selected.Count -ne 1){throw 'Exactly one trust-anchor input path is required.'}
    $rsa=$null;$password=$null;$privateBytes=$null
    try{
        if(-not[string]::IsNullOrWhiteSpace($PublicKeyXmlPath)){$rsa=Import-TrustAnchorPublicXml ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($PublicKeyXmlPath)))}
        elseif(-not[string]::IsNullOrWhiteSpace($PublicKeyPemPath)){$pem=[IO.File]::ReadAllText([IO.Path]::GetFullPath($PublicKeyPemPath),[Text.UTF8Encoding]::new($false,$true));$rsa=Import-TrustAnchorPublicPem $pem}
        else{$privateBytes=Open-TrustAnchorPrivateKey $EncryptedPrivateKeyPath;$password=Read-TrustAnchorPassword;$pem=[Text.UTF8Encoding]::new($false,$true).GetString($privateBytes);$rsa=Import-TrustAnchorEncryptedPrivateKey -Pem $pem -Password $password}
        Assert-TrustAnchorPublicKey $rsa;Get-TrustAnchorFingerprint $rsa
    }finally{if($null-ne$privateBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($privateBytes)};if($null-ne$rsa){$rsa.Dispose()};if($null-ne$password){$password.Dispose()}}
}

Export-ModuleMember -Function @()
