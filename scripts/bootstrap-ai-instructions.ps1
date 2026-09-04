[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SourceArchivePath,
    [string] $TargetRoot,
    [Parameter(Mandatory = $true)]
    [string] $ConfigurationPath,
    [Parameter(Mandatory = $true)]
    [string] $ProvenancePath,
    [string] $GitExecutable = 'git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($GitExecutable)) {
    throw 'GitExecutable must be a non-empty command name or path.'
}

$manifestRelativePath = '.codex/ai-instructions.manifest.json'
$excludeBeginMarker = '# BEGIN Codex AI Instructions managed paths'
$excludeEndMarker = '# END Codex AI Instructions managed paths'

Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ai-instructions-runtime-contract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'agent-artifact-remediation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'license-delivery.psm1') -Force

if (-not ('CodexAiInstructions.NativeFileMutation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexAiInstructions
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct FileDispositionInfo
    {
        [MarshalAs(UnmanagedType.Bool)]
        internal bool DeleteFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileBasicInfo
    {
        internal long CreationTime;
        internal long LastAccessTime;
        internal long LastWriteTime;
        internal long ChangeTime;
        internal uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ByHandleFileInformation
    {
        internal uint FileAttributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }

    public sealed class CreatedDirectoryIdentity
    {
        public string FullPath { get; private set; }
        public string RelativePath { get; private set; }
        public uint VolumeSerialNumber { get; private set; }
        public uint FileIndexHigh { get; private set; }
        public uint FileIndexLow { get; private set; }

        internal CreatedDirectoryIdentity(string fullPath, string relativePath, ByHandleFileInformation information)
        {
            FullPath = fullPath;
            RelativePath = relativePath;
            VolumeSerialNumber = information.VolumeSerialNumber;
            FileIndexHigh = information.FileIndexHigh;
            FileIndexLow = information.FileIndexLow;
        }
    }

    public sealed class AtomicCreateContext : IDisposable
    {
        private SafeFileHandle fileHandle;
        private List<SafeFileHandle> directoryHandles;

        public CreatedDirectoryIdentity[] CreatedDirectories { get; private set; }

        internal AtomicCreateContext(
            SafeFileHandle fileHandle,
            List<SafeFileHandle> directoryHandles,
            List<CreatedDirectoryIdentity> createdDirectories)
        {
            this.fileHandle = fileHandle;
            this.directoryHandles = directoryHandles;
            CreatedDirectories = createdDirectories.ToArray();
        }

        public SafeFileHandle TakeFileHandle()
        {
            if (fileHandle == null)
            {
                throw new InvalidOperationException("The atomic-create file handle has already been transferred.");
            }
            SafeFileHandle result = fileHandle;
            fileHandle = null;
            return result;
        }

        public void Dispose()
        {
            if (fileHandle != null)
            {
                fileHandle.Dispose();
                fileHandle = null;
            }
            if (directoryHandles != null)
            {
                for (int index = directoryHandles.Count - 1; index >= 0; index--)
                {
                    directoryHandles[index].Dispose();
                }
                directoryHandles = null;
            }
        }
    }

    public static class NativeFileMutation
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint Delete = 0x00010000;
        private const uint FileWriteAttributes = 0x00000100;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileAttributeReadOnly = 0x00000001;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const int FileBasicInfoClass = 0;
        private const int FileDispositionInfoClass = 4;
        private const int ErrorAlreadyExists = 183;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateDirectoryW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectory(string path, IntPtr securityAttributes);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileDispositionByHandle(
            SafeFileHandle file,
            int fileInformationClass,
            ref FileDispositionInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileBasicInfoByHandle(
            SafeFileHandle file,
            int fileInformationClass,
            ref FileBasicInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            int fileInformationClass,
            out FileBasicInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags);

        public static SafeFileHandle OpenForAtomicDelete(string targetRoot, string path, string relativePath)
        {
            return OpenValidatedTarget(
                targetRoot,
                path,
                relativePath,
                GenericRead | Delete | FileWriteAttributes,
                FileShareRead);
        }

        public static SafeFileHandle OpenForAtomicWrite(
            string targetRoot,
            string path,
            string relativePath,
            out bool restoreReadOnly)
        {
            restoreReadOnly = false;
            try
            {
                return OpenValidatedTarget(
                    targetRoot,
                    path,
                    relativePath,
                    GenericRead | GenericWrite | FileWriteAttributes,
                    FileShareRead);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode != 5)
                {
                    throw;
                }
            }

            SafeFileHandle attributeHandle = null;
            uint originalAttributes = 0;
            bool attributeCleared = false;
            try
            {
                attributeHandle = OpenValidatedTarget(
                    targetRoot,
                    path,
                    relativePath,
                    GenericRead | FileWriteAttributes,
                    FileShareRead | FileShareWrite);
                originalAttributes = GetAttributes(attributeHandle);
                if ((originalAttributes & FileAttributeReadOnly) == 0)
                {
                    throw new Win32Exception(5, "Unable to acquire an atomic managed-file write handle.");
                }
                SetAttributes(attributeHandle, originalAttributes & ~FileAttributeReadOnly);
                attributeCleared = true;

                SafeFileHandle writeHandle = null;
                try
                {
                    writeHandle = OpenValidatedTarget(
                        targetRoot,
                        path,
                        relativePath,
                        GenericRead | GenericWrite | FileWriteAttributes,
                        FileShareRead);
                    if (!AreSameFile(attributeHandle, writeHandle))
                    {
                        throw new IOException(
                            "The managed-file write handle did not reopen the same file whose read-only attribute was cleared.");
                    }
                    restoreReadOnly = true;
                    SafeFileHandle result = writeHandle;
                    writeHandle = null;
                    return result;
                }
                finally
                {
                    if (writeHandle != null)
                    {
                        writeHandle.Dispose();
                    }
                }
            }
            catch
            {
                restoreReadOnly = false;
                if (attributeCleared && attributeHandle != null && !attributeHandle.IsInvalid)
                {
                    SetAttributes(attributeHandle, originalAttributes);
                }
                throw;
            }
            finally
            {
                if (attributeHandle != null)
                {
                    attributeHandle.Dispose();
                }
            }
        }

        public static AtomicCreateContext OpenForAtomicCreate(
            string targetRoot,
            string path,
            string relativePath)
        {
            string safeRelativePath = NormalizeRelativePath(relativePath);
            string lexicalRoot = Path.GetFullPath(targetRoot).TrimEnd('\\');
            string lexicalPath = Path.GetFullPath(path);
            string expectedLexicalPath = Path.GetFullPath(Path.Combine(lexicalRoot, safeRelativePath));
            if (!string.Equals(lexicalPath, expectedLexicalPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The managed-file create path did not match the target-root relative path.");
            }

            List<SafeFileHandle> directoryHandles = new List<SafeFileHandle>();
            List<SafeFileHandle> createdDirectoryHandles = new List<SafeFileHandle>();
            List<CreatedDirectoryIdentity> createdDirectories = new List<CreatedDirectoryIdentity>();
            SafeFileHandle fileHandle = null;
            try
            {
                SafeFileHandle rootHandle = OpenValidatedDirectory(
                    lexicalRoot,
                    null,
                    GenericRead,
                    FileShareRead | FileShareWrite,
                    "Unable to open the managed target root for atomic creation.");
                directoryHandles.Add(rootHandle);
                string currentLexicalPath = lexicalRoot;
                string currentFinalPath = GetFinalPath(rootHandle).TrimEnd('\\');
                string[] segments = safeRelativePath.Split('\\');
                string currentRelativePath = string.Empty;
                for (int index = 0; index < segments.Length - 1; index++)
                {
                    string segment = segments[index];
                    currentRelativePath = currentRelativePath.Length == 0
                        ? segment
                        : currentRelativePath + "\\" + segment;
                    currentLexicalPath = Path.Combine(currentLexicalPath, segment);
                    bool created = CreateDirectory(currentLexicalPath, IntPtr.Zero);
                    if (!created)
                    {
                        int createError = Marshal.GetLastWin32Error();
                        if (createError != ErrorAlreadyExists)
                        {
                            throw new Win32Exception(createError, "Unable to create a managed target parent directory.");
                        }
                    }
                    string expectedDirectoryFinalPath = currentFinalPath + "\\" + segment;
                    SafeFileHandle directoryHandle = OpenValidatedDirectory(
                        currentLexicalPath,
                        expectedDirectoryFinalPath,
                        GenericRead | (created ? Delete | FileWriteAttributes : 0),
                        FileShareRead | FileShareWrite,
                        "Unable to guard a managed target parent directory.");
                    directoryHandles.Add(directoryHandle);
                    currentFinalPath = expectedDirectoryFinalPath;
                    if (created)
                    {
                        ByHandleFileInformation information = GetInformation(
                            directoryHandle,
                            "Unable to identify a transaction-created managed directory.");
                        createdDirectoryHandles.Add(directoryHandle);
                        createdDirectories.Add(new CreatedDirectoryIdentity(
                            currentLexicalPath,
                            currentRelativePath,
                            information));
                    }
                }

                fileHandle = CreateFile(
                    lexicalPath,
                    GenericRead | GenericWrite | Delete | FileWriteAttributes,
                    FileShareRead,
                    IntPtr.Zero,
                    CreateNew,
                    FileAttributeNormal | FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                EnsureValidHandle(fileHandle, "Unable to acquire an atomic managed-file creation handle.");
                ValidateFileHandle(
                    fileHandle,
                    currentFinalPath + "\\" + segments[segments.Length - 1],
                    "managed-file creation");

                AtomicCreateContext result = new AtomicCreateContext(
                    fileHandle,
                    directoryHandles,
                    createdDirectories);
                fileHandle = null;
                directoryHandles = null;
                return result;
            }
            catch
            {
                if (fileHandle != null && !fileHandle.IsInvalid)
                {
                    try { MarkDeleteOnClose(fileHandle); }
                    catch { }
                    fileHandle.Dispose();
                    fileHandle = null;
                }
                for (int index = createdDirectoryHandles.Count - 1; index >= 0; index--)
                {
                    SafeFileHandle createdHandle = createdDirectoryHandles[index];
                    try { MarkDeleteOnClose(createdHandle); }
                    catch { }
                    createdHandle.Dispose();
                }
                throw;
            }
            finally
            {
                if (fileHandle != null)
                {
                    fileHandle.Dispose();
                }
                if (directoryHandles != null)
                {
                    for (int index = directoryHandles.Count - 1; index >= 0; index--)
                    {
                        directoryHandles[index].Dispose();
                    }
                }
            }
        }

        public static SafeFileHandle OpenCreatedDirectoryForAtomicDelete(
            string targetRoot,
            string path,
            string relativePath,
            uint volumeSerialNumber,
            uint fileIndexHigh,
            uint fileIndexLow)
        {
            string safeRelativePath = NormalizeRelativePath(relativePath);
            string lexicalRoot = Path.GetFullPath(targetRoot).TrimEnd('\\');
            string lexicalPath = Path.GetFullPath(path);
            string expectedLexicalPath = Path.GetFullPath(Path.Combine(lexicalRoot, safeRelativePath));
            if (!string.Equals(lexicalPath, expectedLexicalPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The rollback directory path did not match the target-root relative path.");
            }

            List<SafeFileHandle> ancestorHandles = new List<SafeFileHandle>();
            SafeFileHandle resultHandle = null;
            try
            {
                SafeFileHandle rootHandle = OpenValidatedDirectory(
                    lexicalRoot,
                    null,
                    GenericRead,
                    FileShareRead | FileShareWrite,
                    "Unable to open the managed target root for rollback directory cleanup.");
                ancestorHandles.Add(rootHandle);
                string currentLexicalPath = lexicalRoot;
                string currentFinalPath = GetFinalPath(rootHandle).TrimEnd('\\');
                string[] segments = safeRelativePath.Split('\\');
                for (int index = 0; index < segments.Length; index++)
                {
                    currentLexicalPath = Path.Combine(currentLexicalPath, segments[index]);
                    currentFinalPath = currentFinalPath + "\\" + segments[index];
                    bool isTarget = index == segments.Length - 1;
                    SafeFileHandle directoryHandle = OpenValidatedDirectory(
                        currentLexicalPath,
                        currentFinalPath,
                        GenericRead | (isTarget ? Delete | FileWriteAttributes : 0),
                        FileShareRead | FileShareWrite,
                        "Unable to guard a rollback directory.");
                    if (isTarget)
                    {
                        ByHandleFileInformation information = GetInformation(
                            directoryHandle,
                            "Unable to identify a rollback directory.");
                        if (information.VolumeSerialNumber != volumeSerialNumber ||
                            information.FileIndexHigh != fileIndexHigh ||
                            information.FileIndexLow != fileIndexLow)
                        {
                            directoryHandle.Dispose();
                            throw new IOException("The rollback directory changed concurrently; its current identity was preserved.");
                        }
                        resultHandle = directoryHandle;
                    }
                    else
                    {
                        ancestorHandles.Add(directoryHandle);
                    }
                }
                SafeFileHandle result = resultHandle;
                resultHandle = null;
                return result;
            }
            finally
            {
                if (resultHandle != null)
                {
                    resultHandle.Dispose();
                }
                for (int index = ancestorHandles.Count - 1; index >= 0; index--)
                {
                    ancestorHandles[index].Dispose();
                }
            }
        }

        private static SafeFileHandle OpenValidatedTarget(
            string targetRoot,
            string path,
            string relativePath,
            uint desiredAccess,
            uint shareMode)
        {
            string safeRelativePath = NormalizeRelativePath(relativePath);
            SafeFileHandle rootHandle = CreateFile(
                targetRoot,
                GenericRead,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            try
            {
                EnsureValidHandle(rootHandle, "Unable to open the managed target root for handle-bound validation.");
                ByHandleFileInformation rootInformation = GetInformation(
                    rootHandle,
                    "Unable to inspect the managed target-root handle.");
                if ((rootInformation.FileAttributes & FileAttributeReparsePoint) != 0 ||
                    (rootInformation.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new IOException("The managed target root must be a non-reparse directory.");
                }
                string rootFinalPath = GetFinalPath(rootHandle).TrimEnd('\\');

                SafeFileHandle handle = CreateFile(
                    path,
                    desiredAccess,
                    shareMode,
                    IntPtr.Zero,
                    OpenExisting,
                    FileAttributeNormal | FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                try
                {
                    EnsureValidHandle(handle, "Unable to acquire an atomic managed-file mutation handle.");
                    ValidateFileHandle(handle, rootFinalPath + "\\" + safeRelativePath, "managed-file mutation");
                    return handle;
                }
                catch
                {
                    handle.Dispose();
                    throw;
                }
            }
            finally
            {
                rootHandle.Dispose();
            }
        }

        private static SafeFileHandle OpenValidatedDirectory(
            string path,
            string expectedFinalPath,
            uint desiredAccess,
            uint shareMode,
            string errorMessage)
        {
            SafeFileHandle handle = CreateFile(
                path,
                desiredAccess,
                shareMode,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, errorMessage);
                ByHandleFileInformation information = GetInformation(handle, "Unable to inspect a guarded managed directory.");
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
                {
                    throw new IOException("A guarded managed directory resolves to a reparse point.");
                }
                if ((information.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new IOException("A guarded managed directory path is not a directory.");
                }
                if (expectedFinalPath != null)
                {
                    string actualFinalPath = GetFinalPath(handle).TrimEnd('\\');
                    if (!string.Equals(expectedFinalPath, actualFinalPath, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new IOException(
                            "A guarded managed directory resolved outside the expected target-root path. Expected '" +
                            expectedFinalPath + "' but opened '" + actualFinalPath + "'.");
                    }
                }
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        private static void ValidateFileHandle(SafeFileHandle handle, string expectedFinalPath, string operation)
        {
            ByHandleFileInformation information = GetInformation(
                handle,
                "Unable to inspect the " + operation + " handle.");
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                throw new IOException("The " + operation + " handle resolves to a reparse point.");
            }
            if ((information.FileAttributes & FileAttributeDirectory) != 0)
            {
                throw new IOException("The " + operation + " handle did not open a regular file.");
            }
            if (information.NumberOfLinks != 1)
            {
                throw new IOException(
                    "The " + operation + " handle has multiple file-system links; hard link aliases do not provide exclusive ownership.");
            }
            string actualFinalPath = GetFinalPath(handle).TrimEnd('\\');
            if (!string.Equals(expectedFinalPath, actualFinalPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException(
                    "The " + operation + " handle resolved outside the expected target-root path. Expected '" +
                    expectedFinalPath + "' but opened '" + actualFinalPath + "'.");
            }
        }

        private static ByHandleFileInformation GetInformation(SafeFileHandle handle, string message)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), message);
            }
            return information;
        }

        public static void MarkDeleteOnClose(SafeFileHandle handle)
        {
            uint originalAttributes = GetAttributes(handle);
            bool restoreReadOnly = (originalAttributes & FileAttributeReadOnly) != 0;
            if (restoreReadOnly)
            {
                SetAttributes(handle, originalAttributes & ~FileAttributeReadOnly);
            }
            try
            {
                FileDispositionInfo information = new FileDispositionInfo { DeleteFile = true };
                uint size = (uint)Marshal.SizeOf(typeof(FileDispositionInfo));
                if (!SetFileDispositionByHandle(handle, FileDispositionInfoClass, ref information, size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to mark the managed file for atomic deletion.");
                }
            }
            catch
            {
                if (restoreReadOnly)
                {
                    SetAttributes(handle, originalAttributes);
                }
                throw;
            }
        }

        public static void RestoreReadOnly(SafeFileHandle handle)
        {
            uint attributes = GetAttributes(handle);
            if ((attributes & FileAttributeReadOnly) == 0)
            {
                SetAttributes(handle, (attributes & ~FileAttributeNormal) | FileAttributeReadOnly);
            }
        }

        private static bool AreSameFile(SafeFileHandle first, SafeFileHandle second)
        {
            ByHandleFileInformation firstInformation;
            if (!GetFileInformationByHandle(first, out firstInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to identify the read-only managed-file handle.");
            }
            ByHandleFileInformation secondInformation;
            if (!GetFileInformationByHandle(second, out secondInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to identify the reopened managed-file write handle.");
            }
            return firstInformation.VolumeSerialNumber == secondInformation.VolumeSerialNumber &&
                firstInformation.FileIndexHigh == secondInformation.FileIndexHigh &&
                firstInformation.FileIndexLow == secondInformation.FileIndexLow;
        }

        private static uint GetAttributes(SafeFileHandle handle)
        {
            FileBasicInfo information;
            uint size = (uint)Marshal.SizeOf(typeof(FileBasicInfo));
            if (!GetFileInformationByHandleEx(handle, FileBasicInfoClass, out information, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read managed-file attributes from the mutation handle.");
            }
            return information.FileAttributes;
        }

        private static void SetAttributes(SafeFileHandle handle, uint attributes)
        {
            FileBasicInfo information;
            uint size = (uint)Marshal.SizeOf(typeof(FileBasicInfo));
            if (!GetFileInformationByHandleEx(handle, FileBasicInfoClass, out information, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read managed-file attributes from the mutation handle.");
            }
            information.FileAttributes = attributes == 0 ? FileAttributeNormal : attributes;
            if (!SetFileBasicInfoByHandle(handle, FileBasicInfoClass, ref information, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to update managed-file attributes through the mutation handle.");
            }
        }

        private static string GetFinalPath(SafeFileHandle handle)
        {
            uint capacity = 32768;
            StringBuilder path = new StringBuilder((int)capacity);
            uint length = GetFinalPathNameByHandle(handle, path, capacity, 0);
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve a handle-bound managed-file path.");
            }
            if (length >= capacity)
            {
                capacity = length + 1;
                path = new StringBuilder((int)capacity);
                length = GetFinalPathNameByHandle(handle, path, capacity, 0);
                if (length == 0 || length >= capacity)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve a complete handle-bound managed-file path.");
                }
            }
            return path.ToString().Replace('/', '\\');
        }

        private static string NormalizeRelativePath(string relativePath)
        {
            if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath))
            {
                throw new ArgumentException("Managed-file handle validation requires a safe relative path.", "relativePath");
            }
            string[] segments = relativePath.Replace('/', '\\').Split('\\');
            foreach (string segment in segments)
            {
                if (string.IsNullOrWhiteSpace(segment) || segment == "." || segment == "..")
                {
                    throw new ArgumentException("Managed-file handle validation rejected an unsafe relative path.", "relativePath");
                }
            }
            return string.Join("\\", segments);
        }

        private static void EnsureValidHandle(SafeFileHandle handle, string message)
        {
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, message);
            }
        }
    }
}
'@
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $GitExecutable -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Get-GitExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & $GitExecutable -C $Repository @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-FullPathWithoutTrailingSeparator {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($rootPath) -and
        $fullPath.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase)) {
        return $rootPath
    }
    return $fullPath.TrimEnd([char[]]@('\', '/'))
}

function Get-NormalizedRepositoryLocation {
    param([Parameter(Mandatory = $true)][string] $RepositoryUrl)

    $trimmedUrl = $RepositoryUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedUrl)) {
        throw 'Repository URL cannot be empty.'
    }

    $hostName = $null
    $repositoryPath = $null
    $absoluteUri = $null
    if ([System.Uri]::TryCreate($trimmedUrl, [System.UriKind]::Absolute, [ref] $absoluteUri) -and
        -not [string]::IsNullOrWhiteSpace($absoluteUri.Host)) {
        $hostName = $absoluteUri.Host
        $repositoryPath = $absoluteUri.AbsolutePath
    }
    elseif ($trimmedUrl -match '^(?:[^@/]+@)?(?<Host>[^:/]+):(?<Path>.+)$') {
        $hostName = $Matches.Host
        $repositoryPath = $Matches.Path
    }
    else {
        throw "Repository URL must identify a remote Git repository: $RepositoryUrl"
    }

    $normalizedPath = $repositoryPath.Trim([char[]]@('/', '\'))
    if ($normalizedPath.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedPath = $normalizedPath.Substring(0, $normalizedPath.Length - 4)
    }

    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        throw "Repository URL does not contain a repository path: $RepositoryUrl"
    }

    return "$($hostName.ToLowerInvariant())/$normalizedPath"
}

function Test-RepositoryLocationMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryLocation,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ConfiguredRepositoryLocations
    )

    foreach ($configuredRepositoryLocation in $ConfiguredRepositoryLocations) {
        if ($RepositoryLocation.Equals($configuredRepositoryLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-NormalizedRepositoryRelativeDirectoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $trimmedPath = $Path.Trim().Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        throw 'Repository-relative directory path cannot be empty.'
    }

    if ([System.IO.Path]::IsPathRooted($Path) -or $trimmedPath -match '^[A-Za-z]:') {
        throw "Repository-relative directory path must not be rooted: $Path"
    }

    $parts = @($trimmedPath -split '/+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..') {
            throw "Repository-relative directory path must not contain . or .. segments: $Path"
        }
    }

    return $parts -join '/'
}

function Test-RepositoryDirectoryMatches {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RepositoryRelativePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ConfiguredRepositoryPaths
    )

    foreach ($configuredRepositoryPath in $ConfiguredRepositoryPaths) {
        if ($RepositoryRelativePath.Equals($configuredRepositoryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $RepositoryRelativePath.StartsWith("$configuredRepositoryPath/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $FullPath
    )

    return $FullPath.Substring($RepositoryRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
}

function Get-NormalizedContentHash {
    param([Parameter(Mandatory = $true)][string] $Path)

    $content = [System.IO.File]::ReadAllText($Path)
    $normalizedContent = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $contentBytes = $utf8WithoutBom.GetBytes($normalizedContent)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($contentBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-RawContentHash {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-ManagedContentHash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath
    )

    if ($TargetPath.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal) -or (Test-InstructionLicenseDeliveryPath $TargetPath)) {
        return Get-RawContentHash -Path $Path
    }

    return Get-NormalizedContentHash -Path $Path
}

function Test-IsAllowedManagedPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-InstructionLicenseDeliveryPath $Path) { return $true }

    if ($Path -eq 'AGENTS.md' -or
        $Path -eq '.github/copilot-instructions.md' -or
        $Path -match '^\.codex/AI-Rules/[^/\\]+\.en\.md$' -or
        $Path -match '^\.github/AI-Rules/[^/\\]+\.en\.md$') {
        return $true
    }

    if (-not $Path.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal)) {
        return $false
    }

    $skillPathParts = @($Path.Substring('.agents/skills/'.Length) -split '/')
    if ($skillPathParts.Count -lt 2 -or
        $skillPathParts[0] -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        return $false
    }

    foreach ($skillPathPart in $skillPathParts) {
        if ([string]::IsNullOrWhiteSpace($skillPathPart) -or
            $skillPathPart -eq '.' -or
            $skillPathPart -eq '..' -or
            $skillPathPart.Contains('\')) {
            return $false
        }
    }

    return $true
}

function ConvertFrom-GitQuotedPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not ($Path.Length -ge 2 -and $Path[0] -eq '"' -and $Path[$Path.Length - 1] -eq '"')) {
        return $Path
    }

    $bytes = New-Object System.Collections.Generic.List[byte]
    $content = $Path.Substring(1,$Path.Length - 2)
    for ($index = 0; $index -lt $content.Length; $index++) {
        $character = $content[$index]
        if ($character -ne '\') {
            if ([int]$character -gt 0x7f) { throw "Git returned a non-ASCII byte in a quoted path: $Path" }
            $bytes.Add([byte][int]$character)
            continue
        }
        if (++$index -ge $content.Length) { throw "Git returned an incomplete quoted path escape: $Path" }
        $escape = $content[$index]
        $simpleEscapes = @{ 'a'=0x07; 'b'=0x08; 't'=0x09; 'n'=0x0a; 'v'=0x0b; 'f'=0x0c; 'r'=0x0d; '"'=0x22; '\'=0x5c }
        $escapeText = [string]$escape
        if ($simpleEscapes.ContainsKey($escapeText)) {
            $bytes.Add([byte]$simpleEscapes[$escapeText])
            continue
        }
        if ($escape -lt '0' -or $escape -gt '7' -or $index + 2 -ge $content.Length) {
            throw "Git returned an unsupported quoted path escape: $Path"
        }
        $octal = $content.Substring($index,3)
        if ($octal -cnotmatch '^[0-7]{3}$') { throw "Git returned an invalid octal path escape: $Path" }
        $bytes.Add([byte][Convert]::ToInt32($octal,8))
        $index += 2
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try { return $utf8.GetString($bytes.ToArray()) }
    catch { throw "Git returned a quoted path that is not valid UTF-8: $Path" }
}

function Test-IsCanonicalInstructionSourceRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)

    if ((Get-GitExitCode -Repository $Repository -Arguments @('remote','get-url','origin')) -ne 0) { return $false }
    foreach ($originUrl in @(Invoke-Git -Repository $Repository -Arguments @('remote','get-url','--all','origin'))) {
        try {
            Assert-AiInstructionsCanonicalRepository -Repository ([string]$originUrl)
            return $true
        }
        catch { }
    }
    return $false
}

function Get-GitInfoExcludePath {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $path = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-path','info/exclude')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Repository $path }
    return [System.IO.Path]::GetFullPath($path)
}

function Assert-GitInfoExcludeMutationPath {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $commonGitDirectory = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $Repository $commonGitDirectory }
    $commonGitDirectory = [System.IO.Path]::GetFullPath($commonGitDirectory).TrimEnd([char[]]@('\','/'))
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $commonGitDirectory 'info\exclude'))
    if (-not $resolvedPath.Equals($expectedPath,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe shared Git exclude mutation path '$resolvedPath': expected '$expectedPath'."
    }

    $inspectionPath = $resolvedPath
    while ($true) {
        if (Test-Path -LiteralPath $inspectionPath) {
            $item = Get-Item -Force -LiteralPath $inspectionPath
            $isLeaf = $inspectionPath.Equals($resolvedPath,[System.StringComparison]::OrdinalIgnoreCase)
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or ($isLeaf -and $item.PSIsContainer) -or (-not $isLeaf -and -not $item.PSIsContainer)) {
                throw "Unsafe shared Git exclude mutation path '$resolvedPath': '$inspectionPath' must be a non-reparse $($(if ($isLeaf) { 'file' } else { 'directory' }))."
            }
        }
        if ($inspectionPath.Equals($commonGitDirectory,[System.StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $inspectionPath
        if ([string]::IsNullOrWhiteSpace($parent) -or -not $parent.StartsWith($commonGitDirectory,[System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe shared Git exclude mutation path '$resolvedPath': parent traversal escaped the common Git directory."
        }
        $inspectionPath = $parent
    }
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Value)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-GitPathComparer {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $ignoreCase = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ((Get-GitExitCode -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase')) -eq 0) {
        $configured = ((Invoke-Git -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase')) | Select-Object -First 1).Trim()
        if ($configured -ceq 'true') { $ignoreCase = $true }
    }
    if ($ignoreCase) { return [System.StringComparer]::OrdinalIgnoreCase }
    return [System.StringComparer]::Ordinal
}

function Open-RepositoryOperationLock {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $commonGitDirectory = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-common-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) { $commonGitDirectory = Join-Path $Repository $commonGitDirectory }
    $lockPath = Join-Path ([System.IO.Path]::GetFullPath($commonGitDirectory)) 'codex-ai-instructions.lock'
    try {
        return [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw 'Another AI instruction repository operation is already running; bootstrap stopped before mutation.'
    }
}

function Open-RepositoryIndexTransactionLock {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $gitDirectory = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $Repository $gitDirectory }
    $gitDirectory = [System.IO.Path]::GetFullPath($gitDirectory).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) { throw "Git directory is missing or invalid: $gitDirectory" }
    $gitDirectoryItem = Get-Item -Force -LiteralPath $gitDirectory
    if (($gitDirectoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Git directory must not be a reparse point: $gitDirectory"
    }

    $indexPath = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-path','index')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $Repository $indexPath }
    $indexPath = [System.IO.Path]::GetFullPath($indexPath)
    $expectedIndexPath = [System.IO.Path]::GetFullPath((Join-Path $gitDirectory 'index'))
    if (-not $indexPath.Equals($expectedIndexPath,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Git index path is outside the active worktree Git directory: $indexPath"
    }
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "Git index file is missing: $indexPath" }
    $indexItem = Get-Item -Force -LiteralPath $indexPath
    if (($indexItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Git index file must not be a reparse point: $indexPath"
    }

    $lockPath = $indexPath + '.lock'
    try {
        $stream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw 'The Git index is being changed by another process; bootstrap stopped before index preflight.'
    }
    return [pscustomobject][ordered]@{ Stream=$stream; Path=$lockPath; IndexPath=$indexPath }
}

function Assert-ManagedPathDoesNotCrossReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $resolvedRoot = Get-FullPathWithoutTrailingSeparator -Path $Root
    $rootPrefix = $resolvedRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) { throw "$Context is outside its worktree: $resolvedPath" }
    $inspectionPath = $resolvedPath
    while ($inspectionPath.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $inspectionPath) {
            $item = Get-Item -Force -LiteralPath $inspectionPath
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context crosses a reparse point: $inspectionPath" }
        }
        $inspectionPath = Split-Path -Parent $inspectionPath
    }
}

function Get-SharedManagedExcludePaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $CurrentManagedPaths
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($currentManagedPath in $CurrentManagedPaths) { [void]$paths.Add($currentManagedPath.Replace('\','/')) }
    foreach ($line in @(Invoke-Git -Repository $Repository -Arguments @('worktree','list','--porcelain'))) {
        $text = [string]$line
        if (-not $text.StartsWith('worktree ',[System.StringComparison]::Ordinal)) { continue }
        $worktreeRoot = $text.Substring('worktree '.Length)
        $worktreeManifestPath = Join-Path $worktreeRoot $manifestRelativePath.Replace('/','\')
        if (-not (Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf)) { continue }
        Assert-ManagedPathDoesNotCrossReparsePoint -Root $worktreeRoot -Path $worktreeManifestPath -Context 'Linked worktree managed manifest'
        try {
            $worktreeManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $worktreeManifestPath | ConvertFrom-Json
            $worktreeManifestSchemaVersion = $worktreeManifest.schemaVersion
            if ($worktreeManifestSchemaVersion -isnot [int] -and $worktreeManifestSchemaVersion -isnot [long]) {
                throw 'schemaVersion must be an integer.'
            }
            if ($worktreeManifestSchemaVersion -eq 2) { Assert-ManagedManifestV2 -Manifest $worktreeManifest }
            elseif ($worktreeManifestSchemaVersion -eq 1) { Assert-LegacyManagedManifestV1 -Manifest $worktreeManifest }
            else {
                throw "unsupported schemaVersion '$worktreeManifestSchemaVersion'."
            }
        }
        catch {
            throw "Cannot compose shared Git exclusions because a linked worktree manifest is invalid: $worktreeManifestPath. $($_.Exception.Message)"
        }
        [void]$paths.Add($manifestRelativePath)
        foreach ($entry in @($worktreeManifest.files)) {
            $targetPath = [string]$entry.targetPath
            if (-not (Test-IsAllowedManagedPath -Path $targetPath)) {
                throw "Cannot compose shared Git exclusions because a linked worktree manifest contains an unsafe path: $targetPath"
            }
            [void]$paths.Add($targetPath)
        }
    }
    return @($paths | Sort-Object)
}

function New-GitInfoExcludeSnapshot {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $path = Get-GitInfoExcludePath -Repository $Repository
    Assert-GitInfoExcludeMutationPath -Repository $Repository -Path $path
    return [pscustomobject][ordered]@{
        Path = $path
        Repository = $Repository
        MutationApplied = $false
        Existed = $false
        Bytes = $null
        AppliedBytes = $null
    }
}

function Test-GitInfoExcludeBytesEqual {
    param(
        [AllowNull()][byte[]] $Left,
        [AllowNull()][byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Read-GitInfoExcludeStreamBytes {
    param([Parameter(Mandatory = $true)][System.IO.FileStream] $Stream)

    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.Position = 0
        $Stream.CopyTo($memory)
        return ,([byte[]]$memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function ConvertFrom-GitInfoExcludeBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)

    $memory = New-Object System.IO.MemoryStream
    $reader = $null
    try {
        if ($Bytes.Length -gt 0) { $memory.Write($Bytes,0,$Bytes.Length) }
        $memory.Position = 0
        $reader = New-Object System.IO.StreamReader($memory,[System.Text.Encoding]::UTF8,$true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $memory.Dispose()
    }
}

function Write-GitInfoExcludeStreamBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $Stream.Position = 0
    $Stream.SetLength(0)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes,0,$Bytes.Length) }
    $Stream.Flush($true)
}

function Open-GitInfoExcludeMutationHandle {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $RequireExisting
    )

    Assert-GitInfoExcludeMutationPath -Repository $Repository -Path $Path
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Assert-GitInfoExcludeMutationPath -Repository $Repository -Path $Path
    $stream = $null
    $created = $false
    try {
        if ($RequireExisting) {
            $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
        }
        else {
            try {
                $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
                $created = $true
            }
            catch [System.IO.IOException] {
                $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::Read)
            }
        }
        return [pscustomobject]@{ Stream=$stream; Created=$created }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw "Unable to acquire the exclusive shared Git exclude mutation handle; another process may be changing '$Path'. $($_.Exception.Message)"
    }
}

function Restore-GitInfoExcludeSnapshot {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    if (-not [bool]$Snapshot.MutationApplied) { return }
    $path = [string]$Snapshot.Path
    $repository = [string]$Snapshot.Repository
    Assert-GitInfoExcludeMutationPath -Repository $repository -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if (-not [bool]$Snapshot.Existed) {
            $Snapshot.MutationApplied = $false
            return
        }
        throw "Shared Git exclude changed concurrently during rollback; the missing current state was preserved: $path"
    }

    $handle = Open-GitInfoExcludeMutationHandle -Repository $repository -Path $path -RequireExisting
    try {
        if ([bool]$handle.Created) { throw "Shared Git exclude changed concurrently during rollback; the recreated current state was preserved: $path" }
        [byte[]]$currentBytes = Read-GitInfoExcludeStreamBytes -Stream $handle.Stream
        if (-not (Test-GitInfoExcludeBytesEqual -Left $currentBytes -Right ([byte[]]$Snapshot.AppliedBytes))) {
            throw "Shared Git exclude changed concurrently during rollback; current bytes were preserved: $path"
        }
        $restoreBytes = if ([bool]$Snapshot.Existed) { [byte[]]$Snapshot.Bytes } else { [byte[]]@() }
        Write-GitInfoExcludeStreamBytes -Stream $handle.Stream -Bytes $restoreBytes
        $Snapshot.MutationApplied = $false
    }
    finally {
        if ($null -ne $handle -and $null -ne $handle.Stream) { $handle.Stream.Dispose() }
    }
}

function ConvertTo-GitExcludeLiteralPattern {
    param([Parameter(Mandatory = $true)][string] $Path)

    $escaped = $Path.Replace('\','/')
    foreach ($character in @('\','[',']','*','?')) { $escaped = $escaped.Replace($character,"\$character") }
    if ($escaped.StartsWith('!') -or $escaped.StartsWith('#')) { $escaped = "\$escaped" }
    return "/$escaped"
}

function Set-ManagedGitInfoExclude {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ManagedPaths,
        [Parameter(Mandatory = $true)][object] $Snapshot
    )

    $path = Get-GitInfoExcludePath -Repository $Repository
    if ([string]$Snapshot.Path -cne $path -or [string]$Snapshot.Repository -cne $Repository) {
        throw 'Shared Git exclude snapshot does not match the requested mutation target.'
    }
    Assert-GitInfoExcludeMutationPath -Repository $Repository -Path $path
    $sharedManagedPaths = @(Get-SharedManagedExcludePaths -Repository $Repository -CurrentManagedPaths $ManagedPaths)
    $lines = @($sharedManagedPaths | ForEach-Object { ConvertTo-GitExcludeLiteralPattern -Path $_ })
    $handle = Open-GitInfoExcludeMutationHandle -Repository $Repository -Path $path
    try {
        [byte[]]$beforeBytes = Read-GitInfoExcludeStreamBytes -Stream $handle.Stream
        $Snapshot.Existed = -not [bool]$handle.Created
        $Snapshot.Bytes = if ([bool]$handle.Created) { $null } else { $beforeBytes }
        $Snapshot.AppliedBytes = $beforeBytes
        $Snapshot.MutationApplied = [bool]$handle.Created

        $content = (ConvertFrom-GitInfoExcludeBytes -Bytes $beforeBytes).Replace("`r`n","`n").Replace("`r","`n")
        $pattern = '(?ms)^' + [regex]::Escape($excludeBeginMarker) + '\n.*?^' + [regex]::Escape($excludeEndMarker) + '\n?'
        $beginCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($excludeBeginMarker) + '$').Count
        $endCount = [regex]::Matches($content,'(?m)^' + [regex]::Escape($excludeEndMarker) + '$').Count
        if ($beginCount -ne $endCount -or $beginCount -gt 1 -or ($beginCount -eq 1 -and -not [regex]::IsMatch($content,$pattern))) {
            throw "The Codex AI Instructions managed exclude block is malformed: $path"
        }
        $withoutBlock = [regex]::Replace($content,$pattern,'').TrimEnd("`n")
        $updated = $withoutBlock
        if ($lines.Count -gt 0) {
            $block = $excludeBeginMarker + "`n" + ($lines -join "`n") + "`n" + $excludeEndMarker + "`n"
            $updated = if ([string]::IsNullOrWhiteSpace($withoutBlock)) { $block } else { $withoutBlock + "`n`n" + $block }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($updated)) { $updated += "`n" }
        [byte[]]$updatedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($updated)
        if (-not (Test-GitInfoExcludeBytesEqual -Left $beforeBytes -Right $updatedBytes)) {
            $Snapshot.AppliedBytes = $updatedBytes
            $Snapshot.MutationApplied = $true
            try { Write-GitInfoExcludeStreamBytes -Stream $handle.Stream -Bytes $updatedBytes }
            catch {
                try { $Snapshot.AppliedBytes = [byte[]](Read-GitInfoExcludeStreamBytes -Stream $handle.Stream) }
                catch { }
                throw
            }
        }
    }
    finally {
        if ($null -ne $handle -and $null -ne $handle.Stream) { $handle.Stream.Dispose() }
    }
}

function Test-GitPathHasChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $workingTreeExitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--quiet', '--', $Path)
    $indexExitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path)

    if ($workingTreeExitCode -gt 1 -or $indexExitCode -gt 1) {
        throw "Unable to inspect local changes for managed path: $Path"
    }

    return $workingTreeExitCode -eq 1 -or $indexExitCode -eq 1
}

function Test-GitPathHasStagedChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path)
    if ($exitCode -gt 1) {
        throw "Unable to inspect staged changes for managed path: $Path"
    }

    return $exitCode -eq 1
}

function New-ManifestEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

    $artifactType = 'instruction'
    $artifactId = $null
    $source = $script:instructionProvenance
    if ($TargetPath.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal)) {
        $artifactType = 'skill'
        $skillParts = @($TargetPath.Split('/'))
        $artifactId = $skillParts[2]
        if (-not $script:skillProvenanceById.ContainsKey($artifactId)) {
            throw "Managed Skill '$artifactId' has no source provenance."
        }
        $source = $script:skillProvenanceById[$artifactId]
    }
    elseif ($TargetPath -eq 'AGENTS.md') {
        $artifactId = 'codex-base'
    }
    elseif ($TargetPath -eq '.github/copilot-instructions.md') {
        $artifactId = 'copilot-base'
    }
    elseif (Test-InstructionLicenseDeliveryPath $TargetPath) {
        $artifactId = if ($TargetPath.StartsWith('.codex/')) { 'codex-licensing' } else { 'copilot-licensing' }
    }
    elseif ($TargetPath.StartsWith('.codex/AI-Rules/', [System.StringComparison]::Ordinal)) {
        $ruleName = [regex]::Replace(
            [System.IO.Path]::GetFileName($TargetPath).Replace('.en.md', '').ToLowerInvariant(),
            '[^a-z0-9-]',
            '-'
        ).Trim('-')
        $artifactId = "codex-rule-$ruleName"
    }
    elseif ($TargetPath.StartsWith('.github/AI-Rules/', [System.StringComparison]::Ordinal)) {
        $ruleName = [regex]::Replace(
            [System.IO.Path]::GetFileName($TargetPath).Replace('.en.md', '').ToLowerInvariant(),
            '[^a-z0-9-]',
            '-'
        ).Trim('-')
        $artifactId = "copilot-rule-$ruleName"
    }
    else {
        throw "Cannot derive instruction artifact ID for managed target: $TargetPath"
    }

    if ($artifactId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "Derived artifact ID is not lowercase kebab-case: $artifactId"
    }

    return [pscustomobject][ordered]@{
        artifactType = $artifactType
        artifactId = $artifactId
        sourceId = [string] $source.sourceId
        sourceRepository = [string] $source.sourceRepository
        sourceRef = [string] $source.sourceRef
        sourceCommit = [string] $source.sourceCommit
        sourceVersion = [string] $source.sourceVersion
        sourcePath = $SourcePath
        targetPath = $TargetPath
        sha256 = $Sha256
    }
}

function Copy-ExistingManifestEntry {
    param([Parameter(Mandatory = $true)][object] $Entry)

    return [pscustomobject][ordered]@{
        artifactType = [string] $Entry.artifactType
        artifactId = [string] $Entry.artifactId
        sourceId = [string] $Entry.sourceId
        sourceRepository = [string] $Entry.sourceRepository
        sourceRef = [string] $Entry.sourceRef
        sourceCommit = [string] $Entry.sourceCommit
        sourceVersion = [string] $Entry.sourceVersion
        sourcePath = [string] $Entry.sourcePath
        targetPath = [string] $Entry.targetPath
        sha256 = [string] $Entry.sha256
    }
}

function New-TargetMutationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string[]] $RelativePaths,
        [Parameter(Mandatory = $true)][string] $BackupRoot
    )

    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $resolvedTargetRoot = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
    $targetPrefix = $resolvedTargetRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $fileStates = New-Object System.Collections.Generic.List[object]
    $backupIndex = 0

    foreach ($relativePath in @($RelativePaths | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        try {
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedTargetRoot $relativePath.Replace('/', '\')))
        }
        catch {
            $codePoints = @([char[]][string]$relativePath | ForEach-Object { ([int]$_).ToString('x4') }) -join ' '
            throw "Invalid target mutation path '$relativePath' (UTF-16: $codePoints): $($_.Exception.Message)"
        }
        if (-not $targetPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe target mutation snapshot path: $relativePath"
        }

        $inspectionPath = $targetPath
        while ($inspectionPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $inspectionPath) {
                $inspectionItem = Get-Item -LiteralPath $inspectionPath -Force
                if (($inspectionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Managed target path crosses a reparse point: $relativePath"
                }
            }
            $inspectionPath = Split-Path -Parent $inspectionPath
        }

        $originalType = 'missing'
        $backupPath = $null
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $originalType = 'file'
            $backupPath = Join-Path $BackupRoot ('{0:D6}.bin' -f $backupIndex)
            Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
            $backupIndex++
        }
        elseif (Test-Path -LiteralPath $targetPath) {
            throw "Managed target path must be a file or missing: $relativePath"
        }

        $fileStates.Add([pscustomobject][ordered]@{
            RelativePath = $relativePath
            TargetPath = $targetPath
            OriginalType = $originalType
            BackupPath = $backupPath
            MutationApplied = $false
            AppliedType = $null
            AppliedBytes = $null
        })
    }

    return [pscustomobject][ordered]@{
        TargetRoot = $resolvedTargetRoot
        FileStates = $fileStates.ToArray()
        CreatedDirectories = New-Object System.Collections.Generic.List[object]
    }
}

function Get-TargetMutationFileState {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $matches = @($Snapshot.FileStates | Where-Object { [string]$_.RelativePath -ceq $RelativePath })
    if ($matches.Count -ne 1) { throw "Target mutation snapshot does not contain exactly one state for: $RelativePath" }
    return $matches[0]
}

function Test-TargetMutationBytesEqual {
    param(
        [AllowNull()][byte[]] $Left,
        [AllowNull()][byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Read-TargetMutationStreamBytes {
    param([Parameter(Mandatory = $true)][System.IO.FileStream] $Stream)

    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.Position = 0
        $Stream.CopyTo($memory)
        return ,([byte[]]$memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function Write-TargetMutationStreamBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $Stream.Position = 0
    $Stream.SetLength(0)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes,0,$Bytes.Length) }
    $Stream.Flush($true)
}

function Set-TargetMutationDeleteDisposition {
    param([Parameter(Mandatory = $true)][Microsoft.Win32.SafeHandles.SafeFileHandle] $Handle)

    [CodexAiInstructions.NativeFileMutation]::MarkDeleteOnClose($Handle)
}

function Open-TargetMutationAtomicDeleteStream {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $nativeHandle = $null
    try {
        $nativeHandle = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicDelete(
            $TargetRoot,$TargetPath,$RelativePath)
        $stream = [System.IO.FileStream]::new($nativeHandle,[System.IO.FileAccess]::Read)
        $nativeHandle = $null
        return $stream
    }
    catch {
        throw "$Operation could not acquire the atomic delete handle; the current file was preserved: $RelativePath. $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $nativeHandle) { $nativeHandle.Dispose() }
    }
}

function Open-TargetMutationAtomicWriteStream {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Operation,
        [Parameter(Mandatory = $true)][ref] $RestoreReadOnly
    )

    $nativeHandle = $null
    $nativeRestoreReadOnly = $false
    try {
        $nativeHandle = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicWrite(
            $TargetRoot,$TargetPath,$RelativePath,[ref]$nativeRestoreReadOnly)
        $stream = [System.IO.FileStream]::new($nativeHandle,[System.IO.FileAccess]::ReadWrite)
        $nativeHandle = $null
        $RestoreReadOnly.Value = [bool]$nativeRestoreReadOnly
        return $stream
    }
    catch {
        $openError = $_.Exception.Message
        $restoreError = $null
        if ($null -ne $nativeHandle -and $nativeRestoreReadOnly) {
            try { [CodexAiInstructions.NativeFileMutation]::RestoreReadOnly($nativeHandle) }
            catch { $restoreError = $_.Exception.Message }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$restoreError)) {
            throw "$Operation could not acquire the atomic write stream and could not restore the read-only attribute: $RelativePath. $restoreError"
        }
        throw "$Operation could not acquire the atomic write handle; the current file was preserved: $RelativePath. $openError"
    }
    finally {
        if ($null -ne $nativeHandle) { $nativeHandle.Dispose() }
    }
}

function Open-TargetMutationAtomicCreateStream {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Operation,
        [Parameter(Mandatory = $true)][ref] $CreateContext
    )

    $nativeContext = $null
    $nativeHandle = $null
    try {
        $nativeContext = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicCreate(
            $TargetRoot,$TargetPath,$RelativePath)
        $nativeHandle = $nativeContext.TakeFileHandle()
        $stream = [System.IO.FileStream]::new($nativeHandle,[System.IO.FileAccess]::ReadWrite)
        $nativeHandle = $null
        $CreateContext.Value = $nativeContext
        $nativeContext = $null
        return $stream
    }
    catch {
        throw "$Operation could not acquire the handle-bound create stream; no external path was changed: $RelativePath ($TargetPath). $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $nativeHandle) { $nativeHandle.Dispose() }
        if ($null -ne $nativeContext) { $nativeContext.Dispose() }
    }
}

function Close-TargetMutationStream {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][bool] $RestoreReadOnly
    )

    try {
        if ($RestoreReadOnly) {
            [CodexAiInstructions.NativeFileMutation]::RestoreReadOnly($Stream.SafeFileHandle)
        }
    }
    finally { $Stream.Dispose() }
}

