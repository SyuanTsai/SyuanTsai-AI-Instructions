[CmdletBinding()]
param(
    [string] $SourceArchivePath,
    [string] $TargetRoot,
    [string] $ConfigurationPath,
    [string] $ProvenancePath,
    [string] $ProjectCandidateArchivePath,
    [string] $RuntimeRoot = $PSScriptRoot,
    [string] $GitExecutable = 'git',
    [string] $UserHome = [Environment]::GetFolderPath('UserProfile'),
    [switch] $WhatIf,
    [int] $FailureAfterSkillRemovalCount = 0,
    [string] $RecoverSkillMigration
)

if ($PSVersionTable.PSEdition -cne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7 -or [Environment]::Version.Major -lt 8) {
    throw [System.InvalidOperationException]::new('AI instructions bootstrap requires pwsh 7 on .NET 8 or later; run this bootstrap with pwsh 7. [ai-instructions-refusal-code=runtime-baseline-unavailable]')
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Read-only Git inspection must not opportunistically refresh the live index;
# the journaled index operation is the only permitted index writer.
$env:GIT_OPTIONAL_LOCKS = '0'

if ([string]::IsNullOrWhiteSpace($GitExecutable)) {
    throw 'GitExecutable must be a non-empty command name or path.'
}

$manifestRelativePath = '.codex/ai-instructions.manifest.json'
$excludeBeginMarker = '# BEGIN Codex AI Instructions managed paths'
$excludeEndMarker = '# END Codex AI Instructions managed paths'
$script:repoManifestV4DowngradeSummary =
    'A live worktree already contains REPO managed manifest v4 [ai-instructions-refusal-code=downgrade-refused].'
$script:repoManifestV4ProjectionRequirement =
    'REPO managed manifest schema version 4 requires a projection-aware bootstrap.'
$script:repoManifestV4DowngradeMessage =
    $script:repoManifestV4DowngradeSummary + ' ' + $script:repoManifestV4ProjectionRequirement

$bootstrapPlatformRuntimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)
$bootstrapPlatformRuntimePath = Join-Path $bootstrapPlatformRuntimeRoot 'platform-runtime.psd1'
try {
    Import-Module $bootstrapPlatformRuntimePath -Force -ErrorAction Stop
    Assert-PlatformRuntimeInventory -Root $bootstrapPlatformRuntimeRoot -ManifestPath $bootstrapPlatformRuntimePath | Out-Null
}
catch {
    throw [System.InvalidOperationException]::new(
        "AI instructions bootstrap platform runtime validation failed: $($_.Exception.Message) [ai-instructions-refusal-code=closure-invalid]",
        $_.Exception
    )
}

Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'skills-catalog-contract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ai-instructions-runtime-contract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'agent-artifact-remediation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'license-delivery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'repo-shared-skills-migration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'skills-selection.psm1') -Force

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

        public static SafeFileHandle OpenExclusiveUserUpdateLock(string path)
        {
            SafeFileHandle handle = CreateFile(
                path, GenericRead | GenericWrite, 0,
                IntPtr.Zero, 4 /* OPEN_ALWAYS */, FileAttributeNormal | FileFlagOpenReparsePoint, IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, "Unable to acquire the exclusive USER updater lock.");
                ByHandleFileInformation information = GetInformation(handle, "Unable to inspect the USER updater lock.");
                if ((information.FileAttributes & (FileAttributeReparsePoint | FileAttributeDirectory)) != 0 ||
                    information.NumberOfLinks != 1)
                {
                    throw new IOException("The USER updater lock is not a single-link regular file.");
                }
                return handle;
            }
            catch
            {
                if (handle != null) handle.Dispose();
                throw;
            }
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
        [string[]] $Arguments,

        [string[]] $StandardInputLines
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        if($PSBoundParameters.ContainsKey('StandardInputLines')){
            $startInfo=[Diagnostics.ProcessStartInfo]::new();$startInfo.FileName=$GitExecutable;$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true;$startInfo.RedirectStandardInput=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
            foreach($argument in @('-C',$Repository)+$Arguments){[void]$startInfo.ArgumentList.Add([string]$argument)}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$startInfo
            try{
                if(-not$process.Start()){throw 'Git process did not start.'}
                $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
                $process.StandardInput.Write((@($StandardInputLines)-join"`n")+"`n");$process.StandardInput.Close();$process.WaitForExit()
                $exitCode=$process.ExitCode;$output=@($stdoutTask.GetAwaiter().GetResult(),$stderrTask.GetAwaiter().GetResult()|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
            }finally{$process.Dispose()}
        }else{$output=& $GitExecutable -C $Repository @Arguments 2>&1;$exitCode=$LASTEXITCODE}
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
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

function Get-GitQueryResult {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][int[]] $NegativeExitCodes
    )

    $exitCode = Get-GitExitCode -Repository $Repository -Arguments $Arguments
    if ($exitCode -eq 0) {
        return [pscustomobject][ordered]@{ Succeeded = $true; Output = @(Invoke-Git -Repository $Repository -Arguments $Arguments) }
    }
    if ($exitCode -in $NegativeExitCodes) {
        return [pscustomobject][ordered]@{ Succeeded = $false; Output = @() }
    }

    Invoke-Git -Repository $Repository -Arguments $Arguments | Out-Null
    throw "git $($Arguments -join ' ') failed with exit code $exitCode."
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

    if ($TargetPath -cmatch '^\.(agents|claude|github)/skills/' -or (Test-InstructionLicenseDeliveryPath $TargetPath)) {
        return Get-RawContentHash -Path $Path
    }

    return Get-NormalizedContentHash -Path $Path
}

function Get-ManagedContentHashFromBytes {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes,[Parameter(Mandatory=$true)][string]$TargetPath)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        if($TargetPath-cmatch'^\.(agents|claude|github)/skills/'-or(Test-InstructionLicenseDeliveryPath $TargetPath)){
            return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()
        }
        $offset=if($Bytes.Length-ge3-and$Bytes[0]-eq0xEF-and$Bytes[1]-eq0xBB-and$Bytes[2]-eq0xBF){3}else{0}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes,$offset,$Bytes.Length-$offset).Replace("`r`n","`n").Replace("`r","`n")
        $normalized=[Text.UTF8Encoding]::new($false).GetBytes($text)
        return ([BitConverter]::ToString($sha.ComputeHash($normalized))).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
}

function Test-IsAllowedManagedPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-InstructionLicenseDeliveryPath $Path) { return $true }

    if ($Path -eq 'AGENTS.md' -or
        $Path -eq 'CLAUDE.md' -or
        $Path -eq '.github/copilot-instructions.md' -or
        $Path -match '^\.codex/AI-Rules/[^/\\]+\.en\.md$' -or
        $Path -match '^\.claude/AI-Rules/[^/\\]+\.en\.md$' -or
        $Path -match '^\.github/AI-Rules/[^/\\]+\.en\.md$') {
        return $true
    }

    if ($Path -cnotmatch '^\.(agents|claude|github)/skills/') {
        return $false
    }

    $skillPathParts = @($Path -split '/')
    if ($skillPathParts.Count -lt 4 -or
        $skillPathParts[2] -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
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

function Test-IsSafeProjectCandidatePath {
    param([object] $Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $path = [string]$Value
    if ($path.StartsWith('/') -or $path.EndsWith('/') -or $path.Contains('\') -or $path.Contains('//') -or
        $path.Contains(':') -or $path -match '[\x00-\x1f\x7f-\x9f]') { return $false }
    foreach ($segment in $path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.','..')) { return $false }
    }
    return $true
}

function Get-ProjectCandidateDesiredState {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][object] $SyncConfiguration,
        [Parameter(Mandatory = $true)][string] $ExpectedCatalogId,
        [Parameter(Mandatory = $true)][string] $ExpectedLockSha256,
        [Parameter(Mandatory = $true)][string] $ExpectedProjectionContractSha256
    )
    $inventoryPath = Join-Path $CandidateRoot 'project-candidate.json'
    if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) { throw 'Project candidate is missing project-candidate.json.' }
    try { $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $inventoryPath | ConvertFrom-Json }
    catch { throw "Project candidate inventory is not valid JSON: $($_.Exception.Message)" }
    $expectedTop = @('schemaVersion','catalogId','lockSha256','projectionContractSha256','projections','skills')
    if (@($inventory.PSObject.Properties.Name | Where-Object { $_ -notin $expectedTop }).Count -gt 0 -or
        @($expectedTop | Where-Object { $null -eq $inventory.PSObject.Properties[$_] }).Count -gt 0 -or
        ($inventory.schemaVersion -isnot [int] -and $inventory.schemaVersion -isnot [long]) -or [int64]$inventory.schemaVersion -ne 1) {
        throw 'Project candidate inventory schema or properties are invalid.'
    }
    if ([string]$inventory.catalogId -cne $ExpectedCatalogId -or [string]$inventory.lockSha256 -cne $ExpectedLockSha256 -or
        [string]$inventory.projectionContractSha256 -cne $ExpectedProjectionContractSha256) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project candidate identity is inconsistent with the verified Catalog/Lock/projection contract.')
    }
    [string[]]$expectedProjections = @($SyncConfiguration.projections.project)
    [Array]::Sort($expectedProjections,[StringComparer]::Ordinal)
    [string[]]$actualProjections = @($inventory.projections)
    [Array]::Sort($actualProjections,[StringComparer]::Ordinal)
    if (($expectedProjections -join "`n") -cne ($actualProjections -join "`n") -or $expectedProjections.Count -eq 0) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project candidate projections do not match the verified sync configuration.')
    }
    $selectedSkillIds = @(Resolve-SkillsSelection -Catalog $Catalog -Selection $SyncConfiguration.catalog)
    [string[]]$expectedSkillIds = @($selectedSkillIds)
    [Array]::Sort($expectedSkillIds,[StringComparer]::Ordinal)
    [string[]]$actualSkillIds = @($inventory.skills | ForEach-Object { [string]$_.id })
    [Array]::Sort($actualSkillIds,[StringComparer]::Ordinal)
    if (($expectedSkillIds -join "`n") -cne ($actualSkillIds -join "`n") -or @($actualSkillIds | Select-Object -Unique).Count -ne $actualSkillIds.Count) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project candidate Skill selection does not match the verified Catalog selection.')
    }
    $catalogSkills = @{}; foreach ($skill in @($Catalog.skills)) { $catalogSkills[[string]$skill.id] = $skill }
    $lockedSkills = @{}; foreach ($skill in @($Lock.skills)) { $lockedSkills[[string]$skill.id] = $skill }
    $lockedSources = @{}; foreach ($source in @($Lock.sources)) { $lockedSources[[string]$source.id] = $source }
    $desired = New-Object System.Collections.Generic.List[object]
    $expectedPayloadPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($skill in @($inventory.skills)) {
        $skillId = [string]$skill.id
        $skillProperties = @('id','sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion','files')
        if (@($skill.PSObject.Properties.Name | Where-Object { $_ -notin $skillProperties }).Count -gt 0 -or
            @($skillProperties | Where-Object { $null -eq $skill.PSObject.Properties[$_] }).Count -gt 0 -or
            -not $catalogSkills.ContainsKey($skillId) -or -not $lockedSkills.ContainsKey($skillId) -or
            -not $lockedSources.ContainsKey([string]$skill.sourceId)) {
            throw "Project candidate Skill '$skillId' has invalid properties or is absent from the verified Catalog/Lock."
        }
        $catalogSkill = $catalogSkills[$skillId]; $lockedSkill = $lockedSkills[$skillId]; $lockedSource = $lockedSources[[string]$skill.sourceId]
        if ([string]$catalogSkill.source.sourceId -cne [string]$skill.sourceId -or [string]$lockedSkill.sourceId -cne [string]$skill.sourceId -or
            [string]$skill.sourceRepository -cne [string]$lockedSource.repository -or [string]$skill.sourceRef -cne [string]$lockedSource.requestedRef -or
            [string]$skill.sourceCommit -cne [string]$lockedSource.resolvedCommit -or [string]$skill.sourceVersion -cne [string]$lockedSource.resolvedVersion) {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project candidate Skill '$skillId' provenance does not match the verified Catalog/Lock.")
        }
        $contentLines = New-Object System.Collections.Generic.List[string]
        $seenRelative = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($file in @($skill.files)) {
            $fileProperties = @('sourcePath','relativePath','payloadPath','sha256')
            if (@($file.PSObject.Properties.Name | Where-Object { $_ -notin $fileProperties }).Count -gt 0 -or
                @($fileProperties | Where-Object { $null -eq $file.PSObject.Properties[$_] }).Count -gt 0) { throw "Project candidate Skill '$skillId' file properties are invalid." }
            $relative = [string]$file.relativePath; $payloadPath = [string]$file.payloadPath; $sourcePath = [string]$file.sourcePath
            if (-not (Test-IsSafeProjectCandidatePath $relative) -or -not (Test-IsSafeProjectCandidatePath $payloadPath) -or
                $payloadPath -cne "payload/$skillId/$relative" -or [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                -not $seenRelative.Add($relative) -or -not $expectedPayloadPaths.Add($payloadPath)) {
                throw "Project candidate Skill '$skillId' contains an unsafe or duplicate file inventory entry."
            }
            $payloadFullPath = Join-Path $CandidateRoot $payloadPath.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $payloadFullPath -PathType Leaf) -or (Get-RawContentHash $payloadFullPath) -cne [string]$file.sha256) {
                throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project candidate payload is missing or has raw-byte drift: $payloadPath")
            }
            $isLicense = $relative.StartsWith('.ai-instructions-licenses/',[StringComparison]::Ordinal)
            if (-not $isLicense) {
                $expectedSourcePrefix = ([string]$lockedSkill.sourcePath) + '/'
                if (-not (Test-IsSafeProjectCandidatePath $sourcePath) -or -not $sourcePath.StartsWith($expectedSourcePrefix,[StringComparison]::Ordinal) -or
                    $sourcePath.Substring($expectedSourcePrefix.Length) -cne $relative) {
                    throw "Project candidate Skill '$skillId' sourcePath does not match the Lock: $sourcePath"
                }
                $contentLines.Add("$sourcePath`t$([string]$file.sha256)`n")
            }
            elseif ($relative -cnotmatch '^\.ai-instructions-licenses/(?:delivery\.json|source/.+)$') {
                throw "Project candidate Skill '$skillId' has an invalid license target: $relative"
            }
            foreach ($projectionId in $expectedProjections) {
                $projectionRoot = Get-SkillsCatalogProjectionTargetPath -Catalog $Catalog -SkillId $skillId -ProjectionId $projectionId
                $desired.Add([pscustomobject][ordered]@{
                    FamilyName='Project Skills';IsProjectSkill=$true;SkillId=$skillId;ProjectionId=$projectionId
                    SourceId=[string]$skill.sourceId;SourceRepository=[string]$skill.sourceRepository;SourceRef=[string]$skill.sourceRef
                    SourceCommit=[string]$skill.sourceCommit;SourceVersion=[string]$skill.sourceVersion;SourcePath=$sourcePath
                    TargetPath="$projectionRoot/$relative";SourceFullPath=$payloadFullPath;Sha256=[string]$file.sha256
                })
            }
        }
        [string[]]$orderedLines = @($contentLines.ToArray())
        [Array]::Sort($orderedLines,[StringComparer]::Ordinal)
        $contentBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]::Concat($orderedLines))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $contentHash = ([BitConverter]::ToString($sha.ComputeHash($contentBytes))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($contentHash -cne [string]$lockedSkill.contentSha256) {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project candidate Skill '$skillId' content inventory does not match the Lock.")
        }
    }
    $actualPayloadPaths = @(
        Get-ChildItem -LiteralPath (Join-Path $CandidateRoot 'payload') -File -Recurse -Force | ForEach-Object {
            Get-RepositoryRelativePath -RepositoryRoot $CandidateRoot -FullPath $_.FullName
        }
    )
    if (@($actualPayloadPaths).Count -ne $expectedPayloadPaths.Count -or @($actualPayloadPaths | Where-Object { -not $expectedPayloadPaths.Contains([string]$_) }).Count -gt 0) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project candidate payload contains missing or extra files.')
    }
    return [pscustomobject][ordered]@{Inventory=$inventory;Projections=$expectedProjections;SkillIds=$expectedSkillIds;Files=[object[]]$desired.ToArray()}
}

function Get-ProjectSkillOwnershipConflicts {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][object[]] $DesiredFiles,
        [Parameter(Mandatory = $true)][hashtable] $ManifestEntriesByTarget,
        [Parameter(Mandatory = $true)] $TrackedPaths,
        [Parameter(Mandatory = $true)] $StagedPaths
    )
    $conflicts = New-Object System.Collections.Generic.List[object]
    $groups = @($DesiredFiles | Group-Object ProjectionId,SkillId)
    foreach ($group in $groups) {
        $files = @($group.Group)
        $projectionId = [string]$files[0].ProjectionId; $skillId = [string]$files[0].SkillId
        $targetPrefix = ([string]$files[0].TargetPath).Split('/')[0..2] -join '/'
        $targetRoot = Join-Path $Repository $targetPrefix.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $managed = @{}
        foreach ($entry in @($ManifestEntriesByTarget.Values | Where-Object {
            $null -ne $_.PSObject.Properties['artifactType'] -and [string]$_.artifactType -ceq 'skill' -and
            [string]$_.artifactId -ceq $skillId -and [string]$_.projectionId -ceq $projectionId
        })) { $managed[[string]$entry.targetPath] = $entry }
        $trackedUnderRoot = @($TrackedPaths | Where-Object {
            Test-GitPathEqualsOrIsUnderPrefix -Path ([string]$_) -Prefix $targetPrefix -Comparer $TrackedPaths.Comparer
        })
        foreach ($trackedPath in $trackedUnderRoot) {
            $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=[string]$trackedPath;relativePath=([string]$trackedPath).Substring($targetPrefix.Length).TrimStart('/');status='tracked'})
        }
        foreach ($stagedPath in @($StagedPaths | Where-Object {
            Test-GitPathEqualsOrIsUnderPrefix -Path ([string]$_) -Prefix $targetPrefix -Comparer $StagedPaths.Comparer
        })) {
            $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=[string]$stagedPath;relativePath=([string]$stagedPath).Substring($targetPrefix.Length).TrimStart('/');status='staged'})
        }
        if (Test-Path -LiteralPath $targetRoot) {
            $rootItem = Get-Item -Force -LiteralPath $targetRoot
            if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=$targetPrefix;relativePath='.';status='reparse'})
                continue
            }
            $pending = New-Object System.Collections.Generic.Stack[string]
            $pending.Push($targetRoot)
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                foreach ($item in @(Get-ChildItem -Force -LiteralPath $directory)) {
                    $relative = $item.FullName.Substring($targetRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath="$targetPrefix/$relative";relativePath=$relative;status='reparse'})
                    }
                    elseif ($item.PSIsContainer) { $pending.Push($item.FullName) }
                    else {
                        $path = "$targetPrefix/$relative"
                        if (-not $managed.ContainsKey($path)) {
                            $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=$path;relativePath=$relative;status='unmanaged'})
                        }
                        elseif ((Get-RawContentHash $item.FullName) -cne [string]$managed[$path].sha256) {
                            $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=$path;relativePath=$relative;status='drift'})
                        }
                    }
                }
            }
            foreach ($path in $managed.Keys) {
                $fullPath = Join-Path $Repository ([string]$path).Replace('/',[IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                    $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=[string]$path;relativePath=([string]$path).Substring($targetPrefix.Length).TrimStart('/');status='missing'})
                }
            }
        }
        elseif ($managed.Count -gt 0) {
            foreach ($path in $managed.Keys) {
                $conflicts.Add([pscustomobject][ordered]@{projection=$projectionId;skillId=$skillId;targetPath=[string]$path;relativePath=([string]$path).Substring($targetPrefix.Length).TrimStart('/');status='missing'})
            }
        }
    }
    return $conflicts.ToArray()
}

function Get-ProjectSkillOwnershipConflictsAcrossWorktrees {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][object[]]$DesiredFiles
    )
    $result=New-Object System.Collections.Generic.List[object]
    foreach($worktreeRoot in @(Get-ManagedWorktreeRoots -Repository $Repository -Strict)){
        $entries=@{};$manifestPath=Join-Path $worktreeRoot $manifestRelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
            Assert-ManagedPathDoesNotCrossReparsePoint -Root $worktreeRoot -Path $manifestPath -Context 'Project Skill ownership manifest'
            try{$worktreeManifest=Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath|ConvertFrom-Json}catch{throw "Project Skill ownership preflight cannot parse linked manifest '$manifestPath': $($_.Exception.Message)"}
            if(($worktreeManifest.schemaVersion-is[int]-or$worktreeManifest.schemaVersion-is[long])-and[int64]$worktreeManifest.schemaVersion-eq4){
                Assert-ManagedManifestV4 -Manifest $worktreeManifest
                foreach($entry in @($worktreeManifest.files)){$entries[[string]$entry.targetPath]=$entry}
            }
        }
        $comparer=Get-GitPathComparer -Repository $worktreeRoot
        $tracked=Get-GitListedPathSet -Repository $worktreeRoot -Comparer $comparer -Kind Tracked
        $staged=Get-GitListedPathSet -Repository $worktreeRoot -Comparer $comparer -Kind Staged
        foreach($conflict in @(Get-ProjectSkillOwnershipConflicts -Repository $worktreeRoot -DesiredFiles $DesiredFiles -ManifestEntriesByTarget $entries -TrackedPaths $tracked -StagedPaths $staged)){
            $result.Add([pscustomobject][ordered]@{worktree=$worktreeRoot;projection=$conflict.projection;skillId=$conflict.skillId;targetPath=$conflict.targetPath;relativePath=$conflict.relativePath;status=$conflict.status})
        }
    }
    return $result.ToArray()
}

function Format-ProjectSkillOwnershipConflictDetails {
    param([Parameter(Mandatory=$true)][object[]]$Conflicts)

    return (@($Conflicts|Sort-Object worktree,projection,skillId,targetPath,status|ForEach-Object{
        "skillId=$($_.skillId), projection=$($_.projection), path=$($_.targetPath), status=$($_.status), worktree=$($_.worktree)"
    })-join'; ')
}

function Write-ProjectSkillOwnershipConflictDiagnostics {
    param([Parameter(Mandatory=$true)][object[]]$Conflicts)

    foreach($conflict in @($Conflicts|Sort-Object worktree,projection,skillId,targetPath,status)){
        [Console]::Error.WriteLine("Project Skill conflict: skillId=$($conflict.skillId), projection=$($conflict.projection), path=$($conflict.targetPath), status=$($conflict.status), worktree=$($conflict.worktree)")
    }
    [Console]::Error.WriteLine('Project Skill conflict resolution: remove or rename the project-owned Skill, or remove that Skill from projections.project.')
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

    $origin = Get-GitQueryResult -Repository $Repository -Arguments @('remote','get-url','origin') -NegativeExitCodes @(2)
    if (-not $origin.Succeeded) { return $false }
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
    $query = Get-GitQueryResult -Repository $Repository -Arguments @('config','--bool','--get','core.ignorecase') -NegativeExitCodes @(1)
    if ($query.Succeeded) {
        $configured = ([string]($query.Output | Select-Object -First 1)).Trim()
        if ($configured -ceq 'true') { $ignoreCase = $true }
    }
    if ($ignoreCase) { return [System.StringComparer]::OrdinalIgnoreCase }
    return [System.StringComparer]::Ordinal
}

function Test-GitPathEqualsOrIsUnderPrefix {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Prefix,
        [Parameter(Mandatory=$true)][System.StringComparer]$Comparer
    )

    $normalizedPath=$Path.Replace('\','/')
    $normalizedPrefix=$Prefix.Replace('\','/').TrimEnd('/')
    if($Comparer.Equals($normalizedPath,$normalizedPrefix)){return $true}
    if($normalizedPath.Length-le$normalizedPrefix.Length-or$normalizedPath[$normalizedPrefix.Length]-ne'/'){return $false}
    return $Comparer.Equals($normalizedPath.Substring(0,$normalizedPrefix.Length),$normalizedPrefix)
}

function Get-GitListedPathSet {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][System.StringComparer]$Comparer,
        [Parameter(Mandatory=$true)][ValidateSet('Tracked','Staged')][string]$Kind
    )

    $arguments=if($Kind-ceq'Tracked'){
        @('-c','core.quotePath=true','ls-files')
    }else{
        @('-c','core.quotePath=true','diff','--cached','--name-only','--diff-filter=ACDMRTUXB')
    }
    $paths=New-Object 'System.Collections.Generic.HashSet[string]' $Comparer
    foreach($path in @(Invoke-Git -Repository $Repository -Arguments $arguments)){
        if([string]::IsNullOrWhiteSpace([string]$path)){continue}
        [void]$paths.Add((ConvertFrom-GitQuotedPath -Path ([string]$path)).Replace('\','/'))
    }
    Write-Output -NoEnumerate $paths
}

function Open-UserSkillMigrationLock {
    param([Parameter(Mandatory=$true)][string]$UserHome)
    $homePath = Get-FullPathWithoutTrailingSeparator -Path $UserHome
    if (-not (Test-Path -LiteralPath (Join-Path $homePath '.agents') -PathType Container)) {
        throw 'USER updater lock unavailable because the USER .agents root is missing.'
    }
    $guard = $null
    $handle = $null
    try {
        $guard = [CodexAiInstructions.NativeFileMutation]::OpenForAtomicDirectoryGuard($homePath, '.agents')
        $handle = [CodexAiInstructions.NativeFileMutation]::OpenExclusiveUserUpdateLock(
            (Join-Path $homePath '.agents/update-agent-environment.lock'))
        $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::ReadWrite)
        $handle = $null
        $result = [pscustomobject]@{ Stream=$stream; Guard=$guard }
        $guard = $null
        return $result
    }
    finally {
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $guard) { $guard.Dispose() }
    }
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

function Get-RepositoryActiveGitDirectory {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $gitDirectory = ((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--absolute-git-dir')) | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) { throw "Git returned a non-absolute active worktree directory: $gitDirectory" }
    $gitDirectory = [System.IO.Path]::GetFullPath($gitDirectory).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) { throw "Git directory is missing or invalid: $gitDirectory" }
    $gitDirectoryItem = Get-Item -Force -LiteralPath $gitDirectory
    if (($gitDirectoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Git directory must not be a reparse point: $gitDirectory"
    }
    return $gitDirectory
}

function Get-RepositoryIndexTransactionPath {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $gitDirectory = Get-RepositoryActiveGitDirectory -Repository $Repository

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

    return $indexPath
}

function Open-RepositoryIndexTransactionLock {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $indexPath = Get-RepositoryIndexTransactionPath -Repository $Repository
    $lockPath = $indexPath + '.lock'
    try {
        $stream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw (New-RepositoryIndexLockRefusal -Reason 'The Git index is being changed by another process; bootstrap stopped before index preflight.' -LockPath $lockPath)
    }
    try {
        [byte[]]$indexBytes=[System.IO.File]::ReadAllBytes($indexPath)
        $stream.Write($indexBytes,0,$indexBytes.Length)
        $stream.Flush($true)
        $contentSha256=Get-ByteArraySha256 $indexBytes
    }
    catch {
        $stream.Dispose()
        throw (New-RepositoryIndexLockRefusal -Reason "The Git index.lock could not be prefilled durably with the current index bytes: $($_.Exception.Message)" -LockPath $lockPath)
    }
    return [pscustomobject][ordered]@{ Stream=$stream; Path=$lockPath; IndexPath=$indexPath; ContentSha256=$contentSha256 }
}

function Close-RepositoryIndexTransactionLock {
    param([AllowNull()][object]$Lock)
    if($null-eq$Lock-or$null-eq$Lock.Stream){return}
    $Lock.Stream.Dispose();$Lock.Stream=$null
    Remove-Item -LiteralPath $Lock.Path -Force
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
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $exception = [System.IO.IOException]::new("$Context crosses a reparse point: $inspectionPath")
                $exception.Data['CodexAiInstructionsPathSafetyReason'] = 'reparse-point'
                throw $exception
            }
        }
        $inspectionPath = Split-Path -Parent $inspectionPath
    }
}

