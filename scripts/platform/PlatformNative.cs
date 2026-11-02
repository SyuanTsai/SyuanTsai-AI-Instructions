// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.Runtime.InteropServices;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
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