function Remove-TargetMutationFileAtomically {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $ExpectedBytes,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "$Operation requires the Windows atomic managed-file deletion boundary: $RelativePath"
    }
    $state = Get-TargetMutationFileState -Snapshot $Snapshot -RelativePath $RelativePath
    Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) -Path `
        ([string]$state.TargetPath) -Context "$Operation '$RelativePath'"
    $stream = $null
    try {
        $stream = Open-TargetMutationAtomicDeleteStream -TargetRoot ([string]$Snapshot.TargetRoot) `
            -TargetPath ([string]$state.TargetPath) `
            -RelativePath $RelativePath -Operation $Operation
        [byte[]]$currentBytes = Read-TargetMutationStreamBytes -Stream $stream
        if (-not (Test-TargetMutationBytesEqual -Left $currentBytes -Right $ExpectedBytes)) {
            throw "$Operation detected concurrent content; the current file was preserved: $RelativePath"
        }
        Set-TargetMutationDeleteDisposition -Handle $stream.SafeFileHandle
        $stream.Dispose()
        $stream = $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Set-TargetMutationFileBytes {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $state = Get-TargetMutationFileState -Snapshot $Snapshot -RelativePath $RelativePath
    if ([bool]$state.MutationApplied) { throw "Target mutation state was already applied: $RelativePath" }
    Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) -Path ([string]$state.TargetPath) -Context "Managed target '$RelativePath'"
    $stream = $null
    $restoreReadOnly = $false
    $createContext = $null
    try {
        if ([string]$state.OriginalType -ceq 'file') {
            [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
            try {
                $stream = Open-TargetMutationAtomicWriteStream -TargetRoot ([string]$Snapshot.TargetRoot) `
                    -TargetPath ([string]$state.TargetPath) -RelativePath $RelativePath `
                    -Operation 'Managed target mutation' -RestoreReadOnly ([ref]$restoreReadOnly)
            }
            catch {
                throw "Managed target changed concurrently before mutation: $RelativePath. $($_.Exception.Message)"
            }
            [byte[]]$currentBytes = Read-TargetMutationStreamBytes -Stream $stream
            if (-not (Test-TargetMutationBytesEqual -Left $currentBytes -Right $originalBytes)) {
                throw "Managed target changed concurrently before mutation: $RelativePath"
            }
        }
        else {
            try {
                $stream = Open-TargetMutationAtomicCreateStream -TargetRoot ([string]$Snapshot.TargetRoot) `
                    -TargetPath ([string]$state.TargetPath) -RelativePath $RelativePath `
                    -Operation 'Managed target creation' -CreateContext ([ref]$createContext)
            }
            catch {
                throw "Managed target changed concurrently before creation: $RelativePath. $($_.Exception.Message)"
            }
            foreach ($createdDirectory in @($createContext.CreatedDirectories)) {
                $alreadyRecorded = @($Snapshot.CreatedDirectories | Where-Object {
                    ([string]$_.FullPath).Equals([string]$createdDirectory.FullPath,[System.StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
                if (-not $alreadyRecorded) {
                    $Snapshot.CreatedDirectories.Add([pscustomobject][ordered]@{
                        FullPath = [string]$createdDirectory.FullPath
                        RelativePath = [string]$createdDirectory.RelativePath
                        VolumeSerialNumber = [uint32]$createdDirectory.VolumeSerialNumber
                        FileIndexHigh = [uint32]$createdDirectory.FileIndexHigh
                        FileIndexLow = [uint32]$createdDirectory.FileIndexLow
                    })
                }
            }
        }

        $state.AppliedType = 'file'
        $state.AppliedBytes = [byte[]]$Bytes.Clone()
        $state.MutationApplied = $true
        try {
            Write-TargetMutationStreamBytes -Stream $stream -Bytes $Bytes
            [byte[]]$writtenBytes = Read-TargetMutationStreamBytes -Stream $stream
            if (-not (Test-TargetMutationBytesEqual -Left $writtenBytes -Right $Bytes)) {
                $state.AppliedBytes = $writtenBytes
                throw "Managed target write did not retain the exact applied bytes: $RelativePath"
            }
        }
        catch {
            try { $state.AppliedBytes = [byte[]](Read-TargetMutationStreamBytes -Stream $stream) }
            catch { }
            throw
        }
    }
    finally {
        if ($null -ne $stream) {
            Close-TargetMutationStream -Stream $stream -RestoreReadOnly $restoreReadOnly
        }
        if ($null -ne $createContext) { $createContext.Dispose() }
    }
}

function Remove-TargetMutationFile {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $state = Get-TargetMutationFileState -Snapshot $Snapshot -RelativePath $RelativePath
    if ([bool]$state.MutationApplied -or [string]$state.OriginalType -cne 'file') {
        throw "Target mutation cannot remove an unexpected snapshot state: $RelativePath"
    }
    [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
    Remove-TargetMutationFileAtomically -Snapshot $Snapshot -RelativePath $RelativePath -ExpectedBytes $originalBytes `
        -Operation 'Managed target removal'
    $state.AppliedType = 'missing'
    $state.AppliedBytes = $null
    $state.MutationApplied = $true
}