function Get-ManagedWorktreeRoots {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [switch] $Strict
    )

    try {
        $output = @(Invoke-Git -Repository $Repository -Arguments @('worktree','list','--porcelain','-z'))
        $records = @(ConvertFrom-GitWorktreePorcelainZ -Output $output -Strict:$Strict)
    }
    catch {
        if ($Strict) {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' `
                -Message "Cannot determine linked worktree manifests before mutation. $($_.Exception.Message)" `
                -InnerException $_.Exception)
        }
        return
    }
    foreach ($record in $records) {
        if ([bool]$record.Prunable) { continue }
        [string]$record.Path
    }
}

function Get-ClaudeProjectOwnedWorktreeRoots {
    param([Parameter(Mandatory = $true)][string] $Repository,[switch] $Strict)
    $owned = New-Object System.Collections.Generic.List[string]
    $worktreeRoots = @(Get-ManagedWorktreeRoots -Repository $Repository -Strict:$Strict)
    foreach ($worktreeRoot in $worktreeRoots) {
        $basePath = Join-Path $worktreeRoot 'CLAUDE.md'
        $trackedQuery = Get-GitQueryResult -Repository $worktreeRoot -Arguments @('ls-files','--error-unmatch','--','CLAUDE.md') -NegativeExitCodes @(1)
        $tracked = [bool]$trackedQuery.Succeeded
        $staged = Test-GitPathHasStagedChanges -Repository $worktreeRoot -Path 'CLAUDE.md'
        $baseExists = Test-Path -LiteralPath $basePath -PathType Leaf
        $managedEntry = $null
        $manifestPath = Join-Path $worktreeRoot $manifestRelativePath.Replace('/','\')
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try {
                $candidate = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
                if ($candidate.schemaVersion -eq 4) { Assert-ManagedManifestV4 -Manifest $candidate }
                elseif ($candidate.schemaVersion -in @(2,3)) { Assert-ManagedManifest -Manifest $candidate }
                elseif ($candidate.schemaVersion -eq 1) { Assert-LegacyManagedManifestV1 -Manifest $candidate }
                else { throw "unsupported schemaVersion '$($candidate.schemaVersion)'." }
                $matches = @($candidate.files | Where-Object { [string]$_.targetPath -ceq 'CLAUDE.md' })
                if ($matches.Count -gt 1) { throw 'duplicate CLAUDE.md ownership entries.' }
                if ($matches.Count -eq 1) { $managedEntry = $matches[0] }
            }
            catch {
                if ($Strict) { throw "Invalid linked worktree manifest '$manifestPath': $($_.Exception.Message)" }
                $owned.Add([string]$worktreeRoot)
                continue
            }
        }
        $managedSha256 = if ($null -ne $managedEntry) { [string]$managedEntry.sha256 } else { $null }
        $currentSha256 = if ($baseExists) { Get-ManagedContentHash -Path $basePath -TargetPath 'CLAUDE.md' } else { $null }
        if (Test-AiInstructionsClaudeFamilyProjectOwned -BaseExists $baseExists -BaseTracked $tracked -BaseStaged $staged `
            -ManagedSha256 $managedSha256 -CurrentSha256 $currentSha256) {
            $owned.Add([string]$worktreeRoot)
        }
    }
    return @($owned)
}

function Assert-NoRepoManagedManifestV4 {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [switch] $AllowV4,
        [switch] $Strict
    )

    $worktreeRoots = @(Get-ManagedWorktreeRoots -Repository $Repository -Strict:$Strict)
    foreach ($worktreeRoot in $worktreeRoots) {
        $isSchemaV4 = $false
        $worktreeManifestPath = [string]$worktreeRoot
        try {
            $worktreeManifestPath = Join-Path $worktreeRoot $manifestRelativePath.Replace('/','\')
            if ($Strict -and -not (Test-Path -LiteralPath $worktreeRoot -PathType Container)) { continue }
            if (-not (Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf)) { continue }
            Assert-ManagedPathDoesNotCrossReparsePoint -Root $worktreeRoot -Path $worktreeManifestPath -Context 'REPO managed manifest v4 detection'
        }
        catch {
            if ([string]$_.Exception.Data['CodexAiInstructionsPathSafetyReason'] -ceq 'reparse-point') {
                if ($Strict) { throw }
                continue
            }
            if ($Strict) {
                $inspectionException = $_.Exception
                try { $manifestStillExists = Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf }
                catch {
                    throw "Cannot inspect linked worktree manifest before mutation: $worktreeManifestPath. $($_.Exception.Message)"
                }
                if (-not $manifestStillExists) { continue }
                throw "Cannot inspect linked worktree manifest before mutation: $worktreeManifestPath. $($inspectionException.Message)"
            }
            continue
        }
        try {
            $worktreeManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $worktreeManifestPath | ConvertFrom-Json
            $schemaVersion = $worktreeManifest.schemaVersion
            $isSchemaV4 = ($schemaVersion -is [int] -or $schemaVersion -is [long]) -and [int64]$schemaVersion -eq 4
        }
        catch {
            if ($Strict) {
                $inspectionException = $_.Exception
                try { $manifestStillExists = Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf }
                catch {
                    throw "Cannot inspect linked worktree manifest before mutation: $worktreeManifestPath. $($_.Exception.Message)"
                }
                if (-not $manifestStillExists) { continue }
                throw "Cannot inspect linked worktree manifest before mutation: $worktreeManifestPath. $($inspectionException.Message)"
            }
            continue
        }
        if ($isSchemaV4) {
            if ($AllowV4) { Assert-ManagedManifestV4 -Manifest $worktreeManifest }
            else {
                [Console]::Error.WriteLine($script:repoManifestV4DowngradeSummary)
                [Console]::Error.WriteLine($script:repoManifestV4ProjectionRequirement)
                throw [SyuanTsai.AiInstructions.AiInstructionsRefusalException]::new(
                    'downgrade-refused',
                    $script:repoManifestV4DowngradeMessage
                )
            }
        }
    }
}

function Get-WorktreeGitPathSetCache {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$WorktreeRoots)

    $cache=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($worktreeRoot in $WorktreeRoots){
        if($cache.ContainsKey($worktreeRoot)){throw "Duplicate managed worktree root: $worktreeRoot"}
        $comparer=Get-GitPathComparer -Repository $worktreeRoot
        $cache.Add($worktreeRoot,[pscustomobject][ordered]@{
            Comparer=$comparer
            Tracked=Get-GitListedPathSet -Repository $worktreeRoot -Comparer $comparer -Kind Tracked
            Staged=Get-GitListedPathSet -Repository $worktreeRoot -Comparer $comparer -Kind Staged
        })
    }
    return ,$cache
}

function Get-WorktreeGitDirectoryKey {
    # Stable identity of a worktree's absolute Git directory: the native directory file ID on Windows,
    # otherwise the full path reported by Git.
    param([Parameter(Mandatory = $true)][string] $Repository)
    $gitDirectory = Get-RepositoryActiveGitDirectory -Repository $Repository
    if ($IsWindows) { return 'windows-file-id:' + [CodexAiInstructions.NativeFileMutation]::GetDirectoryIdentity($gitDirectory) }
    return 'path:' + [IO.Path]::GetFullPath($gitDirectory)
}

function Test-IsCurrentWorktreeRoot {
    param(
        [Parameter(Mandatory = $true)][string] $WorktreeRoot,
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $CurrentWorktreeKey
    )
    if (Test-ProjectPublicationPathEqual -Left ([IO.Path]::GetFullPath($WorktreeRoot)) -Right ([IO.Path]::GetFullPath($Repository))) { return $true }
    if (-not (Test-Path -LiteralPath $WorktreeRoot -PathType Container)) { return $false }
    try { $worktreeKey = Get-WorktreeGitDirectoryKey -Repository $WorktreeRoot }
    catch { return $false }
    return [string]::Equals($worktreeKey, $CurrentWorktreeKey, [StringComparison]::Ordinal)
}

function Get-SharedManagedExcludePaths {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $CurrentManagedPaths
    )

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $blockedSkillPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $skillCandidatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($currentManagedPath in $CurrentManagedPaths) {
        $normalized=$currentManagedPath.Replace('\','/')
        [void]$paths.Add($normalized)
        if($normalized-cmatch'^\.(agents|claude|github)/skills/'){[void]$skillCandidatePaths.Add($normalized)}
    }
    $worktreeRoots=@(Get-ManagedWorktreeRoots -Repository $Repository -Strict)
    $worktreeGitPathSets=Get-WorktreeGitPathSetCache -WorktreeRoots $worktreeRoots
    # Identify the current worktree by its Git directory identity, not by path spelling, so a junction or subst TargetRoot
    # cannot make the current worktree's stale on-disk manifest re-enter the shared union.
    $currentWorktreeKey=Get-WorktreeGitDirectoryKey -Repository $Repository
    $currentWorktreeRoots=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($worktreeRoot in $worktreeRoots){
        if(Test-IsCurrentWorktreeRoot -WorktreeRoot $worktreeRoot -Repository $Repository -CurrentWorktreeKey $currentWorktreeKey){[void]$currentWorktreeRoots.Add([string]$worktreeRoot)}
    }
    foreach ($worktreeRoot in $worktreeRoots) {
        if($currentWorktreeRoots.Contains([string]$worktreeRoot)){continue}
        $gitPathState=$worktreeGitPathSets[$worktreeRoot]
        $worktreeTrackedPaths=$gitPathState.Tracked
        $worktreeStagedPaths=$gitPathState.Staged
        $worktreeManifestPath = Join-Path $worktreeRoot $manifestRelativePath.Replace('/','\')
        if (-not (Test-Path -LiteralPath $worktreeManifestPath -PathType Leaf)) { continue }
        Assert-ManagedPathDoesNotCrossReparsePoint -Root $worktreeRoot -Path $worktreeManifestPath -Context 'Linked worktree managed manifest'
        try {
            $worktreeManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $worktreeManifestPath | ConvertFrom-Json
            $worktreeManifestSchemaVersion = $worktreeManifest.schemaVersion
            if ($worktreeManifestSchemaVersion -isnot [int] -and $worktreeManifestSchemaVersion -isnot [long]) {
                throw 'schemaVersion must be an integer.'
            }
            if ($worktreeManifestSchemaVersion -eq 4) { Assert-ManagedManifestV4 -Manifest $worktreeManifest }
            elseif ($worktreeManifestSchemaVersion -in @(2,3)) { Assert-ManagedManifest -Manifest $worktreeManifest }
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
            if ($worktreeManifestSchemaVersion -eq 4 -and [string]$entry.artifactType -ceq 'skill') {
                [void]$skillCandidatePaths.Add($targetPath)
                $targetFullPath = Join-Path $worktreeRoot $targetPath.Replace('/',[IO.Path]::DirectorySeparatorChar)
                $tracked = $worktreeTrackedPaths.Contains($targetPath)
                $staged = $worktreeStagedPaths.Contains($targetPath)
                if ($tracked -or $staged -or -not (Test-Path -LiteralPath $targetFullPath -PathType Leaf) -or
                    (Get-RawContentHash $targetFullPath) -cne [string]$entry.sha256) {
                    [void]$blockedSkillPaths.Add($targetPath)
                    continue
                }
            }
            [void]$paths.Add($targetPath)
        }
    }
    foreach($skillCandidatePath in $skillCandidatePaths){
        $segments=$skillCandidatePath.Split('/');if($segments.Count-lt4){[void]$blockedSkillPaths.Add($skillCandidatePath);continue}
        $prefix=[string]::Join('/',[string[]]$segments[0..2])
        foreach($worktreeRoot in $worktreeRoots){
            if($currentWorktreeRoots.Contains([string]$worktreeRoot)){continue}
            $groupRoot=Join-Path $worktreeRoot $prefix.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if(-not(Test-Path -LiteralPath $groupRoot)){continue}
            $manifestPath=Join-Path $worktreeRoot $manifestRelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){[void]$blockedSkillPaths.Add($skillCandidatePath);continue}
            try{$m=Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath|ConvertFrom-Json;Assert-ManagedManifestV4 -Manifest $m}catch{[void]$blockedSkillPaths.Add($skillCandidatePath);continue}
            $groupEntries=@($m.files|Where-Object{[string]$_.artifactType-ceq'skill'-and([string]$_.targetPath-ceq$prefix-or([string]$_.targetPath).StartsWith($prefix+'/',[StringComparison]::Ordinal))})
            $entryMap=@{};foreach($entry in $groupEntries){$entryMap[[string]$entry.targetPath]=$entry}
            $gitPathState=$worktreeGitPathSets[$worktreeRoot]
            $gitPathComparer=$gitPathState.Comparer
            $worktreeTrackedPaths=$gitPathState.Tracked
            $worktreeStagedPaths=$gitPathState.Staged
            $trackedUnderPrefix=@($worktreeTrackedPaths|Where-Object{Test-GitPathEqualsOrIsUnderPrefix -Path ([string]$_) -Prefix $prefix -Comparer $gitPathComparer})
            $stagedUnderPrefix=@($worktreeStagedPaths|Where-Object{Test-GitPathEqualsOrIsUnderPrefix -Path ([string]$_) -Prefix $prefix -Comparer $gitPathComparer})
            if(-not$entryMap.ContainsKey($skillCandidatePath) -or $trackedUnderPrefix.Count-gt0 -or $stagedUnderPrefix.Count-gt0){
                foreach($path in $entryMap.Keys){[void]$blockedSkillPaths.Add([string]$path)};[void]$blockedSkillPaths.Add($skillCandidatePath);continue
            }
            $groupItem=Get-Item -Force -LiteralPath $groupRoot
            if(-not$groupItem.PSIsContainer-or($groupItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){foreach($path in $entryMap.Keys){[void]$blockedSkillPaths.Add([string]$path)};continue}
            $observed=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $pending=New-Object System.Collections.Generic.Stack[string];$pending.Push($groupRoot)
            while($pending.Count-gt0){
                $directory=$pending.Pop()
                foreach($item in @(Get-ChildItem -Force -LiteralPath $directory)){
                    $relative=$item.FullName.Substring($groupRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/');$path="$prefix/$relative"
                    if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){foreach($owned in $entryMap.Keys){[void]$blockedSkillPaths.Add([string]$owned)}}
                    elseif($item.PSIsContainer){$pending.Push($item.FullName)}
                    else{
                        [void]$observed.Add($path)
                        if(-not$entryMap.ContainsKey($path)-or(Get-RawContentHash $item.FullName)-cne[string]$entryMap[$path].sha256){foreach($owned in $entryMap.Keys){[void]$blockedSkillPaths.Add([string]$owned)}}
                    }
                }
            }
            foreach($path in $entryMap.Keys){if(-not$observed.Contains([string]$path)){foreach($owned in $entryMap.Keys){[void]$blockedSkillPaths.Add([string]$owned)}}}
        }
    }
    foreach ($blockedSkillPath in $blockedSkillPaths) { [void]$paths.Remove($blockedSkillPath) }
    return @($paths | Sort-Object)
}

function New-GitInfoExcludeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [switch] $UsePlatformRuntime
    )

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
        ManagedPaths = @()
        ProtectedPaths = @()
        PlatformState = $null
    }
    if ($UsePlatformRuntime) {
        Import-Module (Join-Path $PSScriptRoot 'ai-instructions-install-transaction.psm1') -Force
        $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path));$leaf=[IO.Path]::GetFileName($path)
        $parentLease=Open-PlatformDirectory -Root $parent -RootOnly
        try{$snapshot.PlatformState=Get-AiInstructionsInstallFileState -ParentLease $parentLease -Leaf $leaf -LiteralPath $path -PlatformOs $(if($IsLinux){'linux'}elseif($IsMacOS){'macos'}else{'windows'}) -IncludePermissions}finally{$parentLease.Dispose()}
        $snapshot.Existed=[bool]$snapshot.PlatformState.exists
        if ($snapshot.Existed) {
            $snapshot.Bytes = [IO.File]::ReadAllBytes($path)
            if((Get-ByteArraySha256 ([byte[]]$snapshot.Bytes))-cne[string]$snapshot.PlatformState.sha256){throw "Shared Git exclude changed concurrently during platform snapshot: $path"}
        }
        return $snapshot
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
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths = @(),
        [AllowEmptyCollection()][ValidateNotNull()][string[]] $PreservedProtectedPaths = @()
    )
    if ($null -eq $script:ProjectPublicationContext) { throw 'Unified repository transaction context is required for shared Git exclude planning.' }
    $path=Get-GitInfoExcludePath -Repository $Repository
    if([string]$Snapshot.Path-cne$path-or[string]$Snapshot.Repository-cne$Repository){throw 'Shared Git exclude snapshot does not match the requested mutation target.'}
    Assert-GitInfoExcludeMutationPath -Repository $Repository -Path $path
    $requestedManagedPaths=@($ManagedPaths)
    $safeManagedPaths=@($ManagedPaths|Where-Object{if(Test-IsProtectedClaudeFamilyPath -Path ([string]$_) -ProtectedPaths $ProtectedPaths){Write-Warning "Protected Claude family path skipped at bootstrap Git exclude: $_ (project-owned Claude family).";return $false};return $true})
    foreach($preservedProtectedPath in $PreservedProtectedPaths){
        if(-not(Test-IsProtectedClaudeFamilyPath -Path ([string]$preservedProtectedPath) -ProtectedPaths $ProtectedPaths)){throw "A preserved Git exclude path is outside the protected Claude family: $preservedProtectedPath"}
        if(@($requestedManagedPaths|Where-Object{[string]$_-ceq[string]$preservedProtectedPath}).Count-eq0){throw "A preserved protected Git exclude path is not managed by the current worktree: $preservedProtectedPath"}
    }
    $Snapshot.ManagedPaths=@($requestedManagedPaths+$PreservedProtectedPaths|Sort-Object -Unique);$Snapshot.ProtectedPaths=@($ProtectedPaths)
    $sharedManagedPaths=@(Get-SharedManagedExcludePaths -Repository $Repository -CurrentManagedPaths $safeManagedPaths)
    $sharedManagedPaths=@($sharedManagedPaths|Where-Object{if(Test-IsProtectedClaudeFamilyPath -Path ([string]$_) -ProtectedPaths $ProtectedPaths){Write-Warning "Protected Claude family path skipped at bootstrap shared Git exclude: $_ (project-owned Claude family).";return $false};return $true})
    $lines=@(@($sharedManagedPaths)+@($PreservedProtectedPaths)|Sort-Object -Unique|ForEach-Object{ConvertTo-GitExcludeLiteralPattern -Path $_})
    [byte[]]$beforeBytes=if([bool]$Snapshot.Existed){[byte[]]$Snapshot.Bytes}else{[byte[]]@()}
    $content=(ConvertFrom-GitInfoExcludeBytes -Bytes $beforeBytes).Replace("`r`n","`n").Replace("`r","`n")
    $pattern='(?ms)^'+[regex]::Escape($excludeBeginMarker)+'\n.*?^'+[regex]::Escape($excludeEndMarker)+'\n?'
    $beginCount=[regex]::Matches($content,'(?m)^'+[regex]::Escape($excludeBeginMarker)+'$').Count;$endCount=[regex]::Matches($content,'(?m)^'+[regex]::Escape($excludeEndMarker)+'$').Count
    if($beginCount-ne$endCount-or$beginCount-gt1-or($beginCount-eq1-and-not[regex]::IsMatch($content,$pattern))){throw "The Codex AI Instructions managed exclude block is malformed: $path"}
    $withoutBlock=[regex]::Replace($content,$pattern,'').TrimEnd("`n");$updated=$withoutBlock
    if($lines.Count-gt0){$block=$excludeBeginMarker+"`n"+($lines-join"`n")+"`n"+$excludeEndMarker+"`n";$updated=if([string]::IsNullOrWhiteSpace($withoutBlock)){$block}else{$withoutBlock+"`n`n"+$block}}
    elseif(-not[string]::IsNullOrWhiteSpace($updated)){$updated+="`n"}
    [byte[]]$updatedBytes=[Text.UTF8Encoding]::new($false).GetBytes($updated)
    if(-not(Test-GitInfoExcludeBytesEqual -Left $beforeBytes -Right $updatedBytes)){
        $expectedExcludeSha256=if([bool]$Snapshot.Existed){Get-ByteArraySha256 ([byte[]]$Snapshot.Bytes)}else{$null}
        Set-ProjectPublicationExternalFileBytes -LiteralPath $path -Bytes $updatedBytes -ExpectedExists ([bool]$Snapshot.Existed) -ExpectedSha256 $expectedExcludeSha256 -ExpectedState $Snapshot.PlatformState
        $Snapshot.AppliedBytes=$updatedBytes;$Snapshot.MutationApplied=$true
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

    if ($workingTreeExitCode -notin @(0, 1)) {
        try { Invoke-Git -Repository $Repository -Arguments @('diff', '--quiet', '--', $Path) | Out-Null }
        catch { throw "Unable to inspect local changes for managed path: $Path (first git exit code: $workingTreeExitCode). $($_.Exception.Message)" }
        throw "Unable to inspect local changes for managed path: $Path (first git exit code: $workingTreeExitCode)."
    }
    if ($indexExitCode -notin @(0, 1)) {
        try { Invoke-Git -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path) | Out-Null }
        catch { throw "Unable to inspect local changes for managed path: $Path (first git exit code: $indexExitCode). $($_.Exception.Message)" }
        throw "Unable to inspect local changes for managed path: $Path (first git exit code: $indexExitCode)."
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
    if ($exitCode -notin @(0, 1)) {
        try { Invoke-Git -Repository $Repository -Arguments @('diff', '--cached', '--quiet', '--', $Path) | Out-Null }
        catch { throw "Unable to inspect staged changes for managed path: $Path (first git exit code: $exitCode). $($_.Exception.Message)" }
        throw "Unable to inspect staged changes for managed path: $Path (first git exit code: $exitCode)."
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
        [string] $Sha256,

        [string] $ProjectSkillId,
        [string] $ProjectionId,
        [object] $ProjectSource
    )

    $artifactType = 'instruction'
    $artifactId = $null
    $source = $script:instructionProvenance
    if (-not [string]::IsNullOrWhiteSpace($ProjectionId)) {
        if ($repoManifestWriter -cne 'v4' -or $ProjectionId -notin @('project-agents','project-claude','project-github') -or
            $ProjectSkillId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$' -or $null -eq $ProjectSource) {
            throw "Invalid project Skill manifest identity for target: $TargetPath"
        }
        $artifactType = 'skill'; $artifactId = $ProjectSkillId; $source = $ProjectSource
    }
    elseif ($TargetPath.StartsWith('.agents/skills/', [System.StringComparison]::Ordinal)) {
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
    elseif ($TargetPath -eq 'CLAUDE.md') {
        $artifactId = 'claude-base'
    }
    elseif (Test-InstructionLicenseDeliveryPath $TargetPath) {
        $artifactId = if ($TargetPath.StartsWith('.codex/')) { 'codex-licensing' } elseif ($TargetPath.StartsWith('.claude/')) { 'claude-licensing' } else { 'copilot-licensing' }
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
    elseif ($TargetPath.StartsWith('.claude/AI-Rules/', [System.StringComparison]::Ordinal)) {
        $ruleName = [regex]::Replace(
            [System.IO.Path]::GetFileName($TargetPath).Replace('.en.md', '').ToLowerInvariant(),
            '[^a-z0-9-]',
            '-'
        ).Trim('-')
        $artifactId = "claude-rule-$ruleName"
    }
    else {
        throw "Cannot derive instruction artifact ID for managed target: $TargetPath"
    }

    if ($artifactId -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') {
        throw "Derived artifact ID is not lowercase kebab-case: $artifactId"
    }

    $result = [ordered]@{
        artifactType = $artifactType
        artifactId = $artifactId
        sourceId = [string] $source.sourceId
        sourceRepository = [string] $source.sourceRepository
        sourceRef = [string] $source.sourceRef
        sourceCommit = [string] $source.sourceCommit
        sourceVersion = [string] $source.sourceVersion
        sourcePath = $SourcePath
    }
    if ($repoManifestWriter -ceq 'v4' -and $artifactType -ceq 'instruction') {
        $result.host = Resolve-ManagedInstructionHostForTarget -TargetPath $TargetPath
        $result.rendererId = 'build-ai-instructions'
        $result.rendererSha256 = [string]$script:rendererSha256
    }
    elseif ($artifactType -ceq 'skill' -and -not [string]::IsNullOrWhiteSpace($ProjectionId)) { $result.projectionId = $ProjectionId }
    $result.targetPath = $TargetPath
    $result.sha256 = $Sha256
    return [pscustomobject]$result
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

function Resolve-ManagedInstructionHostForTarget {
    param([Parameter(Mandatory = $true)][string] $TargetPath)

    $hosts = @(
        if ($TargetPath -ceq 'AGENTS.md' -or
            $TargetPath -cmatch '^\.codex/AI-Rules/[^/\\]+\.en\.md$' -or
            $TargetPath -cmatch '^\.codex/ai-instructions-licenses/(?:[0-9a-f]{40}/)?(?:delivery\.json|source/.+)$') { 'codex' }
        if ($TargetPath -ceq '.github/copilot-instructions.md' -or
            $TargetPath -cmatch '^\.github/AI-Rules/[^/\\]+\.en\.md$' -or
            $TargetPath -cmatch '^\.github/ai-instructions-licenses/(?:[0-9a-f]{40}/)?(?:delivery\.json|source/.+)$') { 'copilot' }
        if ($TargetPath -ceq 'CLAUDE.md' -or
            $TargetPath -cmatch '^\.claude/AI-Rules/[^/\\]+\.en\.md$' -or
            $TargetPath -cmatch '^\.claude/ai-instructions-licenses/(?:[0-9a-f]{40}/)?(?:delivery\.json|source/.+)$') { 'claude' }
    )
    if ($hosts.Count -ne 1) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Cannot determine exactly one instruction host from retained legacy target path '$TargetPath'.")
    }
    return [string]$hosts[0]
}

function Copy-ExistingManifestEntry {
    param([Parameter(Mandatory = $true)][object] $Entry)

    if ($null -eq $Entry.PSObject.Properties['artifactType']) {
        return [pscustomobject][ordered]@{sourcePath=$Entry.sourcePath; targetPath=$Entry.targetPath; sha256=$Entry.sha256}
    }
    $copy = [ordered]@{
        artifactType = [string] $Entry.artifactType
        artifactId = [string] $Entry.artifactId
        sourceId = [string] $Entry.sourceId
        sourceRepository = [string] $Entry.sourceRepository
        sourceRef = [string] $Entry.sourceRef
        sourceCommit = [string] $Entry.sourceCommit
        sourceVersion = [string] $Entry.sourceVersion
        sourcePath = [string] $Entry.sourcePath
    }
    if ($repoManifestWriter -ceq 'v4' -and [string]$Entry.artifactType -ceq 'instruction') {
        if ($manifestSchemaVersion -eq 4) {
            $copy.host = [string]$Entry.host
            $copy.rendererId = [string]$Entry.rendererId
            $copy.rendererSha256 = $Entry.rendererSha256
            if ($null -ne $Entry.PSObject.Properties['retention']) { $copy.retention = [string]$Entry.retention }
        }
        elseif ($manifestSchemaVersion -in @(2,3)) {
            $copy.host = Resolve-ManagedInstructionHostForTarget -TargetPath ([string]$Entry.targetPath)
            $copy.rendererId = 'legacy-unrendered'
            $copy.rendererSha256 = $null
            $copy.retention = 'legacy-preserved'
        }
        else {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Cannot retain instruction entry from managed manifest schema '$manifestSchemaVersion' while writing v4.")
        }
    }
    elseif ($null -ne $Entry.PSObject.Properties['host']) {
        $copy.host = [string]$Entry.host
        $copy.rendererId = [string]$Entry.rendererId
        $copy.rendererSha256 = $Entry.rendererSha256
        if ($null -ne $Entry.PSObject.Properties['retention']) { $copy.retention = [string]$Entry.retention }
    }
    if ($null -ne $Entry.PSObject.Properties['projectionId']) { $copy.projectionId = [string]$Entry.projectionId }
    $copy.targetPath = [string]$Entry.targetPath
    $copy.sha256 = [string]$Entry.sha256
    return [pscustomobject]$copy
}

function New-TargetMutationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string[]] $RelativePaths,
        [Parameter(Mandatory = $true)][string] $BackupRoot,
        [AllowEmptyCollection()][ValidateNotNull()][string[]] $ProtectedPaths = @()
    )

    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $resolvedTargetRoot = Get-FullPathWithoutTrailingSeparator -Path $TargetRoot
    $targetPrefix = $resolvedTargetRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $fileStates = New-Object System.Collections.Generic.List[object]
    $backupIndex = 0

    foreach ($relativePath in @($RelativePaths | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        if (Test-IsProtectedClaudeFamilyPath -Path ([string]$relativePath) -ProtectedPaths $ProtectedPaths) {
            Write-Warning "Protected Claude family path skipped at bootstrap recovery snapshot: $relativePath (project-owned Claude family)."
            continue
        }
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
        ProtectedPaths = @($ProtectedPaths)
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
    $protectedPaths = @(if ($null -ne $Snapshot -and $Snapshot.PSObject.Properties['ProtectedPaths']) {
        if ($null -eq $Snapshot.ProtectedPaths) { throw 'ProtectedPaths state is null.' }
        @($Snapshot.ProtectedPaths)
    } else { @() })
    if ($Kind -ceq 'Target' -and (Test-IsProtectedClaudeFamilyPath -Path $RelativePath -ProtectedPaths $protectedPaths)) {
        Write-Warning "Protected Claude family path skipped at atomic file publication: $RelativePath (project-owned Claude family)."
        return $null
    }
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

    $protectedPaths = @(if ($Snapshot.PSObject.Properties['ProtectedPaths']) {
        if ($null -eq $Snapshot.ProtectedPaths) { throw 'ProtectedPaths state is null.' }
        @($Snapshot.ProtectedPaths)
    } else { @() })
    if (Test-IsProtectedClaudeFamilyPath -Path $RelativePath -ProtectedPaths $protectedPaths) {
        Write-Warning "Protected Claude family path skipped at atomic file deletion: $RelativePath (project-owned Claude family)."
        return
    }
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

$script:ProjectPublicationContext = $null

function ConvertTo-ProjectPublicationIdentity {
    param([Parameter(Mandatory=$true)]$Observation)
    if($IsWindows){return [pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}'-f[uint64]$Observation.Device);fileId=('0x{0:x}'-f[uint64]$Observation.Inode)}}
    return [pscustomobject][ordered]@{kind='unix-device-inode';device=[string][uint64]$Observation.Device;fileId=[string][uint64]$Observation.Inode}
}

function Test-ProjectPublicationPathEqual {
    param([Parameter(Mandatory=$true)][string]$Left,[Parameter(Mandatory=$true)][string]$Right)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    return [string]::Equals([IO.Path]::GetFullPath($Left),[IO.Path]::GetFullPath($Right),$comparison)
}

function Get-RepositoryTransactionStorePath {
    param([Parameter(Mandatory=$true)][string]$GitDirectory)
    return (Join-Path $GitDirectory '.ai-instructions-txn')
}

function Get-RepositoryTransactionPath {
    param([Parameter(Mandatory=$true)][object]$Context)
    return (Join-Path (Get-RepositoryTransactionStorePath -GitDirectory ([string]$Context.GitDirectory)) ([string]$Context.DirectoryLeaf))
}

function Assert-RepositoryTransactionScopeBinding {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string]$GitDirectory,
        [Parameter(Mandatory=$true)][object]$Journal
    )
    try{
        $activeGitDirectory=Get-RepositoryActiveGitDirectory -Repository $Repository
        $commonGitDirectory=((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-common-dir'))|Select-Object -First 1).Trim()
        if(-not[IO.Path]::IsPathRooted($commonGitDirectory)){$commonGitDirectory=Join-Path $Repository $commonGitDirectory}
        $commonGitDirectory=[IO.Path]::GetFullPath($commonGitDirectory)
        $indexPath=((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-path','index'))|Select-Object -First 1).Trim()
        if(-not[IO.Path]::IsPathRooted($indexPath)){$indexPath=Join-Path $Repository $indexPath}
        $indexPath=[IO.Path]::GetFullPath($indexPath)
        $objectFormat=((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--show-object-format'))|Select-Object -First 1).Trim()
        $rootLease=Open-PlatformDirectory -Root $Repository -RootOnly
        try{$repositoryRootIdentity=ConvertTo-ProjectPublicationIdentity $rootLease.Observation}finally{$rootLease.Dispose()}
        $matches=(Test-ProjectPublicationPathEqual -Left $activeGitDirectory -Right $GitDirectory)-and
            (Test-ProjectPublicationPathEqual -Left ([string]$Journal.scope.repositoryRoot) -Right $Repository)-and
            (Test-RepositoryTransactionIdentityEqual -Actual $repositoryRootIdentity -Expected $Journal.scope.repositoryRootIdentity)-and
            (Test-ProjectPublicationPathEqual -Left ([string]$Journal.scope.commonGitDirectory) -Right $commonGitDirectory)-and
            (Test-ProjectPublicationPathEqual -Left ([string]$Journal.scope.gitDirectory) -Right $activeGitDirectory)-and
            (Test-ProjectPublicationPathEqual -Left ([string]$Journal.scope.indexPath) -Right $indexPath)-and
            [string]$Journal.scope.objectFormat-ceq$objectFormat-and
            [string]$Journal.platform.os-ceq(Get-RepositoryTransactionPlatform)
        if(-not$matches){throw 'one or more repository scope bindings changed'}
    }
    catch{
        if((Get-AiInstructionsRefusalCode $_)-ceq'interrupted-install'){throw}
        throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction scope no longer matches repository root identity, common Git directory, active Git directory, index path, object format, or platform; no recovery mutation was attempted. Preserve the transaction evidence for manual inspection. Detail: $($_.Exception.Message)" -InnerException $_.Exception)
    }
}

function New-ProjectPublicationContext {
    param([Parameter(Mandatory=$true)][string]$Repository)
    Import-Module (Join-Path $PSScriptRoot 'ai-instructions-install-transaction.psm1') -Force
    $gitDirectory=Get-RepositoryActiveGitDirectory -Repository $Repository
    Invoke-ProjectPublicationRecovery -Repository $Repository -GitDirectory $gitDirectory
    $storePath=Get-RepositoryTransactionStorePath -GitDirectory $gitDirectory
    if(Test-Path -LiteralPath $storePath){
        $residue=@(Get-ChildItem -Force -LiteralPath $storePath -ErrorAction Stop)
        if($residue.Count-gt0){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Project Skill recovery evidence requires reconciliation before retry: $storePath")}
    }
    return [pscustomobject][ordered]@{
        Repository=$Repository
        GitDirectory=$gitDirectory
        Id=[guid]::NewGuid().ToString('N')
        DirectoryLeaf=$null
        Intents=(New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal))
        Remediation=$null
        Durable=$false
        ContainerLease=$null
        Lease=$null
        Identity=$null
        CurrentJournal=$null
        JournalStoreStates=$null
        RepositoryIndexLock=$null
        ShouldStorePersonalAgentEvidence=$false
        PersonalAgentEvidenceStashBefore=$null
        PlanningObservations=(New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal))
        TerminalManifestEntries=@()
    }
}

function Get-ProjectPublicationPathObservation {
    # Observe one repository-relative target as raw bytes SHA-256, length, and file identity.
    # Any entry that cannot be observed as a regular file is recorded as unobservable so that
    # final manifest verification fails closed instead of silently skipping the path.
    param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$RelativePath)
    $absent=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;unobservable=$null}
    try{
        $full=Join-Path $Repository $RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $parent=[IO.Path]::GetDirectoryName($full);$leaf=[IO.Path]::GetFileName($full)
        if(-not(Test-Path -LiteralPath $parent -PathType Container)-or-not(Test-Path -LiteralPath $full)){return $absent}
        $item=Get-Item -Force -LiteralPath $full
        if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return [pscustomobject][ordered]@{exists=$true;sha256=$null;length=$null;identity=$null;unobservable='not a regular file'}}
        $parentLease=Open-PlatformDirectory -Root $parent -RootOnly
        try{
            $lease=Open-PlatformFile -ParentLease $parentLease -Leaf $leaf -Access Read -CreateMode OpenExisting
            try{
                [byte[]]$bytes=$lease.ReadAllBytes(268435456)
                return [pscustomobject][ordered]@{exists=$true;sha256=(Get-ByteArraySha256 $bytes);length=[int64]$bytes.Length;identity=(ConvertTo-ProjectPublicationIdentity $lease.Observation);unobservable=$null}
            }finally{$lease.Dispose()}
        }finally{$parentLease.Dispose()}
    }
    catch{return [pscustomobject][ordered]@{exists=$true;sha256=$null;length=$null;identity=$null;unobservable=[string]$_.Exception.Message}}
}

function Test-ProjectPublicationPathObservationEqual {
    param([Parameter(Mandatory=$true)][object]$Actual,[Parameter(Mandatory=$true)][object]$Expected)
    if($null-ne$Actual.unobservable-or$null-ne$Expected.unobservable){return $false}
    return Test-ProjectPublicationStateEqual $Actual $Expected
}

function Register-ProjectPublicationPlanningObservations {
    # Record the planning-time observation of every path that the next manifest can own.
    # Final manifest verification compares every manifest path without a publication operation against this value.
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$RelativePaths)
    foreach($relativePath in @($RelativePaths|Sort-Object -Unique)){
        if([string]::IsNullOrWhiteSpace($relativePath)-or$Context.PlanningObservations.ContainsKey($relativePath)){continue}
        $Context.PlanningObservations.Add($relativePath,(Get-ProjectPublicationPathObservation -Repository ([string]$Context.Repository) -RelativePath $relativePath))
    }
}

function Set-ProjectPublicationFileBytesCore {
    param(
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][byte[]]$Bytes,
        [Parameter(Mandatory=$true)][ValidateSet('repository','git-exclude')][string]$TargetKind,
        [Nullable[bool]]$ExpectedExists,
        [string]$ExpectedSha256,
        [ValidateSet('raw','managed')][string]$ExpectedHashKind='raw',
        [object]$ExpectedState
    )
    $context=$script:ProjectPublicationContext;if($null-eq$context){throw 'Project publication context is unavailable.'}
    $parentRelative=(Split-Path -Parent $RelativePath).Replace('\','/');$leaf=Split-Path -Leaf $RelativePath
    $parentLease=$null
    try{
        $target=Join-Path $TargetRoot $RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $parentPath=Split-Path -Parent $target
        $originalCapture=if(Test-Path -LiteralPath $parentPath -PathType Container){
            $parentLease=Open-PlatformDirectory -Root $parentPath -RootOnly
            Get-AiInstructionsInstallFileState -ParentLease $parentLease -Leaf $leaf -LiteralPath $target -PlatformOs $(if($IsLinux){'linux'}elseif($IsMacOS){'macos'}else{'windows'}) -IncludePermissions
        }else{[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;permissions=$null}}
        if($null-ne$ExpectedState -and -not(Test-ProjectPublicationStateEqual $originalCapture $ExpectedState)){throw "Project publication target identity or bytes changed concurrently: $RelativePath"}
        if($null-ne$ExpectedExists -and ([bool]$originalCapture.exists-ne[bool]$ExpectedExists)) { throw "Project publication target existence changed concurrently: $RelativePath" }
        if([bool]$originalCapture.exists -and -not[string]::IsNullOrWhiteSpace($ExpectedSha256)){
            [byte[]]$capturedBytes=[IO.File]::ReadAllBytes($target)
            $rawSha=Get-ManagedContentHashFromBytes -Bytes $capturedBytes -TargetPath '.agents/skills/raw.bin'
            if($rawSha-cne[string]$originalCapture.sha256){throw "Project publication target bytes changed during capture: $RelativePath"}
            $capturedSha=if($ExpectedHashKind-ceq'raw'){$rawSha}else{Get-ManagedContentHashFromBytes -Bytes $capturedBytes -TargetPath $RelativePath}
            if($capturedSha-cne$ExpectedSha256){throw "Project publication target content changed concurrently: $RelativePath"}
        }
        $key="$TargetKind`0$TargetRoot`0$RelativePath"
        if($context.Intents.ContainsKey($key)){
            $intent=$context.Intents[$key]
            $intent.Bytes=[byte[]]$Bytes.Clone();$intent.Remove=$false
        }else{
            $role=if($TargetKind-ceq'git-exclude'){'shared-exclude'}elseif($RelativePath-ceq$manifestRelativePath){'manifest'}elseif(Test-LicenseDeliveryTargetPath $RelativePath){'license'}elseif($RelativePath-cmatch '^\.(?:agents|claude|github)/skills/'){'project-skill'}else{'instruction'}
            $context.Intents.Add($key,[pscustomobject][ordered]@{TargetKind=$TargetKind;TargetRoot=$TargetRoot;RelativePath=$RelativePath;Before=$originalCapture;Bytes=[byte[]]$Bytes.Clone();Remove=$false;Role=$role})
        }
    }
    catch {
        if($TargetKind-ceq'git-exclude'){
            throw "Could not acquire an exclusive shared Git exclude mutation handle: $target. $($_.Exception.Message)"
        }
        throw
    }
    finally{if($null-ne$parentLease){$parentLease.Dispose()}}
}

function Set-ProjectPublicationFileBytes {
    param([Parameter(Mandatory=$true)][string]$RelativePath,[Parameter(Mandatory=$true)][byte[]]$Bytes,[Nullable[bool]]$ExpectedExists,[string]$ExpectedSha256)
    $hashKind=if($RelativePath-ceq$manifestRelativePath){'raw'}else{'managed'}
    Set-ProjectPublicationFileBytesCore -TargetRoot $script:ProjectPublicationContext.Repository -RelativePath $RelativePath -Bytes $Bytes -TargetKind repository -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256 -ExpectedHashKind $hashKind
}

function Set-ProjectPublicationExternalFileBytes {
    param([Parameter(Mandatory=$true)][string]$LiteralPath,[Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][bool]$ExpectedExists,[string]$ExpectedSha256,[object]$ExpectedState)
    $fullPath=[IO.Path]::GetFullPath($LiteralPath);$parent=[IO.Path]::GetDirectoryName($fullPath);$leaf=[IO.Path]::GetFileName($fullPath)
    if([string]::IsNullOrWhiteSpace($parent)-or[string]::IsNullOrWhiteSpace($leaf)){throw 'Project publication external target is invalid.'}
    if(-not(Test-ProjectPublicationPathEqual -Left $fullPath -Right ([string](Get-GitInfoExcludePath -Repository $script:ProjectPublicationContext.Repository)))){throw 'Project publication external target is not the shared Git exclude.'}
    Set-ProjectPublicationFileBytesCore -TargetRoot $parent -RelativePath $leaf -Bytes $Bytes -TargetKind git-exclude -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256 -ExpectedState $ExpectedState
}

function Remove-ProjectPublicationFile {
    param([Parameter(Mandatory=$true)][string]$RelativePath,[string]$ExpectedSha256)
    $context=$script:ProjectPublicationContext;if($null-eq$context){throw 'Project publication context is unavailable.'}
    $parentRelative=(Split-Path -Parent $RelativePath).Replace('\','/');$leaf=Split-Path -Leaf $RelativePath
    $parentLease=$null
    try{
        $target=Join-Path $context.Repository $RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $parentPath=Split-Path -Parent $target
        if(-not(Test-Path -LiteralPath $parentPath -PathType Container)){return}
        $parentLease=Open-PlatformDirectory -Root $parentPath -RootOnly
        $original=Get-AiInstructionsInstallFileState -ParentLease $parentLease -Leaf $leaf -LiteralPath $target -PlatformOs $(if($IsLinux){'linux'}elseif($IsMacOS){'macos'}else{'windows'}) -IncludePermissions
        if(-not$original.exists){return}
        if(-not[string]::IsNullOrWhiteSpace($ExpectedSha256)){
            [byte[]]$capturedBytes=[IO.File]::ReadAllBytes($target);$rawSha=Get-ManagedContentHashFromBytes -Bytes $capturedBytes -TargetPath '.agents/skills/raw.bin'
            if($rawSha-cne[string]$original.sha256){throw "Project publication removal target bytes changed during capture: $RelativePath"}
            if((Get-ManagedContentHashFromBytes -Bytes $capturedBytes -TargetPath $RelativePath)-cne$ExpectedSha256){throw "Project publication removal target content changed concurrently: $RelativePath"}
        }
        $key="repository`0$($context.Repository)`0$RelativePath"
        if($context.Intents.ContainsKey($key)){$intent=$context.Intents[$key];$intent.Bytes=$null;$intent.Remove=$true}
        else{
            $role=if($RelativePath-ceq$manifestRelativePath){'manifest'}elseif(Test-LicenseDeliveryTargetPath $RelativePath){'license'}elseif($RelativePath-cmatch '^\.(?:agents|claude|github)/skills/'){'project-skill'}else{'instruction'}
            $context.Intents.Add($key,[pscustomobject][ordered]@{TargetKind='repository';TargetRoot=$context.Repository;RelativePath=$RelativePath;Before=$original;Bytes=$null;Remove=$true;Role=$role})
        }
    }finally{if($null-ne$parentLease){$parentLease.Dispose()}}
}

function Complete-ProjectPublicationContext {
    param([Parameter(Mandatory=$true)]$Context)
    Invoke-RepositoryInstallTransaction -Context $Context
}

function Get-RepositoryTransactionDiskState {
    param([Parameter(Mandatory=$true)]$Context)
    $transactionPath=Get-RepositoryTransactionPath -Context $Context
    if(-not(Test-Path -LiteralPath $transactionPath -PathType Container)){return [pscustomobject]@{status='orphan';journal=$null}}
    $lease=$Context.Lease;$opened=$false
    try{
        if($null-eq$lease){$lease=Open-PlatformDirectory -Root $Context.GitDirectory -RelativePath ('.ai-instructions-txn/'+$Context.Id);$opened=$true}
        $readLeaf={param([string]$name)$path=Join-Path $transactionPath $name;if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{Kind=$null;Json=$null;State=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}}};if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{Kind='other';Json=$null;State=$null}};$state=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $name -LiteralPath $path -PlatformOs (Get-RepositoryTransactionPlatform);return [pscustomobject]@{Kind='file';Json=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path));State=$state}}
        $journal=&$readLeaf 'journal.json';$previous=&$readLeaf 'journal.prev';$stage=&$readLeaf 'journal.stage'
        $classification=Get-AiInstructionsInstallTransactionClassification -Name $Context.Id -EntryKind directory -JournalEntryKind $journal.Kind -JournalJson $journal.Json -PreviousJournalEntryKind $previous.Kind -PreviousJournalJson $previous.Json -ExpectedOwnerComponent repo-bootstrap
        $Context.JournalStoreStates=[ordered]@{'journal.json'=$journal.State;'journal.prev'=$previous.State;'journal.stage'=$stage.State}
        if([string]$classification.classification-ceq'valid-journal'){Assert-RepositoryTransactionScopeBinding -Repository $Context.Repository -GitDirectory $Context.GitDirectory -Journal $classification.journal;return [pscustomobject]@{status='valid';journal=$classification.journal}}
        if([string]$classification.classification-ceq'orphan-without-journal'){return [pscustomobject]@{status='orphan';journal=$null}}
        return [pscustomobject]@{status='indeterminate';journal=$null;reason=[string]$classification.reason}
    }finally{if($opened){$lease.Dispose()}}
}

