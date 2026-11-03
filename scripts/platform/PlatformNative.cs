// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.Runtime.InteropServices;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    // Bounded data I/O on a borrowed P2 handle; no public native handle or path reopen.
    internal static class LeaseBytes
    {
        internal static byte[] Read(SafeHandle handle, int maximumBytes)
        {
            if (maximumBytes < 0) throw new ArgumentOutOfRangeException("maximumBytes");
            using (var borrowed = new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), false))
            using (var stream = new System.IO.FileStream(borrowed, System.IO.FileAccess.Read))
            {
                if (stream.Length > maximumBytes) throw new System.IO.IOException("File exceeds the bounded read limit.");
                stream.Position = 0;
                byte[] bytes = new byte[checked((int)stream.Length)];
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int count = stream.Read(bytes, offset, bytes.Length - offset);
                    if (count == 0) throw new System.IO.EndOfStreamException();
                    offset += count;
                }
                if (stream.ReadByte() != -1) throw new System.IO.IOException("File grew during the bounded read.");
                return bytes;
            }
        }
        internal static void Write(SafeHandle handle, byte[] bytes)
        {
            if (bytes == null) throw new ArgumentNullException("bytes");
            using (var borrowed = new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), false))
            using (var stream = new System.IO.FileStream(borrowed, System.IO.FileAccess.Write))
            {
                if (stream.Length != 0) throw new System.IO.IOException("New evidence file is no longer empty.");
                stream.Position = 0; stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
            }
        }
    }

    public static class PlatformNative
    {
        public static string GetOperatingSystem()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return "windows";
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return "linux";
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return "macos";
            throw new PlatformCapabilityUnavailableException("operating-system", "unknown");
        }

        public static string GetArchitecture()
        {
            switch (RuntimeInformation.ProcessArchitecture)
            {
                case Architecture.X64: return "x64";
                case Architecture.X86: return "x86";
                case Architecture.Arm64: return "arm64";
                case Architecture.Arm: return "arm";
                default: throw new PlatformCapabilityUnavailableException(
                    "architecture", GetOperatingSystem());
            }
        }
    }

    public class PlatformCapabilityUnavailableException : InvalidOperationException
    {
        public string Capability { get; private set; }
        public string Platform { get; private set; }

        public PlatformCapabilityUnavailableException(string capability, string platform)
            : base(String.Format(
                "Platform capability '{0}' is not available on '{1}'.", capability, platform))
        {
            Capability = capability;
            Platform = platform;
        }

        protected PlatformCapabilityUnavailableException(
            string message, string capability, string platform) : base(message)
        {
            Capability = capability;
            Platform = platform;
        }
    }

    public sealed class PlatformNotImplementedException : PlatformCapabilityUnavailableException
    {
        public string ImplementationStep { get; private set; }

        public PlatformNotImplementedException(string capability, string platform, string implementationStep)
            : base(String.Format(
                "Platform capability '{0}' is not implemented on '{1}'; implementation is deferred to {2}.",
                capability, platform, implementationStep), capability, platform)
        {
            ImplementationStep = implementationStep;
        }
    }

    public sealed class PlatformErrnoException : InvalidOperationException
    {
        public int Errno { get; private set; }
        public string Operation { get; private set; }

        public PlatformErrnoException(string operation, int errno)
            : base(String.Format("Native operation '{0}' failed with errno {1}.", operation, errno))
        {
            Operation = operation;
            Errno = errno;
        }
    }

    public sealed class PlatformVerificationException : System.IO.IOException
    {
        public string Capability { get; private set; }
        public string Platform { get; private set; }

        public PlatformVerificationException(string capability, string platform, string message)
            : base(String.Format("Platform verification for '{0}' failed on '{1}': {2}", capability, platform, message))
        {
            Capability = capability;
            Platform = platform;
        }
    }

    public sealed class PlatformWin32Exception : InvalidOperationException
    {
        public int Win32Error { get; private set; }
        public string Operation { get; private set; }

        public PlatformWin32Exception(string operation, int win32Error)
            : base(String.Format("Native operation '{0}' failed with Win32 error {1}.", operation, win32Error))
        {
            Operation = operation;
            Win32Error = win32Error;
        }
    }
}