function Restore-TargetMutationSnapshot {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    $driftedPaths = New-Object System.Collections.Generic.List[string]
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    foreach ($state in @($Snapshot.FileStates)) {
        if (-not [bool]$state.MutationApplied) { continue }
        $stream = $null
        $restoreReadOnly = $false
        $createContext = $null
        try {
            Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) -Path ([string]$state.TargetPath) -Context "Target rollback '$($state.RelativePath)'"
            switch ([string]$state.AppliedType) {
                'file' {
                    if (-not (Test-Path -LiteralPath ([string]$state.TargetPath) -PathType Leaf)) {
                        $driftedPaths.Add([string]$state.RelativePath)
                        continue
                    }
                    try {
                        $stream = Open-TargetMutationAtomicWriteStream -TargetRoot ([string]$Snapshot.TargetRoot) `
                            -TargetPath ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                            -Operation 'Target rollback mutation' -RestoreReadOnly ([ref]$restoreReadOnly)
                    }
                    catch {
                        $driftedPaths.Add([string]$state.RelativePath)
                        continue
                    }
                    [byte[]]$currentBytes = Read-TargetMutationStreamBytes -Stream $stream
                    if (-not (Test-TargetMutationBytesEqual -Left $currentBytes -Right ([byte[]]$state.AppliedBytes))) {
                        $driftedPaths.Add([string]$state.RelativePath)
                        continue
                    }
                    if ([string]$state.OriginalType -ceq 'file') {
                        [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
                        Write-TargetMutationStreamBytes -Stream $stream -Bytes $originalBytes
                        $state.MutationApplied = $false
                        continue
                    }
                    Close-TargetMutationStream -Stream $stream -RestoreReadOnly $restoreReadOnly
                    $stream = $null
                    $restoreReadOnly = $false
                    try {
                        Remove-TargetMutationFileAtomically -Snapshot $Snapshot -RelativePath ([string]$state.RelativePath) `
                            -ExpectedBytes ([byte[]]$state.AppliedBytes) -Operation 'Target rollback removal'
                    }
                    catch {
                        $driftedPaths.Add([string]$state.RelativePath)
                        $rollbackErrors.Add($_.Exception.Message)
                        continue
                    }
                    $state.MutationApplied = $false
                }
                'missing' {
                    if (Test-Path -LiteralPath ([string]$state.TargetPath)) {
                        $driftedPaths.Add([string]$state.RelativePath)
                        continue
                    }
                    if ([string]$state.OriginalType -ceq 'file') {
                        [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
                        try {
                            $stream = Open-TargetMutationAtomicCreateStream -TargetRoot ([string]$Snapshot.TargetRoot) `
                                -TargetPath ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                                -Operation 'Target rollback creation' -CreateContext ([ref]$createContext)
                        }
                        catch {
                            $driftedPaths.Add([string]$state.RelativePath)
                            continue
                        }
                        Write-TargetMutationStreamBytes -Stream $stream -Bytes $originalBytes
                    }
                    $state.MutationApplied = $false
                }
                default { throw "Target rollback found an unsupported applied state: $($state.RelativePath)" }
            }
        }
        catch { $rollbackErrors.Add("$($state.RelativePath): $($_.Exception.Message)") }
        finally {
            if ($null -ne $stream) {
                Close-TargetMutationStream -Stream $stream -RestoreReadOnly $restoreReadOnly
            }
            if ($null -ne $createContext) { $createContext.Dispose() }
        }
    }

    if ($driftedPaths.Count -eq 0 -and $rollbackErrors.Count -eq 0) {
        foreach ($directoryState in @($Snapshot.CreatedDirectories | Sort-Object { ([string]$_.RelativePath).Length } -Descending)) {
            $directoryHandle = $null
            try {
                $directoryHandle = [CodexAiInstructions.NativeFileMutation]::OpenCreatedDirectoryForAtomicDelete(
                    [string]$Snapshot.TargetRoot,
                    [string]$directoryState.FullPath,
                    [string]$directoryState.RelativePath,
                    [uint32]$directoryState.VolumeSerialNumber,
                    [uint32]$directoryState.FileIndexHigh,
                    [uint32]$directoryState.FileIndexLow)
                [CodexAiInstructions.NativeFileMutation]::MarkDeleteOnClose($directoryHandle)
            }
            catch {
                $rollbackErrors.Add("$($directoryState.RelativePath): transaction-created directory was preserved because safe cleanup failed. $($_.Exception.Message)")
            }
            finally {
                if ($null -ne $directoryHandle) { $directoryHandle.Dispose() }
            }
        }
    }
    if ($driftedPaths.Count -gt 0 -or $rollbackErrors.Count -gt 0) {
        $parts = New-Object System.Collections.Generic.List[string]
        if ($driftedPaths.Count -gt 0) { $parts.Add("Concurrent target changes were preserved and require manual resolution: $(@($driftedPaths | Sort-Object -Unique) -join ', ')") }
        if ($rollbackErrors.Count -gt 0) { $parts.Add("Target rollback errors: $($rollbackErrors -join ' | ')") }
        throw ($parts -join ' ')
    }
}

function Restore-TargetMutationTransaction {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Paths,
        [Parameter(Mandatory = $true)][object] $Snapshot
    )

    Restore-TargetMutationSnapshot -Snapshot $Snapshot
}

function Get-PersonalAgentStashes {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $WorktreeKey
    )

    $stashes = New-Object System.Collections.Generic.List[object]
    $stashLines = @(Invoke-Git -Repository $Repository -Arguments @('stash', 'list', '--format=%gd%x09%H%x09%gs'))
    foreach ($stashLine in $stashLines) {
        $parts = ([string] $stashLine).Split(@("`t"), 3, [System.StringSplitOptions]::None)
        if ($parts.Count -ne 3) { continue }
        $subjectMatch = [System.Text.RegularExpressions.Regex]::Match(
            $parts[2],
            '(?:^|: )CodexPersonalAgent:(?<Worktree>[0-9a-f]{64}):(?<Evidence>[0-9a-f]{64}):PersonalAgent$'
        )
        if (-not $subjectMatch.Success -or $subjectMatch.Groups['Worktree'].Value -cne $WorktreeKey) { continue }

        $indexMatch = [System.Text.RegularExpressions.Regex]::Match($parts[0], '^stash@\{([0-9]+)\}$')
        if (-not $indexMatch.Success) {
            throw "Unexpected PersonalAgent stash reference: $($parts[0])"
        }

        $stashes.Add([pscustomobject]@{
            Reference = $parts[0]
            Hash = $parts[1]
            Index = [int] $indexMatch.Groups[1].Value
            WorktreeKey = $subjectMatch.Groups['Worktree'].Value
            EvidenceFingerprint = $subjectMatch.Groups['Evidence'].Value
        })
    }

    return $stashes
}

function Get-PersonalAgentWorktreeKey {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $gitDirectory = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse', '--git-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $Repository $gitDirectory }
    $identity = [System.IO.Path]::GetFullPath($gitDirectory).Replace('\', '/')
    if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $identity = $identity.ToLowerInvariant() }
    return Get-StringSha256 -Value $identity
}

function Get-PersonalAgentEvidenceFingerprint {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $Paths
    )

    $evidenceLines = foreach ($path in @($Paths | Sort-Object -Unique)) {
        $fullPath = Join-Path $Repository $path.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Cannot fingerprint PersonalAgent evidence because a managed path is missing: $path"
        }
        $blobId = ((Invoke-Git -Repository $Repository -Arguments @('hash-object','--no-filters','--',$path)) | Select-Object -First 1).Trim()
        if ($blobId -cnotmatch '^[0-9a-f]{40,64}$') { throw "Cannot fingerprint PersonalAgent evidence because Git returned an invalid blob ID: $path" }
        "$path`t$blobId"
    }
    return Get-StringSha256 -Value (@($evidenceLines) -join "`n")
}

function Test-PersonalAgentStashEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][object] $Stash,
        [string[]] $Paths = @(),
        [Parameter(Mandatory = $true)][string] $ExpectedFingerprint
    )

    try {
        $parentLine = ((Invoke-Git -Repository $Repository -Arguments @('show','--no-patch','--format=%P',[string]$Stash.Hash)) |
            Select-Object -First 1).Trim()
        $parents = @($parentLine.Split(' ',[System.StringSplitOptions]::RemoveEmptyEntries))
        if ($parents.Count -lt 3) { return $false }
        $untrackedCommit = [string]$parents[2]
        if ($untrackedCommit -cnotmatch '^[0-9a-f]{40,64}$') { return $false }
        $treeEntries = New-Object System.Collections.Generic.List[object]
        foreach ($line in @(Invoke-Git -Repository $Repository -Arguments @('-c','core.quotePath=true','ls-tree','-r','--full-tree',$untrackedCommit))) {
            $match = [System.Text.RegularExpressions.Regex]::Match([string]$line,'^[0-7]{6} blob (?<Hash>[0-9a-f]{40,64})\t(?<Path>.+)$')
            if (-not $match.Success) { return $false }
            $treeEntries.Add([pscustomobject]@{ Path=(ConvertFrom-GitQuotedPath -Path $match.Groups['Path'].Value); Hash=$match.Groups['Hash'].Value })
        }
        if ($Paths.Count -gt 0) {
            $expectedPaths = @($Paths | Sort-Object -Unique)
            $actualPaths = @($treeEntries | ForEach-Object { [string]$_.Path } | Sort-Object -Unique)
            if ($actualPaths.Count -ne $expectedPaths.Count -or (@($actualPaths) -join "`n") -cne (@($expectedPaths) -join "`n")) { return $false }
        }
        $fingerprintLines = @($treeEntries | Sort-Object Path | ForEach-Object { "$($_.Path)`t$($_.Hash)" })
        return (Get-StringSha256 -Value ($fingerprintLines -join "`n")) -ceq $ExpectedFingerprint
    }
    catch { return $false }
}