function Resolve-ActiveProjectPublicationFailure {
    param([Parameter(Mandatory=$true)]$Context,[AllowNull()]$RemediationTransaction)
    if(-not[bool]$Context.Durable){return 'rollback-all'}
    $journalState=Get-RepositoryTransactionDiskState -Context $Context
    if([string]$journalState.status-ceq'orphan'){
        $transactionPath=Get-RepositoryTransactionPath -Context $Context
        if(Test-Path -LiteralPath $transactionPath -PathType Container){
            $unexpected=@(Get-ChildItem -Force -LiteralPath $transactionPath|Where-Object{-not(Test-RepositoryTransactionOrphanChild -Item $_)})
            if($unexpected.Count-gt0){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction orphan contains unknown evidence at '$transactionPath'; inspect it manually before removal.")}
            if($null-ne$Context.Lease){$Context.Lease.Dispose();$Context.Lease=$null}
            Remove-PlatformOwnedDirectoryTree -TransactionRootLease $Context.ContainerLease -Leaf $Context.DirectoryLeaf -ExpectedIdentity $Context.Identity|Out-Null
        }
        if($null-ne$Context.ContainerLease){$Context.ContainerLease.Dispose();$Context.ContainerLease=$null}
        $Context.Durable=$false
        return 'roll-forward-cleanup'
    }
    $action=Resolve-ProjectPublicationRecoveryAction -JournalState $journalState
    if($action-ceq'fail-closed'){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction journal is unreadable or invalid at '$(Get-RepositoryTransactionPath -Context $Context)'; inspect the evidence manually before removal.")}
    $Context.CurrentJournal=$journalState.journal
    Resolve-RepositoryRecoveryIndexLock -Context $Context
    if($action-ceq'rollback-all'){Invoke-RepositoryTransactionRollback $Context}
    elseif($action-ceq'roll-forward-cleanup'){Complete-RepositoryTransactionCleanup $Context}
    else{throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction recovery state is unknown. Inspect and clear '$(Get-RepositoryTransactionPath -Context $Context)' only after verifying journal evidence.")}
    return $action
}

function Test-RepositoryTransactionOrphanChild {
    param([Parameter(Mandatory=$true)][IO.FileSystemInfo]$Item)
    if(($Item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return $false}
    if($Item.PSIsContainer){return $Item.Name-cmatch'^op-[0-9]{6}\.(?:directory|quarantine)(?:\.trash)?$'}
    return $Item.Name-cmatch'^(?:journal\.stage|op-[0-9]{6}\.(?:stage|backup|quarantine))$'
}

function Remove-ProjectPublicationContextEvidence {
    param([Parameter(Mandatory=$true)]$Context)
    if($null-ne$Context.Lease){$Context.Lease.Dispose();$Context.Lease=$null}
    Remove-PlatformOwnedDirectoryTree -TransactionRootLease $Context.ContainerLease -Leaf $Context.Id -ExpectedIdentity $Context.Identity|Out-Null
    $Context.ContainerLease.Dispose();$Context.ContainerLease=$null
}

function Test-ProjectPublicationStateEqual {
    param([Parameter(Mandatory=$true)]$Actual,[Parameter(Mandatory=$true)]$Expected)
    if([bool]$Actual.exists-ne[bool]$Expected.exists){return $false}
    if(-not[bool]$Expected.exists){return $true}
    return [string]$Actual.sha256-ceq[string]$Expected.sha256 -and [int64]$Actual.length-eq[int64]$Expected.length -and
        [string]$Actual.identity.kind-ceq[string]$Expected.identity.kind -and
        [string]::Equals([string]$Actual.identity.device,[string]$Expected.identity.device,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Actual.identity.fileId,[string]$Expected.identity.fileId,[StringComparison]::OrdinalIgnoreCase)
}

function Assert-ProjectSkillManifestFilesCurrent {
    param(
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$ManifestEntries,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$PublishedTargetPaths,
        [AllowNull()][object]$PlanningObservations
    )

    # Closed rule: the verification set is every target path owned by the manifest at the end of this transaction,
    # selected by path only. A path published by this transaction must match the manifest-declared SHA-256;
    # every other path must still match its planning-time raw SHA-256 and file identity.
    $published=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($publishedTargetPath in $PublishedTargetPaths){[void]$published.Add([string]$publishedTargetPath)}
    foreach($entry in @($ManifestEntries|Sort-Object targetPath)){
        $targetPath=[string]$entry.targetPath
        $targetFullPath=Join-Path $TargetRoot $targetPath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if($published.Contains($targetPath)){
            Assert-ManagedPathDoesNotCrossReparsePoint -Root $TargetRoot -Path $targetFullPath -Context "Final project Skill manifest verification '$targetPath'"
            if(-not(Test-Path -LiteralPath $targetFullPath -PathType Leaf)-or
                (Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath)-cne[string]$entry.sha256){
                throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill manifest publication refused because final raw-byte verification failed: $targetPath")
            }
            continue
        }
        $planned=$null
        if($null-eq$PlanningObservations-or-not$PlanningObservations.TryGetValue($targetPath,[ref]$planned)){
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill manifest publication refused because final raw-byte verification failed: $targetPath has no planning observation.")
        }
        $live=Get-ProjectPublicationPathObservation -Repository $TargetRoot -RelativePath $targetPath
        if(-not(Test-ProjectPublicationPathObservationEqual -Actual $live -Expected $planned)){
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill manifest publication refused because final raw-byte verification failed: $targetPath")
        }
    }
}

function Set-TargetMutationFileBytes {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Nullable[bool]] $ExpectedExists,
        [string] $ExpectedSha256
    )
    $protectedPaths = @(if ($Snapshot.PSObject.Properties['ProtectedPaths']) {
        if ($null -eq $Snapshot.ProtectedPaths) { throw 'ProtectedPaths state is null.' }
        @($Snapshot.ProtectedPaths)
    } else { @() })
    if (Test-IsProtectedClaudeFamilyPath -Path $RelativePath -ProtectedPaths $protectedPaths) {
        Write-Warning "Protected Claude family path skipped at bootstrap file write: $RelativePath (project-owned Claude family)."
        return
    }
    if ($null -eq $script:ProjectPublicationContext) { throw 'Unified repository transaction context is required for target mutation planning.' }
    Set-ProjectPublicationFileBytes -RelativePath $RelativePath -Bytes $Bytes -ExpectedExists $ExpectedExists -ExpectedSha256 $ExpectedSha256
}

function Remove-TargetMutationFile {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [string] $ExpectedSha256
    )
    $protectedPaths = @(if ($Snapshot.PSObject.Properties['ProtectedPaths']) {
        if ($null -eq $Snapshot.ProtectedPaths) { throw 'ProtectedPaths state is null.' }
        @($Snapshot.ProtectedPaths)
    } else { @() })
    if (Test-IsProtectedClaudeFamilyPath -Path $RelativePath -ProtectedPaths $protectedPaths) {
        Write-Warning "Protected Claude family path skipped at bootstrap file deletion: $RelativePath (project-owned Claude family)."
        return
    }
    if ($null -eq $script:ProjectPublicationContext) { throw 'Unified repository transaction context is required for target mutation planning.' }
    Remove-ProjectPublicationFile -RelativePath $RelativePath -ExpectedSha256 $ExpectedSha256
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
    $protectedPaths = @(if ($Snapshot.PSObject.Properties['ProtectedPaths']) {
        if ($null -eq $Snapshot.ProtectedPaths) { throw 'ProtectedPaths state is null.' }
        @($Snapshot.ProtectedPaths)
    } else { @() })
    foreach ($state in @($Snapshot.FileStates)) {
        if (Test-IsProtectedClaudeFamilyPath -Path ([string]$state.RelativePath) -ProtectedPaths $protectedPaths) {
            Write-Warning "Protected Claude family path skipped at bootstrap file rollback: $($state.RelativePath) (project-owned Claude family)."
            continue
        }
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
        [string] $ActiveIndexPath,

        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [string[]] $ProtectedPaths = @()
    )

    $requestedPathCount = $Paths.Count
    $Paths = @($Paths | Where-Object {
        if (Test-IsProtectedClaudeFamilyPath -Path ([string]$_) -ProtectedPaths $ProtectedPaths) {
            Write-Warning "Protected Claude family path skipped at PersonalAgent recovery evidence: $_ (project-owned Claude family)."
            return $false
        }
        return $true
    })
    if ($Paths.Count -eq 0) {
        if ($requestedPathCount -gt 0) { return $null }
        throw 'Cannot create PersonalAgent stash without managed changes.'
    }
    $ExpectedEntries = @($ExpectedEntries | Where-Object {
        $entryPath = [string]$_.targetPath
        if (Test-IsProtectedClaudeFamilyPath -Path $entryPath -ProtectedPaths $ProtectedPaths) {
            Write-Warning "Protected Claude family path skipped at PersonalAgent recovery evidence: $entryPath (project-owned Claude family)."
            return $false
        }
        return $true
    })
    $EvidenceFingerprint = Get-PersonalAgentEvidenceFingerprint -Repository $Repository -Paths $Paths

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
    Invoke-RepositoryTransactionEvidenceStashStore -Context $script:ProjectPublicationContext -EvidenceCommit $newEvidenceCommit

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

    $protectedStashHashes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($priorOwnedStash in @($PriorOwnedStashes)) {
        $parentLine = ((Invoke-Git -Repository $Repository -Arguments @('show','--no-patch','--format=%P',[string]$priorOwnedStash.Hash)) |
            Select-Object -First 1).Trim()
        $parents = @($parentLine.Split(' ',[StringSplitOptions]::RemoveEmptyEntries))
        if ($parents.Count -lt 3) { throw "Cannot inspect prior PersonalAgent recovery evidence: $($priorOwnedStash.Hash)" }
        foreach ($line in @(Invoke-Git -Repository $Repository -Arguments @('-c','core.quotePath=true','ls-tree','-r','--name-only',$parents[2]))) {
            $evidencePath = ConvertFrom-GitQuotedPath -Path ([string]$line)
            if (Test-IsProtectedClaudeFamilyPath -Path $evidencePath -ProtectedPaths $ProtectedPaths) {
                Write-Warning "Protected Claude family recovery evidence retained in stash $($priorOwnedStash.Hash): $evidencePath (project-owned Claude family)."
                [void]$protectedStashHashes.Add([string]$priorOwnedStash.Hash)
            }
        }
    }
    $obsoleteStashes = @($PriorOwnedStashes | Where-Object {
        $_.Hash -ne $newStashHash -and -not $protectedStashHashes.Contains([string]$_.Hash)
    } | Sort-Object Index -Descending)
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
    $protectedPaths = @(if ($Snapshot.PSObject.Properties['ProtectedPaths']) {
        if ($null -eq $Snapshot.ProtectedPaths) { throw 'ProtectedPaths state is null.' }
        @($Snapshot.ProtectedPaths)
    } else { @() })
    if (-not [string]::IsNullOrWhiteSpace($PendingPath) -and
        (Test-IsProtectedClaudeFamilyPath -Path $PendingPath -ProtectedPaths $protectedPaths)) {
        Write-Warning "Protected Claude family path skipped at Skill migration journal: $PendingPath (project-owned Claude family)."
        $PendingPath = $null
        $PendingBytes = $null
    }
    $schemaVersion = 2
    if ($Snapshot.PSObject.Properties['JournalSchemaVersion']) { $schemaVersion = [int]$Snapshot.JournalSchemaVersion }
    if ($schemaVersion -eq 1) {
        $states = @(
            foreach ($state in $Snapshot.FileStates) {
                if (Test-IsProtectedClaudeFamilyPath -Path ([string]$state.RelativePath) -ProtectedPaths $protectedPaths) {
                    Write-Warning "Protected Claude family path skipped at Skill migration journal: $($state.RelativePath) (project-owned Claude family)."
                    continue
                }
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
            if (Test-IsProtectedClaudeFamilyPath -Path ([string]$state.RelativePath) -ProtectedPaths $protectedPaths) {
                Write-Warning "Protected Claude family path skipped at Skill migration journal: $($state.RelativePath) (project-owned Claude family)."
                continue
            }
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
    $recoveryProtectedPaths = @(if (@(Get-ClaudeProjectOwnedWorktreeRoots -Repository $Repository -Strict).Count -gt 0) {
        @('CLAUDE.md','.claude/AI-Rules/','.claude/ai-instructions-licenses/')
    }
    else { @() })
    $protectedJournalPaths = New-Object System.Collections.Generic.List[string]
    $gitState = Get-RepoSkillMigrationGitState -Repository $Repository -GitExecutable $GitExecutable
    if ($gitState.head -cne $journal.head -or $gitState.indexSha256 -cne $journal.indexSha256) { throw 'Skill migration recovery preserved concurrent Git changes.' }
    $states = @()
    $seen = @{}
    $seenBackups = @{}
    foreach ($state in $journal.states) {
        $relative = [string]$state.relativePath
        if (Test-IsProtectedClaudeFamilyPath -Path $relative -ProtectedPaths $recoveryProtectedPaths) {
            Write-Warning "Protected Claude family path skipped at Skill migration recovery: $relative (project-owned Claude family)."
            $protectedJournalPaths.Add($relative)
            continue
        }
        if ($schemaVersion -eq 2) {
            Assert-ExactJournalProperties -Value $state -Names @('relativePath','originalType','backupName','backupSha256','mutationApplied',
                'appliedType','appliedBase64','originalDacl','originalReadOnly','originalIdentity','appliedFileIdentity','publication',
                'publicationDacl','publicationReadOnly') `
                -Context 'schema-v2 migration state'
        }
        if ($state.mutationApplied -isnot [bool]) { throw 'Invalid Skill migration recovery mutation flag.' }
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
        JournalSchemaVersion=$schemaVersion; ProtectedPaths=@($recoveryProtectedPaths)}
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
            PublicationDaclRecord=$excludePublicationDacl;PublicationReadOnly=$excludePublicationReadOnly;LegacyRecovery=$true
            ManagedPaths=[string[]]$protectedJournalPaths.ToArray();ProtectedPaths=@($recoveryProtectedPaths)}
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
            PublicationReadOnly=$excludePublicationReadOnly;LegacyRecovery=$false
            ManagedPaths=[string[]]$protectedJournalPaths.ToArray();ProtectedPaths=@($recoveryProtectedPaths)}
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
    try {
        $resolvedRoot = @(Invoke-Git -Repository (Get-Location).Path -Arguments @('rev-parse','--show-toplevel'))
        $resolveExitCode = 0
    }
    catch {
        $resolveExitCode = 1
    }

    if ($resolveExitCode -ne 0) {
        Write-Output 'AI instruction sync skipped: the current directory is not inside a Git repository.'
        return
    }

    $TargetRoot = ($resolvedRoot | Select-Object -First 1).Trim()
}

function Get-RepositoryTransactionPlatform {
    if($IsLinux){return 'linux'}
    if($IsMacOS){return 'macos'}
    return 'windows'
}

function Get-RepositoryTransactionArchitecture {
    $value=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if($value-ceq'x64'){return 'x64'}
    if($value-ceq'arm64'){return 'arm64'}
    throw (New-AiInstructionsRefusalException -Code 'capability-unavailable' -Message "Unsupported repository transaction architecture: $value")
}

function Get-RepositoryTransactionFileState {
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    $path=if([string]$Operation.target.kind-ceq'git-shared-exclude'){[string]$Operation.target.value}else{Join-Path ([string]$Journal.scope.repositoryRoot) ([string]$Operation.target.value).Replace('/',[IO.Path]::DirectorySeparatorChar)}
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path));$leaf=[IO.Path]::GetFileName($path)
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){return [pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;permissions=$null}}
    $lease=Open-PlatformDirectory -Root $parent -RootOnly
    try{return Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath $path -PlatformOs ([string]$Journal.platform.os) -IncludePermissions}
    finally{$lease.Dispose()}
}

function Get-RepositoryTransactionObservedAfter {
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    if(-not$IsWindows-or[string]$Operation.kind-cnotin@('create-file','write-file')){return $null}
    $isExclude=[string]$Operation.target.kind-ceq'git-shared-exclude'
    $path=if($isExclude){[string]$Operation.target.value}else{Join-Path ([string]$Journal.scope.repositoryRoot) ([string]$Operation.target.value).Replace('/',[IO.Path]::DirectorySeparatorChar)}
    $root=if($isExclude){[IO.Path]::GetDirectoryName($path)}else{[string]$Journal.scope.repositoryRoot}
    $relative=if($isExclude){[IO.Path]::GetFileName($path)}else{[string]$Operation.target.value}
    $evidence=Get-PublicationFileEvidence -Root $root -Path $path -RelativePath $relative -Kind $(if($isExclude){'Exclude'}else{'Target'})
    return [pscustomobject][ordered]@{dacl=$evidence.dacl;readOnly=[bool]$evidence.readOnly}
}

# Metadata snapshot/restore set: every displaced-file metadata capture and restore goes through these functions only.
function ConvertTo-RepositoryTransactionMetadataSnapshot {
    param([Parameter(Mandatory=$true)][object]$Permissions)
    if([string]$Permissions.kind-ceq'windows-sddl'){
        return [pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$Permissions.sddl;readOnly=[bool]$Permissions.readOnly}
    }
    if([string]$Permissions.kind-ceq'unix-mode'){
        return [pscustomobject][ordered]@{kind='unix-mode';mode=[string]$Permissions.mode;uid=[uint64]$Permissions.uid;gid=[uint64]$Permissions.gid}
    }
    throw "Unsupported displaced repository file metadata kind '$($Permissions.kind)'."
}

function New-RepositoryTransactionDisplacedMetadataSnapshot {
    param([Parameter(Mandatory=$true)][object]$Before,[Parameter(Mandatory=$true)][ValidateSet('create-file','write-file','remove-file')][string]$Kind)
    if($Kind-ceq'create-file'){return $null}
    if(-not[bool]$Before.exists-or$null-eq$Before.permissions){throw 'A displaced repository file is missing its prepared permission snapshot.'}
    return ConvertTo-RepositoryTransactionMetadataSnapshot -Permissions $Before.permissions
}

function Test-RepositoryTransactionIdentityEqual {
    param([AllowNull()][object]$Actual,[AllowNull()][object]$Expected)
    if($null-eq$Actual-or$null-eq$Expected){return $false}
    return [string]$Actual.kind-ceq[string]$Expected.kind-and
        [string]::Equals([string]$Actual.device,[string]$Expected.device,[StringComparison]::OrdinalIgnoreCase)-and
        [string]::Equals([string]$Actual.fileId,[string]$Expected.fileId,[StringComparison]::OrdinalIgnoreCase)
}

function Get-RepositoryTransactionDisplacedAfterMetadata {
    # Read back the displaced original inside the private transaction directory after redo displaced it.
    # The value is bound in the same journal generation that marks the operation applied.
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][object]$Operation)
    if([string]$Operation.kind-cnotin@('write-file','remove-file')){return $null}
    $backupLeaf=[string]$Operation.backupLeaf
    if(-not(Test-Path -LiteralPath (Join-Path (Get-RepositoryTransactionPath -Context $Context) $backupLeaf) -PathType Leaf)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction sequence $($Operation.sequence) did not leave its displaced original in the transaction directory.")}
    $backupLease=Open-PlatformFile -ParentLease $Context.Lease -Leaf $backupLeaf -Access Read -CreateMode OpenExisting
    try{
        if(-not(Test-RepositoryTransactionIdentityEqual -Actual (ConvertTo-ProjectPublicationIdentity $backupLease.Observation) -Expected $Operation.before.identity)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction sequence $($Operation.sequence) displaced original identity differs from its prepared identity.")}
        return ConvertTo-RepositoryTransactionMetadataSnapshot -Permissions (Get-PlatformPermissions -Lease $backupLease)
    }finally{$backupLease.Dispose()}
}

function Test-RepositoryTransactionDisplacedMetadataEqual {
    param([AllowNull()][object]$Actual,[AllowNull()][object]$Expected)
    if($null-eq$Actual-or$null-eq$Expected){return $null-eq$Actual-and$null-eq$Expected}
    if([string]$Expected.kind-ceq'windows-sddl'){
        return [string]$Actual.kind-ceq'windows-sddl'-and[string]$Actual.sddl-ceq[string]$Expected.sddl-and[bool]$Actual.readOnly-eq[bool]$Expected.readOnly
    }
    return [string]$Actual.kind-ceq'unix-mode'-and[string]$Actual.mode-ceq[string]$Expected.mode-and[uint64]$Actual.uid-eq[uint64]$Expected.uid-and[uint64]$Actual.gid-eq[uint64]$Expected.gid
}

function Get-RepositoryTransactionObservedAfterFromLease {
    param([Parameter(Mandatory=$true)][object]$Lease)
    if(-not$IsWindows){return $null}
    $permissions=Get-PlatformPermissions -Lease $Lease
    $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new([string]$permissions.sddl)
    $dacl=$descriptor.DiscretionaryAcl
    [byte[]]$aclBytes=$null
    if($null-ne$dacl){$aclBytes=[byte[]]::new($dacl.BinaryLength);$dacl.GetBinaryForm($aclBytes,0)}
    return [pscustomobject][ordered]@{
        dacl=[pscustomobject][ordered]@{
            isNull=$null-eq$dacl
            isProtected=($descriptor.ControlFlags-band[Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)-ne0
            aclBase64=if($null-eq$dacl){$null}else{[Convert]::ToBase64String($aclBytes)}
        }
        readOnly=[bool]$permissions.readOnly
    }
}

function Restore-RepositoryTransactionDisplacedMetadata {
    # Three-state metadata CAS for an original file that undo has placed back at its target.
    # Callers invoke this unconditionally; only this function decides whether metadata may be applied:
    #   never displaced (no journaled displaced-after value) -> no mutation
    #   live == prepared original metadata                   -> no-op
    #   live == journaled displaced-after metadata           -> apply the original and read it back
    #   live == journaled published observedAfter metadata   -> apply only after this undo moved the original back
    #   anything else                                        -> third state, no mutation
    # The target handle is bound to the prepared original identity before any metadata is read or applied.
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    if([string]$Operation.kind-cnotin@('write-file','remove-file')-or$null-eq$Operation.displacedMetadata){return}
    $displacedAfter=if($null-ne$Operation.PSObject.Properties['displacedAfterMetadata']){$Operation.displacedAfterMetadata}else{$null}
    if($null-eq$displacedAfter){return}
    $thirdState="Repository transaction sequence $($Operation.sequence) role $($Operation.role) target $($Operation.target.value) is in a third state; evidence was retained for manual inspection and cleanup."
    $path=if([string]$Operation.target.kind-ceq'git-shared-exclude'){[string]$Operation.target.value}else{Join-Path ([string]$Journal.scope.repositoryRoot) ([string]$Operation.target.value).Replace('/',[IO.Path]::DirectorySeparatorChar)}
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path));$leaf=[IO.Path]::GetFileName($path)
    $parentLease=Open-PlatformDirectory -Root $parent -RootOnly
    try{
        $lease=Open-PlatformFile -ParentLease $parentLease -Leaf $leaf -Access Read -CreateMode OpenExisting
        try{
            if(-not(Test-RepositoryTransactionIdentityEqual -Actual (ConvertTo-ProjectPublicationIdentity $lease.Observation) -Expected $Operation.before.identity)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message $thirdState)}
            $live=ConvertTo-RepositoryTransactionMetadataSnapshot -Permissions (Get-PlatformPermissions -Lease $lease)
            if(Test-RepositoryTransactionDisplacedMetadataEqual -Actual $live -Expected $Operation.displacedMetadata){return}
            $matchesDisplacedAfter=Test-RepositoryTransactionDisplacedMetadataEqual -Actual $live -Expected $displacedAfter
            # Publish-PlatformFile's undo path deliberately transfers the live published
            # target metadata to the original backup before moving that identity back.  On
            # Windows, parent inheritance can therefore make the restored target match the
            # operation's durable observedAfter instead of the backup-directory snapshot.
            # Accept only that already-journaled transaction state; arbitrary metadata still
            # remains a third state and is never overwritten.
            $matchesPublishedAfter=$false
            if(-not$matchesDisplacedAfter-and$null-ne$Operation.observedAfter){
                $liveObservedAfter=Get-RepositoryTransactionObservedAfterFromLease -Lease $lease
                $matchesPublishedAfter=Test-RepositoryTransactionObservedAfterEqual -Actual $liveObservedAfter -Expected $Operation.observedAfter
            }
            if(-not$matchesDisplacedAfter-and-not$matchesPublishedAfter){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message $thirdState)}
            Set-PlatformPermissions -Lease $lease -Snapshot $Operation.displacedMetadata|Out-Null
            $readback=Get-PlatformPermissions -Lease $lease
            if(-not(Test-RepositoryTransactionDisplacedMetadataEqual -Actual $readback -Expected $Operation.displacedMetadata)){
                throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction sequence $($Operation.sequence) restored file bytes but not the exact prepared security metadata; evidence was retained.")
            }
        }finally{$lease.Dispose()}
    }finally{$parentLease.Dispose()}
}

function Test-RepositoryTransactionObservedAfterEqual {
    param([AllowNull()][object]$Actual,[AllowNull()][object]$Expected)
    if($null-eq$Expected){return $true}
    if($null-eq$Actual-or[bool]$Actual.readOnly-ne[bool]$Expected.readOnly){return $false}
    return [CodexAiInstructions.NativeFileMutation]::DaclEquals(
        (ConvertFrom-FileDaclJournalRecord $Actual.dacl),
        (ConvertFrom-FileDaclJournalRecord $Expected.dacl))
}

function Get-RepositoryTransactionDirectoryAnchorState {
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    $path=Join-Path ([string]$Journal.scope.repositoryRoot) ([string]$Operation.target.value).Replace('/',[IO.Path]::DirectorySeparatorChar)
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject][ordered]@{exists=$false;identity=$null;permissions=$null}}
    $item=Get-Item -Force -LiteralPath $path
    if(-not$item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Repository transaction directory anchor is not a physical directory: $path"}
    $lease=Open-PlatformDirectory -Root $path -RootOnly
    try{return [pscustomobject][ordered]@{exists=$true;identity=(ConvertTo-ProjectPublicationIdentity $lease.Observation);permissions=(Get-PlatformPermissions -Lease $lease)}}
    finally{$lease.Dispose()}
}

function Get-RepositoryGitRefState {
    param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$Reference)
    $lines=@(Invoke-Git -Repository $Repository -Arguments @('for-each-ref','--format=%(refname)%09%(objectname)','--',$Reference)|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
    $matches=@($lines|ForEach-Object{
        $match=[regex]::Match(([string]$_).Trim(),'^(?<Reference>[^\t]+)\t(?<ObjectId>[0-9a-fA-F]+)$')
        if(-not$match.Success){throw "git for-each-ref returned an invalid ref state record for ${Reference}: $_"}
        if($match.Groups['Reference'].Value-ceq$Reference){$match.Groups['ObjectId'].Value.ToLowerInvariant()}
    })
    if($matches.Count-eq0){return [pscustomobject][ordered]@{exists=$false;objectId=$null}}
    if($matches.Count-ne1){throw "git for-each-ref returned multiple state records for $Reference."}
    return [pscustomobject][ordered]@{exists=$true;objectId=[string]$matches[0]}
}

function Get-RepositoryTransactionGitRefState {
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    return Get-RepositoryGitRefState -Repository ([string]$Journal.scope.repositoryRoot) -Reference ([string]$Operation.target.value)
}

function Get-RepositoryStashRefState {
    param([Parameter(Mandatory=$true)][string]$Repository)
    return Get-RepositoryGitRefState -Repository $Repository -Reference 'refs/stash'
}

function Invoke-RepositoryStashRefCompareAndSwap {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][object]$Expected,
        [string]$NewObjectId,
        [string]$ReflogMessage
    )
    $objectLength=if(((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--show-object-format'))|Select-Object -First 1).Trim()-ceq'sha256'){64}else{40}
    $expectedObjectId=if([bool]$Expected.exists){[string]$Expected.objectId}else{'0'*$objectLength}
    if([string]::IsNullOrWhiteSpace($NewObjectId)){
        if(-not[bool]$Expected.exists){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'PersonalAgent evidence reuse cannot CAS an absent refs/stash value.')}
        $arguments=@('update-ref','refs/stash',$expectedObjectId,$expectedObjectId)
    }else{
        $arguments=@('update-ref','--create-reflog','-m',$ReflogMessage,'refs/stash',$NewObjectId,$expectedObjectId)
    }
    try{Invoke-Git -Repository $Repository -Arguments $arguments|Out-Null}
    catch{
        $updateException=$_.Exception
        $current=$null;$readException=$null
        try{$current=Get-RepositoryStashRefState -Repository $Repository}catch{$readException=$_.Exception}
        if($null-eq$readException){
            $stashChanged=if([bool]$Expected.exists){-not[bool]$current.exists-or[string]$current.objectId-cne$expectedObjectId}else{[bool]$current.exists}
            if($stashChanged){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'PersonalAgent evidence refused because refs/stash changed after the prepared decision.' -InnerException $updateException)}
        }
        $readFailureDetail=if($null-ne$readException){" The refs/stash readback also failed: $($readException.Message)"}else{''}
        throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "PersonalAgent evidence git update-ref refs/stash write failed. $($updateException.Message)$readFailureDetail" -InnerException $updateException)
    }
    $expectedAfter=if([string]::IsNullOrWhiteSpace($NewObjectId)){$expectedObjectId}else{$NewObjectId}
    $readback=Get-RepositoryStashRefState -Repository $Repository
    if(-not[bool]$readback.exists-or[string]$readback.objectId-cne$expectedAfter){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'PersonalAgent evidence refs/stash CAS readback differs from the expected object ID.')}
}

function Get-RepositoryTransactionEvidenceStashState {
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    $commitId=[string]$Operation.after.objectId
    $exists=@(Invoke-Git -Repository ([string]$Journal.scope.repositoryRoot) -Arguments @('stash','list','--format=%H')|Where-Object{([string]$_).Trim()-ceq$commitId}).Count-gt0
    return [pscustomobject][ordered]@{exists=$exists;objectId=$commitId}
}

function Get-RepositoryHeadQueryState {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $symbolicExitCode=Get-GitExitCode -Repository $Repository -Arguments @('symbolic-ref','-q','HEAD')
    if($symbolicExitCode-eq0){$reference=((Invoke-Git -Repository $Repository -Arguments @('symbolic-ref','-q','HEAD'))|Select-Object -First 1).Trim()}
    elseif($symbolicExitCode-eq1){$reference=$null}
    else{
        Invoke-Git -Repository $Repository -Arguments @('symbolic-ref','-q','HEAD')|Out-Null
        throw "git symbolic-ref -q HEAD failed with exit code $symbolicExitCode."
    }
    $objectExitCode=Get-GitExitCode -Repository $Repository -Arguments @('rev-parse','--verify','--quiet','HEAD')
    if($objectExitCode-eq0){$objectId=((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--verify','--quiet','HEAD'))|Select-Object -First 1).Trim()}
    elseif($objectExitCode-eq1){$objectId=$null}
    else{
        Invoke-Git -Repository $Repository -Arguments @('rev-parse','--verify','--quiet','HEAD')|Out-Null
        throw "git rev-parse --verify --quiet HEAD failed with exit code $objectExitCode."
    }
    return [pscustomobject][ordered]@{reference=$reference;objectId=$objectId}
}

function Get-RepositoryTransactionHeadState {
    param([Parameter(Mandatory=$true)][object]$Journal)
    $repository=[string]$Journal.scope.repositoryRoot;$headPath=Join-Path ([string]$Journal.scope.gitDirectory) 'HEAD'
    $raw=Get-ByteArraySha256 ([IO.File]::ReadAllBytes($headPath))
    $head=Get-RepositoryHeadQueryState -Repository $repository;$reference=$head.reference;$objectId=$head.objectId
    $mode=if($null-ne$reference){if($null-eq$objectId){'unborn'}else{'symbolic'}}else{'detached'}
    return [pscustomobject][ordered]@{mode=$mode;reference=$reference;objectId=$objectId;rawSha256=$raw}
}

function Get-RepositoryGitVersion {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $line=((Invoke-Git -Repository $Repository -Arguments @('--version'))|Select-Object -First 1).Trim()
    $match=[regex]::Match($line,'(?i)^git version (?<Major>[0-9]+)\.(?<Minor>[0-9]+)(?:\.(?<Patch>[0-9]+))?')
    if(-not$match.Success){throw (New-AiInstructionsRefusalException -Code 'capability-unavailable' -Message "Detached HEAD remediation requires Git >= 2.46 for atomic symbolic-ref CAS, but the installed Git version could not be parsed: $line")}
    return [version]::new([int]$match.Groups['Major'].Value,[int]$match.Groups['Minor'].Value,$(if($match.Groups['Patch'].Success){[int]$match.Groups['Patch'].Value}else{0}))
}

function Get-RepositoryHeadState {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $head=Get-RepositoryHeadQueryState -Repository $Repository
    if($null-ne$head.reference){return [pscustomobject][ordered]@{mode='symbolic';reference=$head.reference;objectId=$null}}
    return [pscustomobject][ordered]@{mode='detached';reference=$null;objectId=$head.objectId}
}

function Set-RepositoryDetachedHeadSymbolicCompareAndSwap {
    param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$ExpectedObjectId,[Parameter(Mandatory=$true)][string]$NewReference)
    $gitVersion=Get-RepositoryGitVersion -Repository $Repository
    if($gitVersion-lt[version]'2.46.0'){throw (New-AiInstructionsRefusalException -Code 'capability-unavailable' -Message "Detached HEAD remediation requires Git >= 2.46 because changing detached HEAD to a symbolic ref must use an atomic symref CAS and must not overwrite an external HEAD change. Installed: $gitVersion")}
    $commands=@('start',"symref-update HEAD $NewReference oid $ExpectedObjectId",'prepare','commit')
    try{Invoke-Git -Repository $Repository -Arguments @('update-ref','--stdin') -StandardInputLines $commands|Out-Null}
    catch{
        if((Get-AiInstructionsRefusalCode $_)-ceq'capability-unavailable'){throw}
        $updateException=$_.Exception
        $current=$null;$readException=$null
        try{$current=Get-RepositoryHeadState -Repository $Repository}catch{$readException=$_.Exception}
        if($null-eq$readException-and([string]$current.mode-cne'detached'-or[string]$current.objectId-cne$ExpectedObjectId)){
            throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'Detached HEAD atomic symbolic-ref CAS refused because HEAD changed after observation; the external HEAD state was preserved.' -InnerException $updateException)
        }
        $readFailureDetail=if($null-ne$readException){" The HEAD readback also failed: $($readException.Message)"}else{''}
        throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Detached HEAD git update-ref --stdin symbolic-ref CAS write failed. $($updateException.Message)$readFailureDetail" -InnerException $updateException)
    }
}

function Get-RepositoryTransactionIndexEntrySetSha256 {
    param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$IndexPath)
    $had=Test-Path Env:GIT_INDEX_FILE;$prior=$env:GIT_INDEX_FILE
    try{$env:GIT_INDEX_FILE=$IndexPath;$lines=@(Invoke-Git -Repository $Repository -Arguments @('ls-files','--stage'))|Sort-Object -CaseSensitive;return Get-ByteArraySha256 ([Text.UTF8Encoding]::new($false).GetBytes((($lines-join"`n")+"`n")))}
    finally{if($had){$env:GIT_INDEX_FILE=$prior}else{Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue}}
}

function Get-RepositoryTransactionIndexState {
    param([Parameter(Mandatory=$true)][object]$Journal)
    $path=[string]$Journal.scope.indexPath;$parent=[IO.Path]::GetDirectoryName($path);$leaf=[IO.Path]::GetFileName($path);$lease=Open-PlatformDirectory -Root $parent -RootOnly
    try{$state=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath $path -PlatformOs ([string]$Journal.platform.os)}finally{$lease.Dispose()}
    return [pscustomobject][ordered]@{exists=[bool]$state.exists;sha256=$state.sha256;length=$state.length;identity=$state.identity;entrySetSha256=$(if($state.exists){Get-RepositoryTransactionIndexEntrySetSha256 -Repository ([string]$Journal.scope.repositoryRoot) -IndexPath $path}else{$null})}
}

function Test-RepositoryTransactionIndexStateEqual {
    param([Parameter(Mandatory=$true)][object]$Actual,[Parameter(Mandatory=$true)][object]$Expected)
    return [bool]$Actual.exists-eq[bool]$Expected.exists-and
        (-not[bool]$Expected.exists-or(
            [string]$Actual.sha256-ceq[string]$Expected.sha256-and
            [int64]$Actual.length-eq[int64]$Expected.length-and
            [string]$Actual.entrySetSha256-ceq[string]$Expected.entrySetSha256))
}

function New-RepositoryIndexLockRefusal {
    param([Parameter(Mandatory=$true)][string]$Reason,[Parameter(Mandatory=$true)][string]$LockPath)
    return New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "$Reason Confirm that no other Git process is running, then inspect the Git index and remove '$LockPath' manually only when it is safe to do so."
}

function Get-RepositoryIndexLockRollForwardDecision {
    param([Parameter(Mandatory=$true)][object]$Journal)
    $lockPath=([string]$Journal.scope.indexPath)+'.lock'
    if(-not(Test-Path -LiteralPath $lockPath)){return $null}
    if(-not(Test-Path -LiteralPath $lockPath -PathType Leaf)-or(Get-Item -Force -LiteralPath $lockPath).Attributes-band[IO.FileAttributes]::ReparsePoint){throw (New-RepositoryIndexLockRefusal -Reason 'The residual Git index.lock is not a regular file owned by this transaction.' -LockPath $lockPath)}
    if([string]$Journal.phase-cnotin@('prepared','applying','applied','committed')){throw (New-RepositoryIndexLockRefusal -Reason "The residual Git index.lock cannot belong to a repository transaction in phase '$($Journal.phase)'." -LockPath $lockPath)}
    $indexOperations=@($Journal.operations|Where-Object{[string]$_.kind-ceq'replace-git-index'})
    if($indexOperations.Count-gt1){throw (New-RepositoryIndexLockRefusal -Reason 'A residual Git index.lock exists with more than one journaled index step.' -LockPath $lockPath)}
    try{[byte[]]$bytes=[IO.File]::ReadAllBytes($lockPath)}catch{throw (New-RepositoryIndexLockRefusal -Reason "The residual Git index.lock could not be read: $($_.Exception.Message)" -LockPath $lockPath)}
    $sha256=Get-ByteArraySha256 $bytes;$preparedSha256=[string]$Journal.scope.indexLockContentSha256
    if($indexOperations.Count-eq0){
        if($sha256-ceq$preparedSha256){return [pscustomobject][ordered]@{LockPath=$lockPath;IndexPath=[string]$Journal.scope.indexPath;Operation=$null;Destination=$null;DestinationSha256=$preparedSha256;Direction='prefill'}}
        throw (New-RepositoryIndexLockRefusal -Reason 'The residual Git index.lock bytes do not match the prepared lock-content SHA recorded by this transaction.' -LockPath $lockPath)
    }
    $operation=$indexOperations[0]
    if($sha256-ceq[string]$operation.after.sha256){return [pscustomobject][ordered]@{LockPath=$lockPath;IndexPath=[string]$Journal.scope.indexPath;Operation=$operation;Destination=$operation.after;DestinationSha256=[string]$operation.after.sha256;Direction='redo'}}
    if($sha256-ceq[string]$operation.before.sha256-or$sha256-ceq$preparedSha256){return [pscustomobject][ordered]@{LockPath=$lockPath;IndexPath=[string]$Journal.scope.indexPath;Operation=$operation;Destination=$operation.before;DestinationSha256=[string]$operation.before.sha256;Direction='undo'}}
    throw (New-RepositoryIndexLockRefusal -Reason 'The residual Git index.lock bytes do not match the prepared lock-content SHA or either index write-ahead SHA recorded by this transaction.' -LockPath $lockPath)
}

function Complete-RepositoryIndexLockRollForward {
    param([Parameter(Mandatory=$true)][object]$Journal)
    $decision=Get-RepositoryIndexLockRollForwardDecision -Journal $Journal
    if($null-eq$decision){return $null}
    try{Move-Item -LiteralPath $decision.LockPath -Destination $decision.IndexPath -Force}
    catch{throw (New-RepositoryIndexLockRefusal -Reason "The residual Git index.lock could not be rolled forward to the Git index: $($_.Exception.Message)" -LockPath $decision.LockPath)}
    $readback=Get-RepositoryTransactionIndexState $Journal
    if($null-ne$decision.Destination){$matches=Test-RepositoryTransactionIndexStateEqual $readback $decision.Destination}else{$matches=[string]$readback.sha256-ceq[string]$decision.DestinationSha256}
    if(-not$matches){throw (New-RepositoryIndexLockRefusal -Reason 'The Git index readback differs from the journaled lock destination after roll-forward.' -LockPath $decision.LockPath)}
    return $decision
}

function Resolve-RepositoryRecoveryIndexLock {
    param([Parameter(Mandatory=$true)][object]$Context)
    if($null-ne$Context.RepositoryIndexLock-and$null-ne$Context.RepositoryIndexLock.Stream){return}
    $lockPath=([string]$Context.CurrentJournal.scope.indexPath)+'.lock'
    if(Test-Path -LiteralPath $lockPath){Complete-RepositoryIndexLockRollForward -Journal $Context.CurrentJournal|Out-Null}
    try{
        $reacquired=Open-RepositoryIndexTransactionLock -Repository ([string]$Context.Repository)
        if($null-eq$Context.RepositoryIndexLock){$Context.RepositoryIndexLock=$reacquired}
        else{$Context.RepositoryIndexLock.Stream=$reacquired.Stream;$Context.RepositoryIndexLock.Path=$reacquired.Path;$Context.RepositoryIndexLock.IndexPath=$reacquired.IndexPath;$Context.RepositoryIndexLock.ContentSha256=$reacquired.ContentSha256}
    }
    catch{throw (New-RepositoryIndexLockRefusal -Reason "The repository recovery could not acquire the long Git index lock before undo or redo: $($_.Exception.Message)" -LockPath $lockPath)}
}

function Invoke-RepositoryIndexReplacement {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation,[Parameter(Mandatory=$true)][object]$Source,[Parameter(Mandatory=$true)][object]$Destination,[Parameter(Mandatory=$true)][ValidateSet('redo','undo')][string]$Direction)
    $indexPath=[string]$Journal.scope.indexPath;$lockPath=$indexPath+'.lock'
    if($null-eq$Context.RepositoryIndexLock-or$null-eq$Context.RepositoryIndexLock.Stream){throw (New-RepositoryIndexLockRefusal -Reason 'The repository transaction no longer owns the long Git index lock.' -LockPath $lockPath)}
    $artifactLeaf=if($Direction-ceq'redo'){[string]$Operation.stageLeaf}else{[string]$Operation.backupLeaf}
    $artifact=Open-PlatformFile -ParentLease $Context.Lease -Leaf $artifactLeaf -Access Read -CreateMode OpenExisting
    try{[byte[]]$bytes=$artifact.ReadAllBytes(536870912)}finally{$artifact.Dispose()}
    if((Get-ByteArraySha256 $bytes)-cne[string]$Destination.sha256-or[long]$bytes.Length-ne[long]$Destination.length){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction index artifact '$artifactLeaf' differs from its write-ahead state.")}
    $live=Get-RepositoryTransactionIndexState $Journal
    if(Test-RepositoryTransactionIndexStateEqual $live $Destination){return}
    if(-not(Test-RepositoryTransactionIndexStateEqual $live $Source)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'The Git index changed before index.lock publication; transaction evidence was retained.')}
    $stream=$Context.RepositoryIndexLock.Stream
    try{
        $stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null;$Context.RepositoryIndexLock.Stream=$null
        Invoke-AiInstructionsInstallFailpoint -Name 'after-index-lock-write-before-rename'
        $live=Get-RepositoryTransactionIndexState $Journal
        if(-not(Test-RepositoryTransactionIndexStateEqual $live $Source)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'The Git index changed after index.lock was flushed; transaction evidence was retained.')}
        Move-Item -LiteralPath $lockPath -Destination $indexPath -Force
        Invoke-AiInstructionsInstallFailpoint -Name 'after-index-rename-before-reacquire'
        try{$reacquired=Open-RepositoryIndexTransactionLock -Repository ([string]$Context.Repository);$Context.RepositoryIndexLock.Stream=$reacquired.Stream;$Context.RepositoryIndexLock.ContentSha256=$reacquired.ContentSha256}
        catch{throw (New-RepositoryIndexLockRefusal -Reason "The transaction could not reacquire the long Git index lock after index publication: $($_.Exception.Message)" -LockPath $lockPath)}
    }finally{if($null-ne$stream){$stream.Dispose();$Context.RepositoryIndexLock.Stream=$null}}
}

function Test-RepositoryTransactionStateEqual {
    param([Parameter(Mandatory=$true)][object]$Operation,[Parameter(Mandatory=$true)][object]$Actual,[Parameter(Mandatory=$true)][object]$Expected)
    switch([string]$Operation.kind){
        'update-git-ref'{return [bool]$Actual.exists-eq[bool]$Expected.exists-and(-not$Expected.exists-or[string]$Actual.objectId-ceq[string]$Expected.objectId)}
        'store-git-stash-evidence'{return [bool]$Actual.exists-eq[bool]$Expected.exists-and[string]$Actual.objectId-ceq[string]$Expected.objectId}
        'update-git-head'{return [string]$Actual.mode-ceq[string]$Expected.mode-and[string]$Actual.reference-ceq[string]$Expected.reference-and[string]$Actual.objectId-ceq[string]$Expected.objectId-and[string]$Actual.rawSha256-ceq[string]$Expected.rawSha256}
        'ensure-directory-anchor'{if([bool]$Actual.exists-ne[bool]$Expected.exists){return $false};if(-not$Expected.exists){return $true};return [string]$Actual.identity.kind-ceq[string]$Expected.identity.kind-and[string]::Equals([string]$Actual.identity.device,[string]$Expected.identity.device,[StringComparison]::OrdinalIgnoreCase)-and[string]::Equals([string]$Actual.identity.fileId,[string]$Expected.identity.fileId,[StringComparison]::OrdinalIgnoreCase)}
        'replace-git-index'{return Test-RepositoryTransactionIndexStateEqual $Actual $Expected}
        default{return Test-ProjectPublicationStateEqual $Actual $Expected}
    }
}

function Get-RepositoryTransactionOperationState {
    param([Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation)
    switch([string]$Operation.kind){
        'replace-git-index'{return Get-RepositoryTransactionIndexState $Journal}
        'update-git-ref'{return Get-RepositoryTransactionGitRefState $Journal $Operation}
        'store-git-stash-evidence'{return Get-RepositoryTransactionEvidenceStashState $Journal $Operation}
        'update-git-head'{return Get-RepositoryTransactionHeadState $Journal}
        'ensure-directory-anchor'{return Get-RepositoryTransactionDirectoryAnchorState $Journal $Operation}
        default{return Get-RepositoryTransactionFileState $Journal $Operation}
    }
}

function Invoke-RepositoryTransactionOperation {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][object]$Journal,[Parameter(Mandatory=$true)][object]$Operation,[Parameter(Mandatory=$true)][ValidateSet('redo','undo')][string]$Direction)
    if([string]$Operation.kind-ceq'store-git-stash-evidence'-and$Direction-ceq'undo'){return}
    $source=if($Direction-ceq'redo'){$Operation.before}else{$Operation.after};$destination=if($Direction-ceq'redo'){$Operation.after}else{$Operation.before}
    $current=Get-RepositoryTransactionOperationState $Journal $Operation
    $requiresEvidenceReuseCas=$Direction-ceq'redo'-and[string]$Operation.kind-ceq'update-git-ref'-and[string]$Operation.role-ceq'personal-agent-evidence-cas'
    if((Test-RepositoryTransactionStateEqual $Operation $current $destination)-and-not$requiresEvidenceReuseCas){
        if($Direction-ceq'redo'){return [pscustomobject][ordered]@{ObservedAfter=(Get-RepositoryTransactionObservedAfter -Journal $Journal -Operation $Operation);DisplacedAfterMetadata=$null}}
        Restore-RepositoryTransactionDisplacedMetadata -Journal $Journal -Operation $Operation
        return
    }
    if(-not(Test-RepositoryTransactionStateEqual $Operation $current $source)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction sequence $($Operation.sequence) role $($Operation.role) target $($Operation.target.value) is in a third state; evidence was retained for manual inspection and cleanup.")}
    if($Direction-ceq'undo'-and[string]$Operation.kind-cin@('create-file','write-file')-and$null-ne$Operation.observedAfter){
        $liveObservedAfter=Get-RepositoryTransactionObservedAfter -Journal $Journal -Operation $Operation
        if(-not(Test-RepositoryTransactionObservedAfterEqual -Actual $liveObservedAfter -Expected $Operation.observedAfter)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction sequence $($Operation.sequence) role $($Operation.role) target $($Operation.target.value) is in a third state; evidence was retained for manual inspection and cleanup.")}
    }
    $repository=[string]$Journal.scope.repositoryRoot
    if($Direction-ceq'redo'-and[string]$Operation.role-ceq'manifest'-and[string]$Operation.kind-cin@('create-file','write-file')){
        $manifestStagePath=Join-Path (Get-RepositoryTransactionPath -Context $Context) ([string]$Operation.stageLeaf)
        try{$manifestDocument=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($manifestStagePath))|ConvertFrom-Json -ErrorAction Stop}
        catch{throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill manifest publication refused because the staged manifest could not be decoded: $($_.Exception.Message)" -InnerException $_.Exception)}
        if($null-eq$manifestDocument-or$null-eq$manifestDocument.PSObject.Properties['files']){throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project Skill manifest publication refused because the staged manifest has no files inventory.')}
        $publishedTargetPaths=@($Journal.operations|Where-Object{[string]$_.kind-cin@('create-file','write-file')-and[string]$_.target.kind-ceq'repository-relative'}|ForEach-Object{[string]$_.target.value})
        $planningObservations=if($null-ne$Context.PSObject.Properties['PlanningObservations']){$Context.PlanningObservations}else{$null}
        Assert-ProjectSkillManifestFilesCurrent -TargetRoot $repository -ManifestEntries @($manifestDocument.files) -PublishedTargetPaths $publishedTargetPaths -PlanningObservations $planningObservations
    }
    switch([string]$Operation.kind){
        {$_-in@('create-file','write-file','remove-file')} {
            $path=if([string]$Operation.target.kind-ceq'git-shared-exclude'){[string]$Operation.target.value}else{Join-Path $repository ([string]$Operation.target.value).Replace('/',[IO.Path]::DirectorySeparatorChar)}
            $parent=[IO.Path]::GetDirectoryName($path);$leaf=[IO.Path]::GetFileName($path)
            try{$parentLease=Open-PlatformDirectory -Root $parent -RootOnly}
            catch{
                if($Direction-ceq'redo'-and[string]$Operation.kind-cne'remove-file'-and[string]$Operation.target.kind-ceq'repository-relative'){
                    $relativeParent=(Split-Path -Parent ([string]$Operation.target.value)).Replace('\','/').Trim('/')
                    $legacyStage=if([string]::IsNullOrWhiteSpace($relativeParent)){'.syp214-'+[guid]::NewGuid().ToString('N')+'-stage'}else{$relativeParent+'/.syp214-'+[guid]::NewGuid().ToString('N')+'-stage'}
                    throw "Managed publication staging could not acquire the handle-bound create stream; no external path was changed: $legacyStage. A guarded managed directory path is not a directory. $($_.Exception.Message)"
                }
                throw
            }
            try{
                if($Direction-ceq'redo'){
                    if([string]$Operation.kind-ceq'remove-file'){Remove-PlatformOwnedFile -ParentLease $parentLease -Leaf $leaf -ExpectedState $Operation.before -TransactionLease $Context.Lease -TombstoneLeaf ([string]$Operation.backupLeaf)|Out-Null}
                    else{$stageLease=Open-PlatformFile -ParentLease $Context.Lease -Leaf ([string]$Operation.stageLeaf) -Access ReadWrite -CreateMode OpenExisting;try{$p=@{ParentLease=$parentLease;Leaf=$leaf;TransactionLease=$Context.Lease;StageLease=$stageLease;ExpectedState=$Operation.before;ExpectedStage=$Operation.after};if([string]$Operation.kind-ceq'create-file'){$p.NoReplace=$true}else{$p.DisplacedLeaf=[string]$Operation.backupLeaf};Publish-PlatformFile @p|Out-Null}finally{$stageLease.Dispose()}}
                }else{
                    if([string]$Operation.kind-ceq'create-file'){Remove-PlatformOwnedFile -ParentLease $parentLease -Leaf $leaf -ExpectedState $Operation.after -TransactionLease $Context.Lease -TombstoneLeaf ([string]$Operation.stageLeaf)|Out-Null}
                    else{$backupLease=Open-PlatformFile -ParentLease $Context.Lease -Leaf ([string]$Operation.backupLeaf) -Access ReadWrite -CreateMode OpenExisting;try{$p=@{ParentLease=$parentLease;Leaf=$leaf;TransactionLease=$Context.Lease;StageLease=$backupLease;ExpectedState=$Operation.after;ExpectedStage=$Operation.before};if([string]$Operation.kind-ceq'remove-file'){$p.NoReplace=$true}else{$p.DisplacedLeaf=[string]$Operation.stageLeaf};Publish-PlatformFile @p|Out-Null}finally{$backupLease.Dispose()};Restore-RepositoryTransactionDisplacedMetadata -Journal $Journal -Operation $Operation}
                }
            }finally{$parentLease.Dispose()}
        }
        'ensure-directory-anchor' {
            $relative=[string]$Operation.target.value;$parentRelative=(Split-Path -Parent $relative).Replace('\','/');$leaf=Split-Path -Leaf $relative;$parentLease=if([string]::IsNullOrWhiteSpace($parentRelative)){Open-PlatformDirectory -Root $repository -RootOnly}else{Open-PlatformDirectory -Root $repository -RelativePath $parentRelative}
            try{
                if($Direction-ceq'redo'){Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf ([string]$Operation.stageLeaf) -TransactionLease $Context.Lease -DestinationLeaf $leaf -ExpectedIdentity $Operation.after.identity -Direction FromTransaction|Out-Null}
                else{
                    $anchorPath=Join-Path $repository $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
                    if(@(Get-ChildItem -Force -LiteralPath $anchorPath).Count-gt0){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction directory anchor '$relative' is not empty after descendant rollback; unknown content was preserved.")}
                    Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf $leaf -TransactionLease $Context.Lease -DestinationLeaf ([string]$Operation.stageLeaf) -ExpectedIdentity $Operation.after.identity -Direction ToTransaction|Out-Null
                }
            }finally{$parentLease.Dispose()}
        }
        'replace-git-index' {
            Invoke-RepositoryIndexReplacement -Context $Context -Journal $Journal -Operation $Operation -Source $source -Destination $destination -Direction $Direction
        }
        'update-git-ref' {
            if([string]$Operation.role-ceq'personal-agent-evidence-cas'){Invoke-RepositoryStashRefCompareAndSwap -Repository $repository -Expected $source}
            else{
                $ref=[string]$Operation.target.value;$from=$source.objectId;$to=$destination.objectId
                if(-not[bool]$source.exists){Invoke-Git -Repository $repository -Arguments @('update-ref',$ref,$to,('0'*$(if([string]$Journal.scope.objectFormat-ceq'sha256'){64}else{40})))|Out-Null}
                elseif(-not[bool]$destination.exists){Invoke-Git -Repository $repository -Arguments @('update-ref','-d',$ref,$from)|Out-Null}
                else{Invoke-Git -Repository $repository -Arguments @('update-ref',$ref,$to,$from)|Out-Null}
            }
        }
        'update-git-head' {
            if([string]$destination.mode-ceq'detached'){Invoke-Git -Repository $repository -Arguments @('update-ref','--no-deref','HEAD',[string]$destination.objectId,[string]$source.objectId)|Out-Null}
            else{Set-RepositoryDetachedHeadSymbolicCompareAndSwap -Repository $repository -ExpectedObjectId ([string]$source.objectId) -NewReference ([string]$destination.reference)}
        }
        'store-git-stash-evidence' {
            $subject=((Invoke-Git -Repository $repository -Arguments @('show','--no-patch','--format=%s',[string]$destination.objectId))|Select-Object -First 1).Trim()
            Invoke-RepositoryStashRefCompareAndSwap -Repository $repository -Expected $Operation.before -NewObjectId ([string]$destination.objectId) -ReflogMessage $subject
        }
    }
    $readback=Get-RepositoryTransactionOperationState $Journal $Operation
    if(-not(Test-RepositoryTransactionStateEqual $Operation $readback $destination)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction sequence $($Operation.sequence) readback differs from its journal destination state.")}
    if($Direction-ceq'redo'){return [pscustomobject][ordered]@{ObservedAfter=(Get-RepositoryTransactionObservedAfter -Journal $Journal -Operation $Operation);DisplacedAfterMetadata=(Get-RepositoryTransactionDisplacedAfterMetadata -Context $Context -Operation $Operation)}}
}

function Copy-RepositoryInstallJournal {
    param([Parameter(Mandatory=$true)][object]$Journal,[string]$Phase,[Nullable[long]]$Sequence,[string]$EvidenceObjectId,[AllowNull()][object]$ObservedAfter,[AllowNull()][object]$DisplacedAfterMetadata)
    $document=[ordered]@{}
    foreach($property in @($Journal.PSObject.Properties)){
        if($property.Name-cin@('operations','retainedManifestPaths')){$document[$property.Name]=[object[]]@($property.Value)}
        else{$document[$property.Name]=$property.Value}
    }
    $copy=[pscustomobject]$document
    if(-not[string]::IsNullOrEmpty($Phase)){$copy.phase=$Phase}
    if($null-ne$Sequence){
        [object[]]$operations=@($copy.operations)
        $sequenceValue=[int64]$Sequence;$operationIndex=-1
        for($index=0;$index-lt$operations.Count;$index++){if([int64]$operations[$index].sequence-eq$sequenceValue){$operationIndex=$index;break}}
        if($operationIndex-lt0){throw "Repository transaction operation sequence $sequenceValue was not found."}
        if($PSBoundParameters.ContainsKey('EvidenceObjectId')-and[string]$operations[$operationIndex].kind-cne'store-git-stash-evidence'){throw 'Only store-git-stash-evidence may bind after.objectId.'}
        if($PSBoundParameters.ContainsKey('ObservedAfter')-and[string]$operations[$operationIndex].kind-cnotin@('create-file','write-file')){throw 'Only a published file operation may bind observedAfter.'}
        if($PSBoundParameters.ContainsKey('DisplacedAfterMetadata')-and([string]$operations[$operationIndex].kind-cnotin@('write-file','remove-file')-or$null-eq$DisplacedAfterMetadata)){throw 'Only a displacing file operation may bind a non-null displacedAfterMetadata.'}
        $operationDocument=[ordered]@{}
        foreach($property in @($operations[$operationIndex].PSObject.Properties)){
            if($property.Name-ceq'state'){$operationDocument[$property.Name]='applied';continue}
            if($property.Name-ceq'after'-and$PSBoundParameters.ContainsKey('EvidenceObjectId')){$operationDocument[$property.Name]=[pscustomobject][ordered]@{exists=$true;objectId=$EvidenceObjectId};continue}
            if($property.Name-ceq'observedAfter'-and$PSBoundParameters.ContainsKey('ObservedAfter')){$operationDocument[$property.Name]=$ObservedAfter;continue}
            if($property.Name-ceq'displacedAfterMetadata'-and$PSBoundParameters.ContainsKey('DisplacedAfterMetadata')){$operationDocument[$property.Name]=$DisplacedAfterMetadata;continue}
            $operationDocument[$property.Name]=$property.Value
        }
        $operations[$operationIndex]=[pscustomobject]$operationDocument
        $copy.operations=[object[]]$operations
    }
    return $copy
}

function Write-RepositoryInstallJournalGeneration {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][object]$Next)
    $previous=$Context.CurrentJournal
    $Context.CurrentJournal=Write-AiInstructionsInstallJournalStore -TransactionLease $Context.Lease -TransactionPath (Get-RepositoryTransactionPath -Context $Context) -Journal $Next -PreviousJournal $previous -PlatformOs ([string]$Next.platform.os) -JournalStoreStates $Context.JournalStoreStates
}

function Invoke-RepositoryTransactionEvidenceStashStore {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][string]$EvidenceCommit)
    if(-not[bool]$Context.Durable-or[string]$Context.CurrentJournal.phase-cne'applying'){throw 'PersonalAgent evidence can only be stored by an applying durable repository transaction.'}
    if($EvidenceCommit-cnotmatch'^[0-9a-f]{40,64}$'){throw 'PersonalAgent evidence commit ID is invalid.'}
    $evidenceOperations=@($Context.CurrentJournal.operations|Where-Object{[string]$_.kind-ceq'store-git-stash-evidence'})
    if($evidenceOperations.Count-ne1){throw 'The prepared repository transaction must contain exactly one PersonalAgent evidence operation before stash store.'}
    $operation=$evidenceOperations[0];$sequence=[int64]$operation.sequence
    if([string]$operation.state-cne'pending'-or$null-ne$operation.after.objectId){throw 'The prepared PersonalAgent evidence operation has already been bound.'}
    Invoke-AiInstructionsInstallFailpoint -Name ("before-operation-"+$sequence)
    $subject=((Invoke-Git -Repository ([string]$Context.Repository) -Arguments @('show','--no-patch','--format=%s',$EvidenceCommit))|Select-Object -First 1).Trim()
    Invoke-RepositoryStashRefCompareAndSwap -Repository ([string]$Context.Repository) -Expected $operation.before -NewObjectId $EvidenceCommit -ReflogMessage $subject
    if(@(Invoke-Git -Repository ([string]$Context.Repository) -Arguments @('stash','list','--format=%H')|Where-Object{([string]$_).Trim()-ceq$EvidenceCommit}).Count-eq0){throw 'The newly stored PersonalAgent evidence commit was not found in stash history.'}
    Invoke-AiInstructionsInstallFailpoint -Name ("after-operation-"+$sequence+"-before-journal")
    Write-RepositoryInstallJournalGeneration $Context (Copy-RepositoryInstallJournal $Context.CurrentJournal -Sequence $sequence -EvidenceObjectId $EvidenceCommit)
    Invoke-AiInstructionsInstallFailpoint -Name ("after-operation-"+$sequence)
}

function Add-RemediationFileIntents {
    param([Parameter(Mandatory=$true)][object]$Context)
    $remediation=$Context.Remediation;if($null-eq$remediation){return}
    $pathComparer=Get-GitPathComparer -Repository $Context.Repository
    foreach($relative in @($remediation.MutationPaths)){
        $key="repository`0$($Context.Repository)`0$relative"
        $existingIntent=@($Context.Intents.Values|Where-Object{
            [string]$_.TargetKind-ceq'repository'-and
            $pathComparer.Equals([string]$_.TargetRoot,[string]$Context.Repository)-and
            $pathComparer.Equals([string]$_.RelativePath,[string]$relative)
        }|Select-Object -First 1)
        if($existingIntent.Count-eq1){$existingIntent[0].Role='remediation-and-instruction';continue}
        $entry=@($remediation.Backup.Inventory|Where-Object{[string]$_.path-ceq[string]$relative})[0]
        if($null-eq$entry-or-not[bool]$entry.exists){continue}
        $full=Join-Path $Context.Repository ([string]$relative).Replace('/',[IO.Path]::DirectorySeparatorChar);$parent=[IO.Path]::GetDirectoryName($full);$leaf=[IO.Path]::GetFileName($full);$lease=Open-PlatformDirectory -Root $parent -RootOnly
        try{$before=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $leaf -LiteralPath $full -PlatformOs (Get-RepositoryTransactionPlatform) -IncludePermissions}finally{$lease.Dispose()}
        $Context.Intents.Add($key,[pscustomobject][ordered]@{TargetKind='repository';TargetRoot=$Context.Repository;RelativePath=[string]$relative;Before=$before;Bytes=$null;Remove=$true;Role='remediation-file'})
    }
}

function New-RepositoryRetainedManifestPathRecords {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][object[]]$Operations)
    $operationTargets=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($operation in @($Operations)){
        if([string]$operation.target.kind-ceq'repository-relative'){[void]$operationTargets.Add([string]$operation.target.value)}
    }
    $records=New-Object System.Collections.Generic.List[object]
    foreach($entry in @($Context.TerminalManifestEntries|Sort-Object targetPath)){
        $targetPath=[string]$entry.targetPath
        if($operationTargets.Contains($targetPath)){continue}
        $observation=$null
        if(-not$Context.PlanningObservations.TryGetValue($targetPath,[ref]$observation)-or$null-eq$observation-or-not[bool]$observation.exists-or$null-ne$observation.unobservable-or
            [string]::IsNullOrWhiteSpace([string]$observation.sha256)-or$null-eq$observation.identity){
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Repository transaction cannot prepare retained manifest authority for '$targetPath' because its planning observation is absent or not a regular file.")
        }
        $records.Add([pscustomobject][ordered]@{targetPath=$targetPath;sha256=[string]$observation.sha256;length=[int64]$observation.length;identity=$observation.identity})
    }
    return [object[]]$records.ToArray()
}

function New-RepositoryInstallOperations {
    param([Parameter(Mandatory=$true)][object]$Context)
    Add-RemediationFileIntents $Context
    $operations=New-Object System.Collections.Generic.List[object];$platform=Get-RepositoryTransactionPlatform;$transactionPath=Get-RepositoryTransactionPath -Context $Context
    $remediation=$Context.Remediation
    if($null-ne$remediation-and$null-ne$remediation.IndexPlan-and[string]$remediation.IndexPlan.BeforeSha256-cne[string]$remediation.IndexPlan.AfterSha256){
        $sequence=$operations.Count+1;$stageLeaf=('op-{0:D6}.stage'-f$sequence);$backupLeaf=('op-{0:D6}.backup'-f$sequence)
        $stage=New-AiInstructionsInstallStageFile -TransactionLease $Context.Lease -Leaf $stageLeaf -Bytes ([byte[]]$remediation.IndexPlan.AfterBytes) -PlatformOs $platform
        $backup=New-AiInstructionsInstallStageFile -TransactionLease $Context.Lease -Leaf $backupLeaf -Bytes ([byte[]]$remediation.IndexPlan.BeforeBytes) -PlatformOs $platform
        $before=[pscustomobject][ordered]@{exists=$true;sha256=$backup.sha256;length=$backup.length;identity=$backup.identity;entrySetSha256=(Get-RepositoryTransactionIndexEntrySetSha256 -Repository $Context.Repository -IndexPath ([string]$remediation.IndexPath))}
        $after=[pscustomobject][ordered]@{exists=$true;sha256=$stage.sha256;length=$stage.length;identity=$stage.identity;entrySetSha256=[string]$remediation.IndexPlan.AfterEntrySetSha256}
        $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind='replace-git-index';role='git-index';method='index-lock-rename';target=[pscustomobject][ordered]@{kind='git-index';value=[string]$remediation.IndexPath};before=$before;after=$after;observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$stageLeaf;backupLeaf=$backupLeaf;quarantineLeaf=$null;state='pending'})
    }
    if($null-ne$remediation-and-not[string]::IsNullOrWhiteSpace([string]$remediation.NewCommit)){
        $sequence=$operations.Count+1;$ref=if([string]::IsNullOrWhiteSpace([string]$remediation.OriginalHeadReference)){[string]$remediation.NewHeadReference}else{[string]$remediation.OriginalHeadReference}
        $before=if([string]::IsNullOrWhiteSpace([string]$remediation.OriginalHeadReference)){[pscustomobject][ordered]@{exists=$false;objectId=$null}}else{[pscustomobject][ordered]@{exists=$true;objectId=[string]$remediation.OriginalHead}}
        $after=[pscustomobject][ordered]@{exists=$true;objectId=[string]$remediation.NewCommit}
        $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind='update-git-ref';role='git-ref';method='update-ref';target=[pscustomobject][ordered]@{kind='git-ref';value=$ref};before=$before;after=$after;observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$null;backupLeaf=$null;quarantineLeaf=$null;state='pending'})
        if([string]::IsNullOrWhiteSpace([string]$remediation.OriginalHeadReference)){
            $sequence=$operations.Count+1;$headPath=Join-Path ([string]$remediation.GitDirectory) 'HEAD';$beforeHead=[pscustomobject][ordered]@{mode='detached';reference=$null;objectId=[string]$remediation.OriginalHead;rawSha256=(Get-ByteArraySha256 ([IO.File]::ReadAllBytes($headPath)))};$afterBytes=[Text.UTF8Encoding]::new($false).GetBytes("ref: $ref`n");$afterHead=[pscustomobject][ordered]@{mode='symbolic';reference=$ref;objectId=[string]$remediation.NewCommit;rawSha256=(Get-ByteArraySha256 $afterBytes)}
            $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind='update-git-head';role='git-head';method='symbolic-ref';target=[pscustomobject][ordered]@{kind='git-head';value='HEAD'};before=$beforeHead;after=$afterHead;observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$null;backupLeaf=$null;quarantineLeaf=$null;state='pending'})
        }
    }
    $missing=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($intent in $Context.Intents.Values){if([string]$intent.TargetKind-cne'repository'){continue};$parent=(Split-Path -Parent ([string]$intent.RelativePath)).Replace('\','/');if([string]::IsNullOrWhiteSpace($parent)){continue};$segments=$parent.Split('/');for($i=1;$i-le$segments.Count;$i++){$relative=[string]::Join('/',[string[]]$segments[0..($i-1)]);if(-not(Test-Path -LiteralPath (Join-Path $Context.Repository $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))){[void]$missing.Add($relative)}}}
    foreach($relative in @($missing|Sort-Object @{Expression={($_.Split('/')).Count}},@{Expression={$_}})){
        $sequence=$operations.Count+1;$stageLeaf=('op-{0:D6}.directory'-f$sequence);$stageLease=Open-PlatformDirectory -Root $transactionPath -RelativePath $stageLeaf -CreatePrivate
        try{$after=[pscustomobject][ordered]@{exists=$true;identity=(ConvertTo-ProjectPublicationIdentity $stageLease.Observation);permissions=(Get-PlatformPermissions -Lease $stageLease)}}finally{$stageLease.Dispose()}
        $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind='ensure-directory-anchor';role='directory-anchor';method='directory-rename';target=[pscustomobject][ordered]@{kind='repository-relative';value=$relative};before=[pscustomobject][ordered]@{exists=$false;identity=$null;permissions=$null};after=$after;observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$stageLeaf;backupLeaf=$null;quarantineLeaf=$null;state='pending'})
    }
    $priority=@{'instruction'=10;'project-skill'=20;'license'=30;'remediation-file'=40;'remediation-and-instruction'=40;'manifest'=90;'shared-exclude'=100}
    foreach($intent in @($Context.Intents.Values|Sort-Object @{Expression={$priority[[string]$_.Role]}},@{Expression={[string]$_.RelativePath}})){
        if($intent.Remove-and-not[bool]$intent.Before.exists){continue}
        if(-not$intent.Remove-and[bool]$intent.Before.exists-and(Get-ByteArraySha256 ([byte[]]$intent.Bytes))-ceq[string]$intent.Before.sha256){continue}
        $sequence=$operations.Count+1;$kind=if($intent.Remove){'remove-file'}elseif($intent.Before.exists){'write-file'}else{'create-file'};$stageLeaf=$null;$backupLeaf=if($kind-ceq'create-file'){$null}else{('op-{0:D6}.backup'-f$sequence)}
        $after=if($intent.Remove){[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null;permissions=$null}}else{$stageLeaf=('op-{0:D6}.stage'-f$sequence);$stage=New-AiInstructionsInstallStageFile -TransactionLease $Context.Lease -Leaf $stageLeaf -Bytes ([byte[]]$intent.Bytes) -PlatformOs $platform;$stageState=Get-AiInstructionsInstallFileState -ParentLease $Context.Lease -Leaf $stageLeaf -LiteralPath (Join-Path $transactionPath $stageLeaf) -PlatformOs $platform -IncludePermissions;[pscustomobject][ordered]@{exists=$true;sha256=$stage.sha256;length=$stage.length;identity=$stage.identity;permissions=$stageState.permissions}}
        $targetKind=if([string]$intent.TargetKind-ceq'git-exclude'){'git-shared-exclude'}else{'repository-relative'};$targetValue=if($targetKind-ceq'git-shared-exclude'){Join-Path ([string]$intent.TargetRoot) ([string]$intent.RelativePath)}else{[string]$intent.RelativePath}
        $displacedMetadata=New-RepositoryTransactionDisplacedMetadataSnapshot -Before $intent.Before -Kind $kind
        $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind=$kind;role=[string]$intent.Role;method=$(if($kind-ceq'remove-file'){'tombstone-rename'}else{'stage-rename'});target=[pscustomobject][ordered]@{kind=$targetKind;value=$targetValue};before=$intent.Before;after=$after;observedAfter=$null;displacedMetadata=$displacedMetadata;displacedAfterMetadata=$null;stageLeaf=$stageLeaf;backupLeaf=$backupLeaf;quarantineLeaf=$null;state='pending'})
    }
    if([bool]$Context.ShouldStorePersonalAgentEvidence){
        $sequence=$operations.Count+1
        $stashBefore=$Context.PersonalAgentEvidenceStashBefore
        if($null-eq$stashBefore){throw 'PersonalAgent evidence store is missing its prepared refs/stash state.'}
        $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind='store-git-stash-evidence';role='personal-agent-evidence';method='stash-store';target=[pscustomobject][ordered]@{kind='git-stash-evidence';value='refs/stash'};before=$stashBefore;after=[pscustomobject][ordered]@{exists=$true;objectId=$null};observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$null;backupLeaf=$null;quarantineLeaf=$null;state='pending'})
    }elseif($operations.Count-gt0-and$null-ne$Context.PersonalAgentEvidenceStashBefore){
        $sequence=$operations.Count+1;$stashBefore=$Context.PersonalAgentEvidenceStashBefore
        $operations.Add([pscustomobject][ordered]@{sequence=$sequence;kind='update-git-ref';role='personal-agent-evidence-cas';method='update-ref';target=[pscustomobject][ordered]@{kind='git-ref';value='refs/stash'};before=$stashBefore;after=$stashBefore;observedAfter=$null;displacedMetadata=$null;displacedAfterMetadata=$null;stageLeaf=$null;backupLeaf=$null;quarantineLeaf=$null;state='pending'})
    }
    return $operations.ToArray()
}

