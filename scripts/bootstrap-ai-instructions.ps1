[CmdletBinding()]
param(
    [string] $SourceArchivePath,
    [string] $TargetRoot,
    [string] $ConfigurationPath,
    [string] $ProvenancePath,
    [string] $GitExecutable = 'git',
    [string] $UserHome = [Environment]::GetFolderPath('UserProfile'),
    [switch] $WhatIf,
    [int] $FailureAfterSkillRemovalCount = 0,
    [string] $RecoverSkillMigration
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
Import-Module (Join-Path $PSScriptRoot 'repo-shared-skills-migration.psm1') -Force

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

    public sealed class FileDaclSnapshot
    {
        public bool IsNull { get; private set; }
        public byte[] AclBytes { get; private set; }
        public bool IsProtected { get; private set; }

        public FileDaclSnapshot(bool isNull, byte[] aclBytes, bool isProtected)
        {
            IsNull = isNull;
            AclBytes = aclBytes;
            IsProtected = isProtected;
        }
    }

    public sealed class AtomicDirectoryGuard : IDisposable
    {
        private List<SafeFileHandle> directoryHandles;

        internal AtomicDirectoryGuard(List<SafeFileHandle> handles)
        {
            directoryHandles = handles;
        }

        public void Dispose()
        {
            if (directoryHandles == null) return;
            for (int index = directoryHandles.Count - 1; index >= 0; index--) directoryHandles[index].Dispose();
            directoryHandles = null;
        }
    }

    public static class NativeFileMutation
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint Delete = 0x00010000;
        private const uint ReadControl = 0x00020000;
        private const uint WriteDac = 0x00040000;
        private const uint FileWriteAttributes = 0x00000100;
        private const uint FileReadAttributes = 0x00000080;
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
        private const int FileRenameInfoClass = 3;
        private const int ErrorAlreadyExists = 183;
        private const uint SecurityInformationDacl = 0x00000004;
        private const uint SecurityInformationProtectedDacl = 0x80000000;
        private const uint SecurityInformationUnprotectedDacl = 0x20000000;
        private const int SeFileObject = 1;
        private const ushort SeDaclProtected = 0x1000;

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

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileRenameInfoByHandle(
            SafeFileHandle file,
            int fileInformationClass,
            IntPtr fileInformation,
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

        [DllImport("advapi32.dll", SetLastError = false, EntryPoint = "GetSecurityInfo")]
        private static extern uint GetSecurityInfo(
            SafeFileHandle handle, int objectType, uint securityInfo,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);

        [DllImport("advapi32.dll", SetLastError = false, EntryPoint = "SetSecurityInfo")]
        private static extern uint SetSecurityInfo(
            SafeFileHandle handle, int objectType, uint securityInfo,
            IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);

        [DllImport("advapi32.dll", SetLastError = true, EntryPoint = "GetSecurityDescriptorControl")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorControl(IntPtr securityDescriptor, out ushort control, out uint revision);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "LocalFree")]
        private static extern IntPtr LocalFree(IntPtr memory);

        public static SafeFileHandle OpenForAtomicDelete(string targetRoot, string path, string relativePath)
        {
            return OpenValidatedTarget(
                targetRoot,
                path,
                relativePath,
                GenericRead | ReadControl | Delete | FileWriteAttributes,
                FileShareRead);
        }

        public static SafeFileHandle OpenForMetadata(string targetRoot, string path, string relativePath)
        {
            return OpenValidatedTarget(
                targetRoot, path, relativePath, GenericRead | ReadControl | FileWriteAttributes, FileShareRead, false);
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
            return OpenForAtomicCreate(targetRoot, path, relativePath, false);
        }

        public static AtomicDirectoryGuard OpenForAtomicDirectoryGuard(string targetRoot, string relativeDirectoryPath)
        {
            string safeRelativePath = string.IsNullOrWhiteSpace(relativeDirectoryPath)
                ? string.Empty
                : NormalizeRelativePath(relativeDirectoryPath);
            string lexicalRoot = Path.GetFullPath(targetRoot).TrimEnd('\\');
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                SafeFileHandle rootHandle = OpenValidatedDirectory(
                    lexicalRoot, null, GenericRead, FileShareRead | FileShareWrite,
                    "Unable to guard the publication target root.");
                handles.Add(rootHandle);
                string currentPath = lexicalRoot;
                string currentFinalPath = GetFinalPath(rootHandle).TrimEnd('\\');
                if (safeRelativePath.Length > 0)
                {
                    foreach (string segment in safeRelativePath.Split('\\'))
                    {
                        currentPath = Path.Combine(currentPath, segment);
                        currentFinalPath = currentFinalPath + "\\" + segment;
                        SafeFileHandle directoryHandle = OpenValidatedDirectory(
                            currentPath, currentFinalPath, GenericRead, FileShareRead | FileShareWrite,
                            "Unable to guard a publication parent directory.");
                        handles.Add(directoryHandle);
                    }
                }
                AtomicDirectoryGuard result = new AtomicDirectoryGuard(handles);
                handles = null;
                return result;
            }
            finally
            {
                if (handles != null)
                {
                    for (int index = handles.Count - 1; index >= 0; index--) handles[index].Dispose();
                }
            }
        }

        public static AtomicCreateContext OpenForAtomicCreate(
            string targetRoot,
            string path,
            string relativePath,
            bool includeDaclWrite)
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
                    GenericRead | GenericWrite | Delete | FileWriteAttributes | (includeDaclWrite ? WriteDac : 0),
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
            uint shareMode,
            bool requireSingleLink = true)
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
                    ValidateFileHandle(handle, rootFinalPath + "\\" + safeRelativePath, "managed-file mutation", requireSingleLink);
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

        private static void ValidateFileHandle(SafeFileHandle handle, string expectedFinalPath, string operation, bool requireSingleLink = true)
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
            if (requireSingleLink && information.NumberOfLinks != 1)
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

        public static string GetFileIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation information = GetInformation(handle, "Unable to identify a guarded file handle.");
            return information.VolumeSerialNumber.ToString("x8") + ":" +
                information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
        }

        public static string GetDirectoryIdentity(string path)
        {
            SafeFileHandle handle = CreateFile(
                path, FileReadAttributes, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, "Unable to open the guarded publication parent directory.");
                ByHandleFileInformation information = GetInformation(handle, "Unable to identify the guarded publication parent directory.");
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
                    (information.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new IOException("The guarded publication parent must be a non-reparse directory.");
                }
                return GetFileIdentity(handle);
            }
            finally { if (handle != null) handle.Dispose(); }
        }

        public static SafeFileHandle OpenStandaloneForAtomicDelete(string path)
        {
            SafeFileHandle handle = CreateFile(
                path, GenericRead | ReadControl | Delete | FileWriteAttributes, FileShareRead,
                IntPtr.Zero, OpenExisting, FileAttributeNormal | FileFlagOpenReparsePoint, IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, "Unable to acquire the exclusive shared Git exclude mutation handle.");
                ByHandleFileInformation information = GetInformation(handle, "Unable to inspect the shared Git exclude handle.");
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
                    (information.FileAttributes & FileAttributeDirectory) != 0 || information.NumberOfLinks != 1)
                {
                    throw new IOException("The shared Git exclude is not a single-link regular file.");
                }
                return handle;
            }
            catch
            {
                if (handle != null) handle.Dispose();
                throw;
            }
        }

        public static SafeFileHandle OpenStandaloneForMetadata(string path)
        {
            SafeFileHandle handle = CreateFile(
                path, GenericRead | ReadControl | FileReadAttributes, FileShareRead | FileShareWrite,
                IntPtr.Zero, OpenExisting, FileAttributeNormal | FileFlagOpenReparsePoint, IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, "Unable to inspect the shared Git exclude metadata.");
                ByHandleFileInformation information = GetInformation(handle, "Unable to inspect the shared Git exclude metadata.");
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
                    (information.FileAttributes & FileAttributeDirectory) != 0)
                {
                    throw new IOException("The shared Git exclude must be a regular file.");
                }
                return handle;
            }
            catch
            {
                if (handle != null) handle.Dispose();
                throw;
            }
        }

        public static FileDaclSnapshot CaptureDacl(SafeFileHandle handle)
        {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(handle, SeFileObject, SecurityInformationDacl,
                out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new Win32Exception((int)error, "Unable to read the file DACL for safe publication.");
            try
            {
                ushort control;
                uint revision;
                if (!GetSecurityDescriptorControl(descriptor, out control, out revision))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to inspect file DACL protection for safe publication.");
                }
                byte[] bytes = null;
                if (dacl != IntPtr.Zero)
                {
                    int size = (ushort)Marshal.ReadInt16(dacl, 2);
                    if (size < 8) throw new IOException("The file DACL has an invalid ACL size.");
                    bytes = new byte[size];
                    Marshal.Copy(dacl, bytes, 0, size);
                }
                return new FileDaclSnapshot(dacl == IntPtr.Zero, bytes, (control & SeDaclProtected) != 0);
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }

        public static void SetDacl(SafeFileHandle handle, FileDaclSnapshot snapshot)
        {
            if (snapshot == null) throw new ArgumentNullException("snapshot");
            IntPtr acl = IntPtr.Zero;
            try
            {
                if (!snapshot.IsNull)
                {
                    if (snapshot.AclBytes == null || snapshot.AclBytes.Length < 8)
                    {
                        throw new IOException("The saved file DACL is incomplete.");
                    }
                    acl = Marshal.AllocHGlobal(snapshot.AclBytes.Length);
                    Marshal.Copy(snapshot.AclBytes, 0, acl, snapshot.AclBytes.Length);
                }
                uint flags = SecurityInformationDacl |
                    (snapshot.IsProtected ? SecurityInformationProtectedDacl : SecurityInformationUnprotectedDacl);
                uint error = SetSecurityInfo(handle, SeFileObject, flags, IntPtr.Zero, IntPtr.Zero, acl, IntPtr.Zero);
                if (error != 0) throw new Win32Exception((int)error, "Unable to apply the saved file DACL to the staged file.");
            }
            finally { if (acl != IntPtr.Zero) Marshal.FreeHGlobal(acl); }
        }

        public static bool DaclEquals(FileDaclSnapshot left, FileDaclSnapshot right)
        {
            if (left == null || right == null) return left == right;
            if (left.IsNull != right.IsNull || left.IsProtected != right.IsProtected) return false;
            if (left.IsNull) return true;
            if (left.AclBytes == null || right.AclBytes == null || left.AclBytes.Length != right.AclBytes.Length) return false;
            for (int index = 0; index < left.AclBytes.Length; index++)
            {
                if (left.AclBytes[index] != right.AclBytes[index]) return false;
            }
            return true;
        }

        public static bool GetReadOnly(SafeFileHandle handle)
        {
            return (GetAttributes(handle) & FileAttributeReadOnly) != 0;
        }

        public static void SetReadOnly(SafeFileHandle handle, bool readOnly)
        {
            uint attributes = GetAttributes(handle);
            if (readOnly) attributes |= FileAttributeReadOnly;
            else attributes &= ~FileAttributeReadOnly;
            SetAttributes(handle, attributes);
        }

        public static void RenameNoReplace(SafeFileHandle handle, string destinationPath)
        {
            string destination = Path.GetFullPath(destinationPath);
            byte[] fileName = Encoding.Unicode.GetBytes(destination);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + 4;
            int size = nameOffset + fileName.Length + sizeof(char);
            IntPtr information = Marshal.AllocHGlobal(size);
            try
            {
                for (int index = 0; index < size; index++) Marshal.WriteByte(information, index, 0);
                Marshal.WriteByte(information, 0, 0); // ReplaceIfExists = FALSE (classic FileRenameInfo)
                Marshal.WriteIntPtr(information, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(information, lengthOffset, fileName.Length);
                Marshal.Copy(fileName, 0, IntPtr.Add(information, nameOffset), fileName.Length);
                if (!SetFileRenameInfoByHandle(handle, FileRenameInfoClass, information, (uint)size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "A no-replace handle-bound publication rename failed; the current destination was preserved.");
                }
            }
            finally { Marshal.FreeHGlobal(information); }
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

function Get-ByteArraySha256 {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
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
            if ($worktreeManifestSchemaVersion -in @(2,3)) { Assert-ManagedManifest -Manifest $worktreeManifest }
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
    $snapshot = [pscustomobject][ordered]@{
        Path = $path
        Repository = $Repository
        MutationApplied = $false
        Existed = $false
        Bytes = $null
        AppliedBytes = $null
        DaclRecord = $null
        OriginalReadOnly = $false
        OriginalIdentity = $null
        AppliedFileIdentity = $null
        Publication = $null
        PublicationDaclRecord = $null
        PublicationReadOnly = $false
        LegacyRecovery = $false
    }
    $metadataHandle = $null
    $metadataStream = $null
    try {
        $snapshot.Existed = Test-Path -LiteralPath $path -PathType Leaf
        if ($snapshot.Existed) {
            $metadataHandle = [CodexAiInstructions.NativeFileMutation]::OpenStandaloneForMetadata($path)
            $metadataStream = [System.IO.FileStream]::new($metadataHandle,[System.IO.FileAccess]::Read)
            $metadataHandle = $null
            $snapshot.Bytes = [byte[]](Read-GitInfoExcludeStreamBytes -Stream $metadataStream)
            $snapshot.DaclRecord = Get-FileDaclJournalRecord -Handle $metadataStream.SafeFileHandle
            $snapshot.OriginalReadOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($metadataStream.SafeFileHandle)
            $snapshot.OriginalIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($metadataStream.SafeFileHandle)
        }
    }
    finally {
        if ($null -ne $metadataStream) { $metadataStream.Dispose() }
        if ($null -ne $metadataHandle) { $metadataHandle.Dispose() }
    }
    return $snapshot
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
    $stream = $null
    $nativeHandle = $null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            if ($RequireExisting) { throw [System.IO.FileNotFoundException]::new("Shared Git exclude disappeared: $Path") }
            return [pscustomobject]@{ Stream=$null; Created=$true }
        }
        $nativeHandle = [CodexAiInstructions.NativeFileMutation]::OpenStandaloneForAtomicDelete($Path)
        $stream = [System.IO.FileStream]::new($nativeHandle,[System.IO.FileAccess]::Read)
        $nativeHandle = $null
        return [pscustomobject]@{ Stream=$stream; Created=$false }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $nativeHandle) { $nativeHandle.Dispose() }
        throw "Unable to acquire the exclusive shared Git exclude mutation handle; another process may be changing '$Path'. $($_.Exception.Message)"
    }
}