function Update-PersonalAgentStash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Paths,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $ExpectedEntries,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $PriorStashes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $PriorOwnedStashes,

        [Parameter(Mandatory = $true)]
        [string] $WorktreeKey,

        [Parameter(Mandatory = $true)]
        [string] $EvidenceFingerprint,

        [Parameter(Mandatory = $true)]
        [string] $ActiveIndexPath
    )

    if ($Paths.Count -eq 0) {
        throw 'Cannot create PersonalAgent stash without managed changes.'
    }

    $expectedRawHashes = @{}
    foreach ($path in $Paths) {
        $fullPath = Join-Path $Repository $path.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Cannot create byte-safe PersonalAgent evidence because a managed path is missing: $path"
        }
        $expectedRawHashes[$path] = Get-RawContentHash -Path $fullPath
    }

    $stashMessage = "CodexPersonalAgent:$WorktreeKey`:$EvidenceFingerprint`:PersonalAgent"
    $headCommit = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--verify','HEAD')) | Select-Object -First 1).Trim()
    $headTree = ((Invoke-Git -Repository $Repository -Arguments @('show','--no-patch','--format=%T','HEAD')) | Select-Object -First 1).Trim()
    foreach ($objectId in @($headCommit,$headTree)) {
        if ($objectId -cnotmatch '^[0-9a-f]{40,64}$') { throw 'Git returned an invalid object ID while creating PersonalAgent evidence.' }
    }

    $resolvedActiveIndexPath = [System.IO.Path]::GetFullPath($ActiveIndexPath)
    if (-not (Test-Path -LiteralPath $resolvedActiveIndexPath -PathType Leaf)) {
        throw "Cannot create PersonalAgent evidence because the locked Git index is missing: $resolvedActiveIndexPath"
    }
    $activeIndexItem = Get-Item -Force -LiteralPath $resolvedActiveIndexPath
    if (($activeIndexItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Cannot create PersonalAgent evidence from a reparse-point Git index: $resolvedActiveIndexPath"
    }

    # Keep the product index immutable while preserving its exact tree as the stash's index parent.
    # The private copy stays beside the real index so Git split-index shared files remain resolvable.
    $temporaryProductIndexPath = $resolvedActiveIndexPath + '.codex-personal-agent-' + [Guid]::NewGuid().ToString('N')
    $temporaryEvidenceIndexPath = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-personal-agent-index-' + [Guid]::NewGuid().ToString('N'))
    $hadAlternateIndex = Test-Path Env:GIT_INDEX_FILE
    $priorAlternateIndex = $env:GIT_INDEX_FILE
    try {
        [System.IO.File]::Copy($resolvedActiveIndexPath,$temporaryProductIndexPath,$false)
        $env:GIT_INDEX_FILE = $temporaryProductIndexPath
        $indexTree = ((Invoke-Git -Repository $Repository -Arguments @('write-tree')) | Select-Object -First 1).Trim()
        if ($indexTree -cnotmatch '^[0-9a-f]{40,64}$') { throw 'Git returned an invalid product index tree ID.' }

        $env:GIT_INDEX_FILE = $temporaryEvidenceIndexPath
        Invoke-Git -Repository $Repository -Arguments @('read-tree','--empty') | Out-Null
        foreach ($path in @($Paths | Sort-Object -Unique)) {
            $blobId = ((Invoke-Git -Repository $Repository -Arguments @('hash-object','-w','--no-filters','--',$path)) | Select-Object -First 1).Trim()
            if ($blobId -cnotmatch '^[0-9a-f]{40,64}$') { throw "Git returned an invalid managed evidence blob ID: $path" }
            Invoke-Git -Repository $Repository -Arguments @('update-index','--add','--cacheinfo',"100644,$blobId,$path") | Out-Null
        }
        $untrackedTree = ((Invoke-Git -Repository $Repository -Arguments @('write-tree')) | Select-Object -First 1).Trim()
    }
    finally {
        if ($hadAlternateIndex) { $env:GIT_INDEX_FILE = $priorAlternateIndex }
        else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        foreach ($temporaryPath in @(
            $temporaryProductIndexPath,
            ($temporaryProductIndexPath + '.lock'),
            $temporaryEvidenceIndexPath,
            ($temporaryEvidenceIndexPath + '.lock')
        )) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($untrackedTree -cnotmatch '^[0-9a-f]{40,64}$') { throw 'Git returned an invalid PersonalAgent evidence tree ID.' }

    $identityArguments = @('-c','user.name=Codex Runtime','-c','user.email=codex-runtime@example.test','commit-tree')
    $evidenceNonce = [Guid]::NewGuid().ToString('N')
    $indexCommit = ((Invoke-Git -Repository $Repository -Arguments ($identityArguments + @($indexTree,'-p',$headCommit,'-m',"PersonalAgent index $evidenceNonce"))) | Select-Object -First 1).Trim()
    $untrackedCommit = ((Invoke-Git -Repository $Repository -Arguments ($identityArguments + @($untrackedTree,'-p',$headCommit,'-m',"PersonalAgent files $evidenceNonce"))) | Select-Object -First 1).Trim()
    $newEvidenceCommit = ((Invoke-Git -Repository $Repository -Arguments ($identityArguments + @($headTree,'-p',$headCommit,'-p',$indexCommit,'-p',$untrackedCommit,'-m',$stashMessage))) | Select-Object -First 1).Trim()
    foreach ($objectId in @($indexCommit,$untrackedCommit,$newEvidenceCommit)) {
        if ($objectId -cnotmatch '^[0-9a-f]{40,64}$') { throw 'Git returned an invalid commit ID while creating PersonalAgent evidence.' }
    }
    Invoke-Git -Repository $Repository -Arguments @('stash','store','--quiet','-m',$stashMessage,$newEvidenceCommit) | Out-Null

    $priorStashHashCounts = @{}
    foreach ($priorStash in @($PriorStashes)) {
        $priorHash = [string]$priorStash.Hash
        if (-not $priorStashHashCounts.ContainsKey($priorHash)) { $priorStashHashCounts[$priorHash] = 0 }
        $priorStashHashCounts[$priorHash]++
    }

    $currentStashHashCounts = @{}
    $newStashes = New-Object System.Collections.Generic.List[object]
    foreach ($currentStash in @(Get-PersonalAgentStashes -Repository $Repository -WorktreeKey $WorktreeKey)) {
        $currentHash = [string]$currentStash.Hash
        if (-not $currentStashHashCounts.ContainsKey($currentHash)) { $currentStashHashCounts[$currentHash] = 0 }
        $currentStashHashCounts[$currentHash]++
        $priorCount = if ($priorStashHashCounts.ContainsKey($currentHash)) { [int]$priorStashHashCounts[$currentHash] } else { 0 }
        if ($currentStashHashCounts[$currentHash] -gt $priorCount) { $newStashes.Add($currentStash) }
    }
    if ($newStashes.Count -ne 1) {
        throw 'The newly created PersonalAgent stash could not be identified uniquely.'
    }
    $newStashHash = [string]$newStashes[0].Hash
    if (-not (Test-PersonalAgentStashEvidence -Repository $Repository -Stash $newStashes[0] -Paths $Paths -ExpectedFingerprint $EvidenceFingerprint)) {
        throw 'The newly created PersonalAgent stash does not contain the exact fingerprinted managed evidence.'
    }

    foreach ($path in $Paths) {
        $fullPath = Join-Path $Repository $path.Replace('/','\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
            (Get-RawContentHash -Path $fullPath) -cne [string]$expectedRawHashes[$path]) {
            throw "PersonalAgent stash apply changed managed raw bytes; prior stashes were retained: $path"
        }
    }

    foreach ($entry in @($ExpectedEntries)) {
        $targetPath = [string]$entry.targetPath
        $targetFullPath = Join-Path $Repository $targetPath.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf) -or
            (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -cne [string]$entry.sha256) {
            throw "PersonalAgent stash apply changed managed file bytes; prior stashes were retained: $targetPath"
        }
    }

    $obsoleteStashes = @($PriorOwnedStashes | Where-Object { $_.Hash -ne $newStashHash } | Sort-Object Index -Descending)
    foreach ($obsoleteStash in $obsoleteStashes) {
        $droppedHash = $null
        try {
            $currentObsoleteStash = $null
            foreach ($attempt in 1..3) {
                $currentMatches = @(
                    Get-PersonalAgentStashes -Repository $Repository -WorktreeKey $WorktreeKey |
                        Where-Object { $_.Hash -ceq [string]$obsoleteStash.Hash }
                )
                if ($currentMatches.Count -ne 1) {
                    throw "Expected exactly one current PersonalAgent stash with hash $($obsoleteStash.Hash)."
                }

                $candidateReference = $currentMatches[0]
                $resolvedHash = (Invoke-Git -Repository $Repository -Arguments @('rev-parse', '--verify', $candidateReference.Reference) |
                    Select-Object -First 1).Trim()
                if ($resolvedHash -ceq [string]$obsoleteStash.Hash) {
                    $currentObsoleteStash = $candidateReference
                    break
                }
                if ($attempt -eq 3) {
                    throw "PersonalAgent stash reference kept changing before cleanup: $($candidateReference.Reference)"
                }
            }

            $dropOutput = @(Invoke-Git -Repository $Repository -Arguments @('stash', 'drop', $currentObsoleteStash.Reference))
            $dropMatch = [System.Text.RegularExpressions.Regex]::Match(
                ($dropOutput -join [Environment]::NewLine),
                '\(([0-9a-fA-F]{40}|[0-9a-fA-F]{64})\)'
            )
            if (-not $dropMatch.Success) {
                throw "Git did not report the hash removed for $($currentObsoleteStash.Reference)."
            }
            $droppedHash = $dropMatch.Groups[1].Value.ToLowerInvariant()
        }
        catch {
            Write-Warning "Obsolete PersonalAgent stash cleanup stopped before a safe result could be confirmed: $($obsoleteStash.Hash). $($_.Exception.Message)"
            continue
        }

        if ($droppedHash -cne ([string]$obsoleteStash.Hash).ToLowerInvariant()) {
            $recoveryMessage = "Recovered after concurrent PersonalAgent cleanup: $droppedHash"
            try {
                $stashSubject = (Invoke-Git -Repository $Repository -Arguments @('show', '--no-patch', '--format=%s', $droppedHash) |
                    Select-Object -First 1).Trim()
                if (-not [string]::IsNullOrWhiteSpace($stashSubject)) { $recoveryMessage = $stashSubject }
            }
            catch {
                # The immutable commit hash is sufficient for recovery even when its original subject cannot be read.
            }

            try {
                Invoke-Git -Repository $Repository -Arguments @('stash', 'store', '--quiet', '-m', $recoveryMessage, $droppedHash) | Out-Null
            }
            catch {
                throw "An unrelated stash was removed after concurrent index drift and could not be restored: $droppedHash. $($_.Exception.Message)"
            }
            $restoredHashCount = @(
                Invoke-Git -Repository $Repository -Arguments @('stash', 'list', '--format=%H') |
                    Where-Object { ([string]$_).Trim() -ceq $droppedHash }
            ).Count
            if ($restoredHashCount -eq 0) {
                throw "An unrelated stash was removed after concurrent index drift but Git did not retain its restored hash: $droppedHash"
            }
            Write-Warning "Obsolete PersonalAgent cleanup observed concurrent stash index drift; the unrelated stash was restored and old evidence was retained: $droppedHash"
        }
    }

    return $newStashHash
}