function Start-RepositoryInstallTransaction {
    param([Parameter(Mandatory=$true)][object]$Context)
    if($Context.Durable){return}
    Add-RemediationFileIntents $Context
    $hasRemediationGit=$null-ne$Context.Remediation-and(($null-ne$Context.Remediation.IndexPlan-and[string]$Context.Remediation.IndexPlan.BeforeSha256-cne[string]$Context.Remediation.IndexPlan.AfterSha256)-or-not[string]::IsNullOrWhiteSpace([string]$Context.Remediation.NewCommit))
    $hasFileMutation=@($Context.Intents.Values|Where-Object{($_.Remove-and$_.Before.exists)-or(-not$_.Remove-and((-not$_.Before.exists)-or(Get-ByteArraySha256 ([byte[]]$_.Bytes))-cne[string]$_.Before.sha256))}).Count-gt0
    $hasEvidenceMutation=[bool]$Context.ShouldStorePersonalAgentEvidence
    if(-not$hasRemediationGit-and-not$hasFileMutation-and-not$hasEvidenceMutation){return}
    $activeGitDirectory=Get-RepositoryActiveGitDirectory -Repository $Context.Repository
    if(-not(Test-ProjectPublicationPathEqual -Left $activeGitDirectory -Right ([string]$Context.GitDirectory))){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'The active worktree Git directory changed before repository transaction preparation.')}
    $Context.ContainerLease=Open-PlatformDirectory -Root $Context.GitDirectory -RelativePath '.ai-instructions-txn' -CreatePrivate
    $Context.DirectoryLeaf=$Context.Id
    $Context.Lease=Open-PlatformDirectory -Root $Context.GitDirectory -RelativePath ('.ai-instructions-txn/'+$Context.Id) -CreatePrivate
    $Context.Identity=ConvertTo-ProjectPublicationIdentity $Context.Lease.Observation
    $operations=New-RepositoryInstallOperations $Context
    if(@($operations).Count-eq0){Remove-ProjectPublicationContextEvidence $Context;return}
    [object[]]$retainedManifestPaths=@(New-RepositoryRetainedManifestPathRecords -Context $Context -Operations @($operations))
    $common=((Invoke-Git -Repository $Context.Repository -Arguments @('rev-parse','--git-common-dir'))|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($common)){$common=Join-Path $Context.Repository $common};$common=[IO.Path]::GetFullPath($common)
    $git=Get-RepositoryActiveGitDirectory -Repository $Context.Repository
    $index=((Invoke-Git -Repository $Context.Repository -Arguments @('rev-parse','--git-path','index'))|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $Context.Repository $index};$index=[IO.Path]::GetFullPath($index)
    $rootLease=Open-PlatformDirectory -Root $Context.Repository -RootOnly;try{$rootIdentity=ConvertTo-ProjectPublicationIdentity $rootLease.Observation}finally{$rootLease.Dispose()}
    $backup=$null;if($null-ne$Context.Remediation){$inventoryBytes=[Text.UTF8Encoding]::new($false).GetBytes((($Context.Remediation.Backup.Inventory|ConvertTo-Json -Depth 10 -Compress)));$backup=[pscustomobject][ordered]@{root=[string]$Context.Remediation.Backup.Root;indexSha256=[string]$Context.Remediation.Backup.IndexSha256;inventorySha256=(Get-ByteArraySha256 $inventoryBytes)}}
    $scope=[pscustomobject][ordered]@{kind='repository';repositoryRoot=$Context.Repository;repositoryRootIdentity=$rootIdentity;commonGitDirectory=$common;gitDirectory=$git;indexPath=$index;indexLockContentSha256=[string]$Context.RepositoryIndexLock.ContentSha256;objectFormat=$(if($null-ne$Context.Remediation){[string]$Context.Remediation.ObjectFormat}else{((Invoke-Git -Repository $Context.Repository -Arguments @('rev-parse','--show-object-format'))|Select-Object -First 1).Trim()});externalBackup=$backup}
    $manifestIntent=@($Context.Intents.Values|Where-Object{[string]$_.Role-ceq'manifest'})|Select-Object -First 1;$previous=if($null-ne$manifestIntent-and$manifestIntent.Before.exists){[string]$manifestIntent.Before.sha256}else{$null};$candidate=if($null-ne$manifestIntent-and-not$manifestIntent.Remove){Get-ByteArraySha256 ([byte[]]$manifestIntent.Bytes)}else{Get-ByteArraySha256 ([Text.UTF8Encoding]::new($false).GetBytes(($operations|ConvertTo-Json -Depth 15 -Compress)))}
    $start=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$platform=Get-RepositoryTransactionPlatform
    $journal=New-AiInstructionsInstallJournalV2 -TransactionId $Context.Id -OwnerProcessId $PID -OwnerProcessStartIdentity $start -PlatformOs $platform -PlatformArchitecture (Get-RepositoryTransactionArchitecture) -LockPrimitive $(if($platform-ceq'windows'){'windows-fileshare'}else{'flock'}) -LockLeaf 'bootstrap-ai-instructions.lock' -PreviousBundleSha256 $previous -CandidateBundleSha256 $candidate -Scope $scope -RetainedManifestPaths $retainedManifestPaths -Phase prepared -Operations $operations
    $Context.JournalStoreStates=[ordered]@{'journal.json'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null};'journal.prev'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null};'journal.stage'=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}}
    $Context.CurrentJournal=Write-AiInstructionsInstallJournalStore -TransactionLease $Context.Lease -TransactionPath (Get-RepositoryTransactionPath -Context $Context) -Journal $journal -PlatformOs $platform -JournalStoreStates $Context.JournalStoreStates;$Context.Durable=$true
    Invoke-AiInstructionsInstallFailpoint -Name 'after-journal-prepared'
    Write-RepositoryInstallJournalGeneration $Context (Copy-RepositoryInstallJournal $Context.CurrentJournal -Phase applying)
    foreach($operation in @($Context.CurrentJournal.operations|Where-Object{[string]$_.kind-cne'store-git-stash-evidence'}|Sort-Object sequence)){
        Invoke-AiInstructionsInstallFailpoint -Name ("before-operation-"+$operation.sequence)
        $redoBinding=Invoke-RepositoryTransactionOperation -Context $Context -Journal $Context.CurrentJournal -Operation $operation -Direction redo
        Invoke-AiInstructionsInstallFailpoint -Name ("after-operation-"+$operation.sequence+"-before-journal")
        $copyParameters=@{Journal=$Context.CurrentJournal;Sequence=[int64]$operation.sequence}
        if($IsWindows-and[string]$operation.kind-cin@('create-file','write-file')){$copyParameters.ObservedAfter=$redoBinding.ObservedAfter}
        # Bind the displaced original's post-displacement metadata in the same generation that marks the operation applied.
        if([string]$operation.kind-cin@('write-file','remove-file')){$copyParameters.DisplacedAfterMetadata=if($null-ne$redoBinding.DisplacedAfterMetadata){$redoBinding.DisplacedAfterMetadata}else{Get-RepositoryTransactionDisplacedAfterMetadata -Context $Context -Operation $operation}}
        Write-RepositoryInstallJournalGeneration $Context (Copy-RepositoryInstallJournal @copyParameters)
        Invoke-AiInstructionsInstallFailpoint -Name ("after-operation-"+$operation.sequence)
    }
}

