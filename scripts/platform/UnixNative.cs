// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    // Only observations cross the evidence boundary. No public fd/HANDLE property.
    public sealed class FileObservation
    {
        public ulong Device { get; internal set; }
        public ulong Inode { get; internal set; }
        public uint Mode { get; internal set; }
        public ulong LinkCount { get; internal set; }
        public uint Uid { get; internal set; }
        public uint Gid { get; internal set; }
        public long Size { get; internal set; }
        public string Kind { get; internal set; }
    }

    internal sealed class SafeFd : SafeHandle
    {
        internal SafeFd(int fd) : base(new IntPtr(-1), true) { SetHandle(new IntPtr(fd)); }
        public override bool IsInvalid { get { return handle.ToInt64() < 0; } }
        // Do not retry close on EINTR: the descriptor may already have been reused.
        protected override bool ReleaseHandle() { return UnixNative.Close(handle.ToInt32()) == 0; }
    }

    public sealed class UnixLease : IDisposable
    {
        internal readonly object Sync = new object();
        internal SafeFd Fd;
        internal SafeFd Parent;
        internal string Leaf;
        internal string Path;
        internal bool Locked;
        public FileObservation Observation { get; internal set; }
        internal bool NewWritable;
        public byte[] ReadAllBytes(int maximumBytes)
        {
            lock (Sync)
            {
                Check(); UnixNative.AssertIdentity(this, Observation, true);
                byte[] bytes = LeaseBytes.Read(Fd, maximumBytes);
                UnixNative.AssertIdentity(this, Observation, true); return bytes;
            }
        }
        public void WriteNewBytes(byte[] bytes)
        {
            lock (Sync)
            {
                Check(); UnixNative.AssertIdentity(this, Observation, true);
                if (!NewWritable) throw new InvalidOperationException("A fresh create-only writable lease is required.");
                NewWritable = false; LeaseBytes.Write(Fd, bytes);
                UnixNative.AssertIdentity(this, Observation, true);
            }
        }
        internal UnixLease(SafeFd fd, SafeFd parent, string leaf, string path, FileObservation observation)
        { Fd = fd; Parent = parent; Leaf = leaf; Path = path; Observation = observation; }
        internal void Check() { if (Fd == null || Fd.IsClosed) throw new ObjectDisposedException("UnixLease"); }
        public void Dispose()
        {
            lock (Sync)
            {
                if (Fd == null) return;
                try { if (Locked) UnixNative.Unlock(Fd); }
                finally { Fd.Dispose(); if (Parent != null) Parent.Dispose(); Fd = null; Parent = null; }
            }
        }
    }

    public static class PlatformPaths
    {
        public static string[] Segments(string relative)
        {
            if (String.IsNullOrWhiteSpace(relative) || relative.IndexOf('\0') >= 0 ||
                relative.IndexOf(':') >= 0 || relative.StartsWith("/") || relative.StartsWith("\\"))
                throw new ArgumentException("A nonempty relative path is required.");
            string[] parts = relative.Replace('\\', '/').Split('/');
            foreach (string part in parts) Leaf(part);
            return parts;
        }
        public static void Leaf(string leaf)
        {
            if (String.IsNullOrWhiteSpace(leaf) || leaf == "." || leaf == ".." ||
                leaf.IndexOfAny(new char[] { '/', '\\', ':', '\0' }) >= 0)
                throw new ArgumentException("An ordinary single path component is required.");
            if (PlatformNative.GetOperatingSystem() == "windows" &&
                (leaf.EndsWith(".") || leaf.EndsWith(" ") || leaf.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
                throw new ArgumentException("Ambiguous Windows component.");
            if (PlatformNative.GetOperatingSystem() == "windows")
            {
                string stem = leaf.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                    stem == "CONIN$" || stem == "CONOUT$" ||
                    System.Text.RegularExpressions.Regex.IsMatch(stem, "^(COM|LPT)[0-9\u00b9\u00b2\u00b3]$"))
                    throw new ArgumentException("Windows device names are forbidden.");
            }
        }
        internal static void Same(FileObservation actual, FileObservation expected)
        {
            if (expected == null || actual.Device != expected.Device || actual.Inode != expected.Inode || actual.Kind != expected.Kind)
                throw new IOException("The file identity or type changed.");
        }
        internal static void Single(FileObservation value)
        {
            if (value.Kind != "file" || value.LinkCount != 1)
                throw new IOException("A regular file with exactly one link is required.");
        }
    }

    public static class UnixNative
    {
        // Explicit ABI records. Linux x86_64: glibc bits/struct_stat.h (144 bytes).
        // Linux aarch64: asm-generic/stat.h (128 bytes). Darwin: stat64 (144 bytes).
        // Darwin x64 calls the INODE64 symbol; arm64 uses the native 64-bit inode ABI.
        [StructLayout(LayoutKind.Explicit, Size = 144)]
        private struct LinuxX64Stat
        {
            [FieldOffset(0)] public ulong Dev; [FieldOffset(8)] public ulong Ino;
            [FieldOffset(16)] public ulong Nlink; [FieldOffset(24)] public uint Mode;
            [FieldOffset(28)] public uint Uid; [FieldOffset(32)] public uint Gid;
            [FieldOffset(48)] public long Size;
        }
        [StructLayout(LayoutKind.Explicit, Size = 128)]
        private struct LinuxArm64Stat
        {
            [FieldOffset(0)] public ulong Dev; [FieldOffset(8)] public ulong Ino;
            [FieldOffset(16)] public uint Mode; [FieldOffset(20)] public uint Nlink;
            [FieldOffset(24)] public uint Uid; [FieldOffset(28)] public uint Gid;
            [FieldOffset(48)] public long Size;
        }
        [StructLayout(LayoutKind.Explicit, Size = 144)]
        private struct DarwinStat
        {
            [FieldOffset(0)] public uint Dev; [FieldOffset(4)] public ushort Mode;
            [FieldOffset(6)] public ushort Nlink; [FieldOffset(8)] public ulong Ino;
            [FieldOffset(16)] public uint Uid; [FieldOffset(20)] public uint Gid;
            [FieldOffset(96)] public long Size;
        }
        private static class Linux
        {
            [DllImport("libc", SetLastError = true)] internal static extern int openat(int fd, string name, int flags, uint mode);
            [DllImport("libc", SetLastError = true)] internal static extern int mkdirat(SafeFd fd, string name, uint mode);
            [DllImport("libc", SetLastError = true)] internal static extern int fstat(SafeFd fd, IntPtr stat);
            [DllImport("libc", SetLastError = true)] internal static extern int fstatat(SafeFd fd, string name, IntPtr stat, int flags);
            [DllImport("libc", SetLastError = true)] internal static extern int flock(SafeFd fd, int operation);
            [DllImport("libc", SetLastError = true)] internal static extern int fchmod(SafeFd fd, uint mode);
            [DllImport("libc", SetLastError = true)] internal static extern int close(int fd);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr write(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr read(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport("libc", SetLastError = true)] internal static extern int unlinkat(SafeFd fd, string name, int flags);
            [DllImport("libc", SetLastError = true)] internal static extern int linkat(SafeFd fd, string name, SafeFd other, string link, int flags);
            [DllImport("libc", SetLastError = true)] internal static extern int symlinkat(string target, SafeFd fd, string name);
            [DllImport("libc", SetLastError = true)] internal static extern int fcntl(SafeFd fd, int command);
            [DllImport("libc", SetLastError = true)] internal static extern uint geteuid();
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr gnu_get_libc_version();
        }
        private static class Darwin
        {
            private const string Lib = "/usr/lib/libSystem.B.dylib";
            [DllImport(Lib, SetLastError = true)] internal static extern int openat(int fd, string name, int flags, uint mode);
            // Apple arm64 puts variadic arguments on the stack, unlike fixed arguments.
            // Fill x3..x7 so the ninth fixed argument occupies the first stack slot
            // consumed by openat's va_arg(mode_t). We pass ONLY zero here; fchmod
            // applies the requested mode through a non-variadic, handle-bound call.
            [DllImport(Lib, EntryPoint = "openat", SetLastError = true)]
            internal static extern int openatArm64Create(int fd, string name, int flags,
                IntPtr x3, IntPtr x4, IntPtr x5, IntPtr x6, IntPtr x7, uint stackMode);
            [DllImport(Lib, SetLastError = true)] internal static extern int mkdirat(SafeFd fd, string name, uint mode);
            [DllImport(Lib, SetLastError = true)] internal static extern int fstat(SafeFd fd, IntPtr stat);
            [DllImport(Lib, EntryPoint = "fstat$INODE64", SetLastError = true)] internal static extern int fstat64(SafeFd fd, IntPtr stat);
            [DllImport(Lib, SetLastError = true)] internal static extern int fstatat(SafeFd fd, string name, IntPtr stat, int flags);
            [DllImport(Lib, EntryPoint = "fstatat$INODE64", SetLastError = true)] internal static extern int fstatat64(SafeFd fd, string name, IntPtr stat, int flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int flock(SafeFd fd, int operation);
            [DllImport(Lib, SetLastError = true)] internal static extern int fchmod(SafeFd fd, uint mode);
            [DllImport(Lib, SetLastError = true)] internal static extern int close(int fd);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr write(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr read(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport(Lib, SetLastError = true)] internal static extern int unlinkat(SafeFd fd, string name, int flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int linkat(SafeFd fd, string name, SafeFd other, string link, int flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int symlinkat(string target, SafeFd fd, string name);
            // Only F_GETFD is used; it does not consume a variadic third argument.
            [DllImport(Lib, SetLastError = true)] internal static extern int fcntl(SafeFd fd, int command);
            [DllImport(Lib, SetLastError = true)] internal static extern uint geteuid();
        }

        private static bool Mac { get { return PlatformNative.GetOperatingSystem() == "macos"; } }
        private static bool X64 { get { return PlatformNative.GetArchitecture() == "x64"; } }
        // Linux aarch64 overrides asm-generic O_DIRECTORY/O_NOFOLLOW. Select by
        // both OS and architecture; these are NOT the Linux x86_64 values.
        private static int DirectoryFlags { get { return Mac ? 0x100000 : X64 ? 0x10000 : 0x4000; } }
        private static int NoFollow { get { return Mac ? 0x100 : X64 ? 0x20000 : 0x8000; } }
        private static int CloseOnExec { get { return Mac ? 0x1000000 : 0x80000; } }
        private static int Create { get { return Mac ? 0x200 : 0x40; } }
        private static int Exclusive { get { return Mac ? 0x800 : 0x80; } }
        private static int NonBlock { get { return Mac ? 0x4 : 0x800; } }
        private static int AtNoFollow { get { return Mac ? 0x20 : 0x100; } }
        private static int AtRemoveDirectory { get { return Mac ? 0x80 : 0x200; } }
        private static int AtCwd { get { return Mac ? -2 : -100; } }
        // flock values coincide in these ABIs, kept explicit in each selection.
        private static int LockShared { get { return Mac ? 1 : 1; } }
        private static int LockExclusive { get { return Mac ? 2 : 2; } }
        private static int LockNonBlock { get { return Mac ? 4 : 4; } }
        private static int LockUnlock { get { return Mac ? 8 : 8; } }
        private static readonly object AbiSync = new object();
        private static string abiEvidence;
        private static bool abiAttempted;
        private static Exception abiFailure;

        internal static int Close(int fd) { return Mac ? Darwin.close(fd) : Linux.close(fd); }
        private static void Check(int result, string operation)
        { if (result < 0) throw new PlatformErrnoException(operation, Marshal.GetLastWin32Error()); }

        // Retain a SafeHandle reference across raw-int openat, including concurrent Dispose.
        private static SafeFd Open(SafeFd parent, string name, int flags, uint mode)
        {
            bool held = false;
            try
            {
                if (parent != null) parent.DangerousAddRef(ref held);
                int fd = parent == null ? AtCwd : parent.DangerousGetHandle().ToInt32();
                bool creating = (flags & Create) != 0;
                if (creating && (flags & Exclusive) == 0) throw new ArgumentException("Creation must be exclusive before applying permissions.");
                int nativeFlags = flags | NoFollow | CloseOnExec;
                int result;
                if (Mac && !X64 && creating)
                    result = Darwin.openatArm64Create(fd, name, nativeFlags,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0);
                else result = Mac ? Darwin.openat(fd, name, nativeFlags, 0) : Linux.openat(fd, name, nativeFlags, 0);
                Check(result, "openat");
                SafeFd opened = new SafeFd(result);
                try
                {
                    if (creating)
                    {
                        // New inodes start with mode bits 0000, even in a non-private parent.
                        // ACL policy remains outside this mode-only primitive's contract.
                        // This also self-checks the ABI before a requested mode is applied.
                        FileObservation initial = Stat(opened, null);
                        PlatformPaths.Single(initial);
                        if ((initial.Mode & 4095) != 0) throw new IOException("openat initial mode must be 0000; creation ABI check failed.");
                        Chmod(opened, mode);
                        if ((Stat(opened, null).Mode & 4095) != mode) throw new IOException("Created file mode readback failed.");
                    }
                    return opened;
                }
                catch { opened.Dispose(); throw; }
            }
            finally { if (held) parent.DangerousRelease(); }
        }
        private static FileObservation Stat(SafeFd fd, string leaf)
        {
            // Oversized buffer also bounds writes before a layout passes the self-test.
            IntPtr buffer = Marshal.AllocHGlobal(512);
            try
            {
                for (int i = 0; i < 512; i += 8) Marshal.WriteInt64(buffer, i, 0);
                int result;
                if (!Mac) result = leaf == null ? Linux.fstat(fd, buffer) : Linux.fstatat(fd, leaf, buffer, AtNoFollow);
                else if (X64) result = leaf == null ? Darwin.fstat64(fd, buffer) : Darwin.fstatat64(fd, leaf, buffer, AtNoFollow);
                else result = leaf == null ? Darwin.fstat(fd, buffer) : Darwin.fstatat(fd, leaf, buffer, AtNoFollow);
                Check(result, leaf == null ? "fstat" : "fstatat");
                FileObservation value;
                if (Mac)
                {
                    DarwinStat s = (DarwinStat)Marshal.PtrToStructure(buffer, typeof(DarwinStat));
                    value = new FileObservation { Device = s.Dev, Inode = s.Ino, Mode = s.Mode, LinkCount = s.Nlink, Uid = s.Uid, Gid = s.Gid, Size = s.Size };
                }
                else if (X64)
                {
                    LinuxX64Stat s = (LinuxX64Stat)Marshal.PtrToStructure(buffer, typeof(LinuxX64Stat));
                    value = new FileObservation { Device = s.Dev, Inode = s.Ino, Mode = s.Mode, LinkCount = s.Nlink, Uid = s.Uid, Gid = s.Gid, Size = s.Size };
                }
                else
                {
                    LinuxArm64Stat s = (LinuxArm64Stat)Marshal.PtrToStructure(buffer, typeof(LinuxArm64Stat));
                    value = new FileObservation { Device = s.Dev, Inode = s.Ino, Mode = s.Mode, LinkCount = s.Nlink, Uid = s.Uid, Gid = s.Gid, Size = s.Size };
                }
                uint type = value.Mode & 0xf000;
                value.Kind = type == 0x8000 ? "file" : type == 0x4000 ? "directory" : "other";
                return value;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        private static void Chmod(SafeFd fd, uint mode) { Check(Mac ? Darwin.fchmod(fd, mode) : Linux.fchmod(fd, mode), "fchmod"); }
        private static void Unlink(SafeFd fd, string leaf, bool directory)
        { Check(Mac ? Darwin.unlinkat(fd, leaf, directory ? AtRemoveDirectory : 0) : Linux.unlinkat(fd, leaf, directory ? AtRemoveDirectory : 0), "unlinkat-probe-cleanup"); }
        private static SafeFd WalkRoot(string root)
        {
            if (String.IsNullOrEmpty(root) || !root.StartsWith("/") || root.IndexOf('\\') >= 0 || root.IndexOf('\0') >= 0)
                throw new ArgumentException("An absolute physical Unix root is required.");
            SafeFd current = Open(null, "/", DirectoryFlags, 0);
            try
            {
                if (root != "/") foreach (string part in PlatformPaths.Segments(root.Substring(1).TrimEnd('/')))
                {
                    SafeFd next = Open(current, part, DirectoryFlags, 0);
                    current.Dispose(); current = next;
                }
                SafeFd result = current; current = null; return result;
            }
            finally { if (current != null) current.Dispose(); }
        }
        private static SafeFd ChildDirectory(SafeFd parent, string leaf, bool create)
        {
            SafeFd child;
            bool created = false;
            try { child = Open(parent, leaf, DirectoryFlags, 0); }
            catch (PlatformErrnoException ex)
            {
                if (!create || ex.Errno != 2) throw;
                int result = Mac ? Darwin.mkdirat(parent, leaf, 448) : Linux.mkdirat(parent, leaf, 448);
                // EEXIST means a competing creator won. Re-open with NOFOLLOW, never adopt a symlink.
                if (result != 0 && Marshal.GetLastWin32Error() != 17) Check(result, "mkdirat");
                child = Open(parent, leaf, DirectoryFlags, 0);
                if (result == 0)
                {
                    created = true;
                    try { Chmod(child, 448); }
                    catch { child.Dispose(); throw; }
                }
            }
            try
            {
                FileObservation value = Stat(child, null);
                if (value.Kind != "directory") throw new IOException("Not a directory.");
                if (created && (value.Mode & 4095) != 448) throw new IOException("Private-directory mode readback failed.");
                PlatformPaths.Same(value, Stat(parent, leaf));
                return child;
            }
            catch { child.Dispose(); throw; }
        }

        public static string ValidateAbi()
        {
            lock (AbiSync)
            {
                if (abiAttempted)
                {
                    if (abiFailure != null) throw new PlatformCapabilityUnavailableException("unix-abi: " + abiFailure.Message, PlatformNative.GetOperatingSystem());
                    return abiEvidence;
                }
                abiAttempted = true;
                try
                {
                    string os = PlatformNative.GetOperatingSystem(), arch = PlatformNative.GetArchitecture();
                    if ((os != "linux" && os != "macos") || (arch != "x64" && arch != "arm64") ||
                        IntPtr.Size != 8 || !BitConverter.IsLittleEndian)
                        throw new PlatformCapabilityUnavailableException("unix-abi", os + "-" + arch);
                    if (!Mac && Linux.gnu_get_libc_version() == IntPtr.Zero) throw new IOException("glibc is required.");
                    MethodInfo getMode = typeof(File).GetMethod("GetUnixFileMode", new Type[] { typeof(string) });
                    if (getMode == null) throw new IOException("The runtime lacks independent UnixFileMode validation.");
                    string basePath = Mac ? "/private/tmp" : "/tmp";
                    string name = "platform-abi-" + Guid.NewGuid().ToString("N");
                    using (SafeFd parent = WalkRoot(basePath))
                    {
                        Check(Mac ? Darwin.mkdirat(parent, name, 448) : Linux.mkdirat(parent, name, 448), "mkdirat-probe");
                        try
                        {
                            using (SafeFd directory = ChildDirectory(parent, name, false))
                            {
                                using (SafeFd file = Open(directory, "probe", 2 | Create | Exclusive, 384))
                                {
                                    try
                                    {
                                        string path = basePath + "/" + name + "/probe";
                                        if ((Stat(file, null).Mode & 4095) != 384 ||
                                            Convert.ToUInt32(getMode.Invoke(null, new object[] { path })) != 384)
                                            throw new IOException("Created probe must have mode 0600 before any path-based I/O.");
                                        File.WriteAllBytes(path, new byte[173]);
                                        Chmod(file, 416); // 0640, independently read by .NET.
                                        FileObservation observed = Stat(file, null);
                                        PlatformPaths.Single(observed);
                                        PlatformPaths.Same(observed, Stat(directory, "probe"));
                                        if (observed.Inode == 0 || observed.Size != new FileInfo(path).Length || observed.Size != 173 ||
                                            (observed.Mode & 4095) != Convert.ToUInt32(getMode.Invoke(null, new object[] { path })) ||
                                            (observed.Mode & 4095) != 416 || observed.Uid != (Mac ? Darwin.geteuid() : Linux.geteuid()) ||
                                            observed.Gid != Stat(directory, null).Gid)
                                            throw new IOException("stat size/mode/uid/gid self-test failed.");
                                        Check(Mac ? Darwin.linkat(directory, "probe", directory, "alias", 0) : Linux.linkat(directory, "probe", directory, "alias", 0), "linkat-probe");
                                        try { if (Stat(file, null).LinkCount != 2) throw new IOException("stat nlink self-test failed."); }
                                        finally { Unlink(directory, "alias", false); }
                                        int fdFlags = Mac ? Darwin.fcntl(file, 1) : Linux.fcntl(file, 1); // F_GETFD
                                        Check(fdFlags, "fcntl-F_GETFD");
                                        if ((fdFlags & 1) == 0) throw new IOException("O_CLOEXEC self-test failed.");
                                        Check(Mac ? Darwin.symlinkat("probe", directory, "symlink") : Linux.symlinkat("probe", directory, "symlink"), "symlinkat-probe");
                                        try
                                        {
                                            if ((Stat(directory, "symlink").Mode & 0xf000) != 0xa000)
                                                throw new IOException("AT_SYMLINK_NOFOLLOW self-test failed.");
                                            bool refused = false;
                                            try { using (SafeFd unexpected = Open(directory, "symlink", 0, 0)) { } }
                                            catch (PlatformErrnoException ex) { if (ex.Errno != (Mac ? 62 : 40)) throw; refused = true; }
                                            if (!refused) throw new IOException("O_NOFOLLOW self-test failed.");
                                        }
                                        finally { Unlink(directory, "symlink", false); }
                                    }
                                    finally { Unlink(directory, "probe", false); }
                                }
                            }
                        }
                        finally { Unlink(parent, name, true); }
                    }
                    abiEvidence = os + "-" + arch + ": stat/fstatat size, type, mode, uid, gid, inode and nlink self-test passed; nofollow/cloexec passed; create mode 0000 -> 0600 verified";
                    return abiEvidence;
                }
                catch (Exception ex)
                {
                    abiFailure = ex;
                    throw new PlatformCapabilityUnavailableException("unix-abi: " + ex.Message, PlatformNative.GetOperatingSystem());
                }
            }
        }

        // Explicit existing absolute-directory anchor, including /. Relative paths
        // still require ordinary nonempty components; no traversal exception.
        public static UnixLease OpenDirectoryRoot(string root)
        {
            ValidateAbi();
            SafeFd directory = WalkRoot(root);
            try { return new UnixLease(directory, null, null, Path.GetFullPath(root), Stat(directory, null)); }
            catch { directory.Dispose(); throw; }
        }

        public static UnixLease OpenDirectory(string root, string relative, bool create)
        {
            string[] parts = PlatformPaths.Segments(relative);
            ValidateAbi();
            SafeFd current = WalkRoot(root), parent = null;
            try
            {
                foreach (string part in parts)
                {
                    SafeFd next = ChildDirectory(current, part, create);
                    if (parent != null) parent.Dispose(); parent = current; current = next;
                }
                string path = Path.GetFullPath(Path.Combine(root, String.Join("/", parts)));
                UnixLease result = new UnixLease(current, parent, parts[parts.Length - 1], path, Stat(current, null));
                current = null; parent = null; return result;
            }
            finally { if (current != null) current.Dispose(); if (parent != null) parent.Dispose(); }
        }
        public static UnixLease OpenFile(UnixLease parent, string leaf, string access, string createMode)
        {
            PlatformPaths.Leaf(leaf); ValidateAbi();
            int flags = access == "Read" ? 0 : access == "Write" ? 1 : access == "ReadWrite" ? 2 : -1;
            if (flags < 0) throw new ArgumentException("Access must be Read, Write or ReadWrite.");
            if (createMode == "CreateNew") flags |= Create | Exclusive;
            else if (createMode != "OpenExisting") throw new ArgumentException("CreateMode must be CreateNew or OpenExisting.");
            lock (parent.Sync)
            {
                parent.Check();
                AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                SafeFd duplicate = Open(parent.Fd, ".", DirectoryFlags, 0), file = null;
                try
                {
                    // O_NONBLOCK avoids hanging on a malicious FIFO before fstat rejects its type.
                    file = Open(duplicate, leaf, flags | NonBlock, 384);
                    FileObservation value = Stat(file, null);
                    PlatformPaths.Single(value);
                    PlatformPaths.Same(value, Stat(duplicate, leaf));
                    UnixLease result = new UnixLease(file, duplicate, leaf, Path.Combine(parent.Path, leaf), value);
                    result.NewWritable = createMode == "CreateNew" && access != "Read";
                    file = null; duplicate = null; return result;
                }
                finally { if (file != null) file.Dispose(); if (duplicate != null) duplicate.Dispose(); }
            }
        }
        private static UnixLease OpenPreparationSource(string path)
        {
            ValidateAbi();
            // Read-only source anchors may include OS aliases such as /var.
            // As in OpenFile, the leaf is opened NOFOLLOW | NONBLOCK and fstat
            // must prove a single-link regular file BEFORE any content read.
            string full = Path.GetFullPath(path);
            SafeFd file = Open(null, full, NonBlock, 0);
            try
            {
                FileObservation observed = Stat(file, null);
                PlatformPaths.Single(observed);
                return new UnixLease(file, null, null, full, observed);
            }
            catch { file.Dispose(); throw; }
        }
        public static void AssertRegularSourceFile(string path)
        {
            using (UnixLease file = OpenPreparationSource(path))
                AssertIdentity(file, file.Observation, true);
        }
        public static byte[] ReadPreparationFileBytes(string path)
        {
            using (UnixLease file = OpenPreparationSource(path))
            {
                long size = file.Observation.Size;
                if (size < 0 || size > Int32.MaxValue) throw new IOException("Source is too large for a private snapshot.");
                byte[] bytes = new byte[(int)size];
                GCHandle pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                try
                {
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        UIntPtr length = new UIntPtr((uint)Math.Min(65536, bytes.Length - offset));
                        IntPtr data = IntPtr.Add(pinned.AddrOfPinnedObject(), offset);
                        long count = (Mac ? Darwin.read(file.Fd, data, length) : Linux.read(file.Fd, data, length)).ToInt64();
                        if (count < 0)
                        {
                            int error = Marshal.GetLastWin32Error();
                            if (error == 4) continue; // EINTR
                            throw new PlatformErrnoException("read", error);
                        }
                        if (count == 0) throw new EndOfStreamException("Source changed during snapshot read.");
                        if (count > (long)length.ToUInt64()) throw new IOException("Invalid native read result.");
                        offset += (int)count;
                    }
                    if (AssertIdentity(file, file.Observation, true).Size != size)
                        throw new IOException("Source size changed during snapshot read.");
                    return bytes;
                }
                finally { pinned.Free(); }
            }
        }
        public static FileObservation AssertIdentity(UnixLease lease, FileObservation expected, bool single)
        {
            lock (lease.Sync)
            {
                lease.Check(); FileObservation value = Stat(lease.Fd, null);
                PlatformPaths.Same(value, expected);
                if (single) PlatformPaths.Single(value);
                if (lease.Parent != null) PlatformPaths.Same(value, Stat(lease.Parent, lease.Leaf));
                return value;
            }
        }
        public static string GetVerifiedPath(UnixLease lease)
        {
            lock (lease.Sync)
            {
                AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                // The retained parent may itself have been renamed. Re-walk ALL
                // pathname ancestors with NOFOLLOW and compare the final inode.
                // This is read/receipt evidence only, never authority for writes.
                string path = Path.GetFullPath(lease.Path);
                if (lease.Observation.Kind == "directory")
                {
                    using (SafeFd named = WalkRoot(path)) PlatformPaths.Same(Stat(named, null), lease.Observation);
                }
                else
                {
                    using (SafeFd parent = WalkRoot(Path.GetDirectoryName(path)))
                        PlatformPaths.Same(Stat(parent, Path.GetFileName(path)), lease.Observation);
                }
                return path;
            }
        }

        // P4 writes are rooted in the P2 directory descriptor. No cached pathname
        // is reopened for creation or writes, even if a same-account actor renames
        // an ancestor between validation and I/O (the cooperative A1 boundary).
        private static UnixLease OpenPreparationDirectory(UnixLease root, string relative, out FileObservation[] ancestors)
        {
            ancestors = null;
            AssertIdentity(root, root.Observation, false);
            if (root.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
            SafeFd current = Open(root.Fd, ".", DirectoryFlags, 0), parent = null;
            string leaf = root.Leaf, path = root.Path;
            List<FileObservation> observed = new List<FileObservation>();
            try
            {
                PlatformPaths.Same(Stat(current, null), root.Observation);
                observed.Add(root.Observation);
                if (!String.IsNullOrEmpty(relative)) foreach (string part in PlatformPaths.Segments(relative))
                {
                    SafeFd next = ChildDirectory(current, part, true);
                    if (parent != null) parent.Dispose();
                    parent = current; current = next; leaf = part; path = Path.Combine(path, part);
                    observed.Add(Stat(current, null));
                }
                UnixLease result = new UnixLease(current, parent, leaf, path, Stat(current, null));
                ancestors = observed.ToArray();
                current = null; parent = null; return result;
            }
            finally { if (current != null) current.Dispose(); if (parent != null) parent.Dispose(); }
        }

        private static void AssertPreparationDirectoryPath(UnixLease root, string relative, FileObservation[] ancestors, UnixLease directory)
        {
            string[] parts = String.IsNullOrEmpty(relative) ? new string[0] : PlatformPaths.Segments(relative);
            if (ancestors == null || ancestors.Length != parts.Length + 1)
                throw new IOException("Preparation directory ancestry evidence is incomplete.");
            GetVerifiedPath(root);
            SafeFd current = Open(root.Fd, ".", DirectoryFlags, 0);
            try
            {
                PlatformPaths.Same(Stat(current, null), ancestors[0]);
                for (int i = 0; i < parts.Length; i++)
                {
                    // Reopen from the retained root with NOFOLLOW, comparing
                    // EVERY component. Checking only the final c and parent b
                    // misses a moved/replaced a even if b/c keep their inodes.
                    SafeFd next = Open(current, parts[i], DirectoryFlags, 0);
                    try { PlatformPaths.Same(Stat(next, null), ancestors[i + 1]); }
                    catch { next.Dispose(); throw; }
                    current.Dispose(); current = next;
                }
                PlatformPaths.Same(Stat(current, null), directory.Observation);
                AssertIdentity(directory, directory.Observation, false);
                GetVerifiedPath(root);
            }
            finally { current.Dispose(); }
        }

        public static void CreatePreparationDirectory(UnixLease root, string relative)
        {
            PlatformPaths.Segments(relative);
            lock (root.Sync)
            {
                GetVerifiedPath(root);
                FileObservation[] ancestors;
                using (UnixLease directory = OpenPreparationDirectory(root, relative, out ancestors))
                    AssertPreparationDirectoryPath(root, relative, ancestors, directory);
            }
        }

        public static void WritePreparationFile(UnixLease root, string relative, Stream source)
        {
            string[] parts = PlatformPaths.Segments(relative);
            if (source == null || !source.CanRead) throw new ArgumentException("A readable payload stream is required.");
            string parentPath = String.Join("/", parts, 0, parts.Length - 1);
            lock (root.Sync)
            {
                GetVerifiedPath(root);
                FileObservation[] ancestors;
                using (UnixLease directory = OpenPreparationDirectory(root, parentPath, out ancestors))
                {
                    AssertPreparationDirectoryPath(root, parentPath, ancestors, directory);
                    using (UnixLease file = OpenFile(directory, parts[parts.Length - 1], "Write", "CreateNew"))
                    {
                        byte[] buffer = new byte[65536];
                        GCHandle pinned = GCHandle.Alloc(buffer, GCHandleType.Pinned);
                        try
                        {
                            int count;
                            while ((count = source.Read(buffer, 0, buffer.Length)) != 0)
                            {
                                int offset = 0;
                                while (offset < count)
                                {
                                    AssertPreparationDirectoryPath(root, parentPath, ancestors, directory);
                                    AssertIdentity(file, file.Observation, true);
                                    IntPtr data = IntPtr.Add(pinned.AddrOfPinnedObject(), offset);
                                    UIntPtr length = new UIntPtr((uint)(count - offset));
                                    long written = (Mac ? Darwin.write(file.Fd, data, length) : Linux.write(file.Fd, data, length)).ToInt64();
                                    if (written < 0)
                                    {
                                        int error = Marshal.GetLastWin32Error();
                                        if (error == 4) continue; // EINTR, no bytes written.
                                        throw new PlatformErrnoException("write", error);
                                    }
                                    if (written == 0 || written > count - offset) throw new IOException("Invalid native write result.");
                                    offset += (int)written;
                                }
                            }
                            // Read may rename a directory even when it returns EOF.
                            AssertPreparationDirectoryPath(root, parentPath, ancestors, directory);
                            AssertIdentity(file, file.Observation, true);
                        }
                        finally { pinned.Free(); }
                    }
                }
            }
        }
        private static int Flock(SafeFd fd, int operation)
        {
            try { return Mac ? Darwin.flock(fd, operation) : Linux.flock(fd, operation); }
            catch (EntryPointNotFoundException) { throw new PlatformCapabilityUnavailableException("flock-symbol", PlatformNative.GetOperatingSystem()); }
        }
        internal static void Unlock(SafeFd fd) { Flock(fd, LockUnlock); }
        private static void WaitForLockRetry(Stopwatch timer, TimeSpan timeout)
        {
            if (timer.Elapsed >= timeout) throw new TimeoutException("The platform lock deadline expired.");
            Thread.Sleep((int)Math.Min(20, Math.Max(1, (timeout - timer.Elapsed).TotalMilliseconds)));
            if (timer.Elapsed >= timeout) throw new TimeoutException("The platform lock deadline expired.");
        }
        private static FileObservation ObserveLockName(UnixLease parent, string leaf)
        {
            lock (parent.Sync)
            {
                parent.Check();
                AssertIdentity(parent, parent.Observation, false);
                FileObservation value = Stat(parent.Fd, leaf); // AT_SYMLINK_NOFOLLOW
                PlatformPaths.Single(value);
                return value;
            }
        }
        private static UnixLease OpenLockFile(UnixLease parent, string leaf, Stopwatch timer, TimeSpan timeout)
        {
            try { return OpenFile(parent, leaf, "ReadWrite", "CreateNew"); }
            catch (PlatformErrnoException ex) { if (ex.Errno != 17) throw; }

            FileObservation initializing = null;
            while (true)
            {
                FileObservation before = ObserveLockName(parent, leaf);
                if (initializing != null)
                {
                    PlatformPaths.Same(before, initializing);
                    if (before.Uid != initializing.Uid) throw new IOException("The initializing lock owner changed.");
                }
                try
                {
                    UnixLease lease = OpenFile(parent, leaf, "ReadWrite", "OpenExisting");
                    try { AssertIdentity(lease, before, true); return lease; }
                    catch { lease.Dispose(); throw; }
                }
                catch (PlatformErrnoException ex)
                {
                    if (ex.Errno != 13) throw;
                    FileObservation after = ObserveLockName(parent, leaf);
                    PlatformPaths.Same(after, before);
                    uint owner = Mac ? Darwin.geteuid() : Linux.geteuid();
                    uint beforeMode = before.Mode & 4095, afterMode = after.Mode & 4095;
                    // A cooperating creator exposes mode 0000 before fchmod(0600).
                    // Observe both sides of open so completion between EACCES and
                    // fstatat does not turn a legitimate race into a fatal denial.
                    // All other permission failures remain immediate; never chmod
                    // another participant's file or adopt a replacement while waiting.
                    if (before.Uid != owner || after.Uid != owner ||
                        (beforeMode != 0 && afterMode != 0) || (afterMode != 0 && afterMode != 384)) throw;
                    initializing = before;
                    WaitForLockRetry(timer, timeout);
                }
            }
        }
        public static UnixLease EnterLock(UnixLease parent, string leaf, string mode, TimeSpan timeout)
        {
            if (timeout < TimeSpan.Zero || (mode != "Shared" && mode != "Exclusive")) throw new ArgumentException("Invalid lock mode or timeout.");
            Stopwatch timer = Stopwatch.StartNew();
            // Never unlink on release. All participants must use flock on this fixed inode.
            UnixLease lease = OpenLockFile(parent, leaf, timer, timeout);
            try
            {
                while (Flock(lease.Fd, (mode == "Shared" ? LockShared : LockExclusive) | LockNonBlock) != 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != (Mac ? 35 : 11) && error != 4) throw new PlatformErrnoException("flock", error);
                    WaitForLockRetry(timer, timeout);
                }
                lease.Locked = true;
                AssertIdentity(lease, lease.Observation, true);
                return lease;
            }
            catch { lease.Dispose(); throw; }
        }
        public static FileObservation GetPermissions(UnixLease lease) { return AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file"); }
        public static FileObservation SetPermissions(UnixLease lease, uint mode)
        {
            if (mode > 4095) throw new ArgumentOutOfRangeException("mode");
            lock (lease.Sync)
            {
                GetPermissions(lease); Chmod(lease.Fd, mode);
                FileObservation value = GetPermissions(lease);
                if ((value.Mode & 4095) != mode) throw new IOException("Permission readback failed.");
                return value;
            }
        }
    }
}