$syncStartPath = Get-FullPathWithoutTrailingSeparator -Path (Get-Location).Path
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $resolvedRoot = & $GitExecutable -C (Get-Location).Path rev-parse --show-toplevel 2>$null
        $resolveExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($resolveExitCode -ne 0) {
        Write-Output 'AI instruction sync skipped: the current directory is not inside a Git repository.'
        return
    }

    $TargetRoot = ($resolvedRoot | Select-Object -First 1).Trim()
}

$targetRootPath = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
$syncStartRelativePath = ''
if ($syncStartPath.Equals($targetRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $syncStartRelativePath = ''
}
elseif ($syncStartPath.StartsWith($targetRootPath.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $syncStartRelativePath = Get-RepositoryRelativePath -RepositoryRoot $targetRootPath -FullPath $syncStartPath
}

$insideWorkTree = Invoke-Git -Repository $targetRootPath -Arguments @('rev-parse', '--is-inside-work-tree')
if (($insideWorkTree | Select-Object -First 1).Trim() -ne 'true') {
    Write-Output "AI instruction sync skipped: target is not a Git work tree: $targetRootPath"
    return
}

if (Test-IsCanonicalInstructionSourceRepository -Repository $targetRootPath) {
    Write-Output 'AI instruction sync skipped: the current repository is the shared instruction source.'
    return
}

if ((Get-GitExitCode -Repository $targetRootPath -Arguments @('rev-parse', '--verify', 'HEAD')) -ne 0) {
    Write-Output 'AI instruction sync skipped: the target repository has no commit, so managed changes cannot be isolated safely.'
    return
}

if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path $HOME '.codex'
    }
    $ConfigurationPath = Join-Path $codexHome 'ai-instructions-sync.json'
}