function Assert-RepositoryEvidenceReuseCasOperations {
    param([Parameter(Mandatory=$true)][object]$Context)
    foreach($operation in @($Context.CurrentJournal.operations|Where-Object{[string]$_.kind-ceq'update-git-ref'-and[string]$_.role-ceq'personal-agent-evidence-cas'})){
        Invoke-RepositoryStashRefCompareAndSwap -Repository ([string]$Context.Repository) -Expected $operation.before
    }
}

function Assert-RepositoryTransactionTerminalManifestClosure {
    param([Parameter(Mandatory=$true)][object]$Context)
    $journal=$Context.CurrentJournal
    $manifestPath=Join-Path ([string]$journal.scope.repositoryRoot) $manifestRelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
    $retainedRecords=@($journal.retainedManifestPaths)
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
        if($retainedRecords.Count-eq0){return}
        throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'Repository transaction terminal closure gate found retained manifest authority but no terminal manifest file; transaction evidence was retained.')
    }
    try{$manifestDocument=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($manifestPath))|ConvertFrom-Json -ErrorAction Stop}
    catch{throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction terminal closure gate could not decode the terminal manifest; transaction evidence was retained. $($_.Exception.Message)" -InnerException $_.Exception)}
    if($null-eq$manifestDocument-or$null-eq$manifestDocument.PSObject.Properties['files']){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'Repository transaction terminal closure gate found a manifest without a files inventory; transaction evidence was retained.')}
    $manifestPaths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $usedRetained=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($entry in @($manifestDocument.files)){
        $targetPath=[string]$entry.targetPath
        if([string]::IsNullOrWhiteSpace($targetPath)-or-not$manifestPaths.Add($targetPath)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'Repository transaction terminal closure gate found an invalid or duplicate manifest target path; transaction evidence was retained.')}
        $targetOperations=@($journal.operations|Where-Object{[string]$_.target.kind-ceq'repository-relative'-and[string]$_.target.value-ceq$targetPath})
        if($targetOperations.Count-eq1){
            $operation=$targetOperations[0]
            $current=Get-RepositoryTransactionOperationState $journal $operation
            if(-not(Test-RepositoryTransactionStateEqual $operation $current $operation.after)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction terminal closure gate found operation drift at '$targetPath'; transaction evidence was retained.")}
            continue
        }
        if($targetOperations.Count-ne0){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction terminal closure gate found ambiguous operation authority for '$targetPath'; transaction evidence was retained.")}
        $matches=@($retainedRecords|Where-Object{[string]$_.targetPath-ceq$targetPath})
        if($matches.Count-ne1){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction terminal closure gate found missing or ambiguous retained authority for '$targetPath'; transaction evidence was retained.")}
        $expected=[pscustomobject][ordered]@{exists=$true;sha256=[string]$matches[0].sha256;length=[int64]$matches[0].length;identity=$matches[0].identity;unobservable=$null}
        $actual=Get-ProjectPublicationPathObservation -Repository ([string]$journal.scope.repositoryRoot) -RelativePath $targetPath
        if(-not(Test-ProjectPublicationPathObservationEqual -Actual $actual -Expected $expected)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction terminal closure gate found retained path drift at '$targetPath'; transaction evidence was retained.")}
        [void]$usedRetained.Add($targetPath)
    }
    if($usedRetained.Count-ne$retainedRecords.Count){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'Repository transaction terminal closure gate found retained authority outside the terminal manifest inventory; transaction evidence was retained.')}
}

function Complete-RepositoryInstallTransactionApply {
    param([Parameter(Mandatory=$true)][object]$Context)
    if(-not[bool]$Context.Durable){return}
    if([string]$Context.CurrentJournal.phase-ceq'applied'){return}
    if([string]$Context.CurrentJournal.phase-cne'applying'){throw "Repository transaction cannot complete apply from phase '$($Context.CurrentJournal.phase)'."}
    foreach($operation in $Context.CurrentJournal.operations){$current=Get-RepositoryTransactionOperationState $Context.CurrentJournal $operation;if(-not(Test-RepositoryTransactionStateEqual $operation $current $operation.after)){throw (New-AiInstructionsRefusalException -Code interrupted-install -Message "Repository transaction terminal verification failed for sequence $($operation.sequence).")}}
    Assert-RepositoryEvidenceReuseCasOperations -Context $Context
    Assert-RepositoryTransactionTerminalManifestClosure -Context $Context
    Write-RepositoryInstallJournalGeneration $Context (Copy-RepositoryInstallJournal $Context.CurrentJournal -Phase applied)
}

function Resolve-ProjectPublicationRecoveryAction {
    param([Parameter(Mandatory=$true)]$JournalState)
    if([string]$JournalState.status-cne'valid'){return 'fail-closed'}
    switch([string]$JournalState.journal.phase){'prepared'{return 'rollback-all'}'applying'{return 'rollback-all'}'applied'{return 'rollback-all'}'committed'{return 'roll-forward-cleanup'}default{return 'fail-closed'}}
}

function Invoke-ProjectPublicationRecovery {
    param([Parameter(Mandatory=$true)][string]$Repository,[string]$GitDirectory)
    if([string]::IsNullOrWhiteSpace($GitDirectory)){$GitDirectory=Get-RepositoryActiveGitDirectory -Repository $Repository}
    $activeGitDirectory=Get-RepositoryActiveGitDirectory -Repository $Repository
    if(-not(Test-ProjectPublicationPathEqual -Left $activeGitDirectory -Right $GitDirectory)){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message 'The requested repository transaction store is not the active worktree Git directory.')}
    $store=Get-RepositoryTransactionStorePath -GitDirectory $GitDirectory
    if(-not(Test-Path -LiteralPath $store -PathType Container)){return}
    $container=Open-PlatformDirectory -Root $GitDirectory -RelativePath '.ai-instructions-txn'
    try{
        foreach($entry in @(Get-ChildItem -Force -LiteralPath $store|Sort-Object Name)){
            $nameMatch=[regex]::Match([string]$entry.Name,'^(?<Id>[0-9a-f]{32})$')
            if(-not$entry.PSIsContainer-or($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or-not$nameMatch.Success){
                throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Unknown repository transaction residue '$($entry.FullName)'. Inspect the evidence and remove it manually only after proving no transaction target needs recovery.")
            }
            $id=[string]$nameMatch.Groups['Id'].Value;$directoryLeaf=[string]$entry.Name
            $lease=Open-PlatformDirectory -Root $GitDirectory -RelativePath ('.ai-instructions-txn/'+$directoryLeaf)
            $identity=ConvertTo-ProjectPublicationIdentity $lease.Observation
            $context=$null
            try{
                $readLeaf={param($name)$path=Join-Path $entry.FullName $name;if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{Kind=$null;Json=$null;State=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}}};if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{Kind='other';Json=$null;State=$null}};$state=Get-AiInstructionsInstallFileState -ParentLease $lease -Leaf $name -LiteralPath $path -PlatformOs (Get-RepositoryTransactionPlatform);return [pscustomobject]@{Kind='file';Json=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path));State=$state}}
                $journal=&$readLeaf 'journal.json';$previous=&$readLeaf 'journal.prev';$stage=&$readLeaf 'journal.stage'
                if($null-eq$journal.Kind-and$null-eq$previous.Kind){
                    $classification=Get-AiInstructionsInstallTransactionClassification -Name $id -EntryKind directory -JournalEntryKind $null -JournalJson $null -PreviousJournalEntryKind $null -PreviousJournalJson $null -ExpectedOwnerComponent repo-bootstrap
                    $children=@(Get-ChildItem -Force -LiteralPath $entry.FullName)
                    $unexpected=@($children|Where-Object{-not(Test-RepositoryTransactionOrphanChild -Item $_)})
                    $index=((Invoke-Git -Repository $Repository -Arguments @('rev-parse','--git-path','index'))|Select-Object -First 1).Trim();if(-not[IO.Path]::IsPathRooted($index)){$index=Join-Path $Repository $index};$index=[IO.Path]::GetFullPath($index);$lockPath=$index+'.lock'
                    if(Test-Path -LiteralPath $lockPath){throw (New-RepositoryIndexLockRefusal -Reason "Repository transaction '$directoryLeaf' has no readable journal, so its residual Git index.lock cannot be attributed safely." -LockPath $lockPath)}
                    if([string]$classification.classification-cne'orphan-without-journal'-or$unexpected.Count-gt0){throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction '$directoryLeaf' is not a harmless orphan. Inspect its evidence and remove it manually only after verifying every target." )}
                    $lease.Dispose();$lease=$null;Remove-PlatformOwnedDirectoryTree -TransactionRootLease $container -Leaf $directoryLeaf -ExpectedIdentity $identity|Out-Null;continue
                }
                $classification=Get-AiInstructionsInstallTransactionClassification -Name $id -EntryKind directory -JournalEntryKind $journal.Kind -JournalJson $journal.Json -PreviousJournalEntryKind $previous.Kind -PreviousJournalJson $previous.Json -ExpectedOwnerComponent repo-bootstrap
                if([string]$classification.classification-cne'valid-journal'){
                    throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Legacy fix4 or malformed project journal residue was found at '$($entry.FullName)'. Preserve it, inspect journal.json and all stage/backup files, verify repository HEAD/index/files manually, then remove the exact transaction directory before retrying. Classification: $($classification.reason)")
                }
                Assert-RepositoryTransactionScopeBinding -Repository $Repository -GitDirectory $GitDirectory -Journal $classification.journal
                $context=[pscustomobject][ordered]@{Repository=$Repository;GitDirectory=$GitDirectory;Id=$id;DirectoryLeaf=$directoryLeaf;Intents=$null;Remediation=$null;Durable=$true;ContainerLease=$container;Lease=$lease;Identity=$identity;CurrentJournal=$classification.journal;JournalStoreStates=[ordered]@{'journal.json'=$journal.State;'journal.prev'=$previous.State;'journal.stage'=$stage.State};RepositoryIndexLock=$null}
                Resolve-RepositoryRecoveryIndexLock -Context $context
                $action=Resolve-ProjectPublicationRecoveryAction ([pscustomobject]@{status='valid';journal=$classification.journal})
                if($action-ceq'rollback-all'){Invoke-RepositoryTransactionRollback $context}
                elseif($action-ceq'roll-forward-cleanup'){Complete-RepositoryTransactionCleanup $context}
                else{throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction '$directoryLeaf' has an unknown recovery state; evidence was retained.")}
                Close-RepositoryIndexTransactionLock -Lock $context.RepositoryIndexLock
                $lease=$null
                if($null-eq$context.ContainerLease){$container=Open-PlatformDirectory -Root $GitDirectory -RelativePath '.ai-instructions-txn'}
            }
            catch{if($null-ne$context){Close-RepositoryIndexTransactionLock -Lock $context.RepositoryIndexLock};if($null-ne$lease){$lease.Dispose()};if((Get-AiInstructionsRefusalCode $_)-ceq'interrupted-install'){throw};throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction recovery failed and retained evidence at '$($entry.FullName)': $($_.Exception.Message)" -InnerException $_.Exception)}
        }
    }finally{if($null-ne$container){$container.Dispose()}}
}

