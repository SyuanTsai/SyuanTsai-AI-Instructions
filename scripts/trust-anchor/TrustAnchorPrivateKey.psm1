# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1') -Scope Local -ErrorAction Stop

if ($null -eq ('SyuanTsai.AIInstructions.TrustAnchor.SecretBridge' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Buffers;
using System.Buffers.Text;
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
        private static bool ContainsAscii(byte[] value, string text) {
            if (value == null || value.Length < text.Length) return false;
            for (int offset = 0; offset <= value.Length - text.Length; offset++) {
                int index = 0;
                while (index < text.Length && value[offset + index] == (byte)text[index]) index++;
                if (index == text.Length) return true;
            }
            return false;
        }
        private static void RequireEncryptedPrivatePemHeader(byte[] value) {
            if (ContainsAscii(value, "-----BEGIN PRIVATE KEY-----") || ContainsAscii(value, "-----BEGIN RSA PRIVATE KEY-----") ||
                !ContainsAscii(value, "-----BEGIN ENCRYPTED PRIVATE KEY-----"))
                throw new CryptographicException("Only encrypted PKCS#8 PEM input is permitted.");
        }
        private static bool IsAsciiWhitespace(byte value) {
            return value == (byte)' ' || value == (byte)'\t' || value == (byte)'\r' || value == (byte)'\n';
        }
        private static void SkipAsciiWhitespace(byte[] value, ref int offset) {
            while (offset < value.Length && IsAsciiWhitespace(value[offset])) offset++;
        }
        private static bool MatchAscii(byte[] value, int offset, string text, bool ignoreCase) {
            if (value == null || offset < 0 || value.Length - offset < text.Length) return false;
            for (int index = 0; index < text.Length; index++) {
                byte actual = value[offset + index]; char expected = text[index];
                if (actual > 0x7f) return false;
                char character = (char)actual;
                if (ignoreCase) { character = char.ToUpperInvariant(character); expected = char.ToUpperInvariant(expected); }
                if (character != expected) return false;
            }
            return true;
        }
        private static void RequireAscii(byte[] value, ref int offset, string text, bool ignoreCase) {
            if (!MatchAscii(value, offset, text, ignoreCase)) throw new CryptographicException("The public-key input structure is not permitted.");
            offset += text.Length;
        }
        private static byte[] RequirePublicPemEnvelope(byte[] value, out int derLength) {
            if (value == null) throw new ArgumentNullException(nameof(value));
            byte[] encoded = new byte[value.Length];
            derLength = 0;
            try {
            int offset = 0; SkipAsciiWhitespace(value, ref offset);
            RequireAscii(value, ref offset, "-----BEGIN PUBLIC KEY-----", false);
            if (offset >= value.Length || (value[offset] != (byte)'\n' && value[offset] != (byte)'\r'))
                throw new CryptographicException("The PUBLIC KEY header must end with a line break.");
            if (value[offset] == (byte)'\r') { offset++; if (offset >= value.Length || value[offset] != (byte)'\n') throw new CryptographicException("Invalid PEM line ending."); }
            offset++;
            bool lineStart = true, payload = false; int encodedLength = 0;
            while (offset < value.Length) {
                if (lineStart && MatchAscii(value, offset, "-----END PUBLIC KEY-----", false)) {
                    offset += "-----END PUBLIC KEY-----".Length;
                    SkipAsciiWhitespace(value, ref offset);
                    if (!payload || offset != value.Length) throw new CryptographicException("The PUBLIC KEY envelope has trailing content or no payload.");
                    byte[] der = new byte[(encodedLength * 3 + 3) / 4];
                    try {
                        int consumed;
                        OperationStatus status = Base64.DecodeFromUtf8(new ReadOnlySpan<byte>(encoded, 0, encodedLength), der.AsSpan(), out consumed, out derLength);
                        if (status != OperationStatus.Done || consumed != encodedLength || derLength == 0)
                            throw new CryptographicException("The PUBLIC KEY payload is not valid base64.");
                        return der;
                    }
                    catch { CryptographicOperations.ZeroMemory(der); throw; }
                }
                byte current = value[offset];
                bool base64 = (current >= (byte)'A' && current <= (byte)'Z') || (current >= (byte)'a' && current <= (byte)'z') ||
                    (current >= (byte)'0' && current <= (byte)'9') || current == (byte)'+' || current == (byte)'/' || current == (byte)'=';
                if (base64) { payload = true; lineStart = false; encoded[encodedLength++] = current; offset++; continue; }
                if (current == (byte)'\n') { lineStart = true; offset++; continue; }
                if (current == (byte)'\r' && offset + 1 < value.Length && value[offset + 1] == (byte)'\n') { lineStart = true; offset += 2; continue; }
                throw new CryptographicException("Only base64 payload lines are permitted inside a PUBLIC KEY envelope.");
            }
            throw new CryptographicException("The PUBLIC KEY envelope is incomplete.");
            }
            finally { CryptographicOperations.ZeroMemory(encoded); }
        }
        private static void RequireXmlTag(byte[] value, ref int offset, string name, bool closing) {
            RequireAscii(value, ref offset, closing ? "</" : "<", false);
            RequireAscii(value, ref offset, name, true);
            RequireAscii(value, ref offset, ">", false);
        }
        private static void RequireBase64XmlText(byte[] value, ref int offset) {
            bool payload = false;
            while (offset < value.Length && value[offset] != (byte)'<') {
                byte current = value[offset++];
                bool base64 = (current >= (byte)'A' && current <= (byte)'Z') || (current >= (byte)'a' && current <= (byte)'z') ||
                    (current >= (byte)'0' && current <= (byte)'9') || current == (byte)'+' || current == (byte)'/' || current == (byte)'=';
                if (base64) payload = true;
                else if (!IsAsciiWhitespace(current)) throw new CryptographicException("RSA public XML contains non-base64 text.");
            }
            if (!payload) throw new CryptographicException("RSA public XML contains an empty key field.");
        }
        private static void RequirePublicXmlStructure(byte[] value) {
            if (value == null) throw new ArgumentNullException(nameof(value));
            int offset = 0; SkipAsciiWhitespace(value, ref offset);
            RequireXmlTag(value, ref offset, "RSAKeyValue", false); SkipAsciiWhitespace(value, ref offset);
            RequireXmlTag(value, ref offset, "Modulus", false); RequireBase64XmlText(value, ref offset); RequireXmlTag(value, ref offset, "Modulus", true); SkipAsciiWhitespace(value, ref offset);
            RequireXmlTag(value, ref offset, "Exponent", false); RequireBase64XmlText(value, ref offset); RequireXmlTag(value, ref offset, "Exponent", true); SkipAsciiWhitespace(value, ref offset);
            RequireXmlTag(value, ref offset, "RSAKeyValue", true); SkipAsciiWhitespace(value, ref offset);
            if (offset != value.Length) throw new CryptographicException("RSA public XML contains an additional element or trailing content.");
        }
        public static RSA DecodePublicPem(byte[] value) {
            byte[] der = null; RSA rsa = null;
            try {
                int derLength;
                der = RequirePublicPemEnvelope(value, out derLength);
                rsa = RSA.Create();
                int consumed;
                rsa.ImportSubjectPublicKeyInfo(new ReadOnlySpan<byte>(der, 0, derLength), out consumed);
                if (consumed != derLength) throw new CryptographicException("The PUBLIC KEY payload has trailing DER data.");
                RSA result = rsa; rsa = null; return result;
            }
            finally {
                if (rsa != null) rsa.Dispose();
                if (der != null) CryptographicOperations.ZeroMemory(der);
            }
        }
        public static string DecodePublicXml(byte[] value) {
            RequirePublicXmlStructure(value);
            return new System.Text.UTF8Encoding(false, true).GetString(value);
        }
        private static char[] DecodePrivatePem(byte[] pemBytes) {
            var encoding = new System.Text.UTF8Encoding(false, true);
            char[] characters = new char[encoding.GetCharCount(pemBytes)];
            encoding.GetChars(pemBytes, 0, pemBytes.Length, characters, 0);
            return characters;
        }
        private static void ValidateEncryptedPemProfile(char[] pem) {
            PemFields fields;
            if (!PemEncoding.TryFind(pem.AsSpan(), out fields)) throw new CryptographicException("Encrypted PKCS#8 PEM framing is invalid.");
            var location = fields.Location.GetOffsetAndLength(pem.Length);
            var label = fields.Label.GetOffsetAndLength(pem.Length);
            if (location.Offset != 0 || !pem.AsSpan(label.Offset, label.Length).SequenceEqual("ENCRYPTED PRIVATE KEY".AsSpan()))
                throw new CryptographicException("Encrypted PKCS#8 PEM framing is invalid.");
            for (int index = location.Offset + location.Length; index < pem.Length; index++)
                if (!char.IsWhiteSpace(pem[index])) throw new CryptographicException("Encrypted PKCS#8 PEM framing is invalid.");
            var base64 = fields.Base64Data.GetOffsetAndLength(pem.Length);
            byte[] der = new byte[(base64.Length * 3 + 3) / 4];
            int derLength;
            if (!Convert.TryFromBase64Chars(pem.AsSpan(base64.Offset, base64.Length), der, out derLength)) {
                CryptographicOperations.ZeroMemory(der);
                throw new CryptographicException("Encrypted PKCS#8 PEM payload is invalid.");
            }
            try {
                var outerReader = new AsnReader(new ReadOnlyMemory<byte>(der, 0, derLength), AsnEncodingRules.DER);
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
                try { if (salt.Length < 16) throw new CryptographicException("PBKDF2 salt must contain at least 16 bytes."); }
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
        public static RSA ImportEncryptedPem(byte[] pemBytes, char[] password) {
            if (pemBytes == null) throw new ArgumentNullException(nameof(pemBytes));
            RequireEncryptedPrivatePemHeader(pemBytes);
            char[] pem = DecodePrivatePem(pemBytes);
            try {
                ValidateEncryptedPemProfile(pem);
                RSA rsa = RSA.Create();
                try { rsa.ImportFromEncryptedPem(pem.AsSpan(), password.AsSpan()); return rsa; }
                catch { rsa.Dispose(); throw; }
            }
            finally { Zero(pem); }
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
        public static SafeFileHandle OpenReadWithDeleteSharing(string path) {
            SafeFileHandle handle = CreateFile(path, 0x00020081, 0x00000007, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Unable to open the trust-anchor fixture with delete sharing."); }
            return handle;
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

    public sealed class UnixNativeFlagSet {
        public int Directory { get; private set; }
        public int NoFollow { get; private set; }
        public int CloseOnExec { get; private set; }
        public int AtRemoveDirectory { get; private set; }
        public int AtSymlinkNoFollow { get; private set; }
        public int OpenDirectory { get { return Directory | NoFollow | CloseOnExec; } }
        public int OpenFile { get { return NoFollow | CloseOnExec; } }
        private UnixNativeFlagSet(int directory,int noFollow,int closeOnExec,int atRemoveDirectory,int atSymlinkNoFollow) {
            Directory=directory;NoFollow=noFollow;CloseOnExec=closeOnExec;AtRemoveDirectory=atRemoveDirectory;AtSymlinkNoFollow=atSymlinkNoFollow;
        }
        public static UnixNativeFlagSet Select(string operatingSystem,string architecture) {
            if (operatingSystem == "linux" && architecture == "x64") return new UnixNativeFlagSet(0x10000,0x20000,0x80000,0x200,0x100);
            if (operatingSystem == "linux" && architecture == "arm64") return new UnixNativeFlagSet(0x4000,0x8000,0x80000,0x200,0x100);
            if (operatingSystem == "macos" && (architecture == "x64" || architecture == "arm64")) return new UnixNativeFlagSet(0x100000,0x100,0x1000000,0x80,0x20);
            throw new PlatformNotSupportedException("Unsupported trust-anchor Unix ABI: "+operatingSystem+"/"+architecture);
        }
        public static UnixNativeFlagSet Current() {
            string operatingSystem = RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ? "linux" : RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "macos" : "unsupported";
            string architecture = RuntimeInformation.ProcessArchitecture == Architecture.X64 ? "x64" : RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
            return Select(operatingSystem,architecture);
        }
    }

    // Same-UID concurrent processes are outside this rollback threat boundary: they can
    // already read or replace the private key and this tool.  The retained descriptors
    // still bind every decision and prevent unrelated pathname identities from deletion.
    public sealed class UnixRollbackLease : IDisposable {
        [DllImport("libc", EntryPoint="fstatat", SetLastError=true)] private static extern int fstatatLinux(IntPtr fd,string leaf,IntPtr value,int flags);
        [DllImport("libc", EntryPoint="renameat2", SetLastError=true)] private static extern int renameat2(IntPtr oldFd,string oldLeaf,IntPtr newFd,string newLeaf,uint flags);
        [DllImport("libc", EntryPoint="unlinkat", SetLastError=true)] private static extern int unlinkatLinux(IntPtr fd,string leaf,int flags);
        [DllImport("libc", EntryPoint="fsync", SetLastError=true)] private static extern int fsyncLinux(IntPtr fd);
        [DllImport("libc", EntryPoint="mkdirat", SetLastError=true)] private static extern int mkdiratLinux(IntPtr fd,string leaf,uint mode);
        [DllImport("libc", EntryPoint="openat", SetLastError=true)] private static extern int openatLinux(IntPtr fd,string leaf,int flags,uint mode);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fstatat$INODE64", SetLastError=true)] private static extern int fstatatDarwinX64(IntPtr fd,string leaf,IntPtr value,int flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fstatat", SetLastError=true)] private static extern int fstatatDarwin(IntPtr fd,string leaf,IntPtr value,int flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="renameatx_np", SetLastError=true)] private static extern int renameatx(IntPtr oldFd,string oldLeaf,IntPtr newFd,string newLeaf,uint flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="unlinkat", SetLastError=true)] private static extern int unlinkatDarwin(IntPtr fd,string leaf,int flags);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="fsync", SetLastError=true)] private static extern int fsyncDarwin(IntPtr fd);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="mkdirat", SetLastError=true)] private static extern int mkdiratDarwin(IntPtr fd,string leaf,uint mode);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="openat", SetLastError=true)] private static extern int openatDarwin(IntPtr fd,string leaf,int flags,uint mode);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="acl_get_fd_np", SetLastError=true)] private static extern IntPtr acl_get_fd_np(IntPtr fd,int type);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="acl_get_entry", SetLastError=true)] private static extern int acl_get_entry(IntPtr acl,int entryId,out IntPtr entry);
        [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint="acl_free", SetLastError=true)] private static extern int acl_free(IntPtr acl);
        private readonly SafeHandle parent;
        private SafeFileHandle directory;
        private SafeFileHandle file;
        private readonly ulong device;
        private readonly ulong inode;
        private ulong directoryDevice;
        private ulong directoryInode;
        public string DirectoryName { get; private set; }
        public string TombstoneName { get; private set; }
        public string DirectoryPath { get; private set; }
        public string TombstonePath { get { return Path.Combine(DirectoryPath, TombstoneName); } }
        private UnixRollbackLease(SafeHandle parent,string parentPath,ulong device,ulong inode) {
            this.parent=parent;this.device=device;this.inode=inode;
            DirectoryName=".trust-anchor-rollback-"+Guid.NewGuid().ToString("N");
            TombstoneName="key-"+Guid.NewGuid().ToString("N");
            DirectoryPath=Path.Combine(parentPath,DirectoryName);
        }
        private static bool Mac { get { return RuntimeInformation.IsOSPlatform(OSPlatform.OSX); } }
        private static int MkdirAt(SafeHandle parent,string name){return Mac?mkdiratDarwin(parent.DangerousGetHandle(),name,448):mkdiratLinux(parent.DangerousGetHandle(),name,448);}
        private static SafeFileHandle OpenAt(SafeHandle parent,string name,bool directory){
            UnixNativeFlagSet selected=UnixNativeFlagSet.Current();int flags=directory?selected.OpenDirectory:selected.OpenFile;
            int fd=Mac?openatDarwin(parent.DangerousGetHandle(),name,flags,0):openatLinux(parent.DangerousGetHandle(),name,flags,0);
            if(fd<0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to retain the private trust-anchor rollback object.");
            return new SafeFileHandle(new IntPtr(fd),true);
        }
        private static NativeMetadataEvidence Stat(SafeHandle parent,string leaf) {
            IntPtr buffer=Marshal.AllocHGlobal(512);
            try {
                for(int i=0;i<512;i+=8)Marshal.WriteInt64(buffer,i,0);
                bool mac=RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
                int noFollow=UnixNativeFlagSet.Current().AtSymlinkNoFollow;
                int result=mac?(RuntimeInformation.ProcessArchitecture==Architecture.X64?fstatatDarwinX64(parent.DangerousGetHandle(),leaf,buffer,noFollow):fstatatDarwin(parent.DangerousGetHandle(),leaf,buffer,noFollow)):fstatatLinux(parent.DangerousGetHandle(),leaf,buffer,noFollow);
                if(result!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"fstatat failed for the trust-anchor rollback target.");
                if(mac){var s=(UnixMetadataInspector.DarwinStat)Marshal.PtrToStructure(buffer,typeof(UnixMetadataInspector.DarwinStat));return new NativeMetadataEvidence{Device=s.Dev,Inode=s.Ino,LinkCount=s.Links,Mode=s.Mode,Uid=s.Uid,Size=s.Size};}
                if(RuntimeInformation.ProcessArchitecture==Architecture.X64){var s=(UnixMetadataInspector.LinuxX64Stat)Marshal.PtrToStructure(buffer,typeof(UnixMetadataInspector.LinuxX64Stat));return new NativeMetadataEvidence{Device=s.Dev,Inode=s.Ino,LinkCount=s.Links,Mode=s.Mode,Uid=s.Uid,Size=s.Size};}
                var a=(UnixMetadataInspector.LinuxArm64Stat)Marshal.PtrToStructure(buffer,typeof(UnixMetadataInspector.LinuxArm64Stat));return new NativeMetadataEvidence{Device=a.Dev,Inode=a.Ino,LinkCount=a.Links,Mode=a.Mode,Uid=a.Uid,Size=a.Size};
            } finally {Marshal.FreeHGlobal(buffer);}
        }
        private static void SameFile(NativeMetadataEvidence value,ulong device,ulong inode){if(value.Device!=device||value.Inode!=inode||value.LinkCount!=1||(value.Mode&0xF000)!=0x8000)throw new IOException("The trust-anchor rollback target identity or link count changed.");}
        private static void SameDirectory(NativeMetadataEvidence value,ulong device,ulong inode){if(value.Device!=device||value.Inode!=inode||(value.Mode&0xF000)!=0x4000)throw new IOException("The private trust-anchor rollback directory identity changed.");}
        private static void AssertNoMacExtendedAcl(SafeHandle parent){
            if(!Mac)return;
            IntPtr acl=acl_get_fd_np(parent.DangerousGetHandle(),0x100);
            if(acl==IntPtr.Zero){
                int error=Marshal.GetLastWin32Error();
                if(error==2)return;
                throw new Win32Exception(error,"Unable to inspect the retained trust-anchor parent ACL.");
            }
            try{
                IntPtr entry;int result=acl_get_entry(acl,0,out entry);
                if(result==0)throw new IOException("The private trust-anchor parent must not have a macOS extended ACL.");
                int error=Marshal.GetLastWin32Error();
                if(error==2||error==22)return;
                throw new Win32Exception(error,"Unable to enumerate the retained trust-anchor parent ACL.");
            }finally{if(acl_free(acl)!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to release the retained trust-anchor parent ACL.");}
        }
        public static void AssertSafeParent(SafeHandle parent){
            AssertNoMacExtendedAcl(parent);
            NativeMetadataEvidence value=UnixMetadataInspector.Inspect(parent);ulong effectiveUid=SecretBridge.EffectiveUid();
            // Linux POSIX ACL named-user/group permissions are bounded by the ACL mask,
            // which is exposed through the group class mode bits checked below.
            bool trustedOwner=value.Uid==effectiveUid||value.Uid==0;bool restricted=(value.Mode&0x12)==0;bool sticky=(value.Mode&0x200)!=0;
            if((value.Mode&0xF000)!=0x4000||!trustedOwner||(!restricted&&!sticky))throw new IOException("The private trust-anchor parent must be owner-only or sticky and owned by the effective user or root.");
        }
        public static UnixRollbackLease Begin(SafeHandle parent,string parentPath,string leaf,ulong device,ulong inode){
            AssertSafeParent(parent);
            NativeMetadataEvidence before=Stat(parent,leaf);SameFile(before,device,inode);
            var lease=new UnixRollbackLease(parent,parentPath,device,inode);bool directoryCreated=false;bool renamed=false;
            try{
                if(MkdirAt(parent,lease.DirectoryName)!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to create the private trust-anchor rollback directory.");
                directoryCreated=true;lease.directory=OpenAt(parent,lease.DirectoryName,true);
                var directoryEvidence=UnixMetadataInspector.Inspect(lease.directory);
                if((directoryEvidence.Mode&0xF000)!=0x4000||(directoryEvidence.Mode&0x3F)!=0||directoryEvidence.Uid!=SecretBridge.EffectiveUid())throw new IOException("The private trust-anchor rollback directory is not retained with mode 0700-equivalent ownership.");
                lease.directoryDevice=directoryEvidence.Device;lease.directoryInode=directoryEvidence.Inode;
                int moved=Mac?renameatx(parent.DangerousGetHandle(),leaf,lease.directory.DangerousGetHandle(),lease.TombstoneName,0x4):renameat2(parent.DangerousGetHandle(),leaf,lease.directory.DangerousGetHandle(),lease.TombstoneName,1);
                if(moved!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to move the trust-anchor rollback target into the private rollback directory.");
                renamed=true;lease.file=OpenAt(lease.directory,lease.TombstoneName,false);
                SameFile(Stat(lease.directory,lease.TombstoneName),device,inode);
                SameFile(UnixMetadataInspector.Inspect(lease.file),device,inode);
                return lease;
            }catch{
                if(lease.file!=null)lease.file.Dispose();
                if(directoryCreated&&!renamed&&lease.directory!=null){
                    SameDirectory(UnixMetadataInspector.Inspect(lease.directory),lease.directoryDevice,lease.directoryInode);
                    SameDirectory(Stat(parent,lease.DirectoryName),lease.directoryDevice,lease.directoryInode);
                    int removeDirectory=UnixNativeFlagSet.Current().AtRemoveDirectory;
                    int cleanup=Mac?unlinkatDarwin(parent.DangerousGetHandle(),lease.DirectoryName,removeDirectory):unlinkatLinux(parent.DangerousGetHandle(),lease.DirectoryName,removeDirectory);
                    if(cleanup!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to remove the unused private rollback directory.");
                }
                if(lease.directory!=null)lease.directory.Dispose();
                throw;
            }
        }
        public void Complete(){
            SameFile(Stat(directory,TombstoneName),device,inode);SameFile(UnixMetadataInspector.Inspect(file),device,inode);
            int removed=Mac?unlinkatDarwin(directory.DangerousGetHandle(),TombstoneName,0):unlinkatLinux(directory.DangerousGetHandle(),TombstoneName,0);
            if(removed!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to unlink the exact trust-anchor rollback tombstone.");
            var after=UnixMetadataInspector.Inspect(file);if(after.LinkCount!=0)throw new IOException("The trust-anchor rollback target still has a retained hard link after unlink.");
            int directorySynced=Mac?fsyncDarwin(directory.DangerousGetHandle()):fsyncLinux(directory.DangerousGetHandle());if(directorySynced!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to confirm private rollback directory durability.");
            file.Dispose();file=null;
            SameDirectory(UnixMetadataInspector.Inspect(directory),directoryDevice,directoryInode);
            SameDirectory(Stat(parent,DirectoryName),directoryDevice,directoryInode);
            int removeDirectory=UnixNativeFlagSet.Current().AtRemoveDirectory;
            int directoryRemoved=Mac?unlinkatDarwin(parent.DangerousGetHandle(),DirectoryName,removeDirectory):unlinkatLinux(parent.DangerousGetHandle(),DirectoryName,removeDirectory);if(directoryRemoved!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to remove the completed private rollback directory.");
            directory.Dispose();directory=null;
            int parentSynced=Mac?fsyncDarwin(parent.DangerousGetHandle()):fsyncLinux(parent.DangerousGetHandle());if(parentSynced!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to confirm trust-anchor rollback parent durability.");
        }
        public void Dispose(){if(file!=null)file.Dispose();if(directory!=null)directory.Dispose();}
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
    $inputRedirected=[Console]::IsInputRedirected
    $userInteractive=[Environment]::UserInteractive
    if ($inputRedirected -or -not $userInteractive) {
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
        return $Action.Invoke(@(,$characters))
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
    [CmdletBinding()] param([Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][Security.SecureString]$Password)
    try { return Use-TrustAnchorPassword $Password { param([char[]]$characters) [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::ImportEncryptedPem($Bytes,$characters) } }
    catch {throw (New-TrustAnchorError 'Only encrypted PKCS#8 PEM using PBES2 with a minimum 16-byte PBKDF2 salt, PBKDF2-HMAC-SHA256, AES-256-CBC, and 600000 iterations is supported.' 'TrustAnchor.UnsupportedKeyFormat')}
}

function Read-TrustAnchorInputBytes {
    param([Parameter(Mandatory)][string]$Path,[int]$MaximumLength=1048576)
    $full=[IO.Path]::GetFullPath($Path);$stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$bytes=$null;$succeeded=$false
    try{
        if($stream.Length -gt $MaximumLength){throw "The trust-anchor input exceeds the $MaximumLength-byte limit."}
        $bytes=[byte[]]::new([int]$stream.Length);$offset=0
        while($offset -lt $bytes.Length){$count=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($count -eq 0){throw 'The trust-anchor input ended before its declared length.'};$offset+=$count}
        $succeeded=$true;return ,$bytes
    }finally{if(-not$succeeded -and $null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};$stream.Dispose()}
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
    if($null-ne$git){$root=git -C $PathEvidence.Parent rev-parse --show-toplevel 2>$null;if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($root -join ''))){throw 'Trust-anchor key material and generated public output must remain outside every Git worktree.'}}
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
        try{Assert-PlatformFileIdentity -Lease $parent -Expected $PathEvidence.ParentExpected -VerifyPath|Out-Null}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.ParentIdentityChanged')}
        if(-not$IsWindows -and $PathEvidence.Purpose -ceq 'PrivateKey'){try{[SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease]::AssertSafeParent((Get-TrustAnchorLeaseHandle $parent))}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.UnsafeParentAcl')}}
        $file=Open-PlatformFile -ParentLease $parent -Leaf $PathEvidence.Leaf -Access ReadWrite -CreateMode CreateNew;$expected=$file.Observation
        if($PathEvidence.Purpose -ceq 'PrivateKey'){
            if($IsWindows){$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$identity.User.Value}finally{$identity.Dispose()};Set-PlatformPermissions -Lease $file -Policy @{Sddl="D:P(A;;FA;;;$sid)";ReadOnly=$false}|Out-Null}else{Set-PlatformPermissions -Lease $file -Policy @{Mode=384}|Out-Null}
            Assert-TrustAnchorPrivatePermissions $file|Out-Null
        }
        $file.WriteNewBytes($Bytes);Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null
        if($PathEvidence.Purpose -ceq 'PrivateKey'){Assert-TrustAnchorPrivatePermissions $file|Out-Null}
        try{Assert-PlatformFileIdentity -Lease $parent -Expected $PathEvidence.ParentExpected -VerifyPath|Out-Null}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.ParentIdentityChanged')}
        return [pscustomobject]@{Path=$PathEvidence.Path;Parent=$PathEvidence.Parent;Leaf=$PathEvidence.Leaf;ParentLease=$parent;FileLease=$file;Expected=$expected;Purpose=$PathEvidence.Purpose;Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant();Length=[int64]$Bytes.Length}
    }catch{if($null-ne$file){$file.Dispose()};throw}
}

function Remove-TrustAnchorCreatedFile {
    param([Parameter(Mandatory)]$Lease)
    $rollback=$null
    try{
        Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath|Out-Null
        if($IsWindows){
            $Lease.FileLease.Dispose()
            [SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::DeleteExact($Lease.Path,[uint64]$Lease.Expected.Device,[uint64]$Lease.Expected.Inode)
        }else{
            Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath|Out-Null
            $rollback=[SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease]::Begin((Get-TrustAnchorLeaseHandle $Lease.ParentLease),$Lease.Parent,$Lease.Leaf,[uint64]$Lease.Expected.Device,[uint64]$Lease.Expected.Inode)
            $rollback.Complete()
        }
    }finally{if($null-ne$rollback){$rollback.Dispose()};$Lease.FileLease.Dispose();$Lease.ParentLease.Dispose()}
}
function Close-TrustAnchorCreatedFile {param($Lease)if($null-ne$Lease){$Lease.FileLease.Dispose();$Lease.ParentLease.Dispose()}}

function Open-TrustAnchorPrivateKeyLease {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $pathEvidence=$null;$file=$null;$succeeded=$false
    try{
        $pathEvidence=New-TrustAnchorPathEvidence -Path $Path -Purpose PrivateKey -Existing
        $file=Open-PlatformFile -ParentLease $pathEvidence.ParentLease -Leaf $pathEvidence.Leaf -Access Read -CreateMode OpenExisting;$expected=$file.Observation
        try{Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath|Out-Null}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.PrivateIdentityChanged')}
        $openMetadata=Get-TrustAnchorMetadataEvidence $file
        $succeeded=$true;return [pscustomobject]@{PathEvidence=$pathEvidence;FileLease=$file;Expected=$expected;OpenMetadata=$openMetadata}
    }finally{if(-not$succeeded){if($null-ne$file){$file.Dispose()};Close-TrustAnchorPathEvidence $pathEvidence}}
}
function Read-TrustAnchorPrivateKeyLease {
    [CmdletBinding()] param([Parameter(Mandatory)]$Lease)
    $bytes=$null;$succeeded=$false
    try{
        $before=Get-TrustAnchorMetadataEvidence $Lease.FileLease;try{Assert-TrustAnchorPrivatePermissions $Lease.FileLease $before|Out-Null}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.UnsafePrivatePermissions')};if(-not(Test-TrustAnchorMetadataEqual $Lease.OpenMetadata $before)){throw (New-TrustAnchorError 'The private-key handle metadata changed after it was opened.' 'TrustAnchor.PrivateMetadataChanged')}
        $bytes=$Lease.FileLease.ReadAllBytes(1048576)
        try{Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath|Out-Null}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.PrivateIdentityChanged')}
        $after=Get-TrustAnchorMetadataEvidence $Lease.FileLease;try{Assert-TrustAnchorPrivatePermissions $Lease.FileLease $after|Out-Null}catch{throw (New-TrustAnchorError $_.Exception.Message 'TrustAnchor.UnsafePrivatePermissions')}
        if(-not(Test-TrustAnchorMetadataEqual $before $after)){throw (New-TrustAnchorError 'The private-key handle metadata changed while it was being read.' 'TrustAnchor.PrivateMetadataChanged')}
        $succeeded=$true;return ,$bytes
    }finally{if(-not$succeeded -and $null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}}
}
function Close-TrustAnchorPrivateKeyLease {param($Lease)if($null-ne$Lease){$Lease.FileLease.Dispose();Close-TrustAnchorPathEvidence $Lease.PathEvidence}}
function Open-TrustAnchorPrivateKey {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $lease=$null
    try{
        $lease=Open-TrustAnchorPrivateKeyLease $Path
        return ,(Read-TrustAnchorPrivateKeyLease $lease)
    }finally{Close-TrustAnchorPrivateKeyLease $lease}
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
    try{$text=[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::DecodePublicXml($Bytes)}catch{throw (New-TrustAnchorError 'The XML input contains private RSA fields or is not valid UTF-8.' 'TrustAnchor.UnsupportedKeyFormat')}
    if($text -notmatch '\A<RSAKeyValue><Modulus>([^<]+)</Modulus><Exponent>([^<]+)</Exponent></RSAKeyValue>\r?\n?\z'){throw 'The XML input is not a public RSAKeyValue document.'}
    $rsa=[Security.Cryptography.RSA]::Create()
    try{$rsa.ImportParameters([Security.Cryptography.RSAParameters]@{Modulus=[Convert]::FromBase64String($Matches[1]);Exponent=[Convert]::FromBase64String($Matches[2])});return $rsa}catch{$rsa.Dispose();throw}
}

function Import-TrustAnchorPublicPem {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    try{return [SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::DecodePublicPem($Bytes)}catch{throw (New-TrustAnchorError 'Only a PUBLIC KEY PEM without private-key content is supported.' 'TrustAnchor.UnsupportedKeyFormat')}
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
    $target=$null;$rsa=$null;$lease=$null;$bytes=$null;$inputBytes=$null
    try{
        $target=Assert-TrustAnchorKeyPath -Path $OutputPath -Purpose PublicOutput
        $inputBytes=Read-TrustAnchorInputBytes $PublicKeyPemPath
        $rsa=Import-TrustAnchorPublicPem $inputBytes;Assert-TrustAnchorPublicKey $rsa
        $bytes=ConvertTo-TrustAnchorCanonicalXml $rsa;$lease=New-TrustAnchorKeyFile -PathEvidence $target -Bytes $bytes
        Get-TrustAnchorFingerprint $rsa
    }finally{
        Close-TrustAnchorCreatedFile $lease;Close-TrustAnchorPathEvidence $target
        if($null-ne$inputBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($inputBytes)};if($null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};if($null-ne$rsa){$rsa.Dispose()}
    }
}

function Invoke-GetTrustAnchorFingerprintAction {
    param([string]$PublicKeyXmlPath,[string]$PublicKeyPemPath,[string]$EncryptedPrivateKeyPath)
    Assert-TrustAnchorInteractiveHost
    $selected=@(@($PublicKeyXmlPath,$PublicKeyPemPath,$EncryptedPrivateKeyPath)|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($selected.Count -ne 1){throw 'Exactly one trust-anchor input path is required.'}
    $rsa=$null;$password=$null;$inputBytes=$null;$privateLease=$null
    try{
        if(-not[string]::IsNullOrWhiteSpace($PublicKeyXmlPath)){$inputBytes=Read-TrustAnchorInputBytes $PublicKeyXmlPath;$rsa=Import-TrustAnchorPublicXml $inputBytes}
        elseif(-not[string]::IsNullOrWhiteSpace($PublicKeyPemPath)){$inputBytes=Read-TrustAnchorInputBytes $PublicKeyPemPath;$rsa=Import-TrustAnchorPublicPem $inputBytes}
        else{$privateLease=Open-TrustAnchorPrivateKeyLease $EncryptedPrivateKeyPath;$password=Read-TrustAnchorPassword;$inputBytes=Read-TrustAnchorPrivateKeyLease $privateLease;$rsa=Import-TrustAnchorEncryptedPrivateKey -Bytes $inputBytes -Password $password}
        Assert-TrustAnchorPublicKey $rsa;Get-TrustAnchorFingerprint $rsa
    }finally{if($null-ne$inputBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($inputBytes)};Close-TrustAnchorPrivateKeyLease $privateLease;if($null-ne$rsa){$rsa.Dispose()};if($null-ne$password){$password.Dispose()}}
}

Export-ModuleMember -Function @()