$configurationFullPath = [System.IO.Path]::GetFullPath($ConfigurationPath)
if (Test-Path -LiteralPath $configurationFullPath -PathType Leaf) {
    try {
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationFullPath | ConvertFrom-Json
    }
    catch {
        throw "AI instruction sync configuration is not valid JSON: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        $configuration.schemaVersion -ne 3) {
        throw "Unsupported AI instruction sync configuration schema: $configurationFullPath"
    }

    $excludedRepositoryLocations = @(
        if ($configuration.PSObject.Properties.Name -contains 'excludedRepositoryUrls') {
            foreach ($excludedRepositoryUrl in @($configuration.excludedRepositoryUrls)) {
                try {
                    Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $excludedRepositoryUrl)
                }
                catch {
                    throw "excludedRepositoryUrls contains an invalid repository URL '$excludedRepositoryUrl': $($_.Exception.Message)"
                }
            }
        }
    )

    $excludedRepositoryPaths = @(
        if ($configuration.PSObject.Properties.Name -contains 'excludedRepositoryPaths') {
            foreach ($excludedRepositoryPath in @($configuration.excludedRepositoryPaths)) {
                try {
                    Get-NormalizedRepositoryRelativeDirectoryPath -Path ([string] $excludedRepositoryPath)
                }
                catch {
                    throw "excludedRepositoryPaths contains an invalid repository-relative path '$excludedRepositoryPath': $($_.Exception.Message)"
                }
            }
        }
    )

    if (-not [string]::IsNullOrWhiteSpace($syncStartRelativePath) -and
        (Test-RepositoryDirectoryMatches -RepositoryRelativePath $syncStartRelativePath -ConfiguredRepositoryPaths $excludedRepositoryPaths)) {
        Write-Output "AI instruction sync skipped: directory is excluded by ai-instructions-sync.json: $syncStartRelativePath"
        return
    }

    if ($excludedRepositoryLocations.Count -gt 0 -and
        (Get-GitExitCode -Repository $targetRootPath -Arguments @('remote', 'get-url', 'origin')) -eq 0) {
        $originUrls = @(Invoke-Git -Repository $targetRootPath -Arguments @('remote', 'get-url', '--all', 'origin'))
        foreach ($originUrl in $originUrls) {
            $originLocation = Get-NormalizedRepositoryLocation -RepositoryUrl ([string] $originUrl)
            if (Test-RepositoryLocationMatches -RepositoryLocation $originLocation -ConfiguredRepositoryLocations $excludedRepositoryLocations) {
                Write-Output "AI instruction sync skipped: repository is excluded by ai-instructions-sync.json: $originUrl"
                return
            }
        }
    }
}