function Invoke-RepositoryTransactionRollback {
    param([Parameter(Mandatory=$true)][object]$Context)
    $rollbackErrors=New-Object System.Collections.Generic.List[string]
    foreach($operation in @($Context.CurrentJournal.operations|Sort-Object sequence -Descending)){
        try{
            Invoke-RepositoryTransactionOperation -Context $Context -Journal $Context.CurrentJournal -Operation $operation -Direction undo
            Invoke-AiInstructionsInstallFailpoint -Name ("after-rollback-operation-"+$operation.sequence)
        }
        catch{
            $message=[string]$_.Exception.Message
            $thirdStateMatch=[regex]::Match($message,'^Repository transaction sequence [0-9]+ role (?<Role>\S+) target (?<Target>.+) is in a third state;')
            if($thirdStateMatch.Success){
                $target=$thirdStateMatch.Groups['Target'].Value
                $ambiguous="Schema-v2 publication state is ambiguous or changed; current files were preserved for manual recovery: $target"
                $message=if($thirdStateMatch.Groups['Role'].Value-ceq'shared-exclude'){$ambiguous}else{"Target rollback errors: $target`: $ambiguous"}
            }
            $rollbackErrors.Add($message)
        }
    }
    if($rollbackErrors.Count-gt0){throw ($rollbackErrors-join' | ')}
    Close-RepositoryIndexTransactionLock -Lock $Context.RepositoryIndexLock
    Invoke-AiInstructionsInstallFailpoint -Name 'after-index-lock-release-before-journal-cleanup'
    Remove-ProjectPublicationContextEvidence $Context;$Context.Durable=$false
}

