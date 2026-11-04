// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    public sealed class WindowsPermissions
    {
        public string Sddl { get; internal set; }
        public bool ReadOnly { get; internal set; }
    }

    public sealed class WindowsLease : IDisposable
    {
        internal readonly object Sync = new object();
        internal SafeFileHandle Handle;
        internal string Path;
        private List<IDisposable> guards;
        private WindowsLease parent;
        private int references = 1;
        private bool disposed;
        public FileObservation Observation { get; internal set; }
        internal bool NewWritable;
        public byte[] ReadAllBytes(int maximumBytes)
        {
            lock (Sync)
            {
                Check(); WindowsNative.AssertIdentity(this, Observation, true);
                byte[] bytes = LeaseBytes.Read(Handle, maximumBytes);
                WindowsNative.AssertIdentity(this, Observation, true); return bytes;
            }
        }
        public void WriteNewBytes(byte[] bytes)
        {
            lock (Sync)
            {
                Check(); WindowsNative.AssertIdentity(this, Observation, true);
                if (!NewWritable) throw new InvalidOperationException("A fresh create-only writable lease is required.");
                NewWritable = false; LeaseBytes.Write(Handle, bytes);
                WindowsNative.AssertIdentity(this, Observation, true);
            }
        }
        internal WindowsLease(SafeFileHandle handle, string path, List<IDisposable> guards, WindowsLease parent, FileObservation observation)
        {
            Handle = handle; Path = path; this.guards = guards; this.parent = parent; Observation = observation;
            if (parent != null) parent.Retain();
        }
        internal void Check() { if (disposed) throw new ObjectDisposedException("WindowsLease"); }
        private void Retain() { lock (Sync) { Check(); references++; } }
        private void Release()
        {
            lock (Sync)
            {
                if (--references != 0) return;
                Handle.Dispose();
                if (guards != null) for (int i = guards.Count - 1; i >= 0; i--) guards[i].Dispose();
                if (parent != null) parent.Release();
            }
        }
        public void Dispose() { lock (Sync) { if (disposed) return; disposed = true; Release(); } }
    }

    public static class WindowsNative
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct Information
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicInfo { public long Creation, Access, Write, Change; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information information);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out BasicInfo information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref BasicInfo information, uint size);
        [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr LocalFree(IntPtr pointer);
        [DllImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ParseDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll", EntryPoint = "ConvertSecurityDescriptorToStringSecurityDescriptorW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FormatDescriptor(IntPtr descriptor, uint revision, uint information, out IntPtr text, out uint length);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, out bool present, out IntPtr dacl, out bool defaulted);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorControl(IntPtr descriptor, out ushort control, out uint revision);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern uint SetSecurityInfo(SafeFileHandle handle, int type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
        private static void Check(bool result, string operation) { if (!result) throw new PlatformWin32Exception(operation, Marshal.GetLastWin32Error()); }
        private static SafeFileHandle Open(string path, uint access, uint share, uint disposition)
        {
            SafeFileHandle handle = CreateFile(path, access, share, IntPtr.Zero, disposition, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new PlatformWin32Exception("CreateFileW", error);
            }
            return handle;
        }
        private static FileObservation Stat(SafeFileHandle handle)
        {
            Information value; Check(GetFileInformationByHandle(handle, out value), "GetFileInformationByHandle");
            if ((value.Attributes & 0x400) != 0) throw new IOException("Reparse points are forbidden.");
            return new FileObservation { Device = value.Volume, Inode = ((ulong)value.IndexHigh << 32) | value.IndexLow,
                LinkCount = value.Links, Size = ((long)value.SizeHigh << 32) | value.SizeLow,
                Mode = value.Attributes, Kind = (value.Attributes & 0x10) != 0 ? "directory" : "file" };
        }
        // Called only after verified installer-module guards cover EVERY path ancestor.
        // Ownership of guards transfers on success; the PowerShell adapter disposes them on failure.
        public static WindowsLease WrapDirectory(string path, IDisposable[] guards)
        {
            SafeFileHandle handle = Open(path, 0x20080, 3, 3);
            try
            {
                FileObservation value = Stat(handle);
                if (value.Kind != "directory") throw new IOException("Not a directory.");
                return new WindowsLease(handle, path, new List<IDisposable>(guards), null, value);
            }
            catch { handle.Dispose(); throw; }
        }
        public static void CreatePrivateDirectory(string path, string sddl)
        { CreatePrivateDirectory(path, sddl, false); }
        public static void CreatePrivateDirectory(string path, string sddl, bool createOnly)
        {
            IntPtr descriptor; uint size; Check(ParseDescriptor(sddl, 1, out descriptor, out size), "ParseSecurityDescriptor");
            try
            {
                SecurityAttributes attributes = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), Descriptor = descriptor };
                if (!CreateDirectory(path, ref attributes))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (createOnly || error != 183) throw new PlatformWin32Exception("CreateDirectoryW", error);
                }
            }
            finally { LocalFree(descriptor); }
        }
        public static WindowsLease OpenFile(WindowsLease parent, string leaf, string access, string createMode)
        { return OpenFileCore(parent, leaf, access, createMode, 1); }
        // Reacquire a complete no-reparse chain for a receipt's existing runtime.
        // Never create missing directories while validating an existing closure.
        public static WindowsLease OpenPreparationRoot(string path)
        {
            string full = Path.GetFullPath(path);
            if (full.Length < 3 || full[1] != ':' || full[2] != '\\') throw new ArgumentException("A local absolute drive path is required.");
            string root = Path.GetPathRoot(full);
            SafeFileHandle handle = Open(root, 0x80020080, 1, 3);
            WindowsLease current;
            try { current = new WindowsLease(handle, root, null, null, Stat(handle)); }
            catch { handle.Dispose(); throw; }
            try
            {
                string tail = full.Substring(root.Length).TrimEnd('\\');
                if (tail.Length != 0) foreach (string part in PlatformPaths.Segments(tail))
                {
                    WindowsLease next = OpenPreparationDirectory(current, part);
                    current.Dispose(); current = next;
                }
                WindowsLease result = current; current = null; return result;
            }
            finally { if (current != null) current.Dispose(); }
        }
        // Preparation extends the P2 lease chain one component at a time. Deny
        // both write and delete sharing: a held child cannot be renamed/replaced
        // or have a reparse tag installed while a descendant is being written.
        public static WindowsLease OpenPreparationDirectory(WindowsLease parent, string leaf)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                string path = Path.Combine(parent.Path, leaf);
                // Include directory data/list access: metadata-only handles do
                // not participate in Windows data/delete sharing arbitration.
                SafeFileHandle handle = Open(path, 0x80020080, 1, 3);
                try
                {
                    FileObservation value = Stat(handle);
                    if (value.Kind != "directory") throw new IOException("Not a directory.");
                    using (SafeFileHandle named = Open(path, 0, 7, 3)) PlatformPaths.Same(value, Stat(named));
                    return new WindowsLease(handle, path, null, parent, value);
                }
                catch { handle.Dispose(); throw; }
            }
        }
        private static WindowsLease OpenFileCore(WindowsLease parent, string leaf, string access, string createMode, uint share)
        {
            PlatformPaths.Leaf(leaf);
            uint desired = access == "Read" ? 0x80000000 : access == "Write" ? 0x40000000 : access == "ReadWrite" ? 0xc0000000 : 0;
            if (desired == 0) throw new ArgumentException("Access must be Read, Write or ReadWrite.");
            uint disposition = createMode == "CreateNew" ? 1u : createMode == "OpenExisting" ? 3u : 0u;
            if (disposition == 0) throw new ArgumentException("CreateMode must be CreateNew or OpenExisting.");
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                string path = System.IO.Path.Combine(parent.Path, leaf);
                SafeFileHandle handle = Open(path, desired | 0x20080, share, disposition);
                try
                {
                    FileObservation value = Stat(handle); PlatformPaths.Single(value);
                    using (SafeFileHandle named = Open(path, 0, 7, 3)) PlatformPaths.Same(value, Stat(named));
                    return new WindowsLease(handle, path, null, parent, value) { NewWritable = createMode == "CreateNew" && access != "Read" };
                }
                catch { handle.Dispose(); throw; }
            }
        }
        public static FileObservation AssertIdentity(WindowsLease lease, FileObservation expected, bool single)
        {
            lock (lease.Sync)
            {
                lease.Check(); FileObservation value = Stat(lease.Handle);
                PlatformPaths.Same(value, expected); if (single) PlatformPaths.Single(value);
                using (SafeFileHandle named = Open(lease.Path, 0, 7, 3)) PlatformPaths.Same(value, Stat(named));
                return value;
            }
        }
        public static string GetVerifiedPath(WindowsLease lease)
        {
            AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
            return Path.GetFullPath(lease.Path);
        }
        public static WindowsLease EnterLock(WindowsLease parent, string leaf, string mode, TimeSpan timeout)
        {
            if (timeout < TimeSpan.Zero || (mode != "Shared" && mode != "Exclusive")) throw new ArgumentException("Invalid lock mode or timeout.");
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                try
                {
                    try { return OpenFileCore(parent, leaf, mode == "Shared" ? "Read" : "ReadWrite", "CreateNew", mode == "Shared" ? 1u : 0u); }
                    catch (PlatformWin32Exception ex)
                    {
                        if (ex.Win32Error != 80 && ex.Win32Error != 183) throw;
                        return OpenFileCore(parent, leaf, mode == "Shared" ? "Read" : "ReadWrite", "OpenExisting", mode == "Shared" ? 1u : 0u);
                    }
                }
                catch (PlatformWin32Exception ex)
                {
                    if (ex.Win32Error != 32 && ex.Win32Error != 33) throw;
                    if (timer.Elapsed >= timeout) throw new TimeoutException("The platform lock deadline expired.");
                    Thread.Sleep((int)Math.Min(20, Math.Max(1, (timeout - timer.Elapsed).TotalMilliseconds)));
                }
            }
        }
        public static WindowsPermissions GetPermissions(WindowsLease lease)
        {
            lock (lease.Sync)
            {
                FileObservation observed = AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                IntPtr owner, group, dacl, sacl, descriptor;
                uint error = GetSecurityInfo(lease.Handle, 1, 4, out owner, out group, out dacl, out sacl, out descriptor);
                if (error != 0) throw new PlatformWin32Exception("GetSecurityInfo", (int)error);
                try
                {
                    IntPtr text; uint length; Check(FormatDescriptor(descriptor, 1, 4, out text, out length), "FormatSecurityDescriptor");
                    try { return new WindowsPermissions { Sddl = Marshal.PtrToStringUni(text), ReadOnly = (observed.Mode & 1) != 0 }; }
                    finally { LocalFree(text); }
                }
                finally { LocalFree(descriptor); }
            }
        }
        public static WindowsPermissions SetPermissions(WindowsLease lease, string sddl, bool? readOnly)
        {
            // PowerShell converts an unbound/null string argument to String.Empty.
            if (sddl == String.Empty) sddl = null;
            lock (lease.Sync)
            {
                AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                // SetSecurityInfo's DACL/inheritance path needs READ_CONTROL as well
                // as WRITE_DAC. The original lease retains its deny-write/delete share.
                using (SafeFileHandle writable = Open(lease.Path, (sddl == null ? 0u : 0x60000u) | (readOnly.HasValue ? 0x100u : 0u), 7, 3))
                {
                    PlatformPaths.Same(Stat(writable), lease.Observation);
                    if (sddl != null)
                    {
                        IntPtr descriptor; uint size; Check(ParseDescriptor(sddl, 1, out descriptor, out size), "ParseSecurityDescriptor");
                        try
                        {
                            bool present, defaulted; IntPtr dacl;
                            Check(GetSecurityDescriptorDacl(descriptor, out present, out dacl, out defaulted), "GetSecurityDescriptorDacl");
                            if (!present || dacl == IntPtr.Zero) throw new ArgumentException("An explicit non-null DACL is required.");
                            ushort control; uint revision;
                            Check(GetSecurityDescriptorControl(descriptor, out control, out revision), "GetSecurityDescriptorControl");
                            uint error = SetSecurityInfo(writable, 1, 4u | ((control & 0x1000) != 0 ? 0x80000000u : 0x20000000u), IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
                            if (error != 0) throw new PlatformWin32Exception("SetSecurityInfo", (int)error);
                        }
                        finally { LocalFree(descriptor); }
                    }
                    if (readOnly.HasValue)
                    {
                        BasicInfo value; uint size = (uint)Marshal.SizeOf(typeof(BasicInfo));
                        Check(GetFileInformationByHandleEx(writable, 0, out value, size), "GetFileInformationByHandleEx");
                        value.Attributes = readOnly.Value ? value.Attributes | 1 : value.Attributes & ~1u;
                        if (value.Attributes == 0) value.Attributes = 0x80;
                        Check(SetFileInformationByHandle(writable, 0, ref value, size), "SetFileInformationByHandle");
                    }
                }
                return GetPermissions(lease);
            }
        }
    }
}