$repositoryOperationLock = $null
$repositoryIndexLock = $null
$remediationTransaction = $null
try {
    $repositoryOperationLock = Open-RepositoryOperationLock -Repository $targetRootPath
    $remediationTransaction = Invoke-AgentArtifactRemediation -Repository $targetRootPath -GitExecutable $GitExecutable
    if ($null -ne $remediationTransaction) {
        if (@($remediationTransaction.Paths).Count -gt 0) {
            Write-Output "Backed up and migrated tracked Agent artifacts: $($remediationTransaction.Paths -join ', '). Backup: $($remediationTransaction.Backup.Root)"
            if ([string]::IsNullOrWhiteSpace([string]$remediationTransaction.NewCommit)) {
                Write-Output 'Tracked Agent artifact index-only remediation required no commit.'
            }
            else {
                Write-Output "Agent artifact remediation commit created: $($remediationTransaction.NewCommit)"
            }
        }
        else {
            Write-Output "Backed up and removed retired custom FELO artifacts: $($remediationTransaction.MutationPaths -join ', '). Backup: $($remediationTransaction.Backup.Root)"
        }
    }

$families = @(
    @{
        Name = 'Codex'
        SourceBase = '.codex/AGENTS.en.md'
        TargetBase = 'AGENTS.md'
        SourceRules = '.codex/AI-Rules'
        TargetRules = '.codex/AI-Rules'
    },
    @{
        Name = 'GitHub Copilot'
        SourceBase = '.github/copilot-instructions.en.md'
        TargetBase = '.github/copilot-instructions.md'
        SourceRules = '.github/AI-Rules'
        TargetRules = '.github/AI-Rules'
    }
)
$sharedSkillsFamilyName = 'Shared Agent Skills'
$sharedSkillsSource = '.agents/skills'

$manifestFullPath = Join-Path $targetRootPath $manifestRelativePath.Replace('/', '\')
$manifestExists = Test-Path -LiteralPath $manifestFullPath -PathType Leaf
$manifestEntriesByTarget = @{}
$manifestSchemaVersion = $null
$script:instructionProvenance = $null
$script:skillProvenanceById = @{}
$provenance = $null

$resolvedProvenancePath = [System.IO.Path]::GetFullPath($ProvenancePath)
if (-not (Test-Path -LiteralPath $resolvedProvenancePath -PathType Leaf)) {
    throw "Managed source provenance does not exist: $resolvedProvenancePath"
}
try {
    $provenance = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedProvenancePath | ConvertFrom-Json
}
catch {
    throw "Managed source provenance is not valid JSON: $resolvedProvenancePath"
}
if ($provenance.schemaVersion -ne 1 -or
    [string]$provenance.catalogId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
    [string]$provenance.lockSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Managed source provenance has an unsupported schema, catalog ID, or lock hash.'
}

$script:instructionProvenance = $provenance.instruction
foreach ($requiredProperty in @('sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
    if ($null -eq $script:instructionProvenance.PSObject.Properties[$requiredProperty] -or
        [string]::IsNullOrWhiteSpace([string]$script:instructionProvenance.$requiredProperty)) {
        throw "Managed instruction provenance is missing '$requiredProperty'."
    }
}
if ([string]$script:instructionProvenance.sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
    [string]$script:instructionProvenance.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$script:instructionProvenance.sourceRepository -cnotmatch '^https://') {
    throw 'Managed instruction provenance contains an invalid source ID, repository, or commit.'
}

foreach ($skillSource in @($provenance.skills)) {
    $skillId = [string]$skillSource.id
    if ($skillId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        $script:skillProvenanceById.ContainsKey($skillId)) {
        throw "Managed Skill provenance contains an invalid or duplicate Skill ID: $skillId"
    }
    foreach ($requiredProperty in @('sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
        if ($null -eq $skillSource.PSObject.Properties[$requiredProperty] -or
            [string]::IsNullOrWhiteSpace([string]$skillSource.$requiredProperty)) {
            throw "Managed Skill '$skillId' provenance is missing '$requiredProperty'."
        }
    }
    if ([string]$skillSource.sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
        [string]$skillSource.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$skillSource.sourceRepository -cnotmatch '^https://') {
        throw "Managed Skill '$skillId' provenance contains an invalid source."
    }
    $script:skillProvenanceById[$skillId] = $skillSource
}

if ($manifestExists) {
    try {
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestFullPath | ConvertFrom-Json
    }
    catch {
        throw "Managed instruction manifest is not valid JSON: $manifestRelativePath"
    }

    $manifestSchemaVersion = $manifest.schemaVersion
    if (($manifestSchemaVersion -isnot [int] -and $manifestSchemaVersion -isnot [long]) -or $manifestSchemaVersion -notin @(1, 2)) {
        throw "Unsupported managed instruction manifest schema: $($manifest.schemaVersion)"
    }

    if ($manifestSchemaVersion -eq 2) {
        Assert-ManagedManifestV2 -Manifest $manifest
    }
    else { Assert-LegacyManagedManifestV1 -Manifest $manifest }

    if ($manifestSchemaVersion -eq 2 -and
        ([string]$manifest.catalogId -cne [string]$provenance.catalogId -or
         [string]$manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Managed instruction manifest Catalog identity or historical lock hash is invalid.'
    }
    foreach ($entry in @($manifest.files)) {
        $targetPath = [string] $entry.targetPath
        if (-not (Test-IsAllowedManagedPath -Path $targetPath)) {
            throw "Unsafe target path in managed instruction manifest: $targetPath"
        }

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            throw "Duplicate target path in managed instruction manifest: $targetPath"
        }

        if ([string]::IsNullOrWhiteSpace([string] $entry.sourcePath) -or
            [string] $entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid managed instruction manifest entry: $targetPath"
        }
        if ($manifestSchemaVersion -eq 2) {
            foreach ($requiredProperty in @('artifactType','artifactId','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
                if ($null -eq $entry.PSObject.Properties[$requiredProperty] -or
                    [string]::IsNullOrWhiteSpace([string]$entry.$requiredProperty)) {
                    throw "Managed instruction manifest entry '$targetPath' is missing '$requiredProperty'."
                }
            }
            if (@('instruction','skill') -cnotcontains [string]$entry.artifactType -or
                [string]$entry.artifactId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
                [string]$entry.sourceId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or
                [string]$entry.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
                [string]$entry.sourceRepository -cnotmatch '^https://') {
                throw "Managed instruction manifest entry '$targetPath' has invalid provenance."
            }
        }

        $manifestEntriesByTarget[$targetPath] = $entry
    }

    if ($manifestSchemaVersion -eq 1) {
        foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
            $entry = $manifestEntriesByTarget[$targetPath]
            $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf) -or
                (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) -or
                (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -cne [string]$entry.sha256) {
                throw "Cannot migrate managed manifest v1 because legacy managed file is customized, staged, or missing: $targetPath"
            }
        }
    }
}

$repositoryIndexLock = Open-RepositoryIndexTransactionLock -Repository $targetRootPath
$gitPathComparer = Get-GitPathComparer -Repository $targetRootPath
$trackedPaths = New-Object 'System.Collections.Generic.HashSet[string]' $gitPathComparer
foreach ($trackedPath in @(Invoke-Git -Repository $targetRootPath -Arguments @('-c','core.quotePath=true','ls-files'))) {
    [void]$trackedPaths.Add((ConvertFrom-GitQuotedPath -Path ([string]$trackedPath)).Replace('\','/'))
}
$trackedPollutionPaths = @(@(
    if ($trackedPaths.Contains($manifestRelativePath)) { $manifestRelativePath }
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if ($trackedPaths.Contains([string]$targetPath)) { [string]$targetPath }
    }
) | Sort-Object -Unique)
if ($trackedPollutionPaths.Count -gt 0) {
    throw "Tracked reserved Agent artifacts remain after controlled remediation: $($trackedPollutionPaths -join ', ')."
}

$stagedManagedPaths = @(
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path ([string]$targetPath)) {
            [string]$targetPath
        }
    }
)
if ($stagedManagedPaths.Count -gt 0) {
    Write-Output "AI instruction sync skipped because a managed path has staged changes: $($stagedManagedPaths -join ', ')"
    return
}

if ($manifestExists -and
    (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $manifestRelativePath)) {
    Write-Output 'AI instruction sync skipped because the managed manifest has staged changes.'
    return
}

$tempRootPath = Get-FullPathWithoutTrailingSeparator -Path ([System.IO.Path]::GetTempPath())
$workingPath = Join-Path $tempRootPath ('codex-ai-instructions-' + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $workingPath 'source.zip'
$extractPath = Join-Path $workingPath 'source'
$preserveWorkingPath = $false

try {
    New-Item -ItemType Directory -Path $workingPath, $extractPath | Out-Null

    $providedArchivePath = Get-FullPathWithoutTrailingSeparator -Path $SourceArchivePath
    if (-not (Test-Path -LiteralPath $providedArchivePath -PathType Leaf)) {
        throw "Source archive does not exist: $providedArchivePath"
    }

    Copy-Item -LiteralPath $providedArchivePath -Destination $archivePath

    $sourceRootPath = Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot $extractPath
    $desiredEntries = New-Object System.Collections.Generic.List[object]

    foreach ($family in $families) {
        $sourceBasePath = Join-Path $sourceRootPath $family.SourceBase.Replace('/', '\')
        $sourceRulesPath = Join-Path $sourceRootPath $family.SourceRules.Replace('/', '\')

        if (-not (Test-Path -LiteralPath $sourceBasePath -PathType Leaf)) {
            throw "$($family.Name) base instruction is missing from GitHub archive: $($family.SourceBase)"
        }

        if (-not (Test-Path -LiteralPath $sourceRulesPath -PathType Container)) {
            throw "$($family.Name) rule directory is missing from GitHub archive: $($family.SourceRules)"
        }

        $englishRules = @(Get-ChildItem -LiteralPath $sourceRulesPath -File -Filter '*.en.md' | Sort-Object Name)
        if ($englishRules.Count -eq 0) {
            throw "$($family.Name) has no English rule modules in the GitHub archive."
        }

        $desiredEntries.Add([pscustomobject]@{
            FamilyName = $family.Name
            SourcePath = $family.SourceBase
            TargetPath = $family.TargetBase
            SourceFullPath = $sourceBasePath
            Sha256 = Get-NormalizedContentHash -Path $sourceBasePath
        })

        foreach ($sourceRule in $englishRules) {
            $sourceRelativePath = "$($family.SourceRules)/$($sourceRule.Name)"
            $targetRelativePath = "$($family.TargetRules)/$($sourceRule.Name)"
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $family.Name
                SourcePath = $sourceRelativePath
                TargetPath = $targetRelativePath
                SourceFullPath = $sourceRule.FullName
                Sha256 = Get-NormalizedContentHash -Path $sourceRule.FullName
            })
        }
        $artifactPaths = @($desiredEntries | Where-Object FamilyName -eq $family.Name | ForEach-Object SourcePath)
        $licenses = New-LicenseDeliveryPackage -SourceRoot $sourceRootPath -ArtifactPaths $artifactPaths `
            -SourceRepository $script:instructionProvenance.sourceRepository -SourceCommit $script:instructionProvenance.sourceCommit `
            -ArtifactId $family.Name
        $licenseRoot = Join-Path $workingPath "licenses/$($family.Name)"
        Write-LicenseDeliveryPackage -Package $licenses -DestinationRoot $licenseRoot
        $licenseTargetPrefix = if ($family.Name -eq 'Codex') { '.codex' } else { '.github' }
        foreach ($licenseFile in @($licenses.Files)) {
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $family.Name; SourcePath = $licenseFile.sourcePath
                TargetPath = "$licenseTargetPrefix/ai-instructions-licenses/$($licenseFile.relativePath)"
                SourceFullPath = (Join-Path $licenseRoot $licenseFile.relativePath); Sha256 = $licenseFile.sha256
            })
        }
    }

    $sourceSkillsPath = Join-Path $sourceRootPath $sharedSkillsSource.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $sourceSkillsPath -PathType Container)) {
        throw "Shared Agent Skill directory is missing from GitHub archive: $sharedSkillsSource"
    }

    $unexpectedRootSkillFiles = @(
        Get-ChildItem -LiteralPath $sourceSkillsPath -File |
            Where-Object { $_.Name -ne '.gitkeep' }
    )
    if ($unexpectedRootSkillFiles.Count -gt 0) {
        throw "Shared Agent Skill files must be inside a named skill directory: $($unexpectedRootSkillFiles.Name -join ', ')"
    }

    $sourceSkillDirectories = @(Get-ChildItem -LiteralPath $sourceSkillsPath -Directory | Sort-Object Name)
    foreach ($sourceSkillDirectory in $sourceSkillDirectories) {
        if ($sourceSkillDirectory.Name -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
            throw "Invalid shared Agent Skill directory name: $($sourceSkillDirectory.Name)"
        }

        $sourceSkillDefinition = Join-Path $sourceSkillDirectory.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $sourceSkillDefinition -PathType Leaf)) {
            throw "Shared Agent Skill is missing SKILL.md: $($sourceSkillDirectory.Name)"
        }

        $sourceSkillFiles = @(
            Get-ChildItem -LiteralPath $sourceSkillDirectory.FullName -Recurse -File -Force |
                Where-Object { $_.Name -ne '.gitkeep' } |
                Sort-Object FullName
        )
        foreach ($sourceSkillFile in $sourceSkillFiles) {
            $sourceRelativePath = Get-RepositoryRelativePath -RepositoryRoot $sourceRootPath -FullPath $sourceSkillFile.FullName
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $sharedSkillsFamilyName
                SourcePath = $sourceRelativePath
                TargetPath = $sourceRelativePath
                SourceFullPath = $sourceSkillFile.FullName
                Sha256 = Get-RawContentHash -Path $sourceSkillFile.FullName
            })
        }
    }

    $desiredEntriesByTarget = @{}
    foreach ($entry in $desiredEntries) {
        if (-not (Test-IsAllowedManagedPath -Path $entry.TargetPath)) {
            throw "Unsafe desired instruction target path: $($entry.TargetPath)"
        }

        if ($desiredEntriesByTarget.ContainsKey($entry.TargetPath)) {
            throw "Duplicate desired instruction target path: $($entry.TargetPath)"
        }

        $desiredEntriesByTarget[$entry.TargetPath] = $entry
    }

    $eligibleFamilies = @{}
    foreach ($family in $families) {
        $baseTargetPath = $family.TargetBase
        $baseTargetFullPath = Join-Path $targetRootPath $baseTargetPath.Replace('/', '\')
        $baseTargetIsTracked = $trackedPaths.Contains($baseTargetPath)
        $baseTargetMatchesDesired = $false
        if ((Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -and
            -not $baseTargetIsTracked -and
            $desiredEntriesByTarget.ContainsKey($baseTargetPath)) {
            $baseTargetMatchesDesired =
                (Get-ManagedContentHash -Path $baseTargetFullPath -TargetPath $baseTargetPath) -ceq
                [string]$desiredEntriesByTarget[$baseTargetPath].Sha256
        }
        $eligibleFamilies[$family.Name] =
            -not $baseTargetIsTracked -and
            ($manifestEntriesByTarget.ContainsKey($baseTargetPath) -or
             -not (Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -or
             $baseTargetMatchesDesired)
    }
    $eligibleSkillIds = @{}
    foreach ($sourceSkillDirectory in $sourceSkillDirectories) {
        $skillId = [string]$sourceSkillDirectory.Name
        $skillPrefix = ".agents/skills/$skillId/"
        $skillBasePath = $skillPrefix + 'SKILL.md'
        $skillBaseFullPath = Join-Path $targetRootPath $skillBasePath.Replace('/','\')
        $skillManifestOwned = @($manifestEntriesByTarget.Keys | Where-Object { ([string]$_).StartsWith($skillPrefix,[System.StringComparison]::Ordinal) }).Count -gt 0
        $skillHasTrackedPath = @($trackedPaths | Where-Object {
            $trackedPath = [string]$_
            $trackedPath.Length -gt $skillPrefix.Length -and
                $gitPathComparer.Equals($trackedPath.Substring(0,$skillPrefix.Length),$skillPrefix)
        }).Count -gt 0
        $skillBaseMatchesDesired = $false
        if ((Test-Path -LiteralPath $skillBaseFullPath -PathType Leaf) -and
            -not $skillHasTrackedPath -and
            $desiredEntriesByTarget.ContainsKey($skillBasePath)) {
            $skillBaseMatchesDesired =
                (Get-ManagedContentHash -Path $skillBaseFullPath -TargetPath $skillBasePath) -ceq
                [string]$desiredEntriesByTarget[$skillBasePath].Sha256
        }
        $eligibleSkillIds[$skillId] =
            -not $skillHasTrackedPath -and
            ($skillManifestOwned -or -not (Test-Path -LiteralPath $skillBaseFullPath -PathType Leaf) -or $skillBaseMatchesDesired)
    }

    $createdPaths = New-Object System.Collections.Generic.List[string]
    $updatedPaths = New-Object System.Collections.Generic.List[string]
    $removedPaths = New-Object System.Collections.Generic.List[string]
    $skippedPaths = New-Object System.Collections.Generic.List[string]
    $nextManifestEntries = New-Object System.Collections.Generic.List[object]

    $mutationPaths = @(
        @($desiredEntries | ForEach-Object { [string]$_.TargetPath })
        @($manifestEntriesByTarget.Keys)
        $manifestRelativePath
    )
    $mutationBackupRoot = Join-Path $workingPath 'target-backup'
    $mutationSnapshot = New-TargetMutationSnapshot -TargetRoot $targetRootPath -RelativePaths $mutationPaths -BackupRoot $mutationBackupRoot
    $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRootPath

    try {
        foreach ($desiredEntry in @($desiredEntries | Sort-Object TargetPath)) {
        $targetPath = $desiredEntry.TargetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        $targetExists = Test-Path -LiteralPath $targetFullPath -PathType Leaf
        $managedEntry = $null

        $entryIsEligible = [bool]$eligibleFamilies[$desiredEntry.FamilyName]
        if ($targetPath.StartsWith('.agents/skills/',[System.StringComparison]::Ordinal)) {
            $skillId = @($targetPath.Split('/'))[2]
            $entryIsEligible = $eligibleSkillIds.ContainsKey($skillId) -and [bool]$eligibleSkillIds[$skillId]
        }
        if (-not $entryIsEligible) {
            $skippedPaths.Add($targetPath)
            continue
        }

        $desiredManifestEntry = New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            $managedEntry = $manifestEntriesByTarget[$targetPath]
        }

        if ($null -ne $managedEntry) {
            if (-not $targetExists) {
                if (Test-GitPathHasChanges -Repository $targetRootPath -Path $targetPath) {
                    $skippedPaths.Add($targetPath)
                    $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                    continue
                }

                [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
                Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes
                $updatedPaths.Add($targetPath)
                $nextManifestEntries.Add($desiredManifestEntry)
                continue
            }

            if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                continue
            }

            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath
            if ($currentHash -eq [string] $managedEntry.sha256 -or $currentHash -eq $desiredEntry.Sha256) {
                if ($currentHash -ne $desiredEntry.Sha256) {
                    [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
                    Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes
                    $updatedPaths.Add($targetPath)
                }

                $nextManifestEntries.Add($desiredManifestEntry)
            }
            else {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
            }

            continue
        }

        if (-not $targetExists) {
            if ($trackedPaths.Contains($targetPath)) {
                $skippedPaths.Add($targetPath)
                continue
            }
            [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
            Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes
            $createdPaths.Add($targetPath)
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        if (-not $trackedPaths.Contains($targetPath) -and
            -not (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath) -and
            (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -ceq $desiredEntry.Sha256) {
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        $skippedPaths.Add($targetPath)
        }

        foreach ($managedTargetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if ($desiredEntriesByTarget.ContainsKey($managedTargetPath)) {
            continue
        }

        $managedEntry = $manifestEntriesByTarget[$managedTargetPath]
        $targetFullPath = Join-Path $targetRootPath $managedTargetPath.Replace('/', '\')
        if (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $managedTargetPath) {
            $skippedPaths.Add($managedTargetPath)
            $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
            continue
        }

        if (Test-Path -LiteralPath $targetFullPath -PathType Leaf) {
            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $managedTargetPath
            if ($currentHash -ne [string] $managedEntry.sha256) {
                $skippedPaths.Add($managedTargetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                continue
            }

            Remove-TargetMutationFile -Snapshot $mutationSnapshot -RelativePath $managedTargetPath
            $removedPaths.Add($managedTargetPath)
        }
        }

        $shouldWriteManifest = $manifestExists -or $nextManifestEntries.Count -gt 0
        $manifestChanged = $false
        if ($shouldWriteManifest) {
        $manifestObject = [ordered]@{
            schemaVersion = 2
            catalogId = [string] $provenance.catalogId
            lockSha256 = [string] $provenance.lockSha256
            files = @($nextManifestEntries | Sort-Object targetPath)
        }
        $manifestJson = ($manifestObject | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
        $existingManifestJson = if ($manifestExists) {
            ([System.IO.File]::ReadAllText($manifestFullPath)).Replace("`r`n", "`n").Replace("`r", "`n")
        }
        else {
            $null
        }

        if ($existingManifestJson -ne $manifestJson) {
            $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
            [byte[]]$manifestBytes = $utf8WithoutBom.GetBytes($manifestJson)
            Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $manifestRelativePath -Bytes $manifestBytes
            $manifestChanged = $true
        }
        }
        $managedExcludePaths = @($nextManifestEntries | ForEach-Object { [string]$_.targetPath })
        if ($shouldWriteManifest) { $managedExcludePaths += $manifestRelativePath }
        Set-ManagedGitInfoExclude -Repository $targetRootPath -ManagedPaths $managedExcludePaths -Snapshot $excludeSnapshot
    }
    catch {
        $mutationError = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        try { Restore-TargetMutationSnapshot -Snapshot $mutationSnapshot }
        catch { $rollbackErrors.Add($_.Exception.Message) }
        try { Restore-GitInfoExcludeSnapshot -Snapshot $excludeSnapshot }
        catch { $rollbackErrors.Add($_.Exception.Message) }
        if ($rollbackErrors.Count -gt 0) {
            $preserveWorkingPath = $true
            throw "AI instruction target mutation failed: $($mutationError.Exception.Message) Rollback also failed: $($rollbackErrors -join ' | ') Recovery files were preserved at: $mutationBackupRoot"
        }
        throw $mutationError
    }

    if ($skippedPaths.Count -gt 0) {
        $uniqueSkippedPaths = @($skippedPaths | Sort-Object -Unique)
        Write-Output "AI instructions customized or unmanaged; not overwritten: $($uniqueSkippedPaths -join ', ')"
    }

    $changedPaths = @(
        @($createdPaths) +
        @($updatedPaths) +
        @($removedPaths) +
        $(if ($manifestChanged) { @($manifestRelativePath) } else { @() }) |
            Sort-Object -Unique
    )

    $stashPathArguments = @()
    try {
        $stashPaths = New-Object System.Collections.Generic.List[string]
        foreach ($manifestEntry in $nextManifestEntries) {
            $targetPath = [string]$manifestEntry.targetPath
            $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
            if ((Test-Path -LiteralPath $targetFullPath -PathType Leaf) -and
                (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath) -ceq [string]$manifestEntry.sha256) {
                $stashPaths.Add($targetPath)
            }
        }
        if (Test-Path -LiteralPath $manifestFullPath -PathType Leaf) { $stashPaths.Add($manifestRelativePath) }
        $stashPathArguments = @($stashPaths | Sort-Object -Unique)
        if ($stashPathArguments.Count -gt 0) {
            $worktreeKey = Get-PersonalAgentWorktreeKey -Repository $targetRootPath
            $evidenceFingerprint = Get-PersonalAgentEvidenceFingerprint -Repository $targetRootPath -Paths $stashPathArguments
            $personalAgentStashes = @(Get-PersonalAgentStashes -Repository $targetRootPath -WorktreeKey $worktreeKey)
            $ownedPersonalAgentStashes = @($personalAgentStashes | Where-Object {
                Test-PersonalAgentStashEvidence -Repository $targetRootPath -Stash $_ `
                    -ExpectedFingerprint ([string]$_.EvidenceFingerprint)
            })
            $matchingEvidence = @($ownedPersonalAgentStashes | Where-Object { $_.EvidenceFingerprint -ceq $evidenceFingerprint })
            $shouldRefreshPersonalAgentStash = $changedPaths.Count -gt 0 -or $matchingEvidence.Count -ne 1
            if ($shouldRefreshPersonalAgentStash) {
                $expectedStashEntries = @($nextManifestEntries | Where-Object { [string]$_.targetPath -cin $stashPathArguments })
                $newStashHash = Update-PersonalAgentStash -Repository $targetRootPath -Paths $stashPathArguments `
                    -ExpectedEntries $expectedStashEntries -PriorStashes $personalAgentStashes `
                    -PriorOwnedStashes $ownedPersonalAgentStashes `
                    -WorktreeKey $worktreeKey -EvidenceFingerprint $evidenceFingerprint `
                    -ActiveIndexPath ([string]$repositoryIndexLock.IndexPath)
                Write-Output "PersonalAgent recovery evidence updated and retained without index mutation: $newStashHash"
            }
        }
    }
    catch {
        $finalizationError = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        try { Restore-TargetMutationTransaction -Repository $targetRootPath -Paths $stashPathArguments -Snapshot $mutationSnapshot }
        catch { $rollbackErrors.Add($_.Exception.Message) }
        try { Restore-GitInfoExcludeSnapshot -Snapshot $excludeSnapshot }
        catch { $rollbackErrors.Add($_.Exception.Message) }
        if ($rollbackErrors.Count -gt 0) {
            $preserveWorkingPath = $true
            throw "PersonalAgent stash finalization failed: $($finalizationError.Exception.Message) Rollback also failed: $($rollbackErrors -join ' | ') Recovery files were preserved at: $mutationBackupRoot"
        }
        throw $finalizationError
    }

    if ($changedPaths.Count -eq 0) { Write-Output 'AI instructions are up to date; no Git commit was created.' }
    else { Write-Output "AI instructions synchronized as local ignored runtime artifacts without Git commit: $($changedPaths -join ', ')" }
}
catch {
    $syncError = $_
    if ($null -ne $remediationTransaction -and -not [bool]$remediationTransaction.RollbackAttempted) {
        try { Restore-AgentArtifactRemediation -Transaction $remediationTransaction }
        catch {
            throw "AI instruction sync failed after Agent artifact remediation: $($syncError.Exception.Message) $($_.Exception.Message)"
        }
    }
    throw $syncError
}
finally {
    $resolvedWorkingPath = [System.IO.Path]::GetFullPath($workingPath)
    $expectedPrefix = $tempRootPath.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkingPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe temporary cleanup path: $resolvedWorkingPath"
    }

    if ($preserveWorkingPath) {
        Write-Warning "AI instruction sync temporary recovery files were preserved at: $resolvedWorkingPath"
    }
    else {
        Remove-Item -LiteralPath $resolvedWorkingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
}
catch {
    $bootstrapError = $_
    if ($null -ne $remediationTransaction -and -not [bool]$remediationTransaction.RollbackAttempted) {
        try { Restore-AgentArtifactRemediation -Transaction $remediationTransaction }
        catch {
            throw "AI instruction bootstrap failed after Agent artifact remediation: $($bootstrapError.Exception.Message) $($_.Exception.Message)"
        }
    }
    throw $bootstrapError
}
finally {
    if ($null -ne $repositoryIndexLock) {
        $repositoryIndexLock.Stream.Dispose()
        if (Test-Path -LiteralPath ([string]$repositoryIndexLock.Path) -PathType Leaf) {
            Remove-Item -LiteralPath ([string]$repositoryIndexLock.Path) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $repositoryOperationLock) { $repositoryOperationLock.Dispose() }
}