function Complete-RepositoryTransactionCleanup {
    param([Parameter(Mandatory=$true)][object]$Context)
    foreach($operation in @($Context.CurrentJournal.operations|Sort-Object sequence)){Invoke-RepositoryTransactionOperation -Context $Context -Journal $Context.CurrentJournal -Operation $operation -Direction redo|Out-Null}
    Assert-RepositoryTransactionTerminalManifestClosure -Context $Context
    Invoke-AiInstructionsInstallFailpoint -Name 'after-committed-before-cleanup'
    Close-RepositoryIndexTransactionLock -Lock $Context.RepositoryIndexLock
    Invoke-AiInstructionsInstallFailpoint -Name 'after-index-lock-release-before-journal-cleanup'
    $transactionPath=Get-RepositoryTransactionPath -Context $Context
    Remove-InstallTerminalTransactionArtifacts -Journal $Context.CurrentJournal -TransactionLease $Context.Lease -TransactionPath $transactionPath -JournalStoreStates $Context.JournalStoreStates
    Invoke-AiInstructionsInstallFailpoint -Name 'during-cleanup-transaction'
    $Context.Lease.Dispose();$Context.Lease=$null
    Remove-PlatformOwnedDirectoryTree -TransactionRootLease $Context.ContainerLease -Leaf $Context.DirectoryLeaf -ExpectedIdentity $Context.Identity|Out-Null
    $Context.ContainerLease.Dispose();$Context.ContainerLease=$null
    $Context.Durable=$false
}