function Restore-GitInfoExcludeSnapshot {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    if ($null -ne $Snapshot.Publication) {
        Resolve-AtomicFilePublication -Kind Exclude -Root ([string]$Snapshot.Repository) -Path ([string]$Snapshot.Path) `
            -RelativePath ([IO.Path]::GetFileName([string]$Snapshot.Path)) -PublicationState $Snapshot
    }
    if (-not [bool]$Snapshot.MutationApplied) { return }
    if ($null -eq $Snapshot.Publication -and -not [bool]$Snapshot.LegacyRecovery) {
        if (-not [bool]$Snapshot.Existed -and -not (Test-Path -LiteralPath ([string]$Snapshot.Path))) {
            $Snapshot.MutationApplied = $false
            return
        }
        if ([bool]$Snapshot.Existed -and (Test-Path -LiteralPath ([string]$Snapshot.Path) -PathType Leaf)) {
            $originalHandle = $null
            try {
                $originalHandle = Open-GitInfoExcludeMutationHandle -Repository ([string]$Snapshot.Repository) -Path ([string]$Snapshot.Path) -RequireExisting
                [byte[]]$originalCurrent = Read-GitInfoExcludeStreamBytes -Stream $originalHandle.Stream
                $isOriginal = (Test-GitInfoExcludeBytesEqual -Left $originalCurrent -Right ([byte[]]$Snapshot.Bytes)) -and
                    ([CodexAiInstructions.NativeFileMutation]::GetFileIdentity($originalHandle.Stream.SafeFileHandle) -ceq [string]$Snapshot.OriginalIdentity) -and
                    ([bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($originalHandle.Stream.SafeFileHandle) -eq [bool]$Snapshot.OriginalReadOnly) -and
                    [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                        (ConvertFrom-FileDaclJournalRecord (Get-FileDaclJournalRecord -Handle $originalHandle.Stream.SafeFileHandle)),
                        (ConvertFrom-FileDaclJournalRecord $Snapshot.DaclRecord))
                if ($isOriginal) { $Snapshot.MutationApplied = $false; return }
            }
            finally { if ($null -ne $originalHandle -and $null -ne $originalHandle.Stream) { $originalHandle.Stream.Dispose() } }
        }
    }
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
    if (-not [bool]$Snapshot.LegacyRecovery -and $null -eq $Snapshot.Publication -and
        [string]::IsNullOrWhiteSpace([string]$Snapshot.AppliedFileIdentity)) {
        throw "Shared Git exclude has no journal-owned published identity; the current file was preserved: $path"
    }

    $handle = Open-GitInfoExcludeMutationHandle -Repository $repository -Path $path -RequireExisting
    try {
        if ([bool]$handle.Created) { throw "Shared Git exclude changed concurrently during rollback; the recreated current state was preserved: $path" }
        [byte[]]$currentBytes = Read-GitInfoExcludeStreamBytes -Stream $handle.Stream
        if (-not (Test-GitInfoExcludeBytesEqual -Left $currentBytes -Right ([byte[]]$Snapshot.AppliedBytes))) {
            throw "Shared Git exclude changed concurrently during rollback; current bytes were preserved: $path"
        }
        if ([bool]$Snapshot.Existed) {
            [byte[]]$restoreBytes = [byte[]]$Snapshot.Bytes
            $restoreDacl = $Snapshot.DaclRecord
            $restoreReadOnly = [bool]$Snapshot.OriginalReadOnly
            if ([bool]$Snapshot.LegacyRecovery) {
                # V1 recorded bytes but no historical file metadata. Capture the current
                # file metadata only after the exact applied-byte CAS has succeeded.
                $restoreDacl = Get-FileDaclJournalRecord -Handle $handle.Stream.SafeFileHandle
                $restoreReadOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($handle.Stream.SafeFileHandle)
                $Snapshot.AppliedFileIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($handle.Stream.SafeFileHandle)
                $Snapshot.PublicationDaclRecord = $restoreDacl
                $Snapshot.PublicationReadOnly = $restoreReadOnly
            }
            Invoke-AtomicFilePublication -Kind Exclude -Root $repository -Path $path `
                -RelativePath ([IO.Path]::GetFileName($path)) -ExpectedOldExists $true -ExpectedOldBytes $currentBytes `
                -ExpectedOldIdentity ([string]$Snapshot.AppliedFileIdentity) -ExpectedOldSha256 (Get-ByteArraySha256 $currentBytes) `
                -ExpectedOldStream $handle.Stream `
                -DaclRecord $restoreDacl -ReadOnly $restoreReadOnly -NewBytes $restoreBytes `
                -Direction restore -PublicationState $Snapshot -Snapshot $null | Out-Null
            $Snapshot.Publication = $null
            $Snapshot.AppliedFileIdentity = $null
            $Snapshot.AppliedBytes = $null
            $Snapshot.PublicationDaclRecord = $null
            $Snapshot.PublicationReadOnly = $false
            $Snapshot.MutationApplied = $false
        }
        else {
            $currentIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($handle.Stream.SafeFileHandle)
            if ([string]$Snapshot.AppliedFileIdentity -and $currentIdentity -cne [string]$Snapshot.AppliedFileIdentity) {
                throw "Shared Git exclude changed concurrently during rollback; the recreated current state was preserved: $path"
            }
            [CodexAiInstructions.NativeFileMutation]::MarkDeleteOnClose($handle.Stream.SafeFileHandle)
            $handle.Stream.Dispose()
            $handle.Stream = $null
            $Snapshot.MutationApplied = $false
            $Snapshot.Publication = $null
            $Snapshot.AppliedFileIdentity = $null
            $Snapshot.AppliedBytes = $null
            $Snapshot.PublicationDaclRecord = $null
            $Snapshot.PublicationReadOnly = $false
        }
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
        [byte[]]$beforeBytes = if ([bool]$handle.Created) { [byte[]]@() } else { Read-GitInfoExcludeStreamBytes -Stream $handle.Stream }
        if ([bool]$handle.Created -and [bool]$Snapshot.Existed) { throw "Shared Git exclude disappeared before update; the current state was preserved: $path" }
        if (-not [bool]$handle.Created -and -not [bool]$Snapshot.Existed) { throw "Shared Git exclude appeared before update; the current state was preserved: $path" }
        if (-not [bool]$handle.Created -and -not (Test-GitInfoExcludeBytesEqual -Left $beforeBytes -Right ([byte[]]$Snapshot.Bytes))) {
            throw "Shared Git exclude changed concurrently before update; the current state was preserved: $path"
        }
        $Snapshot.AppliedBytes = $beforeBytes

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
            try {
                if ($null -ne $script:SkillMigrationJournalContext) {
                    $context=$script:SkillMigrationJournalContext
                    Save-SkillMigrationJournal $context.Snapshot $Snapshot $context.Path $context.GitState 'mutating'
                }
                Invoke-AtomicFilePublication -Kind Exclude -Root $Repository -Path $path `
                    -RelativePath ([IO.Path]::GetFileName($path)) -ExpectedOldExists ([bool]$Snapshot.Existed) `
                    -ExpectedOldBytes $(if ($Snapshot.Existed) { [byte[]]$Snapshot.Bytes } else { $null }) `
                    -ExpectedOldIdentity $(if ([bool]$Snapshot.Existed) { [string]$Snapshot.OriginalIdentity } else { $null }) `
                    -ExpectedOldSha256 $(if ($Snapshot.Existed) { Get-ByteArraySha256 ([byte[]]$Snapshot.Bytes) } else { $null }) `
                    -ExpectedOldStream $(if ($Snapshot.Existed) { $handle.Stream } else { $null }) `
                    -DaclRecord $Snapshot.DaclRecord -ReadOnly ([bool]$Snapshot.OriginalReadOnly) -NewBytes $updatedBytes `
                    -Direction apply -PublicationState $Snapshot -Snapshot $null | Out-Null
            }
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

function Convert-ManifestEntryForSchema {
    param(
        [Parameter(Mandatory = $true)][object] $Entry,
        [Parameter(Mandatory = $true)][int] $SchemaVersion
    )

    if ($SchemaVersion -ne 3 -or [string]$Entry.artifactType -ne 'skill') {
        return $Entry
    }

    $artifactId = [string]$Entry.artifactId
    $legacyPrefix = ".agents/skills/$artifactId/"
    $canonicalPrefix = "skills/$artifactId/"
    $sourcePath = [string]$Entry.sourcePath
    if ($sourcePath.StartsWith($canonicalPrefix, [System.StringComparison]::Ordinal)) {
        return $Entry
    }
    if (-not $sourcePath.StartsWith($legacyPrefix, [System.StringComparison]::Ordinal)) {
        throw "Managed Skill '$artifactId' cannot be emitted in manifest v3 with source path '$sourcePath'."
    }

    $Entry.sourcePath = $canonicalPrefix + $sourcePath.Substring($legacyPrefix.Length)
    return $Entry
}

function Copy-ExistingManifestEntry {
    param([Parameter(Mandatory = $true)][object] $Entry)

    if ($null -eq $Entry.PSObject.Properties['artifactType']) {
        return [pscustomobject][ordered]@{sourcePath=$Entry.sourcePath; targetPath=$Entry.targetPath; sha256=$Entry.sha256}
    }
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
        $daclRecord = $null
        $readOnly = $false
        $originalIdentity = $null
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $originalType = 'file'
            $backupPath = Join-Path $BackupRoot ('{0:D6}.bin' -f $backupIndex)
            Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
            $metadataHandle = $null
            $metadataStream = $null
            try {
                $metadataHandle = [CodexAiInstructions.NativeFileMutation]::OpenForMetadata($resolvedTargetRoot,$targetPath,$relativePath)
                $metadataStream = [System.IO.FileStream]::new($metadataHandle,[System.IO.FileAccess]::Read)
                $metadataHandle = $null
                [byte[]]$observedBytes = Read-TargetMutationStreamBytes -Stream $metadataStream
                if (-not (Test-TargetMutationBytesEqual -Left $observedBytes -Right ([System.IO.File]::ReadAllBytes($backupPath)))) {
                    throw "Managed target changed while its rollback snapshot was captured: $relativePath"
                }
                $daclRecord = Get-FileDaclJournalRecord -Handle $metadataStream.SafeFileHandle
                $readOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($metadataStream.SafeFileHandle)
                $originalIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($metadataStream.SafeFileHandle)
            }
            finally {
                if ($null -ne $metadataStream) { $metadataStream.Dispose() }
                if ($null -ne $metadataHandle) { $metadataHandle.Dispose() }
            }
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
            OriginalDacl = $daclRecord
            OriginalReadOnly = $readOnly
            OriginalIdentity = $originalIdentity
            AppliedFileIdentity = $null
            MutationApplied = $false
            AppliedType = $null
            AppliedBytes = $null
            Publication = $null
            PublicationDaclRecord = $null
            PublicationReadOnly = $false
            LegacyRecovery = $false
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
        [Parameter(Mandatory = $true)][ref] $CreateContext,
        [switch] $IncludeDaclWrite
    )

    $nativeContext = $null
    $nativeHandle = $null
    try {
        $nativeContext = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicCreate(
            $TargetRoot,$TargetPath,$RelativePath,[bool]$IncludeDaclWrite.IsPresent)
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

function Assert-ExactJournalProperties {
    param([Parameter(Mandatory=$true)][object]$Value,[Parameter(Mandatory=$true)][string[]]$Names,[Parameter(Mandatory=$true)][string]$Context)
    $actual = @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $expected = @($Names | Sort-Object -CaseSensitive)
    if ($actual.Count -ne $expected.Count) { throw "Invalid $Context schema properties." }
    for ($index=0; $index -lt $expected.Count; $index++) {
        if ($actual[$index] -cne $expected[$index]) { throw "Invalid $Context schema properties." }
    }
}

function ConvertTo-FileDaclJournalRecord {
    param([AllowNull()][CodexAiInstructions.FileDaclSnapshot]$Dacl)
    if ($null -eq $Dacl) { return $null }
    return [pscustomobject][ordered]@{
        isNull = [bool]$Dacl.IsNull
        isProtected = [bool]$Dacl.IsProtected
        aclBase64 = if ($Dacl.IsNull) { $null } else { [Convert]::ToBase64String([byte[]]$Dacl.AclBytes) }
    }
}

function ConvertFrom-FileDaclJournalRecord {
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return $null }
    Assert-ExactJournalProperties -Value $Record -Names @('isNull','isProtected','aclBase64') -Context 'schema-v2 file DACL record'
    if ($Record.isNull -isnot [bool] -or $Record.isProtected -isnot [bool]) { throw 'Invalid schema-v2 file DACL record.' }
    [byte[]]$aclBytes = $null
    if ([bool]$Record.isNull) {
        if ($null -ne $Record.aclBase64) { throw 'Invalid null-DACL schema-v2 record.' }
    }
    else {
        if ([string]$Record.aclBase64 -cnotmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$') { throw 'Invalid schema-v2 DACL encoding.' }
        try { $aclBytes = [Convert]::FromBase64String([string]$Record.aclBase64) }
        catch { throw 'Invalid schema-v2 DACL encoding.' }
        if ($aclBytes.Length -lt 8 -or ([BitConverter]::ToUInt16($aclBytes,2) -ne $aclBytes.Length)) { throw 'Invalid schema-v2 DACL byte inventory.' }
    }
    return [CodexAiInstructions.FileDaclSnapshot]::new([bool]$Record.isNull,$aclBytes,[bool]$Record.isProtected)
}

function Get-FileDaclJournalRecord {
    param([Parameter(Mandatory=$true)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    return ConvertTo-FileDaclJournalRecord ([CodexAiInstructions.NativeFileMutation]::CaptureDacl($Handle))
}

function Get-PublicationFileHandle {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][ValidateSet('Target','Exclude')][string]$Kind,
        [switch]$AllowMissing
    )
    try {
        if ($Kind -eq 'Target') {
            return [CodexAiInstructions.NativeFileMutation]::OpenForAtomicDelete($Root,$Path,$RelativePath)
        }
        return [CodexAiInstructions.NativeFileMutation]::OpenStandaloneForAtomicDelete($Path)
    }
    catch {
        $nativeCode = $null
        if ($_.Exception -is [ComponentModel.Win32Exception]) { $nativeCode = $_.Exception.NativeErrorCode }
        elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException -is [ComponentModel.Win32Exception]) {
            $nativeCode = $_.Exception.InnerException.NativeErrorCode
        }
        if ($AllowMissing -and $nativeCode -in @(2,3)) { return $null }
        if ($Kind -eq 'Exclude') {
            throw "Unable to acquire the exclusive shared Git exclude mutation handle; another process may be changing '$Path'. $($_.Exception.Message)"
        }
        throw
    }
}

function Get-PublicationFileEvidence {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][ValidateSet('Target','Exclude')][string]$Kind,
        [switch]$AllowMissing
    )
    $handle = Get-PublicationFileHandle -Root $Root -Path $Path -RelativePath $RelativePath -Kind $Kind -AllowMissing:$AllowMissing
    if ($null -eq $handle) { return $null }
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new($handle,[System.IO.FileAccess]::Read)
        $handle = $null
        [byte[]]$bytes = Read-TargetMutationStreamBytes -Stream $stream
        return [pscustomobject][ordered]@{
            bytes = $bytes
            length = [long]$bytes.Length
            sha256 = Get-ByteArraySha256 -Bytes $bytes
            identity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($stream.SafeFileHandle)
            dacl = Get-FileDaclJournalRecord -Handle $stream.SafeFileHandle
            readOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($stream.SafeFileHandle)
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Remove-VerifiedPublicationFile {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][ValidateSet('Target','Exclude')][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Identity,
        [Parameter(Mandatory=$true)][string]$Sha256,
        [Parameter(Mandatory=$true)][long]$Length
    )
    $handle = Get-PublicationFileHandle -Root $Root -Path $Path -RelativePath $RelativePath -Kind $Kind
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new($handle,[System.IO.FileAccess]::Read)
        $handle = $null
        [byte[]]$bytes = Read-TargetMutationStreamBytes -Stream $stream
        if ([CodexAiInstructions.NativeFileMutation]::GetFileIdentity($stream.SafeFileHandle) -cne $Identity -or
            $bytes.Length -ne $Length -or (Get-ByteArraySha256 -Bytes $bytes) -cne $Sha256) {
            throw "A publication-owned file changed and was preserved: $Path"
        }
        [CodexAiInstructions.NativeFileMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Add-TargetMutationCreatedDirectories {
    param([Parameter(Mandatory=$true)][object]$Snapshot,[AllowNull()][object]$CreateContext)
    if ($null -eq $CreateContext) { return }
    foreach ($createdDirectory in @($CreateContext.CreatedDirectories)) {
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

function New-AtomicFilePublicationRecord {
    param(
        [string]$OperationId,[string]$Direction,[string]$StageLeaf,[string]$TombstoneLeaf,
        [string]$ParentIdentity,[string]$StageIdentity,[AllowNull()][object]$ExpectedOldIdentity,
        [AllowNull()][object]$ExpectedOldSha256,[long]$ExpectedOldLength,[bool]$ExpectedOldExists,
        [string]$NewSha256,[long]$NewLength
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        operationId = $OperationId
        direction = $Direction
        stageLeaf = $StageLeaf
        tombstoneLeaf = $TombstoneLeaf
        parentIdentity = $ParentIdentity
        stageIdentity = $StageIdentity
        expectedOldExists = $ExpectedOldExists
        expectedOldIdentity = $ExpectedOldIdentity
        expectedOldSha256 = $ExpectedOldSha256
        expectedOldLength = $ExpectedOldLength
        newSha256 = $NewSha256
        newLength = $NewLength
    }
}

function Invoke-AtomicFilePublicationRename {
    param(
        [Parameter(Mandatory=$true)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory=$true)][string]$DestinationPath
    )
    [CodexAiInstructions.NativeFileMutation]::RenameNoReplace($Handle,$DestinationPath)
}

function Invoke-AtomicFilePublication {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Target','Exclude')][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][bool]$ExpectedOldExists,
        [AllowNull()][byte[]]$ExpectedOldBytes,
        [AllowNull()][object]$ExpectedOldIdentity,
        [AllowNull()][object]$ExpectedOldSha256,
        [AllowNull()][System.IO.FileStream]$ExpectedOldStream,
        [AllowNull()][object]$DaclRecord,
        [bool]$ReadOnly = $false,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$NewBytes,
        [Parameter(Mandatory=$true)][ValidateSet('apply','restore')][string]$Direction,
        [Parameter(Mandatory=$true)][object]$PublicationState,
        [AllowNull()][object]$Snapshot
    )
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Atomic file publication requires Windows handle-bound rename support.' }
    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $parentRelative = if ($Kind -eq 'Target') { (Split-Path -Parent $RelativePath).Replace('\','/').Trim('/') } else { '' }
    $operationId = [guid]::NewGuid().ToString('N')
    $stageLeaf = ".syp214-$operationId-stage"
    $tombstoneLeaf = ".syp214-$operationId-tomb"
    $stagePath = Join-Path $parent $stageLeaf
    $stageRelative = if ([string]::IsNullOrWhiteSpace($parentRelative)) { $stageLeaf } else { "$parentRelative/$stageLeaf" }
    $tombstonePath = Join-Path $parent $tombstoneLeaf
    $createContext = $null
    $stageStream = $null
    $oldStream = $null
    $ownsOldStream = $false
    $createRoot = if ($Kind -eq 'Target') { $Root } else { $parent }
    $createRelative = if ($Kind -eq 'Target') { $stageRelative } else { $stageLeaf }
    $createGuardPath = if ($Kind -eq 'Target') { $stageRelative.Replace('/','\') } else { $stageLeaf }
    try {
        $stageStream = Open-TargetMutationAtomicCreateStream -TargetRoot $createRoot -TargetPath $stagePath `
            -RelativePath $createRelative -Operation 'Managed publication staging' -CreateContext ([ref]$createContext) -IncludeDaclWrite
        if ($Kind -eq 'Target' -and $null -ne $Snapshot) { Add-TargetMutationCreatedDirectories -Snapshot $Snapshot -CreateContext $createContext }

        $oldEvidence = $null
        if ($ExpectedOldExists) {
            if ($null -ne $ExpectedOldStream) { $oldStream = $ExpectedOldStream }
            else {
                $oldHandle = Get-PublicationFileHandle -Root $Root -Path $Path -RelativePath $RelativePath -Kind $Kind
                $oldStream = [System.IO.FileStream]::new($oldHandle,[System.IO.FileAccess]::Read)
                $ownsOldStream = $true
            }
            [byte[]]$currentOldBytes = Read-TargetMutationStreamBytes -Stream $oldStream
            $actualOldIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($oldStream.SafeFileHandle)
            $actualOldDacl = Get-FileDaclJournalRecord -Handle $oldStream.SafeFileHandle
            $actualOldReadOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($oldStream.SafeFileHandle)
            $actualOldHash = Get-ByteArraySha256 -Bytes $currentOldBytes
            if (-not (Test-TargetMutationBytesEqual -Left $currentOldBytes -Right $ExpectedOldBytes) -or
                ($ExpectedOldIdentity -and $actualOldIdentity -cne $ExpectedOldIdentity) -or
                ($ExpectedOldSha256 -and $actualOldHash -cne $ExpectedOldSha256) -or
                $actualOldReadOnly -ne $ReadOnly -or
                -not [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                    (ConvertFrom-FileDaclJournalRecord $actualOldDacl), (ConvertFrom-FileDaclJournalRecord $DaclRecord))) {
                throw "Managed publication detected concurrent bytes, identity, DACL, or read-only changes; the current file was preserved: $Path"
            }
            $oldEvidence = [pscustomobject]@{identity=$actualOldIdentity;sha256=$actualOldHash;length=[long]$currentOldBytes.Length}
        }
        else {
            $unexpected = Get-PublicationFileHandle -Root $Root -Path $Path -RelativePath $RelativePath -Kind $Kind -AllowMissing
            if ($null -ne $unexpected) {
                $unexpected.Dispose()
                throw "Managed publication destination appeared concurrently and was preserved: $Path"
            }
        }

        if ($null -ne $DaclRecord) {
            $dacl = ConvertFrom-FileDaclJournalRecord $DaclRecord
            [CodexAiInstructions.NativeFileMutation]::SetDacl($stageStream.SafeFileHandle,$dacl)
            $readbackDacl = [CodexAiInstructions.NativeFileMutation]::CaptureDacl($stageStream.SafeFileHandle)
            if (-not [CodexAiInstructions.NativeFileMutation]::DaclEquals($dacl,$readbackDacl)) {
                throw "Managed publication stage DACL did not match the original before writing; the original destination was preserved: $Path"
            }
        }
        if ($Kind -eq 'Target') { Write-TargetMutationStreamBytes -Stream $stageStream -Bytes $NewBytes }
        else { Write-GitInfoExcludeStreamBytes -Stream $stageStream -Bytes $NewBytes }
        [byte[]]$stagedBytes = Read-TargetMutationStreamBytes -Stream $stageStream
        if (-not (Test-TargetMutationBytesEqual -Left $stagedBytes -Right $NewBytes)) {
            throw "Managed publication stage did not retain complete bytes; the original destination was preserved: $Path"
        }
        if ($null -ne $DaclRecord) {
            [CodexAiInstructions.NativeFileMutation]::SetReadOnly($stageStream.SafeFileHandle,$ReadOnly)
        }
        $publicationDaclRecord = Get-FileDaclJournalRecord -Handle $stageStream.SafeFileHandle
        $publicationReadOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($stageStream.SafeFileHandle)
        $stageIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($stageStream.SafeFileHandle)
        $parentIdentity = [CodexAiInstructions.NativeFileMutation]::GetDirectoryIdentity($parent)
        $newHash = Get-ByteArraySha256 -Bytes $NewBytes
        $publication = New-AtomicFilePublicationRecord -OperationId $operationId -Direction $Direction `
            -StageLeaf $stageLeaf -TombstoneLeaf $tombstoneLeaf -ParentIdentity $parentIdentity `
            -StageIdentity $stageIdentity -ExpectedOldIdentity $(if ($oldEvidence) { $oldEvidence.identity } else { $null }) `
            -ExpectedOldSha256 $(if ($oldEvidence) { $oldEvidence.sha256 } else { $null }) `
            -ExpectedOldLength $(if ($oldEvidence) { $oldEvidence.length } else { 0 }) -ExpectedOldExists $ExpectedOldExists `
            -NewSha256 $newHash -NewLength $NewBytes.Length
        $PublicationState.Publication = $publication
        if ($PublicationState.PSObject.Properties['PublicationDaclRecord']) { $PublicationState.PublicationDaclRecord = $publicationDaclRecord }
        if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { $PublicationState.PublicationReadOnly = $publicationReadOnly }
        if ($Direction -eq 'apply') {
            $PublicationState.MutationApplied = $true
            if ($PublicationState.PSObject.Properties['AppliedType']) { $PublicationState.AppliedType = 'file' }
            $PublicationState.AppliedBytes = [byte[]]$NewBytes.Clone()
            if ($PublicationState.PSObject.Properties['AppliedFileIdentity']) { $PublicationState.AppliedFileIdentity = $stageIdentity }
        }
        if ($null -ne $script:SkillMigrationJournalContext) {
            $context = $script:SkillMigrationJournalContext
            Save-SkillMigrationJournal $context.Snapshot $context.ExcludeSnapshot $context.Path $context.GitState 'mutating'
        }

        if ($ExpectedOldExists) {
            Invoke-AtomicFilePublicationRename -Handle $oldStream.SafeFileHandle -DestinationPath $tombstonePath
        }
        Invoke-AtomicFilePublicationRename -Handle $stageStream.SafeFileHandle -DestinationPath $Path
        [byte[]]$publishedBytes = Read-TargetMutationStreamBytes -Stream $stageStream
        if ([CodexAiInstructions.NativeFileMutation]::GetFileIdentity($stageStream.SafeFileHandle) -cne $stageIdentity -or
            -not (Test-TargetMutationBytesEqual -Left $publishedBytes -Right $NewBytes)) {
            throw "Published managed file failed final identity or byte verification: $Path"
        }
        if ($ExpectedOldExists) { [CodexAiInstructions.NativeFileMutation]::MarkDeleteOnClose($oldStream.SafeFileHandle) }
        if ($Direction -eq 'restore') { $PublicationState.MutationApplied = $false }
        return $publication
    }
    finally {
        if ($ownsOldStream -and $null -ne $oldStream) { $oldStream.Dispose() }
        if ($null -ne $stageStream) { $stageStream.Dispose() }
        if ($null -ne $createContext) { $createContext.Dispose() }
    }
}

function Assert-AtomicFilePublicationRecord {
    param([Parameter(Mandatory=$true)][object]$Publication,[Parameter(Mandatory=$true)][string]$RelativePath)
    Assert-ExactJournalProperties -Value $Publication -Names @('schemaVersion','operationId','direction','stageLeaf','tombstoneLeaf',
        'parentIdentity','stageIdentity','expectedOldExists','expectedOldIdentity','expectedOldSha256','expectedOldLength','newSha256','newLength') `
        -Context 'schema-v2 publication ownership record'
    if ($Publication.schemaVersion -ne 1 -or
        [string]$Publication.operationId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Publication.direction -cnotin @('apply','restore') -or
        [string]$Publication.stageLeaf -cne ".syp214-$($Publication.operationId)-stage" -or
        [string]$Publication.tombstoneLeaf -cne ".syp214-$($Publication.operationId)-tomb" -or
        [string]$Publication.parentIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$' -or
        [string]$Publication.stageIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$' -or
        $Publication.expectedOldExists -isnot [bool] -or
        ($Publication.newLength -isnot [int] -and $Publication.newLength -isnot [long]) -or
        [string]$Publication.newSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [long]$Publication.newLength -lt 0) { throw "Invalid schema-v2 publication ownership record for '$RelativePath'." }
    if ([bool]$Publication.expectedOldExists) {
        if (($Publication.expectedOldLength -isnot [int] -and $Publication.expectedOldLength -isnot [long]) -or
            [string]$Publication.expectedOldIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$' -or
            [string]$Publication.expectedOldSha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$Publication.expectedOldLength -lt 0) {
            throw "Invalid schema-v2 expected-old publication record for '$RelativePath'."
        }
        if ([string]$Publication.expectedOldIdentity -ceq [string]$Publication.stageIdentity) {
            throw "Invalid schema-v2 publication with aliased old and staged file identities for '$RelativePath'."
        }
    }
    elseif ($null -ne $Publication.expectedOldIdentity -or $null -ne $Publication.expectedOldSha256 -or
        ($Publication.expectedOldLength -isnot [int] -and $Publication.expectedOldLength -isnot [long]) -or [long]$Publication.expectedOldLength -ne 0) {
        throw "Invalid schema-v2 missing-old publication record for '$RelativePath'."
    }
}

function Test-PublicationEvidenceMatches {
    param(
        [AllowNull()][object]$Evidence,[string]$Identity,[string]$Sha256,[long]$Length,
        [AllowNull()][object]$DaclRecord,[bool]$ReadOnly
    )
    if ($null -eq $Evidence) { return $false }
    if ([string]$Evidence.identity -cne $Identity -or [string]$Evidence.sha256 -cne $Sha256 -or [long]$Evidence.length -ne $Length -or
        [bool]$Evidence.readOnly -ne $ReadOnly) { return $false }
    if ($null -ne $DaclRecord) {
        return [CodexAiInstructions.NativeFileMutation]::DaclEquals(
            (ConvertFrom-FileDaclJournalRecord $DaclRecord),
            (ConvertFrom-FileDaclJournalRecord $Evidence.dacl))
    }
    return $true
}

function Resolve-AtomicFilePublication {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Target','Exclude')][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][object]$PublicationState
    )
    $publication = $PublicationState.Publication
    if ($null -eq $publication) { return }
    Assert-AtomicFilePublicationRecord -Publication $publication -RelativePath $RelativePath
    $parent = Split-Path -Parent $Path
    $stagePath = Join-Path $parent ([string]$publication.stageLeaf)
    $tombstonePath = Join-Path $parent ([string]$publication.tombstoneLeaf)
    $parentRelative = if ($Kind -eq 'Target') { (Split-Path -Parent $RelativePath).Replace('\','/').Trim('/') } else { '' }
    $stageRelative = if ([string]::IsNullOrWhiteSpace($parentRelative)) { [string]$publication.stageLeaf } else { "$parentRelative/$($publication.stageLeaf)" }
    $tombstoneRelative = if ([string]::IsNullOrWhiteSpace($parentRelative)) { [string]$publication.tombstoneLeaf } else { "$parentRelative/$($publication.tombstoneLeaf)" }
    $guardRoot = if ($Kind -eq 'Exclude') { $parent } else { $Root }
    $guard = $null
    try {
        $guard = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicDirectoryGuard($guardRoot,$parentRelative.Replace('/','\'))
        $actualParentIdentity = [CodexAiInstructions.NativeFileMutation]::GetDirectoryIdentity($parent)
        if ($actualParentIdentity -cne [string]$publication.parentIdentity) {
            throw "Publication parent identity changed; all current files were preserved: $Path"
        }
        $stage = Get-PublicationFileEvidence -Root $Root -Path $stagePath -RelativePath $stageRelative -Kind $Kind -AllowMissing
        $final = Get-PublicationFileEvidence -Root $Root -Path $Path -RelativePath $RelativePath -Kind $Kind -AllowMissing
        $tombstone = Get-PublicationFileEvidence -Root $Root -Path $tombstonePath -RelativePath $tombstoneRelative -Kind $Kind -AllowMissing
        $daclRecord = if ($PublicationState.PSObject.Properties['PublicationDaclRecord'] -and $null -ne $PublicationState.PublicationDaclRecord) {
            $PublicationState.PublicationDaclRecord
        } elseif ($PublicationState.PSObject.Properties['DaclRecord']) { $PublicationState.DaclRecord } else { $PublicationState.OriginalDacl }
        $readOnly = if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { [bool]$PublicationState.PublicationReadOnly }
            elseif ($PublicationState.PSObject.Properties['OriginalReadOnly']) { [bool]$PublicationState.OriginalReadOnly }
            else { [bool]$PublicationState.ReadOnly }
        $stageMatches = Test-PublicationEvidenceMatches $stage ([string]$publication.stageIdentity) `
            ([string]$publication.newSha256) ([long]$publication.newLength) $daclRecord $readOnly
        $oldMatchesFinal = $false
        $oldMatchesTombstone = $false
        if ([bool]$publication.expectedOldExists) {
            $oldMatchesFinal = Test-PublicationEvidenceMatches $final ([string]$publication.expectedOldIdentity) `
                ([string]$publication.expectedOldSha256) ([long]$publication.expectedOldLength) $daclRecord $readOnly
            $oldMatchesTombstone = Test-PublicationEvidenceMatches $tombstone ([string]$publication.expectedOldIdentity) `
                ([string]$publication.expectedOldSha256) ([long]$publication.expectedOldLength) $daclRecord $readOnly
        }
        $newMatchesFinal = Test-PublicationEvidenceMatches $final ([string]$publication.stageIdentity) `
            ([string]$publication.newSha256) ([long]$publication.newLength) $daclRecord $readOnly

        if ($newMatchesFinal -and $null -eq $stage -and
            (([bool]$publication.expectedOldExists -and ($null -eq $tombstone -or $oldMatchesTombstone)) -or
             (-not [bool]$publication.expectedOldExists -and $null -eq $tombstone))) {
            if ($null -ne $tombstone) {
                Remove-VerifiedPublicationFile -Root $Root -Path $tombstonePath -RelativePath $tombstoneRelative `
                    -Kind $Kind -Identity ([string]$publication.expectedOldIdentity) `
                    -Sha256 ([string]$publication.expectedOldSha256) -Length ([long]$publication.expectedOldLength)
            }
            if ([string]$publication.direction -ceq 'restore') {
                $PublicationState.MutationApplied = $false
                if ($PublicationState.PSObject.Properties['AppliedFileIdentity']) { $PublicationState.AppliedFileIdentity = $null }
                if ($PublicationState.PSObject.Properties['AppliedBytes']) { $PublicationState.AppliedBytes = $null }
                if ($PublicationState.PSObject.Properties['AppliedType']) { $PublicationState.AppliedType = $null }
                if ($PublicationState.PSObject.Properties['PublicationDaclRecord']) { $PublicationState.PublicationDaclRecord = $null }
                if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { $PublicationState.PublicationReadOnly = $false }
                $PublicationState.Publication = $null
            }
            else {
                $PublicationState.MutationApplied = $true
                if ($PublicationState.PSObject.Properties['AppliedType']) { $PublicationState.AppliedType = 'file' }
                if ($PublicationState.PSObject.Properties['AppliedFileIdentity']) { $PublicationState.AppliedFileIdentity = [string]$publication.stageIdentity }
            }
            return
        }

        $oldIsCurrent = if ([bool]$publication.expectedOldExists) { $oldMatchesFinal } else { $null -eq $final }

        # A restore retry can die after safely returning the old file from its tombstone,
        # then removing the owned stage, before the recovered journal is flushed. Reconcile
        # only the positive, complete old-file identity; a missing final is never sufficient.
        if ([bool]$publication.expectedOldExists -and $oldMatchesFinal -and $null -eq $stage -and $null -eq $tombstone) {
            if ([string]$publication.direction -ceq 'apply') {
                $PublicationState.MutationApplied = $false
                if ($PublicationState.PSObject.Properties['AppliedFileIdentity']) { $PublicationState.AppliedFileIdentity = $null }
                if ($PublicationState.PSObject.Properties['AppliedBytes']) { $PublicationState.AppliedBytes = $null }
                if ($PublicationState.PSObject.Properties['AppliedType']) { $PublicationState.AppliedType = $null }
                if ($PublicationState.PSObject.Properties['PublicationDaclRecord']) { $PublicationState.PublicationDaclRecord = $null }
                if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { $PublicationState.PublicationReadOnly = $false }
            }
            else {
                if ($PublicationState.PSObject.Properties['PublicationDaclRecord']) { $PublicationState.PublicationDaclRecord = $null }
                if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { $PublicationState.PublicationReadOnly = $false }
            }
            $PublicationState.Publication = $null
            return
        }

        if ($oldIsCurrent -and $stageMatches -and $null -eq $tombstone) {
            Remove-VerifiedPublicationFile -Root $Root -Path $stagePath -RelativePath $stageRelative `
                -Kind $Kind -Identity ([string]$publication.stageIdentity) `
                -Sha256 ([string]$publication.newSha256) -Length ([long]$publication.newLength)
            if ([string]$publication.direction -ceq 'apply') {
                $PublicationState.MutationApplied = $false
                if ($PublicationState.PSObject.Properties['AppliedFileIdentity']) { $PublicationState.AppliedFileIdentity = $null }
                if ($PublicationState.PSObject.Properties['AppliedBytes']) { $PublicationState.AppliedBytes = $null }
                if ($PublicationState.PSObject.Properties['AppliedType']) { $PublicationState.AppliedType = $null }
            }
            if ($PublicationState.PSObject.Properties['PublicationDaclRecord']) { $PublicationState.PublicationDaclRecord = $null }
            if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { $PublicationState.PublicationReadOnly = $false }
            $PublicationState.Publication = $null
            return
        }

        if ($null -eq $final -and [bool]$publication.expectedOldExists -and $oldMatchesTombstone -and $stageMatches) {
            $tombstoneHandle = Get-PublicationFileHandle -Root $Root -Path $tombstonePath -RelativePath $tombstoneRelative -Kind $Kind
            $tombstoneStream = $null
            try {
                $tombstoneStream = [System.IO.FileStream]::new($tombstoneHandle,[System.IO.FileAccess]::Read)
                $tombstoneHandle = $null
                [byte[]]$tombstoneBytes = Read-TargetMutationStreamBytes -Stream $tombstoneStream
                if ([CodexAiInstructions.NativeFileMutation]::GetFileIdentity($tombstoneStream.SafeFileHandle) -cne [string]$publication.expectedOldIdentity -or
                    (Get-ByteArraySha256 $tombstoneBytes) -cne [string]$publication.expectedOldSha256 -or
                    $tombstoneBytes.Length -ne [long]$publication.expectedOldLength) {
                    throw "Publication tombstone changed before missing-window recovery; it was preserved: $tombstonePath"
                }
                Invoke-AtomicFilePublicationRename -Handle $tombstoneStream.SafeFileHandle -DestinationPath $Path
            }
            finally {
                if ($null -ne $tombstoneStream) { $tombstoneStream.Dispose() }
                if ($null -ne $tombstoneHandle) { $tombstoneHandle.Dispose() }
            }
            Remove-VerifiedPublicationFile -Root $Root -Path $stagePath -RelativePath $stageRelative `
                -Kind $Kind -Identity ([string]$publication.stageIdentity) `
                -Sha256 ([string]$publication.newSha256) -Length ([long]$publication.newLength)
            if ([string]$publication.direction -ceq 'apply') {
                $PublicationState.MutationApplied = $false
                if ($PublicationState.PSObject.Properties['AppliedFileIdentity']) { $PublicationState.AppliedFileIdentity = $null }
                if ($PublicationState.PSObject.Properties['AppliedBytes']) { $PublicationState.AppliedBytes = $null }
                if ($PublicationState.PSObject.Properties['AppliedType']) { $PublicationState.AppliedType = $null }
            }
            if ($PublicationState.PSObject.Properties['PublicationDaclRecord']) { $PublicationState.PublicationDaclRecord = $null }
            if ($PublicationState.PSObject.Properties['PublicationReadOnly']) { $PublicationState.PublicationReadOnly = $false }
            $PublicationState.Publication = $null
            return
        }

        throw "Schema-v2 publication state is ambiguous or changed; current files were preserved for manual recovery: $Path"
    }
    finally { if ($null -ne $guard) { $guard.Dispose() } }
}

function Remove-TargetMutationFileAtomically {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $ExpectedBytes,
        [Parameter(Mandatory = $true)][string] $Operation,
        [AllowNull()][string] $ExpectedIdentity,
        [AllowNull()][object] $ExpectedDaclRecord,
        [AllowNull()][object] $ExpectedReadOnly,
        [AllowNull()][string] $ExpectedParentIdentity,
        [switch] $AllowReadOnlyOnlyDrift
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "$Operation requires the Windows atomic managed-file deletion boundary: $RelativePath"
    }
    $state = Get-TargetMutationFileState -Snapshot $Snapshot -RelativePath $RelativePath
    Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) -Path `
        ([string]$state.TargetPath) -Context "$Operation '$RelativePath'"
    $stream = $null
    $parentGuard = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$ExpectedParentIdentity)) {
            $parentRelativePath = (Split-Path -Parent $RelativePath).Replace('/','\').Trim('\')
            $parentPath = Split-Path -Parent ([string]$state.TargetPath)
            $parentGuard = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicDirectoryGuard(
                [string]$Snapshot.TargetRoot, $parentRelativePath)
            $actualParentIdentity = [CodexAiInstructions.NativeFileMutation]::GetDirectoryIdentity($parentPath)
            if ($actualParentIdentity -cne [string]$ExpectedParentIdentity) {
                throw "$Operation detected a changed publication parent; the current file was preserved: $RelativePath"
            }
        }
        $stream = Open-TargetMutationAtomicDeleteStream -TargetRoot ([string]$Snapshot.TargetRoot) `
            -TargetPath ([string]$state.TargetPath) `
            -RelativePath $RelativePath -Operation $Operation
        [byte[]]$currentBytes = Read-TargetMutationStreamBytes -Stream $stream
        $currentIdentity = [CodexAiInstructions.NativeFileMutation]::GetFileIdentity($stream.SafeFileHandle)
        if (-not (Test-TargetMutationBytesEqual -Left $currentBytes -Right $ExpectedBytes) -or
            ($ExpectedIdentity -and $currentIdentity -cne $ExpectedIdentity)) {
            throw "$Operation detected concurrent content; the current file was preserved: $RelativePath"
        }
        if ($null -ne $ExpectedDaclRecord) {
            $currentDaclRecord = Get-FileDaclJournalRecord -Handle $stream.SafeFileHandle
            if (-not [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                (ConvertFrom-FileDaclJournalRecord $ExpectedDaclRecord),
                (ConvertFrom-FileDaclJournalRecord $currentDaclRecord))) {
                throw "$Operation detected concurrent security metadata; the current file was preserved: $RelativePath"
            }
        }
        if ($null -ne $ExpectedReadOnly) {
            $currentReadOnly = [bool][CodexAiInstructions.NativeFileMutation]::GetReadOnly($stream.SafeFileHandle)
            $readOnlyOnlyChange = ($AllowReadOnlyOnlyDrift -and -not [bool]$ExpectedReadOnly -and $currentReadOnly)
            if ($currentReadOnly -ne [bool]$ExpectedReadOnly -and -not $readOnlyOnlyChange) {
                throw "$Operation detected concurrent file attributes; the current file was preserved: $RelativePath"
            }
        }
        Set-TargetMutationDeleteDisposition -Handle $stream.SafeFileHandle
        $stream.Dispose()
        $stream = $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $parentGuard) { $parentGuard.Dispose() }
    }
}

function Set-TargetMutationFileBytes {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    if ($RelativePath.StartsWith('.agents/skills/',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Consumer write boundary rejects shared Skill installation; use the USER reconciler.'
    }
    $state = Get-TargetMutationFileState -Snapshot $Snapshot -RelativePath $RelativePath
    if ([bool]$state.MutationApplied) { throw "Target mutation state was already applied: $RelativePath" }
    if ($null -ne $script:SkillMigrationJournalContext) {
        $context = $script:SkillMigrationJournalContext
        Save-SkillMigrationJournal $Snapshot $context.ExcludeSnapshot $context.Path $context.GitState 'mutating' $RelativePath 'file' $Bytes
    }
    Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) -Path ([string]$state.TargetPath) -Context "Managed target '$RelativePath'"
    $expectedOldExists = [string]$state.OriginalType -ceq 'file'
    $expectedOldBytes = if ($expectedOldExists) { [System.IO.File]::ReadAllBytes([string]$state.BackupPath) } else { $null }
    $expectedOldHash = if ($expectedOldExists) { Get-RawContentHash ([string]$state.BackupPath) } else { $null }
    Invoke-AtomicFilePublication -Kind Target -Root ([string]$Snapshot.TargetRoot) `
        -Path ([string]$state.TargetPath) -RelativePath $RelativePath -ExpectedOldExists $expectedOldExists `
        -ExpectedOldBytes $expectedOldBytes -ExpectedOldIdentity $(if ($expectedOldExists) { [string]$state.OriginalIdentity } else { $null }) `
        -ExpectedOldSha256 $expectedOldHash -DaclRecord $state.OriginalDacl -ReadOnly ([bool]$state.OriginalReadOnly) `
        -NewBytes $Bytes -Direction apply -PublicationState $state -Snapshot $Snapshot | Out-Null
    $state.AppliedType = 'file'
    $state.AppliedBytes = [byte[]]$Bytes.Clone()
    $state.AppliedFileIdentity = [string]$state.Publication.stageIdentity
    $state.MutationApplied = $true
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
    if ($null -ne $script:SkillMigrationJournalContext) {
        $context = $script:SkillMigrationJournalContext
        Save-SkillMigrationJournal $Snapshot $context.ExcludeSnapshot $context.Path $context.GitState 'mutating' $RelativePath
    }
    Remove-TargetMutationFileAtomically -Snapshot $Snapshot -RelativePath $RelativePath -ExpectedBytes $originalBytes `
        -Operation 'Managed target removal'
    $state.AppliedType = 'missing'
    $state.AppliedBytes = $null
    $state.MutationApplied = $true
}

function Get-TargetCreatedReadOnlyRollbackEvidence {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][object] $State
    )

    if ([string]$State.OriginalType -cne 'missing' -or -not [bool]$State.MutationApplied -or
        [string]$State.AppliedType -cne 'file' -or $null -eq $State.Publication -or
        $null -eq $State.PublicationDaclRecord -or [bool]$State.OriginalReadOnly -or
        [bool]$State.PublicationReadOnly -or $null -ne $State.OriginalIdentity -or
        $null -ne $State.OriginalDacl) { return $null }

    $publication = $State.Publication
    Assert-AtomicFilePublicationRecord -Publication $publication -RelativePath ([string]$State.RelativePath)
    if ([string]$publication.direction -cne 'apply' -or [bool]$publication.expectedOldExists -or
        $null -ne $publication.expectedOldIdentity -or $null -ne $publication.expectedOldSha256 -or
        [string]$State.AppliedFileIdentity -cne [string]$publication.stageIdentity) { return $null }

    [byte[]]$appliedBytes = [byte[]]$State.AppliedBytes
    if ($null -eq $appliedBytes -or [string]$publication.newSha256 -cne (Get-ByteArraySha256 -Bytes $appliedBytes) -or
        [long]$publication.newLength -ne [long]$appliedBytes.Length) { return $null }
    [void](ConvertFrom-FileDaclJournalRecord $State.PublicationDaclRecord)

    Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) `
        -Path ([string]$State.TargetPath) -Context "Target rollback '$($State.RelativePath)'"
    $path = [string]$State.TargetPath
    $relativePath = [string]$State.RelativePath
    $parent = Split-Path -Parent $path
    $parentRelative = (Split-Path -Parent $relativePath).Replace('\','/').Trim('/')
    $stagePath = Join-Path $parent ([string]$publication.stageLeaf)
    $tombstonePath = Join-Path $parent ([string]$publication.tombstoneLeaf)
    $stageRelative = if ([string]::IsNullOrWhiteSpace($parentRelative)) { [string]$publication.stageLeaf } else { "$parentRelative/$($publication.stageLeaf)" }
    $tombstoneRelative = if ([string]::IsNullOrWhiteSpace($parentRelative)) { [string]$publication.tombstoneLeaf } else { "$parentRelative/$($publication.tombstoneLeaf)" }
    $guard = $null
    try {
        $guard = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicDirectoryGuard(
            [string]$Snapshot.TargetRoot,$parentRelative.Replace('/','\'))
        if ([CodexAiInstructions.NativeFileMutation]::GetDirectoryIdentity($parent) -cne [string]$publication.parentIdentity) {
            return $null
        }
        $stage = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) -Path $stagePath `
            -RelativePath $stageRelative -Kind Target -AllowMissing
        $final = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) -Path $path `
            -RelativePath $relativePath -Kind Target -AllowMissing
        $tombstone = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) -Path $tombstonePath `
            -RelativePath $tombstoneRelative -Kind Target -AllowMissing
        if ($null -ne $stage -or $null -ne $tombstone -or $null -eq $final -or -not [bool]$final.readOnly -or
            [string]$final.identity -cne [string]$publication.stageIdentity -or
            [string]$final.sha256 -cne [string]$publication.newSha256 -or
            [long]$final.length -ne [long]$publication.newLength -or
            -not [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                (ConvertFrom-FileDaclJournalRecord $State.PublicationDaclRecord),
                (ConvertFrom-FileDaclJournalRecord $final.dacl))) {
            return $null
        }
        return $final
    }
    finally { if ($null -ne $guard) { $guard.Dispose() } }
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
            $readOnlyCreatedFileEvidence = $null
            if ($null -ne $state.Publication) {
                $readOnlyCreatedFileEvidence = Get-TargetCreatedReadOnlyRollbackEvidence -Snapshot $Snapshot -State $state
                if ($null -eq $readOnlyCreatedFileEvidence) {
                    Resolve-AtomicFilePublication -Kind Target -Root ([string]$Snapshot.TargetRoot) `
                        -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) -PublicationState $state
                }
                if (-not [bool]$state.MutationApplied) { continue }
            }
            if (-not [bool]$state.LegacyRecovery -and $null -eq $state.Publication) {
                $currentEvidence = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) `
                    -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) -Kind Target -AllowMissing
                $isOriginal = if ([string]$state.OriginalType -ceq 'missing') { $null -eq $currentEvidence } else {
                    Test-PublicationEvidenceMatches $currentEvidence ([string]$state.OriginalIdentity) `
                        (Get-RawContentHash ([string]$state.BackupPath)) ([long](Get-Item -LiteralPath ([string]$state.BackupPath)).Length) `
                        $state.OriginalDacl ([bool]$state.OriginalReadOnly)
                }
                if ($isOriginal) {
                    $state.MutationApplied = $false
                    $state.Publication = $null
                    continue
                }
            }
            Assert-ManagedPathDoesNotCrossReparsePoint -Root ([string]$Snapshot.TargetRoot) -Path ([string]$state.TargetPath) -Context "Target rollback '$($state.RelativePath)'"
            switch ([string]$state.AppliedType) {
                'file' {
                    if (-not [bool]$state.LegacyRecovery) {
                        if ([string]$state.OriginalType -ceq 'file') {
                            $currentEvidence = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) `
                                -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) -Kind Target -AllowMissing
                            [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
                            [byte[]]$appliedBytes = [byte[]]$state.AppliedBytes
                            if (-not (Test-PublicationEvidenceMatches $currentEvidence ([string]$state.AppliedFileIdentity) `
                                (Get-ByteArraySha256 $appliedBytes) ([long]$appliedBytes.Length) $state.OriginalDacl ([bool]$state.OriginalReadOnly))) {
                                $driftedPaths.Add([string]$state.RelativePath)
                                continue
                            }
                            Invoke-AtomicFilePublication -Kind Target -Root ([string]$Snapshot.TargetRoot) `
                                -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                                -ExpectedOldExists $true -ExpectedOldBytes $appliedBytes -ExpectedOldIdentity ([string]$state.AppliedFileIdentity) `
                                -ExpectedOldSha256 (Get-ByteArraySha256 $appliedBytes) -DaclRecord $state.OriginalDacl `
                                -ReadOnly ([bool]$state.OriginalReadOnly) -NewBytes $originalBytes -Direction restore `
                                -PublicationState $state -Snapshot $Snapshot | Out-Null
                            $state.Publication = $null
                            $state.PublicationDaclRecord = $null
                            $state.PublicationReadOnly = $false
                            $state.AppliedFileIdentity = $null
                            $state.AppliedBytes = $null
                            $state.AppliedType = $null
                            continue
                        }
                        $currentEvidence = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) `
                            -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) -Kind Target -AllowMissing
                        [byte[]]$appliedBytes = [byte[]]$state.AppliedBytes
                        $readOnlyCreatedFileEvidence = if ([string]$state.OriginalType -ceq 'missing') {
                            Get-TargetCreatedReadOnlyRollbackEvidence -Snapshot $Snapshot -State $state
                        } else { $null }
                        $currentMatchesOriginalMetadata = Test-PublicationEvidenceMatches $currentEvidence `
                            ([string]$state.AppliedFileIdentity) (Get-ByteArraySha256 $appliedBytes) `
                            ([long]$appliedBytes.Length) $state.OriginalDacl ([bool]$state.OriginalReadOnly)
                        if (-not $currentMatchesOriginalMetadata -and $null -eq $readOnlyCreatedFileEvidence) {
                            $driftedPaths.Add([string]$state.RelativePath)
                            continue
                        }
                        $expectedDeleteDacl = if ([string]$state.OriginalType -ceq 'missing') { $state.PublicationDaclRecord } else { $null }
                        $expectedDeleteReadOnly = if ([string]$state.OriginalType -ceq 'missing') { [bool]$state.PublicationReadOnly } else { $null }
                        $expectedDeleteParentIdentity = $null
                        if ([string]$state.OriginalType -ceq 'missing' -and [bool]$state.MutationApplied -and
                            [string]$state.AppliedType -ceq 'file' -and $null -ne $state.Publication -and
                            [string]$state.Publication.direction -ceq 'apply' -and
                            -not [bool]$state.Publication.expectedOldExists -and
                            $null -ne $state.PublicationDaclRecord -and
                            [string]$state.AppliedFileIdentity -ceq [string]$state.Publication.stageIdentity) {
                            $expectedDeleteParentIdentity = [string]$state.Publication.parentIdentity
                        }
                        Remove-TargetMutationFileAtomically -Snapshot $Snapshot -RelativePath ([string]$state.RelativePath) `
                            -ExpectedBytes $appliedBytes -ExpectedIdentity ([string]$state.AppliedFileIdentity) `
                            -ExpectedDaclRecord $expectedDeleteDacl -ExpectedReadOnly $expectedDeleteReadOnly `
                            -ExpectedParentIdentity $expectedDeleteParentIdentity `
                            -AllowReadOnlyOnlyDrift:($null -ne $readOnlyCreatedFileEvidence) -Operation 'Target rollback removal'
                        $state.MutationApplied = $false
                        $state.Publication = $null
                        $state.PublicationDaclRecord = $null
                        $state.PublicationReadOnly = $false
                        $state.AppliedFileIdentity = $null
                        $state.AppliedBytes = $null
                        $state.AppliedType = $null
                        continue
                    }
                    $currentEvidence = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) `
                        -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) -Kind Target -AllowMissing
                    if ($null -eq $currentEvidence -or
                        -not (Test-TargetMutationBytesEqual -Left ([byte[]]$currentEvidence.bytes) -Right ([byte[]]$state.AppliedBytes))) {
                        $driftedPaths.Add([string]$state.RelativePath)
                        continue
                    }
                    if ([string]$state.OriginalType -ceq 'file') {
                        [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
                        # Schema-v1 did not retain the original identity or DACL. Use live
                        # metadata only after the old whole-file byte CAS succeeds, and keep
                        # that fact separate from historic metadata in the journal.
                        $state.PublicationDaclRecord = $currentEvidence.dacl
                        $state.PublicationReadOnly = [bool]$currentEvidence.readOnly
                        Invoke-AtomicFilePublication -Kind Target -Root ([string]$Snapshot.TargetRoot) `
                            -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                            -ExpectedOldExists $true -ExpectedOldBytes ([byte[]]$currentEvidence.bytes) `
                            -ExpectedOldIdentity ([string]$currentEvidence.identity) -ExpectedOldSha256 ([string]$currentEvidence.sha256) `
                            -DaclRecord $currentEvidence.dacl -ReadOnly ([bool]$currentEvidence.readOnly) `
                            -NewBytes $originalBytes -Direction restore -PublicationState $state -Snapshot $Snapshot | Out-Null
                        $state.MutationApplied = $false
                        $state.Publication = $null
                        $state.PublicationDaclRecord = $null
                        $state.PublicationReadOnly = $false
                        $state.AppliedBytes = $null
                        $state.AppliedType = $null
                        continue
                    }
                    try {
                        Remove-TargetMutationFileAtomically -Snapshot $Snapshot -RelativePath ([string]$state.RelativePath) `
                            -ExpectedBytes ([byte[]]$state.AppliedBytes) -ExpectedIdentity ([string]$currentEvidence.identity) `
                            -Operation 'Target rollback removal'
                    }
                    catch {
                        $driftedPaths.Add([string]$state.RelativePath)
                        $rollbackErrors.Add($_.Exception.Message)
                        continue
                    }
                    $state.MutationApplied = $false
                }
                'missing' {
                    if (-not [bool]$state.LegacyRecovery) {
                        if ([string]$state.OriginalType -ceq 'file') {
                            $currentEvidence = Get-PublicationFileEvidence -Root ([string]$Snapshot.TargetRoot) `
                                -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                                -Kind Target -AllowMissing
                            if ($null -ne $currentEvidence) {
                                $driftedPaths.Add([string]$state.RelativePath)
                                continue
                            }
                            [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
                            Invoke-AtomicFilePublication -Kind Target -Root ([string]$Snapshot.TargetRoot) `
                                -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                                -ExpectedOldExists $false -ExpectedOldBytes $null -ExpectedOldIdentity $null -ExpectedOldSha256 $null `
                                -DaclRecord $state.OriginalDacl -ReadOnly ([bool]$state.OriginalReadOnly) -NewBytes $originalBytes `
                                -Direction restore -PublicationState $state -Snapshot $Snapshot | Out-Null
                            $state.Publication = $null
                            $state.PublicationDaclRecord = $null
                            $state.PublicationReadOnly = $false
                            $state.AppliedFileIdentity = $null
                            $state.AppliedBytes = $null
                            $state.AppliedType = $null
                        }
                        else { $state.MutationApplied = $false; $state.Publication = $null; $state.PublicationDaclRecord = $null
                            $state.PublicationReadOnly = $false; $state.AppliedFileIdentity = $null; $state.AppliedBytes = $null; $state.AppliedType = $null }
                        continue
                    }
                    if (Test-Path -LiteralPath ([string]$state.TargetPath)) {
                        $driftedPaths.Add([string]$state.RelativePath)
                        continue
                    }
                    if ([string]$state.OriginalType -ceq 'file') {
                        if ([string]$state.AppliedType -cne 'missing' -or $null -ne $state.AppliedBytes) {
                            throw "Schema-v1 recovery cannot prove that the missing target belongs to a journaled deletion; the backup was preserved for manual recovery: $($state.RelativePath)"
                        }
                        [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes([string]$state.BackupPath)
                        # V1 has no historic DACL or file identity. The journaled missing
                        # state plus the verified backup authorizes a no-replace stage into
                        # the guarded parent; capture the new file's actual ACL for retries.
                        Invoke-AtomicFilePublication -Kind Target -Root ([string]$Snapshot.TargetRoot) `
                            -Path ([string]$state.TargetPath) -RelativePath ([string]$state.RelativePath) `
                            -ExpectedOldExists $false -ExpectedOldBytes $null -ExpectedOldIdentity $null -ExpectedOldSha256 $null `
                            -DaclRecord $null -ReadOnly $false -NewBytes $originalBytes -Direction restore `
                            -PublicationState $state -Snapshot $Snapshot | Out-Null
                        $state.MutationApplied = $false
                        $state.Publication = $null
                        $state.PublicationDaclRecord = $null
                        $state.PublicationReadOnly = $false
                        $state.AppliedBytes = $null
                        $state.AppliedType = $null
                        continue
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

function Save-SkillMigrationJournal {
    param([object]$Snapshot, [object]$ExcludeSnapshot, [string]$Path, [object]$GitState, [string]$Phase,
        [string]$PendingPath, [string]$PendingType='missing', [byte[]]$PendingBytes)
    $schemaVersion = 2
    if ($Snapshot.PSObject.Properties['JournalSchemaVersion']) { $schemaVersion = [int]$Snapshot.JournalSchemaVersion }
    if ($schemaVersion -eq 1) {
        $states = @(
            foreach ($state in $Snapshot.FileStates) {
                $pending = [string]$state.RelativePath -ceq $PendingPath
                $legacyState = [ordered]@{
                    relativePath=$state.RelativePath; originalType=$state.OriginalType
                    backupName=$(if ($state.BackupPath) { Split-Path -Leaf $state.BackupPath } else { $null })
                    backupSha256=$(if ($state.BackupPath) { Get-RawContentHash $state.BackupPath } else { $null })
                    mutationApplied=([bool]$state.MutationApplied -or $pending)
                    appliedType=$(if ($pending) { $PendingType } else { $state.AppliedType })
                    appliedBase64=$(if ($pending -and $null -ne $PendingBytes) { [Convert]::ToBase64String($PendingBytes) }
                        elseif ($null -ne $state.AppliedBytes) { [Convert]::ToBase64String([byte[]]$state.AppliedBytes) } else { $null })
                }
                if ($null -ne $state.Publication) {
                    $legacyState.publication = $state.Publication
                    $legacyState.publicationDacl = $state.PublicationDaclRecord
                    $legacyState.publicationReadOnly = [bool]$state.PublicationReadOnly
                }
                $legacyState
            }
        )
        $exclude = [ordered]@{
            Path=$ExcludeSnapshot.Path; Repository=$ExcludeSnapshot.Repository
            MutationApplied=[bool]$ExcludeSnapshot.MutationApplied; Existed=[bool]$ExcludeSnapshot.Existed
            Bytes=$ExcludeSnapshot.Bytes; AppliedBytes=$ExcludeSnapshot.AppliedBytes
        }
        if ($null -ne $ExcludeSnapshot.Publication) {
            $exclude.publication = $ExcludeSnapshot.Publication
            $exclude.publicationDacl = $ExcludeSnapshot.PublicationDaclRecord
            $exclude.publicationReadOnly = [bool]$ExcludeSnapshot.PublicationReadOnly
        }
        $document = [ordered]@{schemaVersion=1; targetRoot=$Snapshot.TargetRoot; phase=$Phase; head=$GitState.head
            indexSha256=$GitState.indexSha256; states=$states; exclude=$exclude}
    }
    else {
    $states = @(
        foreach ($state in $Snapshot.FileStates) {
            $pending = [string]$state.RelativePath -ceq $PendingPath
            [ordered]@{relativePath=$state.RelativePath; originalType=$state.OriginalType
                backupName=$(if ($state.BackupPath) { Split-Path -Leaf $state.BackupPath } else { $null })
                backupSha256=$(if ($state.BackupPath) { Get-RawContentHash $state.BackupPath } else { $null })
                mutationApplied=([bool]$state.MutationApplied -or $pending)
                appliedType=$(if ($pending) { $PendingType } else { $state.AppliedType })
                appliedBase64=$(if ($pending -and $null -ne $PendingBytes) { [Convert]::ToBase64String($PendingBytes) }
                    elseif ($null -ne $state.AppliedBytes) { [Convert]::ToBase64String([byte[]]$state.AppliedBytes) } else { $null })
                originalDacl=$state.OriginalDacl; originalReadOnly=[bool]$state.OriginalReadOnly; originalIdentity=$state.OriginalIdentity
                appliedFileIdentity=$state.AppliedFileIdentity; publication=$state.Publication
                publicationDacl=$state.PublicationDaclRecord; publicationReadOnly=[bool]$state.PublicationReadOnly}
        }
    )
    $exclude = [ordered]@{
        path=$ExcludeSnapshot.Path; repository=$ExcludeSnapshot.Repository
        mutationApplied=[bool]$ExcludeSnapshot.MutationApplied; existed=[bool]$ExcludeSnapshot.Existed
        bytesBase64=$(if ([bool]$ExcludeSnapshot.Existed -and $null -ne $ExcludeSnapshot.Bytes) { [Convert]::ToBase64String([byte[]]$ExcludeSnapshot.Bytes) } else { $null })
        appliedBase64=$(if ($null -ne $ExcludeSnapshot.AppliedBytes) { [Convert]::ToBase64String([byte[]]$ExcludeSnapshot.AppliedBytes) } else { $null })
        dacl=$ExcludeSnapshot.DaclRecord; originalReadOnly=[bool]$ExcludeSnapshot.OriginalReadOnly
        originalIdentity=$ExcludeSnapshot.OriginalIdentity; appliedFileIdentity=$ExcludeSnapshot.AppliedFileIdentity
        publication=$ExcludeSnapshot.Publication; publicationDacl=$ExcludeSnapshot.PublicationDaclRecord
        publicationReadOnly=[bool]$ExcludeSnapshot.PublicationReadOnly
    }
    $createdDirectories = @($Snapshot.CreatedDirectories | ForEach-Object {
        [ordered]@{fullPath=$_.FullPath;relativePath=$_.RelativePath;volumeSerialNumber=$_.VolumeSerialNumber
            fileIndexHigh=$_.FileIndexHigh;fileIndexLow=$_.FileIndexLow}
    })
    $document = [ordered]@{schemaVersion=2; targetRoot=$Snapshot.TargetRoot; phase=$Phase; head=$GitState.head; indexSha256=$GitState.indexSha256
        states=$states; exclude=$exclude; createdDirectories=$createdDirectories}
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($document | ConvertTo-Json -Depth 14) + "`n")
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temporary,$Path,$true)
}

function Restore-SkillMigrationJournal {
    param([string]$Repository, [string]$Path)
    $journalPath = [IO.Path]::GetFullPath($Path)
    $backupRoot = Split-Path -Parent $journalPath
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $backupRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $backupRoot) -cne 'target-backup' -or (Split-Path -Leaf $journalPath) -cne 'skill-migration.json') { throw 'Unsafe Skill migration recovery location.' }
    Assert-ManagedPathDoesNotCrossReparsePoint -Root $tempPrefix.TrimEnd([char[]]@('\','/')) -Path $journalPath -Context 'Skill migration recovery'
    $journal = Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
    $schemaVersion = [int]$journal.schemaVersion
    if ($schemaVersion -eq 2) {
        Assert-ExactJournalProperties -Value $journal -Names @('schemaVersion','targetRoot','phase','head','indexSha256','states','exclude','createdDirectories') -Context 'schema-v2 migration journal'
        if ($null -eq $journal.states -or $null -eq $journal.exclude -or $null -eq $journal.createdDirectories) { throw 'Schema-v2 migration journal is incomplete.' }
    }
    if ($schemaVersion -notin @(1,2) -or [string]$journal.targetRoot -cne $Repository -or
        $journal.phase -notin @('mutating','applied','rolled-back','recovered') -or
        [string]$journal.head -cnotmatch '^[0-9a-f]{40,64}$' -or [string]$journal.indexSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Skill migration journal identity or schema is invalid.'
    }
    $gitState = Get-RepoSkillMigrationGitState -Repository $Repository -GitExecutable $GitExecutable
    if ($gitState.head -cne $journal.head -or $gitState.indexSha256 -cne $journal.indexSha256) { throw 'Skill migration recovery preserved concurrent Git changes.' }
    $states = @()
    $seen = @{}
    $seenBackups = @{}
    foreach ($state in $journal.states) {
        if ($schemaVersion -eq 2) {
            Assert-ExactJournalProperties -Value $state -Names @('relativePath','originalType','backupName','backupSha256','mutationApplied',
                'appliedType','appliedBase64','originalDacl','originalReadOnly','originalIdentity','appliedFileIdentity','publication',
                'publicationDacl','publicationReadOnly') `
                -Context 'schema-v2 migration state'
        }
        if ($state.mutationApplied -isnot [bool]) { throw 'Invalid Skill migration recovery mutation flag.' }
        $relative = [string]$state.relativePath
        if ((-not (Test-IsAllowedManagedPath $relative) -and $relative -cne '.codex/ai-instructions.manifest.json') -or
            $seen.ContainsKey($relative) -or $state.originalType -notin @('file','missing')) { throw 'Invalid Skill migration recovery path/state.' }
        $seen[$relative]=$true
        $target = [IO.Path]::GetFullPath((Join-Path $Repository $relative))
        Assert-ManagedPathDoesNotCrossReparsePoint -Root $Repository -Path $target -Context 'Skill migration recovery target'
        $backup = $null
        if ($state.originalType -eq 'file') {
            if ([string]$state.backupName -cnotmatch '^\d{6}\.bin$' -or [string]$state.backupSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid Skill migration backup inventory.' }
            if ($seenBackups.ContainsKey([string]$state.backupName)) { throw 'Duplicate Skill migration backup inventory.' }
            $seenBackups[[string]$state.backupName]=$true
            $backup = Join-Path $backupRoot $state.backupName
            Assert-ManagedPathDoesNotCrossReparsePoint -Root $backupRoot -Path $backup -Context 'Skill migration recovery backup'
            if ((Get-RawContentHash $backup) -cne [string]$state.backupSha256) { throw 'Skill migration recovery backup hash mismatch.' }
        }
        elseif ($schemaVersion -eq 2 -and ($null -ne $state.backupName -or $null -ne $state.backupSha256)) {
            throw 'Schema-v2 missing original file contains an unexpected backup inventory.'
        }
        $applied = [bool]$state.mutationApplied
        if ($applied -and $state.appliedType -notin @('file','missing')) { throw 'Invalid applied Skill migration recovery state.' }
        $appliedBytes = $null
        if ($null -ne $state.appliedBase64) {
            try { $appliedBytes = [Convert]::FromBase64String([string]$state.appliedBase64) }
            catch { throw 'Invalid Skill migration applied-byte encoding.' }
        }
        $originalDacl = $null; $originalReadOnly = $false; $originalIdentity = $null
        $appliedIdentity = $null; $publication = $null; $publicationDacl = $null; $publicationReadOnly = $false
        $legacyRecovery = $schemaVersion -eq 1
        $statePublicationProperty = $state.PSObject.Properties['publication']
        $statePublication = if ($null -eq $statePublicationProperty) { $null } else { $statePublicationProperty.Value }
        if ($schemaVersion -eq 1 -and $null -ne $statePublication) {
            Assert-AtomicFilePublicationRecord -Publication $statePublication -RelativePath $relative
            $publication = $statePublication
            $publicationNewMatchesBackup = [string]$publication.direction -ceq 'restore' -and
                $state.originalType -ceq 'file' -and
                [string]$publication.newSha256 -ceq [string]$state.backupSha256 -and
                [long]$publication.newLength -eq [long](Get-Item -LiteralPath $backup).Length
            if ($state.appliedType -ceq 'file') {
                $publicationOldMatchesApplied = $null -ne $appliedBytes -and [bool]$publication.expectedOldExists -and
                    [string]$publication.expectedOldSha256 -ceq (Get-ByteArraySha256 $appliedBytes) -and
                    [long]$publication.expectedOldLength -eq [long]$appliedBytes.Length
            }
            else {
                $publicationOldMatchesApplied = $state.appliedType -ceq 'missing' -and $null -eq $appliedBytes -and
                    -not [bool]$publication.expectedOldExists -and $null -eq $publication.expectedOldIdentity -and
                    $null -eq $publication.expectedOldSha256 -and [long]$publication.expectedOldLength -eq 0
            }
            if (-not $publicationNewMatchesBackup -or -not $publicationOldMatchesApplied -or
                $state.publicationReadOnly -isnot [bool] -or $null -eq $state.publicationDacl) {
                throw 'Invalid schema-v1 staged recovery publication state.'
            }
            $publicationDacl = $state.publicationDacl
            $null = ConvertFrom-FileDaclJournalRecord $publicationDacl
            $publicationReadOnly = [bool]$state.publicationReadOnly
        }
        if ($schemaVersion -eq 2) {
            if ($null -ne $state.appliedType -and $state.appliedType -notin @('file','missing')) { throw 'Invalid schema-v2 applied state type.' }
            if ($state.originalReadOnly -isnot [bool]) { throw 'Invalid schema-v2 original read-only attribute.' }
            $originalReadOnly = [bool]$state.originalReadOnly
            if ($state.originalType -eq 'file') {
                if ([string]$state.originalIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$' -or $null -eq $state.originalDacl) { throw 'Invalid schema-v2 original file identity or DACL.' }
                $originalIdentity = [string]$state.originalIdentity
                $originalDacl = $state.originalDacl
                $null = ConvertFrom-FileDaclJournalRecord $originalDacl
            }
            elseif ($null -ne $state.originalIdentity -or $null -ne $state.originalDacl -or $originalReadOnly) { throw 'Invalid schema-v2 missing original file metadata.' }
            if ($applied -and $state.appliedType -ceq 'file' -and $null -eq $appliedBytes) { throw 'Schema-v2 applied file bytes are missing.' }
            if ($applied -and $state.appliedType -ceq 'missing' -and $null -ne $appliedBytes) { throw 'Schema-v2 missing applied state has file bytes.' }
            if ($null -ne $state.appliedFileIdentity) {
                if ([string]$state.appliedFileIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$') { throw 'Invalid schema-v2 applied file identity.' }
                $appliedIdentity = [string]$state.appliedFileIdentity
            }
            if ($null -eq $statePublication -and $null -ne $appliedIdentity) {
                throw 'Schema-v2 applied file identity has no publication ownership record.'
            }
            if ($null -ne $statePublication) {
                Assert-AtomicFilePublicationRecord -Publication $statePublication -RelativePath $relative
                $publication = $statePublication
                if ($null -eq $state.publicationDacl -or $state.publicationReadOnly -isnot [bool]) {
                    throw 'Schema-v2 publication is missing its measured staged-file metadata.'
                }
                $publicationDacl = $state.publicationDacl
                $null = ConvertFrom-FileDaclJournalRecord $publicationDacl
                $publicationReadOnly = [bool]$state.publicationReadOnly
                if ($state.originalType -ceq 'file' -and
                    (-not [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                        (ConvertFrom-FileDaclJournalRecord $originalDacl), (ConvertFrom-FileDaclJournalRecord $publicationDacl)) -or
                     $publicationReadOnly -ne $originalReadOnly)) {
                    throw 'Schema-v2 publication metadata does not match the preserved original file metadata.'
                }
                if ($publication.direction -ceq 'apply') {
                    if ($null -eq $appliedBytes -or (Get-ByteArraySha256 $appliedBytes) -cne [string]$publication.newSha256 -or
                        [long]$appliedBytes.Length -ne [long]$publication.newLength -or $appliedIdentity -cne [string]$publication.stageIdentity) {
                        throw 'Schema-v2 apply publication does not match its recorded file state.'
                    }
                    if ([bool]$publication.expectedOldExists -ne ($state.originalType -ceq 'file') -or
                        ([bool]$publication.expectedOldExists -and ([string]$publication.expectedOldSha256 -cne [string]$state.backupSha256 -or
                            [string]$publication.expectedOldIdentity -cne [string]$originalIdentity -or
                            [long]$publication.expectedOldLength -ne [long](Get-Item -LiteralPath $backup).Length))) {
                        throw 'Schema-v2 apply publication does not match its original file inventory.'
                    }
                }
                else {
                    $restoreNewMatchesBackup = $state.originalType -ceq 'file' -and
                        [string]$publication.newSha256 -ceq [string]$state.backupSha256 -and
                        [long]$publication.newLength -eq [long](Get-Item -LiteralPath $backup).Length
                    if ($state.appliedType -ceq 'file') {
                        $restoreOldMatchesApplied = [bool]$publication.expectedOldExists -and $null -ne $appliedBytes -and
                            $null -ne $appliedIdentity -and
                            [string]$publication.expectedOldSha256 -ceq (Get-ByteArraySha256 $appliedBytes) -and
                            [long]$publication.expectedOldLength -eq [long]$appliedBytes.Length -and
                            [string]$publication.expectedOldIdentity -ceq [string]$appliedIdentity
                    }
                    else {
                        $restoreOldMatchesApplied = $state.appliedType -ceq 'missing' -and
                            -not [bool]$publication.expectedOldExists -and
                            $null -eq $publication.expectedOldIdentity -and $null -eq $publication.expectedOldSha256 -and
                            [long]$publication.expectedOldLength -eq 0 -and
                            $null -eq $appliedBytes -and $null -eq $appliedIdentity
                    }
                    if (-not $restoreNewMatchesBackup -or -not $restoreOldMatchesApplied) {
                        throw 'Schema-v2 restore publication does not match its original backup and applied state.'
                    }
                }
            }
            elseif ($null -ne $state.publicationDacl -or $state.publicationReadOnly -isnot [bool] -or [bool]$state.publicationReadOnly) {
                throw 'Schema-v2 state contains staged-file metadata without publication ownership.'
            }
        }
        elseif ($null -eq $publication -and $applied -and (($state.originalType -eq 'file' -and (Test-Path -LiteralPath $target -PathType Leaf) -and
            (Get-RawContentHash $target) -ceq [string]$state.backupSha256) -or
            ($state.originalType -eq 'missing' -and -not (Test-Path -LiteralPath $target)))) {
            # Schema-v1 intent had no publication record; only an exact original state is a no-op.
            $applied = $false
        }
        $states += [pscustomobject][ordered]@{RelativePath=$relative; TargetPath=$target; OriginalType=$state.originalType; BackupPath=$backup
            OriginalDacl=$originalDacl; OriginalReadOnly=$originalReadOnly; OriginalIdentity=$originalIdentity
            AppliedFileIdentity=$appliedIdentity; Publication=$publication; PublicationDaclRecord=$publicationDacl
            PublicationReadOnly=$publicationReadOnly; LegacyRecovery=$legacyRecovery
            MutationApplied=$applied; AppliedType=$state.appliedType; AppliedBytes=$appliedBytes}
    }
    $createdDirectories = New-Object 'System.Collections.Generic.List[object]'
    if ($schemaVersion -eq 2) {
        $seenCreatedDirectories=@{}
        foreach ($directory in @($journal.createdDirectories)) {
            Assert-ExactJournalProperties -Value $directory -Names @('fullPath','relativePath','volumeSerialNumber','fileIndexHigh','fileIndexLow') `
                -Context 'schema-v2 created-directory identity'
            $relativeDirectory = [string]$directory.relativePath
            $directorySegments=$relativeDirectory.Replace('\','/').Split('/')
            if ([string]::IsNullOrWhiteSpace($relativeDirectory) -or $relativeDirectory.Contains(':') -or $relativeDirectory.StartsWith('/') -or
                @($directorySegments | Where-Object { $_ -in @('','.','..') }).Count -gt 0 -or
                [uint32]$directory.volumeSerialNumber -eq 0 -or ([uint32]$directory.fileIndexHigh -eq 0 -and [uint32]$directory.fileIndexLow -eq 0)) {
                throw 'Invalid schema-v2 created-directory identity.'
            }
            $fullDirectory = [IO.Path]::GetFullPath((Join-Path $Repository $relativeDirectory.Replace('/','\')))
            $repositoryPrefix=[IO.Path]::GetFullPath($Repository).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
            if (-not $fullDirectory.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase) -or
                $fullDirectory -cne [IO.Path]::GetFullPath([string]$directory.fullPath) -or
                $seenCreatedDirectories.ContainsKey($relativeDirectory)) { throw 'Invalid schema-v2 created-directory path.' }
            $seenCreatedDirectories[$relativeDirectory]=$true
            [void]$createdDirectories.Add([pscustomobject][ordered]@{FullPath=$fullDirectory;RelativePath=$relativeDirectory
                VolumeSerialNumber=[uint32]$directory.volumeSerialNumber;FileIndexHigh=[uint32]$directory.fileIndexHigh;FileIndexLow=[uint32]$directory.fileIndexLow})
        }
    }
    $snapshot = [pscustomobject][ordered]@{TargetRoot=$Repository; FileStates=$states; CreatedDirectories=$createdDirectories
        JournalSchemaVersion=$schemaVersion}
    $journalExclude = $journal.exclude
    if ([string]$journalExclude.Repository -cne $Repository -or [string]$journalExclude.Path -cne (Get-GitInfoExcludePath $Repository)) { throw 'Invalid Skill migration exclude recovery target.' }
    Assert-GitInfoExcludeMutationPath -Repository $Repository -Path $journalExclude.Path
    $excludePublicationProperty = $journalExclude.PSObject.Properties['publication']
    $journalExcludePublication = if ($null -eq $excludePublicationProperty) { $null } else { $excludePublicationProperty.Value }
    if ($schemaVersion -eq 1) {
        $excludePublication = $journalExcludePublication
        $excludePublicationDacl = $null; $excludePublicationReadOnly = $false
        if ($null -ne $excludePublication) {
            Assert-AtomicFilePublicationRecord -Publication $excludePublication -RelativePath ([IO.Path]::GetFileName([string]$journalExclude.Path))
            if ([string]$excludePublication.direction -cne 'restore' -or -not [bool]$journalExclude.Existed -or
                $null -eq $journalExclude.AppliedBytes -or
                [string]$excludePublication.newSha256 -cne (Get-ByteArraySha256 ([byte[]]$journalExclude.Bytes)) -or
                [long]$excludePublication.newLength -ne [long]([byte[]]$journalExclude.Bytes).Length -or
                -not [bool]$excludePublication.expectedOldExists -or
                [string]$excludePublication.expectedOldSha256 -cne (Get-ByteArraySha256 ([byte[]]$journalExclude.AppliedBytes)) -or
                [long]$excludePublication.expectedOldLength -ne [long]([byte[]]$journalExclude.AppliedBytes).Length -or
                $journalExclude.publicationReadOnly -isnot [bool] -or $null -eq $journalExclude.publicationDacl) {
                throw 'Invalid schema-v1 exclude staged recovery publication state.'
            }
            $excludePublicationDacl = $journalExclude.publicationDacl
            $null = ConvertFrom-FileDaclJournalRecord $excludePublicationDacl
            $excludePublicationReadOnly = [bool]$journalExclude.publicationReadOnly
        }
        $exclude = [pscustomobject][ordered]@{Path=$journalExclude.Path;Repository=$journalExclude.Repository
            MutationApplied=[bool]$journalExclude.MutationApplied;Existed=[bool]$journalExclude.Existed
            Bytes=$(if ($null -ne $journalExclude.bytes) { [byte[]]$journalExclude.bytes } else { $null })
            AppliedBytes=$(if ($null -ne $journalExclude.appliedBytes) { [byte[]]$journalExclude.appliedBytes } else { $null })
            DaclRecord=$null;OriginalReadOnly=$false;OriginalIdentity=$null;AppliedFileIdentity=$null;Publication=$excludePublication
            PublicationDaclRecord=$excludePublicationDacl;PublicationReadOnly=$excludePublicationReadOnly;LegacyRecovery=$true}
    }
    else {
        Assert-ExactJournalProperties -Value $journalExclude -Names @('path','repository','mutationApplied','existed','bytesBase64','appliedBase64',
            'dacl','originalReadOnly','originalIdentity','appliedFileIdentity','publication','publicationDacl','publicationReadOnly') -Context 'schema-v2 exclude state'
        if ($journalExclude.mutationApplied -isnot [bool] -or $journalExclude.existed -isnot [bool] -or $journalExclude.originalReadOnly -isnot [bool]) {
            throw 'Invalid schema-v2 exclude mutation metadata.'
        }
        $excludeBytes=$null; $excludeAppliedBytes=$null
        if ($null -ne $journalExclude.bytesBase64) { try { $excludeBytes=[Convert]::FromBase64String([string]$journalExclude.bytesBase64) } catch { throw 'Invalid schema-v2 exclude backup encoding.' } }
        if ($null -ne $journalExclude.appliedBase64) { try { $excludeAppliedBytes=[Convert]::FromBase64String([string]$journalExclude.appliedBase64) } catch { throw 'Invalid schema-v2 exclude applied encoding.' } }
        $excludeDacl=$journalExclude.dacl
        if ([bool]$journalExclude.existed) {
            if ($null -eq $excludeBytes -or [string]$journalExclude.originalIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$' -or $null -eq $excludeDacl) { throw 'Invalid schema-v2 exclude original inventory.' }
            $null=ConvertFrom-FileDaclJournalRecord $excludeDacl
        }
        elseif ($null -ne $excludeBytes -or $null -ne $journalExclude.originalIdentity -or $null -ne $excludeDacl -or [bool]$journalExclude.originalReadOnly) { throw 'Invalid schema-v2 missing exclude original inventory.' }
        if ($null -ne $journalExclude.appliedFileIdentity -and
            [string]$journalExclude.appliedFileIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}$') {
            throw 'Invalid schema-v2 exclude applied file identity.'
        }
        $excludePublication=$journalExcludePublication
        $excludePublicationDacl=$journalExclude.publicationDacl
        $excludePublicationReadOnly=$false
        if ($null -ne $excludePublication) {
            if ($null -eq $excludePublicationDacl -or $journalExclude.publicationReadOnly -isnot [bool]) {
                throw 'Schema-v2 exclude publication is missing its measured staged-file metadata.'
            }
            $null=ConvertFrom-FileDaclJournalRecord $excludePublicationDacl
            $excludePublicationReadOnly=[bool]$journalExclude.publicationReadOnly
            if ([bool]$journalExclude.existed -and
                (-not [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                    (ConvertFrom-FileDaclJournalRecord $excludeDacl), (ConvertFrom-FileDaclJournalRecord $excludePublicationDacl)) -or
                 $excludePublicationReadOnly -ne [bool]$journalExclude.originalReadOnly)) {
                throw 'Schema-v2 exclude publication metadata does not match its preserved original metadata.'
            }
        }
        elseif ($null -ne $excludePublicationDacl -or $journalExclude.publicationReadOnly -isnot [bool] -or [bool]$journalExclude.publicationReadOnly) {
            throw 'Schema-v2 exclude contains staged-file metadata without publication ownership.'
        }
        if ($null -eq $excludePublication -and $null -ne $journalExclude.appliedFileIdentity) {
            throw 'Schema-v2 exclude applied file identity has no publication ownership record.'
        }
        if ($null -ne $excludePublication) {
            Assert-AtomicFilePublicationRecord -Publication $excludePublication -RelativePath ([IO.Path]::GetFileName([string]$journalExclude.Path))
            if ($excludePublication.direction -ceq 'apply' -and ($null -eq $excludeAppliedBytes -or
                (Get-ByteArraySha256 $excludeAppliedBytes) -cne [string]$excludePublication.newSha256 -or
                [long]$excludeAppliedBytes.Length -ne [long]$excludePublication.newLength -or
                [string]$journalExclude.appliedFileIdentity -cne [string]$excludePublication.stageIdentity -or
                [bool]$excludePublication.expectedOldExists -ne [bool]$journalExclude.existed -or
                ([bool]$excludePublication.expectedOldExists -and ([string]$excludePublication.expectedOldIdentity -cne [string]$journalExclude.originalIdentity -or
                    [string]$excludePublication.expectedOldSha256 -cne (Get-ByteArraySha256 $excludeBytes) -or
                    [long]$excludePublication.expectedOldLength -ne [long]$excludeBytes.Length)))) { throw 'Schema-v2 exclude publication does not match its applied state.' }
            if ($excludePublication.direction -ceq 'restore' -and ([bool]$journalExclude.existed -eq $false -or
                (Get-ByteArraySha256 $excludeBytes) -cne [string]$excludePublication.newSha256 -or
                [long]$excludePublication.newLength -ne [long]$excludeBytes.Length -or
                $null -eq $excludeAppliedBytes -or [string]$excludePublication.expectedOldIdentity -cne [string]$journalExclude.appliedFileIdentity -or
                [string]$excludePublication.expectedOldSha256 -cne (Get-ByteArraySha256 $excludeAppliedBytes) -or
                [long]$excludePublication.expectedOldLength -ne [long]$excludeAppliedBytes.Length)) { throw 'Schema-v2 exclude restore publication does not match its backup.' }
        }
        $exclude=[pscustomobject][ordered]@{Path=$journalExclude.Path;Repository=$journalExclude.Repository
            MutationApplied=[bool]$journalExclude.mutationApplied;Existed=[bool]$journalExclude.existed;Bytes=$excludeBytes
            AppliedBytes=$excludeAppliedBytes;DaclRecord=$excludeDacl;OriginalReadOnly=[bool]$journalExclude.originalReadOnly
            OriginalIdentity=$journalExclude.originalIdentity;AppliedFileIdentity=$journalExclude.appliedFileIdentity
            Publication=$excludePublication;PublicationDaclRecord=$excludePublicationDacl
            PublicationReadOnly=$excludePublicationReadOnly;LegacyRecovery=$false}
    }
    if ($schemaVersion -eq 1 -and $null -eq $exclude.Publication -and [bool]$exclude.MutationApplied) {
        $legacyExcludeIsOriginal = $false
        if ([bool]$exclude.Existed -and (Test-Path -LiteralPath $exclude.Path -PathType Leaf)) {
            $legacyExcludeIsOriginal = Test-GitInfoExcludeBytesEqual -Left ([IO.File]::ReadAllBytes([string]$exclude.Path)) `
                -Right ([byte[]]$exclude.Bytes)
        }
        elseif (-not [bool]$exclude.Existed -and -not (Test-Path -LiteralPath $exclude.Path)) {
            $legacyExcludeIsOriginal = $true
        }
        if ($legacyExcludeIsOriginal) { $exclude.MutationApplied = $false }
    }
    $previousJournalContext = $script:SkillMigrationJournalContext
    $script:SkillMigrationJournalContext = [pscustomobject]@{
        Snapshot=$snapshot; ExcludeSnapshot=$exclude; Path=$journalPath; GitState=$gitState
    }
    try {
        Restore-TargetMutationSnapshot -Snapshot $snapshot
        Restore-GitInfoExcludeSnapshot -Snapshot $exclude
        Save-SkillMigrationJournal $snapshot $exclude $journalPath $gitState 'recovered'
        Write-Output "Skill migration recovery verified: $journalPath"
    }
    finally { $script:SkillMigrationJournalContext = $previousJournalContext }
}

$script:SkillMigrationJournalContext = $null
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
Assert-RepoAndUserRootsDistinct -Repository $targetRootPath -UserHome $UserHome | Out-Null
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

if (-not [string]::IsNullOrWhiteSpace($RecoverSkillMigration)) {
    $recoveryLock = Open-RepositoryOperationLock $targetRootPath
    $recoveryIndexLock = $null
    try {
        $recoveryIndexLock = Open-RepositoryIndexTransactionLock $targetRootPath
        Restore-SkillMigrationJournal $targetRootPath $RecoverSkillMigration
    }
    finally {
        if ($recoveryIndexLock) { $recoveryIndexLock.Stream.Dispose(); Remove-Item -LiteralPath $recoveryIndexLock.Path -Force }
        $recoveryLock.Dispose()
    }
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
    if (-not $WhatIf) {
        $repositoryOperationLock = Open-RepositoryOperationLock -Repository $targetRootPath
        $remediationTransaction = Invoke-AgentArtifactRemediation -Repository $targetRootPath -GitExecutable $GitExecutable
    }
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
    if (($manifestSchemaVersion -isnot [int] -and $manifestSchemaVersion -isnot [long]) -or $manifestSchemaVersion -notin @(1, 2, 3)) {
        throw "Unsupported managed instruction manifest schema: $($manifest.schemaVersion)"
    }

    if ($manifestSchemaVersion -in @(2,3)) {
        Assert-ManagedManifest -Manifest $manifest
    }
    else { Assert-LegacyManagedManifestV1 -Manifest $manifest }

    if ($manifestSchemaVersion -in @(2,3) -and
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
            if ([string]$targetPath -like '.agents/skills/*') { continue }
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

if (-not $WhatIf) { $repositoryIndexLock = Open-RepositoryIndexTransactionLock -Repository $targetRootPath }
$gitPathComparer = Get-GitPathComparer -Repository $targetRootPath
$trackedPaths = New-Object 'System.Collections.Generic.HashSet[string]' $gitPathComparer
foreach ($trackedPath in @(Invoke-Git -Repository $targetRootPath -Arguments @('-c','core.quotePath=true','ls-files'))) {
    [void]$trackedPaths.Add((ConvertFrom-GitQuotedPath -Path ([string]$trackedPath)).Replace('\','/'))
}
$trackedPollutionPaths = @(@(
    if ($trackedPaths.Contains($manifestRelativePath)) { $manifestRelativePath }
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if (-not ([string]$targetPath).StartsWith('.agents/skills/',[StringComparison]::Ordinal) -and $trackedPaths.Contains([string]$targetPath)) { [string]$targetPath }
    }
) | Sort-Object -Unique)
if ($trackedPollutionPaths.Count -gt 0 -and -not $WhatIf) {
    throw "Tracked reserved Agent artifacts remain after controlled remediation: $($trackedPollutionPaths -join ', ')."
}

$stagedManagedPaths = @(
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        if (-not ([string]$targetPath).StartsWith('.agents/skills/',[StringComparison]::Ordinal) -and (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path ([string]$targetPath))) {
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
                TargetPath = "$licenseTargetPrefix/ai-instructions-licenses/$($script:instructionProvenance.sourceCommit)/$($licenseFile.relativePath)"
                SourceFullPath = (Join-Path $licenseRoot $licenseFile.relativePath); Sha256 = $licenseFile.sha256
            })
        }
    }

    # Consumer scope is Instructions-only, including direct and legacy composed archives.
    # Shared Skill sources remain available to the USER reconciler and migration evidence.

    $trustedSkills = @(
        foreach ($skill in @($provenance.skills)) {
            if ($null -eq $skill.PSObject.Properties['files']) {
                $legacySource = Join-Path $sourceRootPath ".agents/skills/$($skill.id)"
                $inventory = @()
                if (Test-Path -LiteralPath $legacySource -PathType Container) {
                    $inventory = @(Get-ChildItem -LiteralPath $legacySource -File -Recurse -Force | Where-Object Name -ne '.gitkeep' | ForEach-Object {
                        [pscustomobject]@{targetPath=(Get-RepositoryRelativePath $sourceRootPath $_.FullName); sha256=(Get-RawContentHash $_.FullName)}
                    })
                }
                $skill | Add-Member -NotePropertyName files -NotePropertyValue $inventory
            }
            $skill
        }
    )
    foreach ($readiness in @(Get-UserSharedSkillsReadiness -UserHome $UserHome -CatalogId $provenance.catalogId -TrustedSkills $trustedSkills)) {
        if (-not $readiness.ready) { Write-Output "USER Skill repair/update required for $($readiness.id): $($readiness.reason). REPO fallback is disabled." }
    }
    $skillMigration = @()
    if ($manifestExists -and $manifestSchemaVersion -in @(2,3)) {
        $skillMigration = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRootPath -Manifest $manifest -TrustedSkills $trustedSkills -UserHome $UserHome -GitExecutable $GitExecutable)
    }
    $migrationById = @{}
    foreach ($skill in $skillMigration) {
        $migrationById[[string]$skill.id] = $skill
        $disposition = if ($skill.removable) { 'retire verified ignored/untracked copy' } else { "preserve: $($skill.reason)" }
        Write-Output "Skill migration $($skill.id): $disposition"
    }
    $existingSkillsRoot = Join-Path $targetRootPath '.agents/skills'
    if ((Test-Path -LiteralPath $existingSkillsRoot -PathType Container) -and
        -not ((Get-Item -Force -LiteralPath $existingSkillsRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        foreach ($directory in @(Get-ChildItem -Directory -Force -LiteralPath $existingSkillsRoot)) {
            if (-not $migrationById.ContainsKey($directory.Name)) { Write-Output "Repository Skill preserved without provable shared ownership: $($directory.Name)" }
        }
    }
    $retainLegacyManifest = $manifestExists -and $manifestSchemaVersion -eq 1 -and @($manifestEntriesByTarget.Keys | Where-Object { $_ -like '.agents/skills/*' }).Count -gt 0

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
    $createdPaths = New-Object System.Collections.Generic.List[string]
    $updatedPaths = New-Object System.Collections.Generic.List[string]
    $removedPaths = New-Object System.Collections.Generic.List[string]
    $skippedPaths = New-Object System.Collections.Generic.List[string]
    $nextManifestEntries = New-Object System.Collections.Generic.List[object]

    if ($WhatIf) {
        Write-Output 'WhatIf: consumer Instructions-only synchronization; shared Skills will never be installed in REPO.'
        return
    }

    $mutationPaths = @(
        @($desiredEntries | ForEach-Object { [string]$_.TargetPath })
        @($manifestEntriesByTarget.Keys | Where-Object {
            if ([string]$_ -notlike '.agents/skills/*') { $true }
            else { $id=([string]$_).Split('/')[2]; $migrationById.ContainsKey($id) -and $migrationById[$id].removable }
        })
        $manifestRelativePath
    )
    $mutationBackupRoot = Join-Path $workingPath 'target-backup'
    $mutationSnapshot = New-TargetMutationSnapshot -TargetRoot $targetRootPath -RelativePaths $mutationPaths -BackupRoot $mutationBackupRoot
    $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRootPath
    $migrationJournalPath = Join-Path $mutationBackupRoot 'skill-migration.json'
    $migrationGitState = $null
    if (@($skillMigration | Where-Object removable).Count -gt 0) {
        $migrationGitState = Get-RepoSkillMigrationGitState -Repository $targetRootPath -GitExecutable $GitExecutable
        $preserveWorkingPath = $true
        $script:SkillMigrationJournalContext = [pscustomobject]@{Snapshot=$mutationSnapshot; ExcludeSnapshot=$excludeSnapshot; Path=$migrationJournalPath; GitState=$migrationGitState}
        Save-SkillMigrationJournal $mutationSnapshot $excludeSnapshot $migrationJournalPath $migrationGitState 'mutating'
    }

    try {
        foreach ($desiredEntry in @($desiredEntries | Sort-Object TargetPath)) {
        $targetPath = $desiredEntry.TargetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        $targetExists = Test-Path -LiteralPath $targetFullPath -PathType Leaf
        $managedEntry = $null

        $entryIsEligible = [bool]$eligibleFamilies[$desiredEntry.FamilyName]
        if (-not $entryIsEligible) {
            $skippedPaths.Add($targetPath)
            continue
        }

        $desiredManifestEntry = New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256
        $desiredManifestSchemaVersion = 2
        if ($manifestExists) { $desiredManifestSchemaVersion = [int]$manifestSchemaVersion }
        $desiredManifestEntry = Convert-ManifestEntryForSchema -Entry $desiredManifestEntry -SchemaVersion $desiredManifestSchemaVersion
        if ($retainLegacyManifest) { $desiredManifestEntry = $desiredManifestEntry | Select-Object sourcePath,targetPath,sha256 }

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

        # Reconcile payload removals first so retained customizations keep their original license version.
        foreach ($managedTargetPath in @($manifestEntriesByTarget.Keys | Sort-Object @{Expression={ [int](Test-LicenseDeliveryTargetPath $_) }}, @{Expression={ $_ }})) {
        if ($desiredEntriesByTarget.ContainsKey($managedTargetPath)) {
            continue
        }

        $managedEntry = $manifestEntriesByTarget[$managedTargetPath]
        if ($managedTargetPath.StartsWith('.agents/skills/',[StringComparison]::Ordinal)) {
            $id = $managedTargetPath.Split('/')[2]
            if ($migrationById.ContainsKey($id) -and $migrationById[$id].removable) {
                Assert-RepoSharedSkillsMigrationEvidence -Repository $targetRootPath -Skill $migrationById[$id] -RemovedPaths @($removedPaths) -GitExecutable $GitExecutable
                Remove-TargetMutationFile -Snapshot $mutationSnapshot -RelativePath $managedTargetPath
                $removedPaths.Add($managedTargetPath)
                Save-SkillMigrationJournal $mutationSnapshot $excludeSnapshot $migrationJournalPath $migrationGitState 'mutating'
                if ($FailureAfterSkillRemovalCount -gt 0 -and @($removedPaths | Where-Object { $_ -like '.agents/skills/*' }).Count -eq $FailureAfterSkillRemovalCount) { throw 'Injected Skill migration failure.' }
                continue
            }
            $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
            $skippedPaths.Add($managedTargetPath)
            Write-Output "USER Skill migration unavailable; repair USER installation and ownership before retiring: $managedTargetPath"
            continue
        }
        $targetFullPath = Join-Path $targetRootPath $managedTargetPath.Replace('/', '\')
        if (Test-LicenseDeliveryTargetPath $managedTargetPath) {
            $owner = Get-LicenseDeliveryOwner $managedTargetPath
            $referenced = @($nextManifestEntries | Where-Object {
                -not (Test-LicenseDeliveryTargetPath $_.targetPath) -and
                (Get-LicenseDeliveryOwner $_.targetPath) -ceq $owner -and
                $_.sourceId -ceq $managedEntry.sourceId -and $_.sourceCommit -ceq $managedEntry.sourceCommit
            }).Count -gt 0
            if ($referenced) {
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf) -or
                    (Get-ManagedContentHash -Path $targetFullPath -TargetPath $managedTargetPath) -cne $managedEntry.sha256) {
                    $skippedPaths.Add($managedTargetPath)
                }
                continue
            }
        }
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
            schemaVersion = if ($manifestExists -and $manifestSchemaVersion -eq 3) { 3 } else { 2 }
            catalogId = [string] $provenance.catalogId
            lockSha256 = [string] $provenance.lockSha256
            files = @($nextManifestEntries | Sort-Object targetPath)
        }
        if ($retainLegacyManifest) {
            $manifestObject = [ordered]@{schemaVersion=1; sourceRepository=$manifest.sourceRepository; sourceRef=$manifest.sourceRef; files=@($nextManifestEntries | Sort-Object targetPath)}
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
        if ($migrationGitState) { Save-SkillMigrationJournal $mutationSnapshot $excludeSnapshot $migrationJournalPath $migrationGitState 'applied' }
    }
    catch {
        $mutationError = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        try { Restore-TargetMutationSnapshot -Snapshot $mutationSnapshot }
        catch { $rollbackErrors.Add($_.Exception.Message) }
        try { Restore-GitInfoExcludeSnapshot -Snapshot $excludeSnapshot }
        catch { $rollbackErrors.Add($_.Exception.Message) }
        if ($migrationGitState -and $rollbackErrors.Count -eq 0) { Save-SkillMigrationJournal $mutationSnapshot $excludeSnapshot $migrationJournalPath $migrationGitState 'rolled-back' }
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
            if ([string]$manifestEntry.targetPath -like '.agents/skills/*') { continue }
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
        if ($migrationGitState -and $rollbackErrors.Count -eq 0) {
            Save-SkillMigrationJournal $mutationSnapshot $excludeSnapshot $migrationJournalPath $migrationGitState 'rolled-back'
        }
        if ($rollbackErrors.Count -gt 0) {
            $preserveWorkingPath = $true
            throw "PersonalAgent stash finalization failed: $($finalizationError.Exception.Message) Rollback also failed: $($rollbackErrors -join ' | ') Recovery files were preserved at: $mutationBackupRoot"
        }
        throw $finalizationError
    }

    if ($changedPaths.Count -eq 0) { Write-Output 'AI instructions are up to date; no Git commit was created.' }
    else { Write-Output "AI instructions synchronized as local ignored runtime artifacts without Git commit: $($changedPaths -join ', ')" }
    if ($migrationGitState) { Write-Output "Skill migration transaction retained. Backup and recovery journal: $migrationJournalPath" }
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
    $script:SkillMigrationJournalContext = $null
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