function Invoke-RepositoryInstallTransaction {
    param([Parameter(Mandatory=$true)][object]$Context)
    Start-RepositoryInstallTransaction $Context
    if(-not$Context.Durable){return}
    Complete-RepositoryInstallTransactionApply $Context
    if([string]$Context.CurrentJournal.phase-cne'applied'){throw 'Repository transaction cannot commit before applied verification.'}
    Assert-RepositoryEvidenceReuseCasOperations -Context $Context
    Assert-RepositoryTransactionTerminalManifestClosure -Context $Context
    Invoke-AiInstructionsInstallFailpoint -Name 'before-committed-journal-write'
    Write-RepositoryInstallJournalGeneration $Context (Copy-RepositoryInstallJournal $Context.CurrentJournal -Phase committed)
    Invoke-AiInstructionsInstallFailpoint -Name 'after-committed-journal-write'
    Complete-RepositoryTransactionCleanup $Context
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

$initialHeadState = Get-RepositoryHeadQueryState -Repository $targetRootPath
if ($null -eq $initialHeadState.objectId) {
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
$configuration = $null
$repoManifestWriter = 'legacy'
$projectionContractSha256 = $null
$verifiedRoutingCatalogId = $null
$verifiedRuntimeLockSha256 = $null
$verifiedProjectCandidateSha256 = $null
$projectProjectionIds = @()
if (Test-Path -LiteralPath $configurationFullPath -PathType Leaf) {
    try {
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationFullPath | ConvertFrom-Json
    }
    catch {
        throw "AI instruction sync configuration is not valid JSON: $configurationFullPath"
    }

    if ($configuration.PSObject.Properties.Name -contains 'schemaVersion' -and
        ($configuration.schemaVersion -is [int] -or $configuration.schemaVersion -is [long]) -and
        [int64]$configuration.schemaVersion -eq 5) {
        throw 'AI Instructions sync configuration schema version 5 requires a projection-aware installer.'
    }
    if (($configuration.schemaVersion -is [int] -or $configuration.schemaVersion -is [long]) -and
        [int64]$configuration.schemaVersion -eq 4 -and $null -ne $configuration.PSObject.Properties['syncConfiguration']) {
        foreach ($name in @($configuration.PSObject.Properties.Name)) {
            if ($name -cnotin @('schemaVersion','syncConfiguration','catalogId','lockSha256','projectionContractSha256','projectCandidateSha256')) {
                throw "Projection-aware routing configuration contains unsupported property '$name'."
            }
        }
        foreach ($name in @('syncConfiguration','catalogId','lockSha256','projectionContractSha256')) {
            if ($null -eq $configuration.PSObject.Properties[$name]) { throw "Projection-aware routing configuration is missing '$name'." }
        }
        $syncConfiguration = $configuration.syncConfiguration
        Assert-AiInstructionsSyncConfigurationV5 -Configuration $syncConfiguration | Out-Null
        $projectProjectionIds = @($syncConfiguration.projections.project)
        $runtimeRootPath = [System.IO.Path]::GetFullPath($RuntimeRoot)
        $runtimeBundlePath = Join-Path $runtimeRootPath 'runtime-bundle.json'
        $runtimeCatalogPath = Join-Path $runtimeRootPath 'catalog\skills-catalog.json'
        $runtimeLockPath = Join-Path $runtimeRootPath 'catalog\skills-catalog-lock.json'
        $platformRuntimePath = Join-Path $runtimeRootPath 'platform-runtime.psd1'
        try {
            $runtimeBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $runtimeBundlePath | ConvertFrom-Json
            $runtimeCatalog = Test-SkillsCatalogDocument -CatalogPath $runtimeCatalogPath
            $runtimeLock = Test-SkillsCatalogLockDocument -LockPath $runtimeLockPath -CatalogPath $runtimeCatalogPath
        }
        catch { throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Projection-aware bootstrap routing validation failed: $($_.Exception.Message)" -InnerException $_.Exception) }
        $runtimeLockSha256 = Get-RawContentHash -Path $runtimeLockPath
        if ([int64]$runtimeCatalog.schemaVersion -ne 3 -or [int64]$runtimeLock.schemaVersion -ne 3 -or
            [string]$runtimeCatalog.catalogId -cne [string]$configuration.catalogId -or
            $runtimeLockSha256 -cne [string]$configuration.lockSha256 -or
            [string]$runtimeLock.projectionContractSha256 -cne [string]$configuration.projectionContractSha256 -or
            [string]$runtimeBundle.projectionContractSha256 -cne [string]$configuration.projectionContractSha256) {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Projection-aware routing Catalog/Lock/bundle identity is inconsistent.')
        }
        Import-Module $platformRuntimePath -Force -ErrorAction Stop
        $capabilityReceipt = Get-PlatformCapabilities -Required ([string[]]@($runtimeBundle.requiredCapabilities))
        Assert-AiInstructionsRuntimeGate -Bundle $runtimeBundle -Configuration $syncConfiguration -RuntimeRoot $runtimeRootPath -CapabilityReceipt $capabilityReceipt | Out-Null
        $repoManifestWriter = 'v4'
        $projectionContractSha256 = [string]$configuration.projectionContractSha256
        $verifiedRoutingCatalogId = [string]$configuration.catalogId
        $verifiedRuntimeLockSha256 = [string]$runtimeLockSha256
        if ($projectProjectionIds.Count -gt 0) {
            if ($null -eq $configuration.PSObject.Properties['projectCandidateSha256'] -or
                [string]$configuration.projectCandidateSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                [string]::IsNullOrWhiteSpace($ProjectCandidateArchivePath)) {
                throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project projection selection requires a lock-bound project candidate archive.')
            }
            $projectCandidateFullPath = [IO.Path]::GetFullPath($ProjectCandidateArchivePath)
            if (-not (Test-Path -LiteralPath $projectCandidateFullPath -PathType Leaf) -or
                (Get-RawContentHash $projectCandidateFullPath) -cne [string]$configuration.projectCandidateSha256) {
                throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'Project candidate archive is missing or does not match its routing hash.')
            }
            $verifiedProjectCandidateSha256 = [string]$configuration.projectCandidateSha256
        }
        elseif ($null -ne $configuration.PSObject.Properties['projectCandidateSha256'] -or -not [string]::IsNullOrWhiteSpace($ProjectCandidateArchivePath)) {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'A project candidate archive is not allowed when projections.project is empty.')
        }
        $configuration = [pscustomobject][ordered]@{
            schemaVersion = 3
            excludedRepositoryUrls = @($syncConfiguration.excludedRepositoryUrls)
            excludedRepositoryPaths = @($syncConfiguration.excludedRepositoryPaths)
        }
    }
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

if (Test-Path -LiteralPath $configurationFullPath -PathType Leaf) {
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

    if ($excludedRepositoryLocations.Count -gt 0) {
        $originQuery = Get-GitQueryResult -Repository $targetRootPath -Arguments @('remote', 'get-url', 'origin') -NegativeExitCodes @(2)
        if ($originQuery.Succeeded) {
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
}

if ($repoManifestWriter -ceq 'v4') {
    $identityProvenancePath = [System.IO.Path]::GetFullPath($ProvenancePath)
    if (-not (Test-Path -LiteralPath $identityProvenancePath -PathType Leaf)) {
        throw "Managed source provenance does not exist: $identityProvenancePath"
    }
    try { $identityProvenance = Get-Content -Raw -Encoding UTF8 -LiteralPath $identityProvenancePath | ConvertFrom-Json }
    catch { throw "Managed source provenance is not valid JSON: $identityProvenancePath" }
    $identityMismatches = New-Object System.Collections.Generic.List[string]
    if ([string]$identityProvenance.catalogId -cne [string]$verifiedRoutingCatalogId) { $identityMismatches.Add('catalogId') }
    if ([string]$identityProvenance.lockSha256 -cne [string]$verifiedRuntimeLockSha256) { $identityMismatches.Add('lockSha256') }
    if ($identityMismatches.Count -gt 0) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Managed source provenance identity is inconsistent with the verified routing/runtime context: $($identityMismatches -join ', ').")
    }
}

$tempRootPath = Get-FullPathWithoutTrailingSeparator -Path ([System.IO.Path]::GetTempPath())
$workingPath = Join-Path $tempRootPath ('codex-ai-instructions-' + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $workingPath 'source.zip'
$extractPath = Join-Path $workingPath 'source'
$projectCandidateExtractPath = Join-Path $workingPath 'project-candidate-source'
$projectCandidateState = $null
$preserveWorkingPath = $false
$repositoryOperationLock = $null
$repositoryIndexLock = $null
$repositoryIndexPath = $null
$userSkillMigrationLock = $null
$remediationTransaction = $null
$plannedRemediationPathSet = $null
try {
    New-Item -ItemType Directory -Path $workingPath, $extractPath | Out-Null
    if ($projectProjectionIds.Count -gt 0) {
        New-Item -ItemType Directory -Path $projectCandidateExtractPath | Out-Null
        $candidateRoot = Expand-SafeZipRepository -ArchivePath ([IO.Path]::GetFullPath($ProjectCandidateArchivePath)) -DestinationRoot $projectCandidateExtractPath
        $projectCandidateState = Get-ProjectCandidateDesiredState -CandidateRoot $candidateRoot -Catalog $runtimeCatalog -Lock $runtimeLock `
            -SyncConfiguration $syncConfiguration -ExpectedCatalogId $verifiedRoutingCatalogId `
            -ExpectedLockSha256 $verifiedRuntimeLockSha256 -ExpectedProjectionContractSha256 $projectionContractSha256
    }
    Assert-NoRepoManagedManifestV4 -Repository $targetRootPath -AllowV4:($repoManifestWriter -ceq 'v4')
    $claudeProjectOwnedWorktrees = @(Get-ClaudeProjectOwnedWorktreeRoots -Repository $targetRootPath)
    $currentClaudeProjectOwned = @($claudeProjectOwnedWorktrees | Where-Object {
        [System.IO.Path]::GetFullPath([string]$_).TrimEnd([char[]]@('\','/')).Equals($targetRootPath,[System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    $activeWorktreeProtectedClaudeFamilyPaths = @(if ($currentClaudeProjectOwned) {
        @('CLAUDE.md','.claude/AI-Rules','.claude/ai-instructions-licenses')
    }
    else { @('CLAUDE.md') })
    $repositoryProtectedClaudeFamilyPaths = @(if ($claudeProjectOwnedWorktrees.Count -gt 0) {
        @('CLAUDE.md','.claude/AI-Rules/','.claude/ai-instructions-licenses/')
    }
    else { @() })
    if (-not $WhatIf) {
        $repositoryOperationLock = Open-RepositoryOperationLock -Repository $targetRootPath
        $activeGitDirectory=Get-RepositoryActiveGitDirectory -Repository $targetRootPath
        if(Test-Path -LiteralPath (Get-RepositoryTransactionStorePath -GitDirectory $activeGitDirectory)){
            Import-Module (Join-Path $PSScriptRoot 'ai-instructions-install-transaction.psm1') -Force
            Invoke-ProjectPublicationRecovery -Repository $targetRootPath -GitDirectory $activeGitDirectory
        }
        Assert-NoRepoManagedManifestV4 -Repository $targetRootPath -AllowV4:($repoManifestWriter -ceq 'v4') -Strict
        $claudeProjectOwnedWorktrees = @(Get-ClaudeProjectOwnedWorktreeRoots -Repository $targetRootPath -Strict)
        $currentClaudeProjectOwned = @($claudeProjectOwnedWorktrees | Where-Object {
            [System.IO.Path]::GetFullPath([string]$_).TrimEnd([char[]]@('\','/')).Equals($targetRootPath,[System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        $activeWorktreeProtectedClaudeFamilyPaths = @(if ($currentClaudeProjectOwned) {
            @('CLAUDE.md','.claude/AI-Rules','.claude/ai-instructions-licenses')
        }
        else { @('CLAUDE.md') })
        $repositoryProtectedClaudeFamilyPaths = @(if ($claudeProjectOwnedWorktrees.Count -gt 0) {
            @('CLAUDE.md','.claude/AI-Rules/','.claude/ai-instructions-licenses/')
        }
        else { @() })
        if ($null -ne $projectCandidateState -and @($projectCandidateState.Files).Count -gt 0) {
            $earlyConflicts=@(Get-ProjectSkillOwnershipConflictsAcrossWorktrees -Repository $targetRootPath -DesiredFiles @($projectCandidateState.Files))
            if($earlyConflicts.Count-gt0){
                $details=Format-ProjectSkillOwnershipConflictDetails -Conflicts $earlyConflicts
                Write-ProjectSkillOwnershipConflictDiagnostics -Conflicts $earlyConflicts
                throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill transaction refused before remediation or project mutation: $details. Resolve each conflict: remove or rename the project-owned Skill, or remove that Skill from projections.project.")
            }
        }
        $script:ProjectPublicationContext=New-ProjectPublicationContext -Repository $targetRootPath
        $remediationTransaction = New-AgentArtifactRemediationPlan -Repository $targetRootPath -GitExecutable $GitExecutable `
            -ProtectedPathPrefixes $activeWorktreeProtectedClaudeFamilyPaths `
            -SharedExcludeProtectedPathPrefixes $repositoryProtectedClaudeFamilyPaths
        if($null-ne$remediationTransaction){
            $script:ProjectPublicationContext.Remediation=$remediationTransaction
            $plannedRemediationPathSet=New-Object 'System.Collections.Generic.HashSet[string]' (Get-GitPathComparer -Repository $targetRootPath)
            foreach($plannedRemediationPath in @($remediationTransaction.Paths)){[void]$plannedRemediationPathSet.Add([string]$plannedRemediationPath)}
        }
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
        Host = 'codex'
        SourceBase = '.codex/AGENTS.en.md'
        TargetBase = 'AGENTS.md'
        SourceRules = '.codex/AI-Rules'
        TargetRules = '.codex/AI-Rules'
    },
    @{
        Name = 'GitHub Copilot'
        Host = 'copilot'
        SourceBase = '.github/copilot-instructions.en.md'
        TargetBase = '.github/copilot-instructions.md'
        SourceRules = '.github/AI-Rules'
        TargetRules = '.github/AI-Rules'
    }
)
if ($repoManifestWriter -ceq 'v4') {
    $families += @{
        Name = 'Claude'
        Host = 'claude'
        SourceBase = '.claude/CLAUDE.en.md'
        TargetBase = 'CLAUDE.md'
        SourceRules = '.claude/AI-Rules'
        TargetRules = '.claude/AI-Rules'
    }
}
$sharedSkillsFamilyName = 'Shared Agent Skills'
$sharedSkillsSource = '.agents/skills'

$manifestFullPath = Join-Path $targetRootPath $manifestRelativePath.Replace('/', '\')
$manifestExists = Test-Path -LiteralPath $manifestFullPath -PathType Leaf
$manifestInitialRawSha256 = if ($manifestExists) { Get-RawContentHash $manifestFullPath } else { $null }
$manifestEntriesByTarget = @{}
$manifestSchemaVersion = $null
$script:instructionProvenance = $null
$script:rendererSha256 = $null
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
    if ($manifestSchemaVersion -eq 4) {
        if ($repoManifestWriter -cne 'v4') {
            [Console]::Error.WriteLine($script:repoManifestV4DowngradeSummary)
            [Console]::Error.WriteLine($script:repoManifestV4ProjectionRequirement)
            throw [SyuanTsai.AiInstructions.AiInstructionsRefusalException]::new(
                'downgrade-refused',
                $script:repoManifestV4DowngradeMessage
            )
        }
        Assert-ManagedManifestV4 -Manifest $manifest
    }
    if (($manifestSchemaVersion -isnot [int] -and $manifestSchemaVersion -isnot [long]) -or $manifestSchemaVersion -notin @(1, 2, 3, 4)) {
        throw "Unsupported managed instruction manifest schema: $($manifest.schemaVersion)"
    }

    if ($manifestSchemaVersion -in @(2,3)) {
        Assert-ManagedManifest -Manifest $manifest
    }
    elseif ($manifestSchemaVersion -eq 1) { Assert-LegacyManagedManifestV1 -Manifest $manifest }

    if ($manifestSchemaVersion -in @(2,3) -and
        ([string]$manifest.catalogId -cne [string]$provenance.catalogId -or
         [string]$manifest.lockSha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Managed instruction manifest Catalog identity or historical lock hash is invalid.'
    }
    # A valid v4 identity is historical ownership evidence. The candidate manifest below is rebound to the current P7e-verified context.
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
            if($null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains([string]$targetPath)){continue}
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

$retiredLegacySkillPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
if ($repoManifestWriter -ceq 'v4' -and $manifestExists -and $manifestSchemaVersion -eq 1) {
    $retainedLegacySkillPaths = New-Object System.Collections.Generic.List[string]
    foreach ($legacySkillPath in @($manifestEntriesByTarget.Keys | Where-Object { $_ -like '.agents/skills/*' } | Sort-Object)) {
        $legacySkillFullPath = Join-Path $targetRootPath ([string]$legacySkillPath).Replace('/','\')
        $legacySkillExists = Test-Path -LiteralPath $legacySkillFullPath -PathType Leaf
        $legacySkillHasChanges = Test-GitPathHasChanges -Repository $targetRootPath -Path ([string]$legacySkillPath)
        if (-not $legacySkillExists -and -not $legacySkillHasChanges) {
            [void]$retiredLegacySkillPaths.Add([string]$legacySkillPath)
            continue
        }
        $retainedLegacySkillPaths.Add([string]$legacySkillPath)
    }
    if ($retainedLegacySkillPaths.Count -gt 0) {
        throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Projection-aware bootstrap cannot replace retained legacy REPO Skill ownership: $(@($retainedLegacySkillPaths) -join ', '). Complete USER migration or repair ownership evidence first.")
    }
}

if (-not $WhatIf) { $repositoryIndexPath = Get-RepositoryIndexTransactionPath -Repository $targetRootPath }
$gitPathComparer = Get-GitPathComparer -Repository $targetRootPath
$trackedPaths = Get-GitListedPathSet -Repository $targetRootPath -Comparer $gitPathComparer -Kind Tracked
$stagedPaths = Get-GitListedPathSet -Repository $targetRootPath -Comparer $gitPathComparer -Kind Staged
$trackedPollutionPaths = @(@(
    if ($trackedPaths.Contains($manifestRelativePath) -and -not($null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains($manifestRelativePath))) { $manifestRelativePath }
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        $isProtectedClaude = Test-IsProtectedClaudeFamilyPath -Path ([string]$targetPath) -ProtectedPaths $activeWorktreeProtectedClaudeFamilyPaths
        if ($isProtectedClaude) { Write-Warning "Protected Claude family path skipped at tracked pollution inspection: $targetPath (project-owned Claude family)." }
        $isV4ProjectSkill = $manifestSchemaVersion -eq 4 -and $null -ne $manifestEntriesByTarget[$targetPath].PSObject.Properties['artifactType'] -and [string]$manifestEntriesByTarget[$targetPath].artifactType -ceq 'skill'
        $isPlannedRemediation=$null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains([string]$targetPath)
        if (-not $isProtectedClaude -and -not $isV4ProjectSkill -and -not $isPlannedRemediation -and -not ([string]$targetPath).StartsWith('.agents/skills/',[StringComparison]::Ordinal) -and $trackedPaths.Contains([string]$targetPath)) { [string]$targetPath }
    }
) | Sort-Object -Unique)
if ($trackedPollutionPaths.Count -gt 0 -and -not $WhatIf) {
    throw "Tracked reserved Agent artifacts remain after controlled remediation: $($trackedPollutionPaths -join ', ')."
}

$stagedManagedPaths = @(
    foreach ($targetPath in @($manifestEntriesByTarget.Keys | Sort-Object)) {
        $isProtectedClaude = Test-IsProtectedClaudeFamilyPath -Path ([string]$targetPath) -ProtectedPaths $activeWorktreeProtectedClaudeFamilyPaths
        if ($isProtectedClaude) { Write-Warning "Protected Claude family path skipped at staged mutation inspection: $targetPath (project-owned Claude family)." }
        $isV4ProjectSkill = $manifestSchemaVersion -eq 4 -and $null -ne $manifestEntriesByTarget[$targetPath].PSObject.Properties['artifactType'] -and [string]$manifestEntriesByTarget[$targetPath].artifactType -ceq 'skill'
        $isPlannedRemediation=$null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains([string]$targetPath)
        if (-not $isProtectedClaude -and -not $isV4ProjectSkill -and
            -not $isPlannedRemediation -and
            -not ([string]$targetPath).StartsWith('.agents/skills/',[StringComparison]::Ordinal) -and
            (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path ([string]$targetPath))) {
            [string]$targetPath
        }
    }
)
if ($stagedManagedPaths.Count -gt 0) {
    Write-Output "AI instruction sync skipped because a managed path has staged changes: $($stagedManagedPaths -join ', ')"
    return
}

if ($manifestExists -and
    -not($null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains($manifestRelativePath)) -and
    (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $manifestRelativePath)) {
    Write-Output 'AI instruction sync skipped because the managed manifest has staged changes.'
    return
}

try {
    $providedArchivePath = Get-FullPathWithoutTrailingSeparator -Path $SourceArchivePath
    if (-not (Test-Path -LiteralPath $providedArchivePath -PathType Leaf)) {
        throw "Source archive does not exist: $providedArchivePath"
    }

    Copy-Item -LiteralPath $providedArchivePath -Destination $archivePath

    $sourceRootPath = Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot $extractPath
    if ($repoManifestWriter -ceq 'v4') {
        $rendererPath = Join-Path $sourceRootPath 'scripts\Build-AiInstructions.ps1'
        if (-not (Test-Path -LiteralPath $rendererPath -PathType Leaf)) { throw 'Projection-aware source snapshot is missing scripts/Build-AiInstructions.ps1.' }
        $script:rendererSha256 = Get-RawContentHash -Path $rendererPath
    }
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
        $licenseTargetPrefix = switch ($family.Host) { 'codex' { '.codex' } 'copilot' { '.github' } 'claude' { '.claude' } }
        foreach ($licenseFile in @($licenses.Files)) {
            $desiredEntries.Add([pscustomobject]@{
                FamilyName = $family.Name; SourcePath = $licenseFile.sourcePath
                TargetPath = "$licenseTargetPrefix/ai-instructions-licenses/$($script:instructionProvenance.sourceCommit)/$($licenseFile.relativePath)"
                SourceFullPath = (Join-Path $licenseRoot $licenseFile.relativePath); Sha256 = $licenseFile.sha256
            })
        }
    }

    # Project Skills are supplied only by the independently verified, lock-bound candidate.
    # The Instructions archive remains Instructions-only and is never a Skill fallback source.
    if ($null -ne $projectCandidateState) {
        foreach ($projectFile in @($projectCandidateState.Files)) {
            if (-not $script:skillProvenanceById.ContainsKey([string]$projectFile.SkillId)) {
                throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project candidate Skill '$($projectFile.SkillId)' is absent from multisource provenance.")
            }
            $provenanceSkill = $script:skillProvenanceById[[string]$projectFile.SkillId]
            foreach ($name in @('sourceId','sourceRepository','sourceRef','sourceCommit','sourceVersion')) {
                if ([string]$projectFile.$name -cne [string]$provenanceSkill.$name) {
                    throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project candidate Skill '$($projectFile.SkillId)' $name differs from multisource provenance.")
                }
            }
            $desiredEntries.Add($projectFile)
        }
    }

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
    $hasHistoricalSkills = $manifestExists -and $manifestSchemaVersion -in @(2,3) -and
        @($manifestEntriesByTarget.Keys | Where-Object { $_ -like '.agents/skills/*' }).Count -gt 0
    if ($hasHistoricalSkills -and -not $WhatIf) {
        try { $userSkillMigrationLock = Open-UserSkillMigrationLock -UserHome $UserHome }
        catch { Write-Output "USER updater lock unavailable; preserve REPO Skills and retry after USER repair/update completes: $($_.Exception.Message)" }
    }
    foreach ($readiness in @(Get-UserSharedSkillsReadiness -UserHome $UserHome -CatalogId $provenance.catalogId -TrustedSkills $trustedSkills)) {
        if (-not $readiness.ready) { Write-Output "USER Skill repair/update required for $($readiness.id): $($readiness.reason). REPO fallback is disabled." }
    }
    $skillMigration = @()
    if ($hasHistoricalSkills -and ($WhatIf -or $null -ne $userSkillMigrationLock)) {
        $skillMigration = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRootPath -Manifest $manifest -TrustedSkills $trustedSkills -UserHome $UserHome -GitExecutable $GitExecutable)
    }
    $migrationById = @{}
    foreach ($skill in $skillMigration) {
        $migrationById[[string]$skill.id] = $skill
        $disposition = if ($skill.removable) { 'retire verified ignored/untracked copy' } else { "preserve: $($skill.reason)" }
        Write-Output "Skill migration $($skill.id): $disposition"
    }
    if ($repoManifestWriter -ceq 'v4' -and $manifestExists -and $manifestSchemaVersion -in @(2,3)) {
        $retainedHistoricalSkillPaths = New-Object System.Collections.Generic.List[string]
        foreach ($historicalSkillPath in @($manifestEntriesByTarget.Keys | Where-Object { $_ -like '.agents/skills/*' } | Sort-Object)) {
            $historicalSkillId = ([string]$historicalSkillPath).Split('/')[2]
            if (-not $migrationById.ContainsKey($historicalSkillId) -or -not [bool]$migrationById[$historicalSkillId].removable) {
                $retainedHistoricalSkillPaths.Add([string]$historicalSkillPath)
            }
        }
        if ($retainedHistoricalSkillPaths.Count -gt 0) {
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Projection-aware bootstrap cannot replace retained legacy REPO Skill ownership: $(@($retainedHistoricalSkillPaths) -join ', '). Complete USER migration or repair ownership evidence first.")
        }
    }
    $existingSkillsRoot = Join-Path $targetRootPath '.agents/skills'
    if ((Test-Path -LiteralPath $existingSkillsRoot -PathType Container) -and
        -not ((Get-Item -Force -LiteralPath $existingSkillsRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        foreach ($directory in @(Get-ChildItem -Directory -Force -LiteralPath $existingSkillsRoot)) {
            if (-not $migrationById.ContainsKey($directory.Name)) { Write-Output "Repository Skill preserved without provable shared ownership: $($directory.Name)" }
        }
    }
    $retainLegacyManifest = $repoManifestWriter -cne 'v4' -and $manifestExists -and $manifestSchemaVersion -eq 1 -and
        @($manifestEntriesByTarget.Keys | Where-Object { $_ -like '.agents/skills/*' }).Count -gt 0

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
    if ($null -ne $script:ProjectPublicationContext) {
        Register-ProjectPublicationPlanningObservations -Context $script:ProjectPublicationContext `
            -RelativePaths @(@($desiredEntriesByTarget.Keys) + @($manifestEntriesByTarget.Keys) | ForEach-Object { [string]$_ })
    }

    $projectDesiredFiles =@($desiredEntries | Where-Object { $null -ne $_.PSObject.Properties['IsProjectSkill'] -and [bool]$_.IsProjectSkill })
    $relinquishedProjectTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($projectDesiredFiles.Count -gt 0) {
        $projectConflicts = @(Get-ProjectSkillOwnershipConflictsAcrossWorktrees -Repository $targetRootPath -DesiredFiles $projectDesiredFiles)
        if ($projectConflicts.Count -gt 0) {
            $details=Format-ProjectSkillOwnershipConflictDetails -Conflicts $projectConflicts
            Write-ProjectSkillOwnershipConflictDiagnostics -Conflicts $projectConflicts
            throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill transaction refused before project mutation: $details. Resolve each conflict: remove or rename the project-owned Skill, or remove that Skill from projections.project.")
        }
    }
    if ($manifestSchemaVersion -eq 4) {
        $retiredEntries = @($manifest.files | Where-Object {
            [string]$_.artifactType -ceq 'skill' -and -not $desiredEntriesByTarget.ContainsKey([string]$_.targetPath)
        })
        $retiredGroups = @($retiredEntries | Group-Object projectionId,artifactId)
        foreach ($retiredGroup in $retiredGroups) {
            $retiredGroupEntries = @($retiredGroup.Group); $projectionId=[string]$retiredGroupEntries[0].projectionId; $skillId=[string]$retiredGroupEntries[0].artifactId
            $entries = @($manifest.files|Where-Object{
                [string]$_.artifactType-ceq'skill' -and [string]$_.projectionId-ceq$projectionId -and [string]$_.artifactId-ceq$skillId
            })
            $desiredGroupFiles = @($projectDesiredFiles|Where-Object{[string]$_.ProjectionId -ceq $projectionId -and [string]$_.SkillId -ceq $skillId})
            $prefix = ([string]$entries[0].targetPath).Split('/')[0..2] -join '/'
            $ownedReasons = New-Object System.Collections.Generic.List[string]
            if (@($trackedPaths | Where-Object { Test-GitPathEqualsOrIsUnderPrefix -Path ([string]$_) -Prefix $prefix -Comparer $gitPathComparer }).Count -gt 0) { $ownedReasons.Add('tracked') }
            if (@($stagedPaths | Where-Object { Test-GitPathEqualsOrIsUnderPrefix -Path ([string]$_) -Prefix $prefix -Comparer $gitPathComparer }).Count -gt 0) { $ownedReasons.Add('staged') }
            $entryMap=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
            foreach($entry in $entries){$entryMap.Add([string]$entry.targetPath,$entry)}
            $root=Join-Path $targetRootPath $prefix.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if(Test-Path -LiteralPath $root){
                $item=Get-Item -Force -LiteralPath $root
                if(-not$item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){$ownedReasons.Add('reparse')}
                else{
                    $pending=New-Object System.Collections.Generic.Stack[string];$pending.Push($root)
                    while($pending.Count-gt0){
                        $directory=$pending.Pop()
                        foreach($child in @(Get-ChildItem -LiteralPath $directory -Force)){
                            $relative=$child.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
                            if(($child.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){$ownedReasons.Add("reparse:$relative")}
                            elseif($child.PSIsContainer){$pending.Push($child.FullName)}
                            else{
                                $path="$prefix/$relative"
                                if(-not$entryMap.ContainsKey($path)){$ownedReasons.Add("unmanaged:$relative")}
                                elseif((Get-RawContentHash $child.FullName)-cne[string]$entryMap[$path].sha256){$ownedReasons.Add("drift:$relative")}
                            }
                        }
                    }
                }
            }
            foreach($entry in $entries){
                $full=Join-Path $targetRootPath ([string]$entry.targetPath).Replace('/',[IO.Path]::DirectorySeparatorChar)
                if(-not(Test-Path -LiteralPath $full -PathType Leaf)){
                    $missingRelative=([string]$entry.targetPath).Substring($prefix.Length).TrimStart('/')
                    $ownedReasons.Add("missing:$missingRelative")
                }
            }
            if($ownedReasons.Count-gt0){
                if($desiredGroupFiles.Count-gt0){
                    $conflicts=@($ownedReasons|Sort-Object -Unique|ForEach-Object{
                        $reason=[string]$_;$separator=$reason.IndexOf(':');$status=if($separator-ge0){$reason.Substring(0,$separator)}else{$reason};$relative=if($separator-ge0){$reason.Substring($separator+1)}else{'.'}
                        [pscustomobject][ordered]@{worktree=$targetRootPath;projection=$projectionId;skillId=$skillId;targetPath=if($relative-ceq'.'){$prefix}else{"$prefix/$relative"};relativePath=$relative;status=$status}
                    })
                    $details=Format-ProjectSkillOwnershipConflictDetails -Conflicts $conflicts
                    Write-ProjectSkillOwnershipConflictDiagnostics -Conflicts $conflicts
                    throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message "Project Skill update retirement refused before project mutation: $details. Resolve each conflict: remove or rename the project-owned Skill, or remove that Skill from projections.project.")
                }
                foreach($entry in $entries){[void]$relinquishedProjectTargets.Add([string]$entry.targetPath)}
                Write-Output "ownership-relinquished: $projectionId/$skillId [$(@($ownedReasons|Sort-Object -Unique)-join ', ')]"
            }
        }
    }

    $eligibleFamilies = @{}
    foreach ($family in $families) {
        $baseTargetPath = $family.TargetBase
        $baseTargetFullPath = Join-Path $targetRootPath $baseTargetPath.Replace('/', '\')
        $baseTargetIsPlannedRemediation=$null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains([string]$baseTargetPath)
        $baseTargetIsTracked = $trackedPaths.Contains($baseTargetPath) -and -not $baseTargetIsPlannedRemediation
        $baseTargetMatchesDesired = $false
        if ((Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -and
            -not $baseTargetIsTracked -and
            $desiredEntriesByTarget.ContainsKey($baseTargetPath)) {
            $baseTargetMatchesDesired =
                (Get-ManagedContentHash -Path $baseTargetFullPath -TargetPath $baseTargetPath) -ceq
                [string]$desiredEntriesByTarget[$baseTargetPath].Sha256
        }
        if ($family.Name -ceq 'Claude') {
            $eligibleFamilies[$family.Name] = -not $currentClaudeProjectOwned
            if (-not $eligibleFamilies[$family.Name]) { Write-Output 'claude-base-skipped-project-owned' }
        }
        else {
            $eligibleFamilies[$family.Name] =
                $baseTargetIsPlannedRemediation -or
                (-not $baseTargetIsTracked -and
                 ($manifestEntriesByTarget.ContainsKey($baseTargetPath) -or
                 -not (Test-Path -LiteralPath $baseTargetFullPath -PathType Leaf) -or
                 $baseTargetMatchesDesired))
        }
    }
    $eligibleFamilies['Project Skills'] = $true
    $createdPaths = New-Object System.Collections.Generic.List[string]
    $updatedPaths = New-Object System.Collections.Generic.List[string]
    $removedPaths = New-Object System.Collections.Generic.List[string]
    $skippedPaths = New-Object System.Collections.Generic.List[string]
    $nextManifestEntries = New-Object System.Collections.Generic.List[object]

    if ($WhatIf) {
        Write-Output 'WhatIf: consumer Instructions-only synchronization; shared Skills will never be installed in REPO.'
        return
    }

    $targetMutationProtectedClaudeFamilyPaths = @(if ([bool]$eligibleFamilies['Claude']) {
        @()
    }
    else { $activeWorktreeProtectedClaudeFamilyPaths })
    $mutationPaths = @(
        @($desiredEntries | ForEach-Object { [string]$_.TargetPath })
        @($manifestEntriesByTarget.Keys | Where-Object {
            $existingEntry = $manifestEntriesByTarget[[string]$_]
            $isProjectSkill = $manifestSchemaVersion -eq 4 -and $null -ne $existingEntry.PSObject.Properties['artifactType'] -and [string]$existingEntry.artifactType -ceq 'skill'
            if ($isProjectSkill -or [string]$_ -notlike '.agents/skills/*') { $true }
            else { $id=([string]$_).Split('/')[2]; $migrationById.ContainsKey($id) -and $migrationById[$id].removable }
        })
        $manifestRelativePath
    )
    $projectMutationPathSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($entry in $desiredEntries){if($null-ne$entry.PSObject.Properties['IsProjectSkill']-and[bool]$entry.IsProjectSkill){[void]$projectMutationPathSet.Add([string]$entry.TargetPath)}}
    if($manifestSchemaVersion-eq4){foreach($entry in @($manifest.files|Where-Object{[string]$_.artifactType-ceq'skill'})){[void]$projectMutationPathSet.Add([string]$entry.targetPath)}}
    $projectMutationPaths = @($mutationPaths | Where-Object { $projectMutationPathSet.Contains([string]$_) })
    $snapshotMutationPaths = @($mutationPaths | Where-Object {
        -not $projectMutationPathSet.Contains([string]$_) -and
        -not ($projectMutationPaths.Count -gt 0 -and [string]$_ -ceq $manifestRelativePath)
    })
    $mutationBackupRoot = Join-Path $workingPath 'target-backup'
    $mutationSnapshot = New-TargetMutationSnapshot -TargetRoot $targetRootPath -RelativePaths $snapshotMutationPaths -BackupRoot $mutationBackupRoot -ProtectedPaths $targetMutationProtectedClaudeFamilyPaths
    $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRootPath -UsePlatformRuntime:($projectMutationPaths.Count -gt 0)
    $migrationJournalPath = Join-Path $mutationBackupRoot 'skill-migration.json'
    $migrationGitState = $null
    if (@($skillMigration | Where-Object removable).Count -gt 0) {
        $migrationGitState = Get-RepoSkillMigrationGitState -Repository $targetRootPath -GitExecutable $GitExecutable
    }
    if ($projectMutationPaths.Count -gt 0) {
        if($null-eq$script:ProjectPublicationContext){throw 'Project publication context was not prepared before remediation.'}
    }

    try {
        foreach ($desiredEntry in @($desiredEntries | Sort-Object TargetPath)) {
        $targetPath = $desiredEntry.TargetPath
        $targetFullPath = Join-Path $targetRootPath $targetPath.Replace('/', '\')
        $targetExists = Test-Path -LiteralPath $targetFullPath -PathType Leaf
        $isPlannedRemediation=$null-ne$plannedRemediationPathSet-and$plannedRemediationPathSet.Contains([string]$targetPath)
        $managedEntry = $null

        $entryIsEligible = [bool]$eligibleFamilies[$desiredEntry.FamilyName]
        if (-not $entryIsEligible) {
            $skippedPaths.Add($targetPath)
            if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $manifestEntriesByTarget[$targetPath]))
            }
            continue
        }

        if ($null -ne $desiredEntry.PSObject.Properties['IsProjectSkill'] -and [bool]$desiredEntry.IsProjectSkill) {
            $projectSource = [pscustomobject][ordered]@{
                sourceId=$desiredEntry.SourceId;sourceRepository=$desiredEntry.SourceRepository;sourceRef=$desiredEntry.SourceRef
                sourceCommit=$desiredEntry.SourceCommit;sourceVersion=$desiredEntry.SourceVersion
            }
            $desiredManifestEntry = New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256 `
                -ProjectSkillId $desiredEntry.SkillId -ProjectionId $desiredEntry.ProjectionId -ProjectSource $projectSource
        }
        else { $desiredManifestEntry = New-ManifestEntry -SourcePath $desiredEntry.SourcePath -TargetPath $targetPath -Sha256 $desiredEntry.Sha256 }
        $desiredManifestSchemaVersion = 2
        if ($manifestExists) { $desiredManifestSchemaVersion = [int]$manifestSchemaVersion }
        if ($null -ne $desiredEntry.PSObject.Properties['IsProjectSkill'] -and [bool]$desiredEntry.IsProjectSkill) { $desiredManifestSchemaVersion = 4 }
        $desiredManifestEntry = Convert-ManifestEntryForSchema -Entry $desiredManifestEntry -SchemaVersion $desiredManifestSchemaVersion
        if ($retainLegacyManifest) { $desiredManifestEntry = $desiredManifestEntry | Select-Object sourcePath,targetPath,sha256 }

        if ($manifestEntriesByTarget.ContainsKey($targetPath)) {
            $managedEntry = $manifestEntriesByTarget[$targetPath]
        }

        if ($isPlannedRemediation) {
            [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
            $expectedSha256 = if ($targetExists) { Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath } else { $null }
            Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes `
                -ExpectedExists $targetExists -ExpectedSha256 $expectedSha256
            $updatedPaths.Add($targetPath)
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        if ($null -ne $managedEntry) {
            if (-not $targetExists) {
                if (-not $isPlannedRemediation -and (Test-GitPathHasChanges -Repository $targetRootPath -Path $targetPath)) {
                    $skippedPaths.Add($targetPath)
                    $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                    continue
                }

                [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
                Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes `
                    -ExpectedExists $false
                $updatedPaths.Add($targetPath)
                $nextManifestEntries.Add($desiredManifestEntry)
                continue
            }

            if (-not $isPlannedRemediation -and (Test-GitPathHasStagedChanges -Repository $targetRootPath -Path $targetPath)) {
                $skippedPaths.Add($targetPath)
                $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
                continue
            }

            $currentHash = Get-ManagedContentHash -Path $targetFullPath -TargetPath $targetPath
            if ($currentHash -eq [string] $managedEntry.sha256 -or $currentHash -eq $desiredEntry.Sha256) {
                if ($currentHash -ne $desiredEntry.Sha256) {
                    [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
                    Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes `
                        -ExpectedExists $true -ExpectedSha256 $currentHash
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
            if ($trackedPaths.Contains($targetPath) -and -not $isPlannedRemediation) {
                $skippedPaths.Add($targetPath)
                continue
            }
            [byte[]]$desiredBytes = [System.IO.File]::ReadAllBytes([string]$desiredEntry.SourceFullPath)
            Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $targetPath -Bytes $desiredBytes `
                -ExpectedExists $false
            $createdPaths.Add($targetPath)
            $nextManifestEntries.Add($desiredManifestEntry)
            continue
        }

        if ($desiredEntry.FamilyName -ceq 'Claude') {
            $skippedPaths.Add($targetPath)
            continue
        }

        if ((-not $trackedPaths.Contains($targetPath) -or $isPlannedRemediation) -and
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
        $isProtectedClaude = Test-IsProtectedClaudeFamilyPath -Path $managedTargetPath -ProtectedPaths $targetMutationProtectedClaudeFamilyPaths
        if ($isProtectedClaude) {
            Write-Warning "Protected Claude family path skipped at bootstrap manifest reconciliation: $managedTargetPath (project-owned Claude family)."
            $nextManifestEntries.Add((Copy-ExistingManifestEntry -Entry $managedEntry))
            $skippedPaths.Add($managedTargetPath)
            continue
        }
        $managedProjectSkill = $manifestSchemaVersion -eq 4 -and $null -ne $managedEntry.PSObject.Properties['artifactType'] -and [string]$managedEntry.artifactType -ceq 'skill'
        if ($managedProjectSkill -and $relinquishedProjectTargets.Contains($managedTargetPath)) {
            continue
        }
        if ($managedTargetPath.StartsWith('.agents/skills/',[StringComparison]::Ordinal) -and -not $managedProjectSkill) {
            if ($retiredLegacySkillPaths.Contains($managedTargetPath)) { continue }
            $id = $managedTargetPath.Split('/')[2]
            if ($migrationById.ContainsKey($id) -and $migrationById[$id].removable) {
                Assert-RepoSharedSkillsMigrationEvidence -Repository $targetRootPath -Skill $migrationById[$id] -RemovedPaths @($removedPaths) -GitExecutable $GitExecutable
                Remove-TargetMutationFile -Snapshot $mutationSnapshot -RelativePath $managedTargetPath
                $removedPaths.Add($managedTargetPath)
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

            Remove-TargetMutationFile -Snapshot $mutationSnapshot -RelativePath $managedTargetPath -ExpectedSha256 $currentHash
            $removedPaths.Add($managedTargetPath)
        }
        }

        $shouldWriteManifest = $manifestExists -or $nextManifestEntries.Count -gt 0
        $manifestChanged = $false
        if ($shouldWriteManifest) {
        if ($repoManifestWriter -ceq 'v4') {
            $generation = if ($manifestExists -and $manifestSchemaVersion -eq 4) { [int64]$manifest.generation } else { [int64]1 }
            $candidate = [ordered]@{
                schemaVersion = 4
                catalogId = [string]$verifiedRoutingCatalogId
                lockSha256 = [string]$verifiedRuntimeLockSha256
                projectionContractSha256 = [string]$projectionContractSha256
                generation = $generation
                projections = @($projectProjectionIds | Sort-Object)
                files = @($nextManifestEntries | Sort-Object targetPath)
            }
            if ($manifestExists -and $manifestSchemaVersion -eq 4) {
                $candidateJson = ($candidate | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"
                $existingNormalized = ([System.IO.File]::ReadAllText($manifestFullPath)).Replace("`r`n","`n").Replace("`r","`n")
                if ($candidateJson -cne $existingNormalized) {
                    if ($generation -eq [int64]::MaxValue) { throw (New-AiInstructionsRefusalException -Code 'closure-invalid' -Message 'REPO managed manifest v4 generation would overflow.') }
                    $candidate.generation = $generation + 1
                }
            }
            $manifestObject = $candidate
            Assert-ManagedManifestV4 -Manifest ([pscustomobject]$manifestObject)
        }
        else {
            $manifestObject = [ordered]@{
                schemaVersion = if ($manifestExists -and $manifestSchemaVersion -eq 3) { 3 } else { 2 }
                catalogId = [string] $provenance.catalogId
                lockSha256 = [string] $provenance.lockSha256
                files = @($nextManifestEntries | Sort-Object targetPath)
            }
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
            Set-TargetMutationFileBytes -Snapshot $mutationSnapshot -RelativePath $manifestRelativePath -Bytes $manifestBytes `
                -ExpectedExists $manifestExists -ExpectedSha256 $manifestInitialRawSha256
            $manifestChanged = $true
        }
        }
        $managedExcludePaths = @($nextManifestEntries | ForEach-Object { [string]$_.targetPath })
        if ($shouldWriteManifest) { $managedExcludePaths += $manifestRelativePath }
        $preservedProtectedExcludePaths = @(
            if (-not [bool]$eligibleFamilies['Claude'] -and $claudeProjectOwnedWorktrees.Count -eq 1) {
                foreach ($entry in $nextManifestEntries) {
                    $entryPath = [string]$entry.targetPath
                    if ($entryPath -ceq 'CLAUDE.md' -or
                        -not (Test-IsProtectedClaudeFamilyPath -Path $entryPath -ProtectedPaths $repositoryProtectedClaudeFamilyPaths)) { continue }
                    $entryFullPath = Join-Path $targetRootPath $entryPath.Replace('/','\')
                    if ((Test-Path -LiteralPath $entryFullPath -PathType Leaf) -and
                        (Get-ManagedContentHash -Path $entryFullPath -TargetPath $entryPath) -ceq [string]$entry.sha256) {
                        $entryPath
                    }
                }
            }
        )
        Set-ManagedGitInfoExclude -Repository $targetRootPath -ManagedPaths $managedExcludePaths -Snapshot $excludeSnapshot `
            -ProtectedPaths $repositoryProtectedClaudeFamilyPaths -PreservedProtectedPaths $preservedProtectedExcludePaths
    }
    catch {
        throw
    }

    $changedPaths = @(
        @($createdPaths) +
        @($updatedPaths) +
        @($removedPaths) +
        $(if ($manifestChanged) { @($manifestRelativePath) } else { @() }) |
            Sort-Object -Unique
    )
    $plannedStashPaths=New-Object System.Collections.Generic.List[string]
    foreach($manifestEntry in $nextManifestEntries){
        if($null-ne$manifestEntry.PSObject.Properties['artifactType']-and[string]$manifestEntry.artifactType-ceq'skill'){continue}
        if([string]$manifestEntry.targetPath-like'.agents/skills/*'){continue}
        $plannedTargetPath=[string]$manifestEntry.targetPath
        if(Test-IsProtectedClaudeFamilyPath -Path $plannedTargetPath -ProtectedPaths $targetMutationProtectedClaudeFamilyPaths){continue}
        $plannedStashPaths.Add($plannedTargetPath)
    }
    if($shouldWriteManifest){$plannedStashPaths.Add($manifestRelativePath)}
    $plannedStashPathArguments=@($plannedStashPaths|Sort-Object -Unique)
    if($plannedStashPathArguments.Count-gt0){
        $shouldStorePersonalAgentEvidence=$changedPaths.Count-gt0
        if(-not$shouldStorePersonalAgentEvidence){
            $plannedWorktreeKey=Get-PersonalAgentWorktreeKey -Repository $targetRootPath
            $plannedEvidenceFingerprint=Get-PersonalAgentEvidenceFingerprint -Repository $targetRootPath -Paths $plannedStashPathArguments
            $plannedOwnedEvidence=@(Get-PersonalAgentStashes -Repository $targetRootPath -WorktreeKey $plannedWorktreeKey|Where-Object{Test-PersonalAgentStashEvidence -Repository $targetRootPath -Stash $_ -ExpectedFingerprint ([string]$_.EvidenceFingerprint)})
            $shouldStorePersonalAgentEvidence=@($plannedOwnedEvidence|Where-Object{$_.EvidenceFingerprint-ceq$plannedEvidenceFingerprint}).Count-ne1
        }
        $script:ProjectPublicationContext.ShouldStorePersonalAgentEvidence=$shouldStorePersonalAgentEvidence
        $script:ProjectPublicationContext.PersonalAgentEvidenceStashBefore=Get-RepositoryStashRefState -Repository $targetRootPath
    }
    $script:ProjectPublicationContext.TerminalManifestEntries=@($nextManifestEntries|Sort-Object targetPath)

    $repositoryIndexLock=Open-RepositoryIndexTransactionLock -Repository $targetRootPath
    $repositoryIndexPath=[string]$repositoryIndexLock.IndexPath
    $script:ProjectPublicationContext.RepositoryIndexLock=$repositoryIndexLock
    Start-RepositoryInstallTransaction $script:ProjectPublicationContext

    if ($skippedPaths.Count -gt 0) {
        $uniqueSkippedPaths = @($skippedPaths | Sort-Object -Unique)
        Write-Output "AI instructions customized or unmanaged; not overwritten: $($uniqueSkippedPaths -join ', ')"
    }

    $stashPathArguments = @()
    try {
        $stashPaths = New-Object System.Collections.Generic.List[string]
        foreach ($manifestEntry in $nextManifestEntries) {
            if ($null -ne $manifestEntry.PSObject.Properties['artifactType'] -and [string]$manifestEntry.artifactType -ceq 'skill') { continue }
            if ([string]$manifestEntry.targetPath -like '.agents/skills/*') { continue }
            $targetPath = [string]$manifestEntry.targetPath
            if (Test-IsProtectedClaudeFamilyPath -Path $targetPath -ProtectedPaths $targetMutationProtectedClaudeFamilyPaths) {
                Write-Warning "Protected Claude family path skipped at PersonalAgent recovery collection: $targetPath (project-owned Claude family)."
                continue
            }
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
                    -ActiveIndexPath ([string]$repositoryIndexPath) -ProtectedPaths $targetMutationProtectedClaudeFamilyPaths
                Write-Output "PersonalAgent recovery evidence updated and retained without index mutation: $newStashHash"
            }
        }
    }
    catch {
        throw
    }

    # Finalization failures are classified once by the outer handler after recovery has actually run,
    # so the final message reports whether evidence was rolled back, rolled forward, or retained.
    if ($null -ne $script:ProjectPublicationContext) {
        Complete-ProjectPublicationContext $script:ProjectPublicationContext
        $script:ProjectPublicationContext=$null
    }
    if ($changedPaths.Count -eq 0) { Write-Output 'AI instructions are up to date; no Git commit was created.' }
    else { Write-Output "AI instructions synchronized as local ignored runtime artifacts without Git commit: $($changedPaths -join ', ')" }
}
catch {
    $syncError = $_
    if($null-ne$script:ProjectPublicationContext){
        $transactionWasDurable=[bool]$script:ProjectPublicationContext.Durable
        try{
            $action=Resolve-ActiveProjectPublicationFailure -Context $script:ProjectPublicationContext -RemediationTransaction $remediationTransaction
        }catch{
            $recoveryError=$_
            $script:ProjectPublicationContext=$null
            $preserveWorkingPath=$true
            $recoveryMessage=[string]$recoveryError.Exception.Message
            $thirdStateMatch=[regex]::Match($recoveryMessage,'^Repository transaction sequence [0-9]+ role (?<Role>\S+) target (?<Target>.+) is in a third state;')
            if($thirdStateMatch.Success){
                $thirdStateTarget=$thirdStateMatch.Groups['Target'].Value
                $ambiguous="Schema-v2 publication state is ambiguous or changed; current files were preserved for manual recovery: $thirdStateTarget"
                $recoveryMessage=if($thirdStateMatch.Groups['Role'].Value-ceq'shared-exclude'){$ambiguous}else{"Target rollback errors: $thirdStateTarget`: $ambiguous"}
            }
            throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Original: $($syncError.Exception.Message) Rollback also failed: $recoveryMessage Recovery files were preserved at: $workingPath" -InnerException $recoveryError.Exception)
        }
        $script:ProjectPublicationContext=$null
        # No durable journal means no repository mutation happened; keep the original error classification.
        if(-not$transactionWasDurable){throw $syncError}
        $syncErrorCode=Get-AiInstructionsRefusalCode $syncError
        if($action-ceq'rollback-all'){
            if(-not[string]::IsNullOrWhiteSpace($syncErrorCode)){throw $syncError}
            throw (New-AiInstructionsRefusalException -Code 'interrupted-install' -Message "Repository transaction failed and was rolled back: $($syncError.Exception.Message)" -InnerException $syncError.Exception)
        }
        if($action-ceq'roll-forward-cleanup'){
            $rollForwardCode=if([string]::IsNullOrWhiteSpace($syncErrorCode)){'interrupted-install'}else{$syncErrorCode}
            throw (New-AiInstructionsRefusalException -Code $rollForwardCode -Message "Repository transaction failed after its committed journal generation; recovery kept the committed repository changes and completed transaction cleanup: $($syncError.Exception.Message)" -InnerException $syncError.Exception)
        }
        throw $syncError
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
    if($null-ne$script:ProjectPublicationContext){
        try{Resolve-ActiveProjectPublicationFailure -Context $script:ProjectPublicationContext -RemediationTransaction $remediationTransaction|Out-Null;$script:ProjectPublicationContext=$null}
        catch{$script:ProjectPublicationContext=$null;throw}
    }
    throw $bootstrapError
}
finally {
    if ($null -ne $userSkillMigrationLock) {
        $userSkillMigrationLock.Stream.Dispose()
        $userSkillMigrationLock.Guard.Dispose()
    }
    if ($null -ne $repositoryIndexLock) {
        Close-RepositoryIndexTransactionLock -Lock $repositoryIndexLock
    }
    if ($null -ne $repositoryOperationLock) { $repositoryOperationLock.Dispose() }
}
