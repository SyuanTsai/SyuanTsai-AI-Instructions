# Reuse the established disposable bootstrap fixtures without executing their Describe blocks.
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$fixtureText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'bootstrap-ai-instructions.Tests.ps1')
. ([scriptblock]::Create($fixtureText.Substring(0, $fixtureText.IndexOf("Describe 'bootstrap-ai-instructions'")).Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")))

function New-Syp214LegacySkill {
    param([string]$Repository, [string]$UserHome, [int]$SchemaVersion = 2)
    $entries = @()
    foreach ($relative in @('SKILL.md', 'assets/data.bin')) {
        $path = ".agents/skills/syp214-fixture/$relative"
        $full = Join-Path $Repository $path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        [IO.File]::WriteAllBytes($full, [byte[]]@(0x80, 0x81, 0x0a))
        $entries += [pscustomobject][ordered]@{
            artifactType='skill'; artifactId='syp214-fixture'; sourceId='test-skills'
            sourceRepository='https://example.com/test-skills.git'; sourceRef='main'
            sourceCommit=('b'*40); sourceVersion='test@bbbbbbbb'
            sourcePath="$(if ($SchemaVersion -eq 3) { 'skills' } else { '.agents/skills' })/syp214-fixture/$relative"
            targetPath=$path; sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{schemaVersion=$SchemaVersion; catalogId='test-catalog'; lockSha256=('a'*64); files=$entries}
    New-Item -ItemType Directory -Force -Path (Join-Path $Repository '.codex') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Repository $script:ManifestPath), ($manifest | ConvertTo-Json -Depth 10) + "`n")
    [IO.File]::AppendAllText((Join-Path $Repository '.git/info/exclude'), "`n/.agents/skills/`n/.codex/`n")
    if ($UserHome) {
        foreach ($entry in $entries) {
            $full = Join-Path $UserHome $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::Copy((Join-Path $Repository $entry.targetPath), $full)
        }
        $userEntries = @($entries | ForEach-Object {
            [ordered]@{skillId=$_.artifactId; sourceId=$_.sourceId; sourceRepository=$_.sourceRepository
                sourceRef=$_.sourceRef; sourceCommit=$_.sourceCommit; sourceVersion=$_.sourceVersion
                sourcePath=$_.sourcePath; targetPath=$_.targetPath; sha256=$_.sha256}
        })
        $userManifest = [ordered]@{schemaVersion=$(if ($SchemaVersion -eq 3) {2} else {1})
            catalogRepository='https://example.com/ai-instructions.git'; catalogCommit=('c'*40)
            catalogId='test-catalog'; lockSha256=('a'*64); files=$userEntries}
        [IO.File]::WriteAllText((Join-Path $UserHome '.agents/catalog-skills.manifest.json'), ($userManifest | ConvertTo-Json -Depth 10))
        # The real USER updater retains its coordination file after installation.
        $fixtureLock = [IO.File]::Open((Join-Path $UserHome '.agents/update-agent-environment.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fixtureLock.Dispose()
    }
    return $entries
}

function Set-Syp214SingleFileSkillFixture {
    param([string]$Repository,[string]$UserHome,[object[]]$Entries)
    $skillEntry=@($Entries | Where-Object { [string]$_.targetPath -ceq '.agents/skills/syp214-fixture/SKILL.md' })
    if($skillEntry.Count -ne 1){ throw 'Expected one fixture Skill.md entry.' }
    foreach($entry in @($Entries | Where-Object { [string]$_.targetPath -cne '.agents/skills/syp214-fixture/SKILL.md' })){
        $roots=@($Repository,$UserHome) | Select-Object -Unique
        foreach($root in $roots){
            $path=Join-Path $root ([string]$entry.targetPath)
            if(Test-Path -LiteralPath $path -PathType Leaf){ Remove-Item -LiteralPath $path -Force }
        }
    }
    $repositoryManifestPath=Join-Path $Repository $script:ManifestPath
    $repositoryManifest=Get-Content -Raw -Encoding UTF8 -LiteralPath $repositoryManifestPath | ConvertFrom-Json
    $repositoryManifest.files=@($repositoryManifest.files | Where-Object { [string]$_.targetPath -ceq [string]$skillEntry[0].targetPath })
    [IO.File]::WriteAllText($repositoryManifestPath,($repositoryManifest | ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))
    $userManifestPath=Join-Path $UserHome '.agents/catalog-skills.manifest.json'
    $userManifest=Get-Content -Raw -Encoding UTF8 -LiteralPath $userManifestPath | ConvertFrom-Json
    $userManifest.files=@($userManifest.files | Where-Object { [string]$_.targetPath -ceq [string]$skillEntry[0].targetPath })
    [IO.File]::WriteAllText($userManifestPath,($userManifest | ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))
    return ,$skillEntry
}

function New-Syp214SubstAlias {
    param([string]$TargetRoot)
    $substPath=Join-Path $env:SystemRoot 'System32/subst.exe'
    foreach($letter in @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N')){
        if(Get-PSDrive -Name $letter -ErrorAction SilentlyContinue){continue}
        $drive=$letter+':'
        & $substPath $drive ([IO.Path]::GetFullPath($TargetRoot)) | Out-Null
        if($LASTEXITCODE -eq 0){return [pscustomobject]@{drive=$drive;path=($drive+'\')}}
    }
    throw 'No unused drive letter was available for the SYP214 SUBST alias fixture.'
}

function Remove-Syp214SubstAlias {
    param([object]$Alias)
    if($null -eq $Alias){return}
    $substPath=Join-Path $env:SystemRoot 'System32/subst.exe'
    & $substPath /D ([string]$Alias.drive) | Out-Null
    if($LASTEXITCODE -ne 0){throw "Could not remove the SYP214 temporary SUBST alias $($Alias.drive)."}
}

function Remove-Syp214TemporaryRecoveryRoot {
    param([string]$Path,[string]$ExpectedPrefix)
    $fullPath=[IO.Path]::GetFullPath($Path)
    $tempPath=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
    $tempPrefix=$tempPath+[IO.Path]::DirectorySeparatorChar
    if(-not $fullPath.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetDirectoryName($fullPath)).Equals($tempPath,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $fullPath) -cnotmatch ('^'+[regex]::Escape($ExpectedPrefix)+'[0-9a-f]{32}$')){
        throw 'Refusing to remove a SYP214 recovery fixture outside its exact temporary task directory.'
    }
    if(-not (Test-Path -LiteralPath $fullPath)){return}
    $pending=[System.Collections.Generic.Stack[string]]::new()
    $pending.Push($fullPath)
    while($pending.Count -gt 0){
        $directory=$pending.Pop()
        $item=Get-Item -Force -LiteralPath $directory
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
            throw 'Refusing recursive cleanup because a SYP214 temporary recovery fixture contains a reparse point.'
        }
        if(-not $item.PSIsContainer){continue}
        foreach($child in @(Get-ChildItem -Force -LiteralPath $directory -ErrorAction Stop)){
            if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                throw 'Refusing recursive cleanup because a SYP214 temporary recovery fixture contains a reparse point.'
            }
            if($child.PSIsContainer){$pending.Push($child.FullName)}
        }
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Get-Syp214GitInfoExcludeFixturePath {
    param([string]$Repository)
    $relativePath=(Invoke-TestGit -Repository $Repository -Arguments @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
    if([IO.Path]::IsPathRooted($relativePath)){return [IO.Path]::GetFullPath($relativePath)}
    return [IO.Path]::GetFullPath((Join-Path $Repository $relativePath))
}

function Get-Syp214CrashWriterHandleInspectionSource {
    @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Syp214.TestSupport
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeFileTime
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeByHandleFileInformation
    {
        public uint FileAttributes;
        public NativeFileTime CreationTime;
        public NativeFileTime LastAccessTime;
        public NativeFileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public sealed class CrashWriterHandleEvidence
    {
        public string FinalPath { get; private set; }
        public uint VolumeSerialNumber { get; private set; }
        public uint FileIndexHigh { get; private set; }
        public uint FileIndexLow { get; private set; }
        public uint NumberOfLinks { get; private set; }
        public uint NativeFileType { get; private set; }
        public uint FileAttributes { get; private set; }
        public long Length { get; private set; }
        public bool RegularFile { get; private set; }

        internal CrashWriterHandleEvidence(string finalPath, NativeByHandleFileInformation information, uint nativeFileType)
        {
            FinalPath = finalPath;
            VolumeSerialNumber = information.VolumeSerialNumber;
            FileIndexHigh = information.FileIndexHigh;
            FileIndexLow = information.FileIndexLow;
            NumberOfLinks = information.NumberOfLinks;
            NativeFileType = nativeFileType;
            FileAttributes = information.FileAttributes;
            Length = ((long)information.FileSizeHigh << 32) | information.FileSizeLow;
            RegularFile = nativeFileType == 1 &&
                (information.FileAttributes & (0x10u | 0x400u)) == 0 &&
                information.NumberOfLinks == 1;
        }
    }

    public static class CrashWriterHandleInspection
    {
        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "GetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out NativeByHandleFileInformation information);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "GetFileType")]
        private static extern uint GetFileType(SafeFileHandle file);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true,
            EntryPoint = "GetFinalPathNameByHandleW", ExactSpelling = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags);

        public static CrashWriterHandleEvidence Capture(SafeFileHandle file)
        {
            if (file == null || file.IsInvalid || file.IsClosed)
            {
                throw new ArgumentException("Crash-writer evidence requires a live held file handle.", "file");
            }

            NativeByHandleFileInformation information;
            if (!GetFileInformationByHandle(file, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read identity from the held crash-writer handle.");
            }

            uint nativeFileType = GetFileType(file);
            if (nativeFileType == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read type from the held crash-writer handle.");
            }

            uint capacity = 1024;
            string finalPath = null;
            while (capacity <= 32768)
            {
                StringBuilder path = new StringBuilder((int)capacity);
                uint length = GetFinalPathNameByHandleW(file, path, capacity, 0);
                if (length == 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve the held crash-writer handle path.");
                }
                if (length < capacity)
                {
                    finalPath = path.ToString().Replace('/', '\\');
                    break;
                }
                capacity = length + 1;
            }
            if (String.IsNullOrEmpty(finalPath))
            {
                throw new IOException("The held crash-writer handle path exceeded the supported evidence bound.");
            }

            return new CrashWriterHandleEvidence(finalPath, information, nativeFileType);
        }
    }
}
'@
}

function Get-Syp214CrashWriterHandleEvidence {
    param([Parameter(Mandatory=$true)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    if(-not ('Syp214.TestSupport.CrashWriterHandleInspection' -as [type])){
        Add-Type -TypeDefinition (Get-Syp214CrashWriterHandleInspectionSource) -Language CSharp
    }
    return [Syp214.TestSupport.CrashWriterHandleInspection]::Capture($Handle)
}

function ConvertTo-Syp214HandleFinalPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $normalized=$Path.Replace('/','\')
    if($normalized.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){
        $normalized='\\'+$normalized.Substring(8)
    }
    elseif($normalized.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith('\??\',[StringComparison]::OrdinalIgnoreCase)){
        $normalized=$normalized.Substring(4)
    }
    return [IO.Path]::GetFullPath($normalized)
}

function Get-Syp214MeasuredCrashWriterEvidence {
    param([Parameter(Mandatory=$true)][IO.FileStream]$Stream)
    $native=Get-Syp214CrashWriterHandleEvidence -Handle $Stream.SafeFileHandle
    $Stream.Position=0
    $memory=[IO.MemoryStream]::new()
    try{
        $Stream.CopyTo($memory)
        [byte[]]$bytes=$memory.ToArray()
    }
    finally{$memory.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([Convert]::ToHexString($sha.ComputeHash($bytes))).ToLowerInvariant()}
    finally{$sha.Dispose()}
    if([long]$native.Length -ne [long]$bytes.LongLength){
        throw 'SYP214 held-handle length did not match the bytes read from that same stream.'
    }
    [ordered]@{
        finalPath=[string]$native.FinalPath
        volumeSerialNumber=[uint32]$native.VolumeSerialNumber
        fileIndexHigh=[uint32]$native.FileIndexHigh
        fileIndexLow=[uint32]$native.FileIndexLow
        numberOfLinks=[uint32]$native.NumberOfLinks
        nativeFileType=[uint32]$native.NativeFileType
        fileAttributes=[uint32]$native.FileAttributes
        regularFile=[bool]$native.RegularFile
        type=$(if([bool]$native.RegularFile){'file'}else{'non-regular'})
        length=[long]$native.Length
        sha256=$hash
    }
}

function Get-Syp214PathCrashWriterEvidence {
    param([Parameter(Mandatory=$true)][string]$Path)
    $item=Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
        throw 'SYP214 crash-writer evidence path is not a regular, non-reparse file.'
    }
    $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
    try{return Get-Syp214MeasuredCrashWriterEvidence -Stream $stream}
    finally{$stream.Dispose()}
}

function Test-Syp214CrashWriterEvidenceMatchesPath {
    param([Parameter(Mandatory=$true)][object]$Evidence,[Parameter(Mandatory=$true)][string]$Path)
    try{$actual=Get-Syp214PathCrashWriterEvidence -Path $Path}
    catch{return $false}
    return ([string]$Evidence.type -ceq 'file' -and [bool]$Evidence.regularFile -and
        [uint32]$Evidence.nativeFileType -eq 1 -and [uint32]$Evidence.numberOfLinks -eq 1 -and
        [string](ConvertTo-Syp214HandleFinalPath ([string]$Evidence.finalPath)) -ceq
            [string](ConvertTo-Syp214HandleFinalPath ([string]$actual.finalPath)) -and
        [uint32]$Evidence.volumeSerialNumber -eq [uint32]$actual.volumeSerialNumber -and
        [uint32]$Evidence.fileIndexHigh -eq [uint32]$actual.fileIndexHigh -and
        [uint32]$Evidence.fileIndexLow -eq [uint32]$actual.fileIndexLow -and
        [string]$Evidence.type -ceq [string]$actual.type -and
        [long]$Evidence.length -eq [long]$actual.length -and
        [string]$Evidence.sha256 -ceq [string]$actual.sha256)
}

function Test-Syp214CrashWriterStageIfRetained {
    param([Parameter(Mandatory=$true)][object]$Evidence,[Parameter(Mandatory=$true)][string]$FinalPath)
    $evidencePath=ConvertTo-Syp214HandleFinalPath ([string]$Evidence.finalPath)
    $finalFullPath=[IO.Path]::GetFullPath($FinalPath)
    if($evidencePath.Equals($finalFullPath,[StringComparison]::OrdinalIgnoreCase)){return $true}
    $evidenceParent=[IO.Path]::GetDirectoryName($evidencePath)
    $finalParent=[IO.Path]::GetDirectoryName($finalFullPath)
    if(-not $evidenceParent.Equals($finalParent,[StringComparison]::OrdinalIgnoreCase) -or
        [string]$Evidence.type -cne 'file' -or -not [bool]$Evidence.regularFile -or
        [uint32]$Evidence.nativeFileType -ne 1 -or [uint32]$Evidence.numberOfLinks -ne 1){return $false}
    if(-not (Test-Path -LiteralPath $evidencePath)){return $true}
    if(-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)){return $false}
    return Test-Syp214CrashWriterEvidenceMatchesPath -Evidence $Evidence -Path $evidencePath
}

function Test-Syp214CrashRecoveryRepositoryTree {
    param(
        [Parameter(Mandatory=$true)][object[]]$Before,
        [Parameter(Mandatory=$true)][object[]]$After,
        [Parameter(Mandatory=$true)][object]$Evidence,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$FinalPath
    )
    if(Test-Syp214InventoryEqual -Left $Before -Right $After){return $true}
    $beforeRecords=@($Before)
    $afterRecords=@($After)
    foreach($record in $beforeRecords){
        $matches=@($afterRecords | Where-Object { [string]$_.relativePath -ceq [string]$record.relativePath })
        if($matches.Count -ne 1 -or -not (Test-Syp214FileInventoryRecordEqual -Left $record -Right $matches[0])){return $false}
    }
    $extras=@($afterRecords | Where-Object {
        $candidate=$_
        @($beforeRecords | Where-Object { [string]$_.relativePath -ceq [string]$candidate.relativePath }).Count -eq 0
    })
    if($extras.Count -ne 1){return $false}
    $evidencePath=ConvertTo-Syp214HandleFinalPath ([string]$Evidence.finalPath)
    $finalFullPath=[IO.Path]::GetFullPath($FinalPath)
    if($evidencePath.Equals($finalFullPath,[StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Syp214CrashWriterStageIfRetained -Evidence $Evidence -FinalPath $FinalPath)){return $false}
    $rootFullPath=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]@('\','/'))
    $rootPrefix=$rootFullPath+[IO.Path]::DirectorySeparatorChar
    if(-not $evidencePath.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){return $false}
    $relativePath=$evidencePath.Substring($rootPrefix.Length).Replace('\','/')
    $extra=$extras[0]
    $expected=[pscustomobject][ordered]@{
        relativePath=$relativePath;type='file';regularFile=$true
        length=[long]$Evidence.length;sha256=[string]$Evidence.sha256
    }
    return ((Test-Syp214FileInventoryRecordEqual -Left $extra -Right $expected) -and
        (Test-Syp214CrashWriterEvidenceMatchesPath -Evidence $Evidence -Path $evidencePath))
}

function New-Syp214WriterCrashChildScript {
    $nativeEvidenceSource=Get-Syp214CrashWriterHandleInspectionSource
    $childScript=@'
param([string]$BootstrapScriptPath,[string]$TargetRoot,[string]$UserHome,[string]$RecoveryRoot,[string]$RelativePath,[string]$WriterKind,[string]$MarkerPath,[string]$CompletionPath)
$ErrorActionPreference='Stop'
$nativeEvidenceSource=@"
__SYP214_NATIVE_HANDLE_EVIDENCE__
"@
Add-Type -TypeDefinition $nativeEvidenceSource -Language CSharp
function Get-Syp214ChildMeasuredHandleEvidence {
    param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,[Parameter(Mandatory=$true)][string]$WriterKind)
    $native=[Syp214.TestSupport.CrashWriterHandleInspection]::Capture($Stream.SafeFileHandle)
    $Stream.Position=0
    $memory=[IO.MemoryStream]::new()
    try{$Stream.CopyTo($memory);[byte[]]$bytes=$memory.ToArray()}
    finally{$memory.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([Convert]::ToHexString($sha.ComputeHash($bytes))).ToLowerInvariant()}
    finally{$sha.Dispose()}
    if([long]$native.Length -ne [long]$bytes.LongLength){
        throw 'SYP214 child held-handle length did not match bytes read from its stream.'
    }
    [ordered]@{
        writerKind=$WriterKind
        finalPath=[string]$native.FinalPath
        volumeSerialNumber=[uint32]$native.VolumeSerialNumber
        fileIndexHigh=[uint32]$native.FileIndexHigh
        fileIndexLow=[uint32]$native.FileIndexLow
        numberOfLinks=[uint32]$native.NumberOfLinks
        nativeFileType=[uint32]$native.NativeFileType
        fileAttributes=[uint32]$native.FileAttributes
        regularFile=[bool]$native.RegularFile
        type=$(if([bool]$native.RegularFile){'file'}else{'non-regular'})
        length=[long]$native.Length
        sha256=$hash
    }
}
$bootstrapText=[IO.File]::ReadAllText($BootstrapScriptPath)
$prefixEnd=$bootstrapText.IndexOf('$syncStartPath = ',[StringComparison]::Ordinal)
if($prefixEnd -lt 0){throw 'Could not find the bootstrap definition prefix boundary.'}
$bootstrapRoot=Split-Path -Parent $BootstrapScriptPath
$bootstrapRootLiteral="'"+$bootstrapRoot.Replace("'","''")+"'"
$prefixText=$bootstrapText.Substring(0,$prefixEnd).Replace('$PSScriptRoot',$bootstrapRootLiteral)
. ([scriptblock]::Create($prefixText)) -TargetRoot $TargetRoot -UserHome $UserHome -GitExecutable 'git'
$backupRoot=Join-Path $RecoveryRoot 'target-backup'
$journalPath=Join-Path $backupRoot 'skill-migration.json'
$snapshot=New-TargetMutationSnapshot -TargetRoot $TargetRoot -RelativePaths @($RelativePath) -BackupRoot $backupRoot
$excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $TargetRoot
$gitState=Get-RepoSkillMigrationGitState -Repository $TargetRoot -GitExecutable 'git'
Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot -Path $journalPath -GitState $gitState -Phase 'mutating'
$script:SkillMigrationJournalContext=[pscustomobject]@{Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState}
$writerPath=if($WriterKind -ceq 'target'){'Function:\Write-TargetMutationStreamBytes'}else{'Function:\Write-GitInfoExcludeStreamBytes'}
$processId=$PID
$prefixWriter={
    param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,[Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $Stream.Position=0
    $Stream.SetLength(0)
    $prefixLength=[Math]::Min(3,$Bytes.Length)
    if($prefixLength -gt 0){$Stream.Write($Bytes,0,$prefixLength)}
    $Stream.Flush($true)
    $evidence=Get-Syp214ChildMeasuredHandleEvidence -Stream $Stream -WriterKind $WriterKind
    if(-not [bool]$evidence.regularFile -or [string]$evidence.type -cne 'file'){
        throw 'SYP214 flushed writer handle did not identify one regular disk file.'
    }
    [IO.File]::WriteAllText($MarkerPath,($evidence | ConvertTo-Json -Depth 4 -Compress),[Text.UTF8Encoding]::new($false))
    Stop-Process -Id $processId -Force
}.GetNewClosure()
Set-Item -Path $writerPath -Value $prefixWriter
if($WriterKind -ceq 'target'){
    Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $RelativePath -Bytes ([Text.Encoding]::UTF8.GetBytes('# applied replacement'+"`n"))
}
else{
    Set-ManagedGitInfoExclude -Repository $TargetRoot -ManagedPaths @($RelativePath) -Snapshot $excludeSnapshot
}
[IO.File]::WriteAllText($CompletionPath,'writer unexpectedly returned',[Text.UTF8Encoding]::new($false))
'@
    return $childScript.Replace('__SYP214_NATIVE_HANDLE_EVIDENCE__',$nativeEvidenceSource)
}

function New-Syp214RenameCrashChildScript {
    return @'
param([string]$BootstrapScriptPath,[string]$TargetRoot,[string]$UserHome,[string]$RecoveryRoot,[string]$RelativePath,[string]$WriterKind,[string]$MarkerPath,[string]$CompletionPath)
$ErrorActionPreference='Stop'
$bootstrapText=[IO.File]::ReadAllText($BootstrapScriptPath)
$prefixEnd=$bootstrapText.IndexOf('$syncStartPath = ',[StringComparison]::Ordinal)
if($prefixEnd -lt 0){throw 'Could not find the bootstrap definition prefix boundary.'}
$bootstrapRoot=Split-Path -Parent $BootstrapScriptPath
$bootstrapRootLiteral="'"+$bootstrapRoot.Replace("'","''")+"'"
$prefixText=$bootstrapText.Substring(0,$prefixEnd).Replace('$PSScriptRoot',$bootstrapRootLiteral)
. ([scriptblock]::Create($prefixText)) -TargetRoot $TargetRoot -UserHome $UserHome -GitExecutable 'git'
$backupRoot=Join-Path $RecoveryRoot 'target-backup'
$journalPath=Join-Path $backupRoot 'skill-migration.json'
$snapshot=New-TargetMutationSnapshot -TargetRoot $TargetRoot -RelativePaths @($RelativePath) -BackupRoot $backupRoot
$excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $TargetRoot
$gitState=Get-RepoSkillMigrationGitState -Repository $TargetRoot -GitExecutable 'git'
Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot -Path $journalPath -GitState $gitState -Phase 'mutating'
$script:SkillMigrationJournalContext=[pscustomobject]@{Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState}
$realRename=(Get-Command Invoke-AtomicFilePublicationRename -CommandType Function).ScriptBlock
$processId=$PID
$dieAfterTombstone={
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,[string]$DestinationPath)
    & $realRename -Handle $Handle -DestinationPath $DestinationPath
    if([IO.Path]::GetFileName($DestinationPath) -match '-[0-9a-f]{32}-tomb$'){
        [IO.File]::WriteAllText($MarkerPath,$DestinationPath,[Text.UTF8Encoding]::new($false))
        Stop-Process -Id $processId -Force
    }
}.GetNewClosure()
Set-Item -Path 'Function:\Invoke-AtomicFilePublicationRename' -Value $dieAfterTombstone
if($WriterKind -ceq 'target'){
    Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $RelativePath -Bytes ([Text.Encoding]::UTF8.GetBytes('# staged replacement'+"`n"))
}
else{
    Set-ManagedGitInfoExclude -Repository $TargetRoot -ManagedPaths @($RelativePath) -Snapshot $excludeSnapshot
}
[IO.File]::WriteAllText($CompletionPath,'publication unexpectedly returned',[Text.UTF8Encoding]::new($false))
'@
}

function New-Syp214RestoreCrashChildScript {
    return @'
param([string]$BootstrapScriptPath,[string]$TargetRoot,[string]$UserHome,[string]$JournalPath,[string]$CrashAt,[string]$MarkerPath,[string]$CompletionPath)
$ErrorActionPreference='Stop'
$bootstrapText=[IO.File]::ReadAllText($BootstrapScriptPath)
$prefixEnd=$bootstrapText.IndexOf('$syncStartPath = ',[StringComparison]::Ordinal)
if($prefixEnd -lt 0){throw 'Could not find the bootstrap definition prefix boundary.'}
$bootstrapRoot=Split-Path -Parent $BootstrapScriptPath
$bootstrapRootLiteral="'"+$bootstrapRoot.Replace("'","''")+"'"
$prefixText=$bootstrapText.Substring(0,$prefixEnd).Replace('$PSScriptRoot',$bootstrapRootLiteral)
. ([scriptblock]::Create($prefixText)) -TargetRoot $TargetRoot -UserHome $UserHome -GitExecutable 'git'
$processId=$PID
if($CrashAt -ceq 'restore-first-rename'){
    $realRename=(Get-Command Invoke-AtomicFilePublicationRename -CommandType Function).ScriptBlock
    $dieAfterOldRename={
        param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,[string]$DestinationPath)
        & $realRename -Handle $Handle -DestinationPath $DestinationPath
        if([IO.Path]::GetFileName($DestinationPath) -match '-[0-9a-f]{32}-tomb$'){
            [IO.File]::WriteAllText($MarkerPath,$DestinationPath,[Text.UTF8Encoding]::new($false))
            Stop-Process -Id $processId -Force
        }
    }.GetNewClosure()
    Set-Item -Path 'Function:\Invoke-AtomicFilePublicationRename' -Value $dieAfterOldRename
}
elseif($CrashAt -ceq 'restore-stage-cleanup'){
    $realRemove=(Get-Command Remove-VerifiedPublicationFile -CommandType Function).ScriptBlock
    $dieAfterStageRemoval={
        param([string]$Root,[string]$Path,[string]$RelativePath,[string]$Kind,[string]$Identity,[string]$Sha256,[long]$Length)
        & $realRemove -Root $Root -Path $Path -RelativePath $RelativePath -Kind $Kind `
            -Identity $Identity -Sha256 $Sha256 -Length $Length
        if([IO.Path]::GetFileName($Path) -match '-[0-9a-f]{32}-stage$'){
            [IO.File]::WriteAllText($MarkerPath,$Path,[Text.UTF8Encoding]::new($false))
            Stop-Process -Id $processId -Force
        }
    }.GetNewClosure()
    Set-Item -Path 'Function:\Remove-VerifiedPublicationFile' -Value $dieAfterStageRemoval
}
else{throw 'Unknown SYP214 recovery crash seam.'}
Restore-SkillMigrationJournal -Repository $TargetRoot -Path $JournalPath | Out-Null
[IO.File]::WriteAllText($CompletionPath,'recovery unexpectedly completed',[Text.UTF8Encoding]::new($false))
'@
}

function Invoke-Syp214RestoreCrashChild {
    param([string]$RecoveryRoot,[string]$TargetRoot,[string]$UserHome,[string]$JournalPath,[string]$CrashAt)
    $childScriptPath=Join-Path $RecoveryRoot 'restore-crash-child.ps1'
    $markerPath=Join-Path $RecoveryRoot ($CrashAt+'.marker')
    $completionPath=Join-Path $RecoveryRoot ($CrashAt+'.completion')
    $stdoutPath=Join-Path $RecoveryRoot ($CrashAt+'.stdout.log')
    $stderrPath=Join-Path $RecoveryRoot ($CrashAt+'.stderr.log')
    [IO.File]::WriteAllText($childScriptPath,(New-Syp214RestoreCrashChildScript),[Text.UTF8Encoding]::new($false))
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$childScriptPath,
        $script:BootstrapScript,$TargetRoot,$UserHome,$JournalPath,$CrashAt,$markerPath,$completionPath)
    $argumentLine=[string]::Join(' ',@($arguments | ForEach-Object { '"'+([string]$_).Replace('"','\"')+'"' }))
    $process=Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $argumentLine `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if(-not $process.WaitForExit(30000)){
        Stop-Process -Id $process.Id -Force
        throw "SYP214 $CrashAt recovery child exceeded its bounded 30-second wait."
    }
    $process.Refresh()
    return [pscustomobject][ordered]@{ExitCode=$process.ExitCode;MarkerPath=$markerPath
        MarkerExists=(Test-Path -LiteralPath $markerPath -PathType Leaf)
        CompletionExists=(Test-Path -LiteralPath $completionPath -PathType Leaf)
        MarkerValue=$(if(Test-Path -LiteralPath $markerPath -PathType Leaf){Get-Content -Raw -Encoding UTF8 -LiteralPath $markerPath}else{$null})
        StdoutPath=$stdoutPath;StderrPath=$stderrPath}
}

function Invoke-Syp214RenameCrashChild {
    param(
        [Parameter(Mandatory=$true)][string]$RecoveryRoot,
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [Parameter(Mandatory=$true)][string]$UserHome,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$WriterKind
    )
    $childScriptPath=Join-Path $RecoveryRoot 'rename-crash-child.ps1'
    $markerPath=Join-Path $RecoveryRoot 'tombstone-renamed.marker'
    $completionPath=Join-Path $RecoveryRoot 'publication-completed.marker'
    $stdoutPath=Join-Path $RecoveryRoot 'child.stdout.log'
    $stderrPath=Join-Path $RecoveryRoot 'child.stderr.log'
    [IO.File]::WriteAllText($childScriptPath,(New-Syp214RenameCrashChildScript),[Text.UTF8Encoding]::new($false))
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$childScriptPath,
        $script:BootstrapScript,$TargetRoot,$UserHome,$RecoveryRoot,$RelativePath,$WriterKind,$markerPath,$completionPath)
    $argumentLine=[string]::Join(' ',@($arguments | ForEach-Object { '"'+([string]$_).Replace('"','\"')+'"' }))
    $process=Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $argumentLine `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if(-not $process.WaitForExit(30000)){
        Stop-Process -Id $process.Id -Force
        throw 'SYP214 rename crash child exceeded its bounded 30-second wait.'
    }
    $process.Refresh()
    return [pscustomobject][ordered]@{
        ExitCode=$process.ExitCode
        MarkerPath=$markerPath
        MarkerExists=(Test-Path -LiteralPath $markerPath -PathType Leaf)
        CompletionExists=(Test-Path -LiteralPath $completionPath -PathType Leaf)
        TombstonePath=$(if(Test-Path -LiteralPath $markerPath -PathType Leaf){Get-Content -Raw -Encoding UTF8 -LiteralPath $markerPath}else{$null})
        StdoutPath=$stdoutPath
        StderrPath=$stderrPath
    }
}

function Invoke-Syp214Bootstrap {
    param([switch]$WhatIf, [int]$FailureAfterSkillRemovalCount = 0, [string]$RecoverSkillMigration, [switch]$CaptureFailure)
    New-TestProvenance -ArchivePath $sourceArchive -Path $script:TestProvenancePath
    $arguments = @('-NoProfile','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,
        '-TargetRoot',$targetRoot,'-ConfigurationPath',$script:TestConfigurationPath,
        '-ProvenancePath',$script:TestProvenancePath,'-UserHome',$userHome)
    if ($RecoverSkillMigration) { $arguments += @('-RecoverSkillMigration', $RecoverSkillMigration) }
    if ($WhatIf) { $arguments += '-WhatIf' }
    if ($FailureAfterSkillRemovalCount) { $arguments += @('-FailureAfterSkillRemovalCount', $FailureAfterSkillRemovalCount) }
    $output = & $script:TestPowerShellExecutable @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($CaptureFailure) {
        return [pscustomobject][ordered]@{ exitCode=$exitCode; output=@($output | ForEach-Object { [string]$_ }) }
    }
    if ($exitCode -ne 0) { throw ($output -join "`n") }
    return $output
}

function Get-Syp214RepositoryTransactionRoot {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $gitOutput=@(& git -C $Repository rev-parse --absolute-git-dir 2>$null)
    $gitExitCode=$LASTEXITCODE
    $gitDirectory=@($gitOutput | Select-Object -First 1)
    if($gitExitCode -ne 0 -or $gitDirectory.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$gitDirectory[0])){
        throw 'Could not resolve the SYP214 fixture Git directory.'
    }
    return (Join-Path ([IO.Path]::GetFullPath(([string]$gitDirectory[0]).Trim())) '.ai-instructions-txn')
}

function New-Syp214UnifiedTransactionBootstrap {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Failpoint
    )
    $scriptRoot=Join-Path $Root 'scripts'
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination $scriptRoot -Recurse
    $bootstrapPath=Join-Path $scriptRoot 'bootstrap-ai-instructions.ps1'
    $bootstrapText=[IO.File]::ReadAllText($bootstrapPath)
    if($Failpoint -ceq 'RecoveryOnly'){
        $invocation='            Invoke-ProjectPublicationRecovery -Repository $targetRootPath -GitDirectory $activeGitDirectory'
        if(-not$bootstrapText.Contains($invocation)){throw 'Unified recovery invocation was not found.'}
        $bootstrapText=$bootstrapText.Replace($invocation,$invocation+"`n            throw 'Injected SYP214 RecoveryOnly failure.'")
    }
    else{
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($bootstrapText,[ref]$tokens,[ref]$parseErrors)
        if(@($parseErrors).Count -ne 0 -or $null -eq $ast.ParamBlock){throw 'Unified failpoint bootstrap has no valid param block.'}
        $prefix="`n[Environment]::SetEnvironmentVariable('AI_INSTRUCTIONS_INSTALL_FAILPOINT','$Failpoint','Process')`n"
        $bootstrapText=$bootstrapText.Insert($ast.ParamBlock.Extent.EndOffset,$prefix)
    }
    [IO.File]::WriteAllText($bootstrapPath,$bootstrapText,[Text.UTF8Encoding]::new($false))
    return $bootstrapPath
}

function Invoke-Syp214ManifestIntentExitChild {
    param(
        [Parameter(Mandatory=$true)][string]$RecoveryRoot,
        [Parameter(Mandatory=$true)][string]$SourceArchivePath,
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [Parameter(Mandatory=$true)][string]$ConfigurationPath,
        [Parameter(Mandatory=$true)][string]$ProvenancePath,
        [Parameter(Mandatory=$true)][string]$UserHome
    )
    $childScriptPath=Join-Path $RecoveryRoot 'manifest-intent-exit-child.ps1'
    $markerPath=Join-Path $RecoveryRoot 'manifest-intent.marker.json'
    $stdoutPath=Join-Path $RecoveryRoot 'manifest-intent.stdout.log'
    $stderrPath=Join-Path $RecoveryRoot 'manifest-intent.stderr.log'
    $bootstrapText=[IO.File]::ReadAllText($script:BootstrapScript)
    $prefixEnd=$bootstrapText.IndexOf('$syncStartPath = ',[StringComparison]::Ordinal)
    if($prefixEnd -lt 0){throw 'Could not find the bootstrap definition prefix boundary.'}
    $bootstrapRoot=Split-Path -Parent $script:BootstrapScript
    $bootstrapRootLiteral="'"+$bootstrapRoot.Replace("'","''")+"'"
    $prefixText=$bootstrapText.Substring(0,$prefixEnd).Replace('$PSScriptRoot',$bootstrapRootLiteral)
    $markerLiteral="'"+$markerPath.Replace("'","''")+"'"
    $hookTemplate=@'
$realRename=(Get-Command Invoke-AtomicFilePublicationRename -CommandType Function).ScriptBlock
$markerPath=__SYP214_MARKER_PATH__
$exitAtManifestIntent={
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,[string]$DestinationPath)
    $context=$script:SkillMigrationJournalContext
    $manifestState=$null
    if($null -ne $context){
        $manifestState=@($context.Snapshot.FileStates | Where-Object { [string]$_.RelativePath -ceq $manifestRelativePath } | Select-Object -First 1)[0]
    }
    if($null -ne $manifestState -and $null -ne $manifestState.Publication -and
        [string]$manifestState.Publication.direction -ceq 'apply'){
        $expectedDestination=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent ([string]$manifestState.TargetPath)) `
            ([string]$manifestState.Publication.tombstoneLeaf)))
        if([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($DestinationPath),$expectedDestination)){
            [ordered]@{journalPath=[string]$context.Path;relativePath=[string]$manifestState.RelativePath
                direction=[string]$manifestState.Publication.direction
                expectedOldIdentity=[string]$manifestState.Publication.expectedOldIdentity
                stageIdentity=[string]$manifestState.Publication.stageIdentity} |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $markerPath -Encoding UTF8
            exit 0
        }
    }
    & $realRename -Handle $Handle -DestinationPath $DestinationPath
}
Set-Item -Path 'Function:\Invoke-AtomicFilePublicationRename' -Value $exitAtManifestIntent
'@
    $hookText=$hookTemplate.Replace('__SYP214_MARKER_PATH__',$markerLiteral)
    $childText=$prefixText+"`n"+$hookText+"`n"+$bootstrapText.Substring($prefixEnd)
    [IO.File]::WriteAllText($childScriptPath,$childText,[Text.UTF8Encoding]::new($false))
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$childScriptPath,
        '-SourceArchivePath',$SourceArchivePath,'-TargetRoot',$TargetRoot,'-ConfigurationPath',$ConfigurationPath,
        '-ProvenancePath',$ProvenancePath,'-GitExecutable','git','-UserHome',$UserHome)
    $argumentLine=[string]::Join(' ',@($arguments | ForEach-Object { '"'+([string]$_).Replace('"','\"')+'"' }))
    $process=Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $argumentLine `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if(-not $process.WaitForExit(120000)){
        Stop-Process -Id $process.Id -Force
        $stdoutDiagnostic=if(Test-Path -LiteralPath $stdoutPath -PathType Leaf){[IO.File]::ReadAllText($stdoutPath)}else{''}
        $stderrDiagnostic=if(Test-Path -LiteralPath $stderrPath -PathType Leaf){[IO.File]::ReadAllText($stderrPath)}else{''}
        if($stdoutDiagnostic.Length -gt 1200){$stdoutDiagnostic=$stdoutDiagnostic.Substring(0,1200)}
        if($stderrDiagnostic.Length -gt 1200){$stderrDiagnostic=$stderrDiagnostic.Substring(0,1200)}
        throw ("SYP214 manifest-intent child exceeded its bounded 120-second wait. stdout: {0}; stderr: {1}" -f $stdoutDiagnostic,$stderrDiagnostic)
    }
    $process.Refresh()
    $marker=$null
    if(Test-Path -LiteralPath $markerPath -PathType Leaf){
        $marker=Get-Content -Raw -Encoding UTF8 -LiteralPath $markerPath | ConvertFrom-Json
    }
    return [pscustomobject][ordered]@{ExitCode=$process.ExitCode;MarkerPath=$markerPath;MarkerExists=($null -ne $marker)
        Marker=$marker;StdoutPath=$stdoutPath;StderrPath=$stderrPath}
}

function Get-Syp214FileInventory {
    param([string]$Root,[string[]]$RelativePaths)
    $resolvedRoot=[IO.Path]::GetFullPath($Root)
    foreach($relative in @($RelativePaths | Sort-Object -Unique)){
        $normalized=[string]$relative -replace '\\','/'
        $full=Join-Path $resolvedRoot $normalized.Replace('/',[string][IO.Path]::DirectorySeparatorChar)
        if(Test-Path -LiteralPath $full){
            $item=Get-Item -Force -LiteralPath $full
            if($item.PSIsContainer){
                [ordered]@{relativePath=$normalized;type='directory';regularFile=$false;length=$null;sha256=$null}
            }
            elseif(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                [ordered]@{relativePath=$normalized;type='reparse-point';regularFile=$false;length=$null;sha256=$null}
            }
            else{
                [ordered]@{relativePath=$normalized;type='file';regularFile=$true;length=[long]$item.Length
                    sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
        }
        else{
            [ordered]@{relativePath=$normalized;type='missing';regularFile=$false;length=$null;sha256=$null}
        }
    }
}

function Get-Syp214TreeInventory {
    param([string]$Root)
    $resolvedRoot=[IO.Path]::GetFullPath($Root)
    $rootPrefix=$resolvedRoot.TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
    $pending=[System.Collections.Generic.Stack[string]]::new()
    $pending.Push($resolvedRoot)
    $records=[System.Collections.Generic.List[object]]::new()
    while($pending.Count -gt 0){
        $directory=$pending.Pop()
        foreach($item in @(Get-ChildItem -Force -LiteralPath $directory | Sort-Object Name)){
            $relativePath=$item.FullName.Substring($rootPrefix.Length).Replace('\','/')
            if($relativePath -match '(^|/)\.git(?:/|$)'){ continue }
            $isReparsePoint=(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            if($item.PSIsContainer){
                if($isReparsePoint){
                    $records.Add([ordered]@{relativePath=$relativePath;type='reparse-point';regularFile=$false;length=$null;sha256=$null})
                }
                else{
                    $records.Add([ordered]@{relativePath=$relativePath;type='directory';regularFile=$false;length=$null;sha256=$null})
                    $pending.Push($item.FullName)
                }
            }
            elseif($isReparsePoint){
                $records.Add([ordered]@{relativePath=$relativePath;type='reparse-point';regularFile=$false;length=$null;sha256=$null})
            }
            else{
                $records.Add([ordered]@{relativePath=$relativePath;type='file';regularFile=$true;length=[long]$item.Length
                    sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
            }
        }
    }
    # OrderedDictionary records need an explicit key expression; named-property sorting may not read dictionary keys.
    return @($records | Sort-Object { [string]$_['relativePath'] })
}

function Test-Syp214InventoryEqual {
    param([AllowEmptyCollection()][object[]]$Left,[AllowEmptyCollection()][object[]]$Right)
    $leftJson=ConvertTo-Json -InputObject @($Left) -Depth 12 -Compress
    $rightJson=ConvertTo-Json -InputObject @($Right) -Depth 12 -Compress
    return $leftJson -ceq $rightJson
}

function Test-Syp214InventoryComposedFromSnapshots {
    param([object[]]$Before,[object[]]$Applied,[object[]]$Actual)
    $beforeRecords=@($Before);$appliedRecords=@($Applied);$actualRecords=@($Actual)
    foreach($record in $actualRecords){
        $matches=@($beforeRecords+$appliedRecords | Where-Object {
            [string]$_.relativePath -ceq [string]$record.relativePath -and
            (Test-Syp214FileInventoryRecordEqual -Left $_ -Right $record)
        })
        if($matches.Count -eq 0){return $false}
    }
    foreach($path in @(($beforeRecords+$appliedRecords | ForEach-Object { [string]$_.relativePath }) | Sort-Object -Unique)){
        $beforeHas=@($beforeRecords | Where-Object { [string]$_.relativePath -ceq $path }).Count -gt 0
        $appliedHas=@($appliedRecords | Where-Object { [string]$_.relativePath -ceq $path }).Count -gt 0
        $actualHas=@($actualRecords | Where-Object { [string]$_.relativePath -ceq $path }).Count -gt 0
        if($beforeHas -and $appliedHas -and -not$actualHas){return $false}
    }
    return $true
}

function Test-Syp214FileInventoryRecordEqual {
    param([object]$Left,[object]$Right)
    if($null -eq $Left -or $null -eq $Right){ return $false }
    $lengthEqual=if($null -eq $Left.length -or $null -eq $Right.length){
        $null -eq $Left.length -and $null -eq $Right.length
    }
    else{ [long]$Left.length -eq [long]$Right.length }
    return ([string]$Left.relativePath -ceq [string]$Right.relativePath -and
        [string]$Left.type -ceq [string]$Right.type -and
        [bool]$Left.regularFile -eq [bool]$Right.regularFile -and
        $lengthEqual -and [string]$Left.sha256 -ceq [string]$Right.sha256)
}

function Test-Syp214PointInventoryEqual {
    param([object]$Left,[object]$Right)
    return ((Test-Syp214InventoryEqual -Left $Left.files -Right $Right.files) -and
        (Test-Syp214InventoryEqual -Left $Left.missingFileWitness -Right $Right.missingFileWitness))
}

function New-Syp214RepositorySnapshotWithFileOverride {
    param([object]$Snapshot,[object]$TreeFileRecord,[object]$PointFileRecord)
    $relativePath=[string]$TreeFileRecord.relativePath
    if([string]$PointFileRecord.relativePath -cne $relativePath){
        throw "Tree and point inventory drift records disagree on path: $relativePath"
    }
    $originalTreeRecords=@($Snapshot.fullTree | Where-Object { [string]$_.relativePath -ceq $relativePath })
    $originalPointRecords=@($Snapshot.files | Where-Object { [string]$_.relativePath -ceq $relativePath })
    if($originalTreeRecords.Count -ne 1 -or $originalPointRecords.Count -ne 1){
        throw "Expected exactly one original inventory record for drift path: $relativePath"
    }
    # Keep full records for exact comparison while sorting by the dictionary's explicit relativePath key.
    $fullTree=@(@($Snapshot.fullTree | Where-Object { [string]$_.relativePath -cne $relativePath }) + @($TreeFileRecord) | Sort-Object { [string]$_['relativePath'] })
    $files=@(@($Snapshot.files | Where-Object { [string]$_.relativePath -cne $relativePath }) + @($PointFileRecord) | Sort-Object { [string]$_['relativePath'] })
    return [pscustomobject][ordered]@{
        fullTree=$fullTree
        files=$files
        missingFileWitness=@($files | Where-Object { [string]$_.type -ceq 'missing' } | ForEach-Object {
            [ordered]@{relativePath=$_.relativePath;type=$_.type}
        })
    }
}

function Test-Syp214GitCoreStateEqual {
    param([object]$Left,[object]$Right)
    return ([string]$Left.head -ceq [string]$Right.head -and
        (Test-Syp214InventoryEqual -Left @($Left.indexEntries) -Right @($Right.indexEntries)) -and
        (Test-Syp214InventoryEqual -Left @($Left.status) -Right @($Right.status)))
}

function Test-Syp214GitStateEqual {
    param([object]$Left,[object]$Right)
    return ((Test-Syp214GitCoreStateEqual -Left $Left -Right $Right) -and
        (Test-Syp214InventoryEqual -Left @($Left.stashes) -Right @($Right.stashes)))
}

function Get-Syp214GitStatusAll {
    param([Parameter(Mandatory=$true)][string]$Repository)
    return @(Invoke-TestGit $Repository @('status','--porcelain=v1','--untracked-files=all'))
}

function Test-Syp214RegularFileInventory {
    param([object[]]$Inventory)
    return (@($Inventory).Count -eq 1 -and [string]$Inventory[0].type -ceq 'file' -and
        [bool]$Inventory[0].regularFile -and $null -ne $Inventory[0].length -and
        [long]$Inventory[0].length -ge 0 -and [string]$Inventory[0].sha256 -cmatch '^[0-9a-f]{64}$')
}

function Get-Syp214SafeOutputText {
    param([string]$Text,[string[]]$PrivateRoots)
    $safeText=$Text
    foreach($privateRoot in @($PrivateRoots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object Length -Descending -Unique)){
        $resolved=[IO.Path]::GetFullPath([string]$privateRoot).TrimEnd([char[]]@('\','/'))
        if($resolved.Length -gt 2){
            $safeText=[regex]::Replace($safeText,[regex]::Escape($resolved),'<fixture-path>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    return $safeText
}

function New-Syp214UnrelatedEvidenceFiles {
    param([string]$Repository,[string]$UserHome)
    $repositoryPaths=@('.codex/AI-Rules/Personal.md','.github/AI-Rules/Project.md')
    $userPaths=@('AGENTS.md','local-evidence.bin')
    foreach($path in @($repositoryPaths | ForEach-Object { Join-Path $Repository $_ }) + @($userPaths | ForEach-Object { Join-Path $UserHome $_ })){
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    }
    Set-TestText -Path (Join-Path $Repository $repositoryPaths[0]) -Value '# Personal Codex Instructions'
    Set-TestText -Path (Join-Path $Repository $repositoryPaths[1]) -Value '# Project Copilot Instructions'
    Set-TestText -Path (Join-Path $UserHome $userPaths[0]) -Value '# USER home Instructions'
    $userBinaryPath=Join-Path $UserHome $userPaths[1]
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $userBinaryPath) | Out-Null
    [IO.File]::WriteAllBytes($userBinaryPath,[byte[]]@(0x01,0x02,0x03,0xfe))
    return [pscustomobject][ordered]@{repository=[string[]]$repositoryPaths;user=[string[]]$userPaths}
}

function Get-Syp214FixtureSnapshot {
    param([string]$Repository,[string]$UserHome,[object[]]$Entries)
    $repositoryPaths=@(@($Entries | ForEach-Object { [string]$_.targetPath }) + @($script:ManifestPath,'AGENTS.md'))
    $userPaths=@(@($Entries | ForEach-Object { [string]$_.targetPath }) + @('.agents/catalog-skills.manifest.json'))
    $indexPath=Join-Path $Repository '.git/index'
    $repositoryFiles=@(Get-Syp214FileInventory -Root $Repository -RelativePaths $repositoryPaths)
    $userFiles=@(Get-Syp214FileInventory -Root $UserHome -RelativePaths $userPaths)
    $gitExcludeRelativePath=(Invoke-TestGit $Repository @('rev-parse','--git-path','info/exclude') | Select-Object -First 1).Trim()
    if([IO.Path]::IsPathRooted($gitExcludeRelativePath)){
        $gitExcludeFullPath=[IO.Path]::GetFullPath($gitExcludeRelativePath)
        $repositoryPrefix=[IO.Path]::GetFullPath($Repository).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
        if(-not $gitExcludeFullPath.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Fixture Git info/exclude path is outside its disposable repository.'
        }
        $gitExcludeRelativePath=$gitExcludeFullPath.Substring($repositoryPrefix.Length).Replace('\','/')
    }
    else{ $gitExcludeRelativePath=$gitExcludeRelativePath.Replace('\','/') }
    [ordered]@{
        repository=[ordered]@{
            files=$repositoryFiles
            missingFileWitness=@($repositoryFiles | Where-Object { [string]$_.type -ceq 'missing' } | ForEach-Object { [ordered]@{relativePath=$_.relativePath;type=$_.type} })
            fullTree=@(Get-Syp214TreeInventory -Root $Repository)
            gitInfoExclude=@(Get-Syp214FileInventory -Root $Repository -RelativePaths @($gitExcludeRelativePath))
            head=((Invoke-TestGit $Repository @('rev-parse','HEAD') | Select-Object -First 1).Trim())
            indexSha256=$(if(Test-Path -LiteralPath $indexPath -PathType Leaf){(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null})
            indexEntries=@(Invoke-TestGit $Repository @('ls-files','--stage'))
            status=@(Invoke-TestGit $Repository @('status','--porcelain'))
            stashes=@(Invoke-TestGit $Repository @('stash','list','--format=%H%x00%gs'))
        }
        user=[ordered]@{
            files=$userFiles
            missingFileWitness=@($userFiles | Where-Object { [string]$_.type -ceq 'missing' } | ForEach-Object { [ordered]@{relativePath=$_.relativePath;type=$_.type} })
            fullTree=@(Get-Syp214TreeInventory -Root $UserHome)
        }
    }
}

function Get-Syp214JournalInventory {
    param([string]$JournalPath,[object]$Journal)
    $journalName=[string](Split-Path -Leaf $JournalPath)
    $backupStates=@($Journal.states | Where-Object { [string]$_.originalType -ceq 'file' })
    $relativePaths=@($journalName)
    $relativePaths+=@($backupStates | ForEach-Object { [string]$_.backupName })
    $inventory=@(Get-Syp214FileInventory -Root (Split-Path -Parent $JournalPath) -RelativePaths $relativePaths)
    foreach($item in $inventory){
        if([string]$item.relativePath -ceq $journalName){
            $item['kind']='journal'
            $item['expectedSha256']=$null
            $item['matchesJournalSha256']=$null
        }
        else{
            $state=@($backupStates | Where-Object { [string]$_.backupName -ceq [string]$item.relativePath })[0]
            $expectedSha256=[string]$state.backupSha256
            $matchesJournalSha256=([string]$item.type -ceq 'file' -and [bool]$item.regularFile -and
                [string]$item.sha256 -cmatch '^[0-9a-f]{64}$' -and
                [string]$item.sha256 -ceq $expectedSha256)
            $item['kind']='backup'
            $item['expectedSha256']=$expectedSha256
            $item['matchesJournalSha256']=$matchesJournalSha256
        }
        $item
    }
}

function Test-Syp214JournalInventory {
    param([object[]]$Inventory,[object]$Journal,[string]$ExpectedCorruptBackupName)
    $journalRecords=@($Inventory | Where-Object { [string]$_.kind -ceq 'journal' })
    if($journalRecords.Count -ne 1 -or [string]$journalRecords[0].type -cne 'file' -or
        -not [bool]$journalRecords[0].regularFile -or
        $null -eq $journalRecords[0].length -or [long]$journalRecords[0].length -lt 0 -or
        [string]$journalRecords[0].sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }

    $backupStates=@($Journal.states | Where-Object { [string]$_.originalType -ceq 'file' })
    $backupRecords=@($Inventory | Where-Object { [string]$_.kind -ceq 'backup' })
    if($backupRecords.Count -ne $backupStates.Count) { return $false }
    $corruptWitnessFound=$false
    foreach($state in $backupStates){
        $record=@($backupRecords | Where-Object { [string]$_.relativePath -ceq [string]$state.backupName })
        if($record.Count -ne 1 -or [string]$record[0].type -cne 'file' -or
            -not [bool]$record[0].regularFile -or
            $null -eq $record[0].length -or [long]$record[0].length -lt 0 -or
            [string]$state.backupSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$record[0].sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
        $matchesJournalSha256=([string]$record[0].sha256 -ceq [string]$state.backupSha256)
        if([bool]$record[0].matchesJournalSha256 -ne $matchesJournalSha256) { return $false }
        if([string]$state.backupName -ceq $ExpectedCorruptBackupName){
            if($matchesJournalSha256) { return $false }
            $corruptWitnessFound=$true
        }
        elseif(-not $matchesJournalSha256){ return $false }
    }
    if(-not [string]::IsNullOrEmpty($ExpectedCorruptBackupName) -and -not $corruptWitnessFound) { return $false }
    return $true
}

function Get-Syp214RunIdentity {
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $testPath=[IO.Path]::GetFullPath($PSCommandPath)
    $bootstrapPath=[IO.Path]::GetFullPath($script:BootstrapScript)
    [ordered]@{
        runId=[string]$env:GITHUB_RUN_ID
        runAttempt=[string]$env:GITHUB_RUN_ATTEMPT
        workflow=[string]$env:GITHUB_WORKFLOW
        event=[string]$env:GITHUB_EVENT_NAME
        ref=[string]$env:GITHUB_REF
        sourceHeadCommit=[string]$env:SYP214_SOURCE_HEAD_SHA
        checkoutHeadCommit=((Invoke-TestGit $repositoryRoot @('rev-parse','HEAD') | Select-Object -First 1).Trim())
        checkoutTree=((Invoke-TestGit $repositoryRoot @('rev-parse','HEAD^{tree}') | Select-Object -First 1).Trim())
        testScriptSha256=(Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash.ToLowerInvariant()
        bootstrapScriptSha256=(Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash.ToLowerInvariant()
        powershellVersion=$PSVersionTable.PSVersion.ToString()
        powershellExecutable=[IO.Path]::GetFullPath((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
        pesterVersion=[string]$env:SYP214_PESTER_VERSION
    }
}

function Save-Syp214FixtureEvidence {
    param([string]$Name,[object]$Value)
    if (-not $env:SYP214_FIXTURE_EVIDENCE_ROOT) { return }
    $root=[IO.Path]::GetFullPath($env:SYP214_FIXTURE_EVIDENCE_ROOT)
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root ($Name+'.json')),($Value | ConvertTo-Json -Depth 14)+"`n",[Text.UTF8Encoding]::new($false))
}

Describe 'SYP214 whole-Skill migration evidence' {
    BeforeEach {
        Import-Module (Join-Path $PSScriptRoot '../scripts/skills-catalog-contract.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '../scripts/repo-shared-skills-migration.psm1')
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        New-TestRepository -Path $targetRoot
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $trusted = [pscustomobject]@{id='syp214-fixture'; sourceId='test-skills'; sourceRepository='https://example.com/test-skills.git'
            sourceCommit=('b'*40); sourceVersion='test@bbbbbbbb'; files=$entries}
    }

    # Scenario: A USER installation and ignored REPO copy have complete matching ownership.
    # Purpose: Recognize only a full stable identity and source inventory, including legacy/canonical versions.
    It 'InterT10_complete_inventory_allows_legacy_and_canonical_manifests' {
        # Given / When / Then
        foreach ($version in @(2,3)) {
            $manifest.schemaVersion = $version
            if ($version -eq 3) {
                foreach ($entry in $manifest.files) { $entry.sourcePath = $entry.sourcePath.Replace('.agents/skills/', 'skills/') }
            }
            $plan = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
            $plan.Count | Should Be 1
            $plan[0].removable | Should Be $true
            # USER is validated against its own immutable version, never against the old REPO bytes.
            foreach ($entry in $manifest.files) { $entry.sourceCommit = ('a'*40); $entry.sourceVersion='older' }
        }
    }

    # Scenario: USER coordinator manifest v3 contains user-agents and user-claude projections.
    # Purpose: Use only user-agents as W11 deletion evidence; another projection cannot substitute for it.
    It 'InterT61_uses_only_user_agents_entries_from_USER_manifest_v3' {
        $userManifestPath=Join-Path $userHome '.agents/catalog-skills.manifest.json'
        $legacy=Get-Content -Raw -Encoding UTF8 -LiteralPath $userManifestPath|ConvertFrom-Json
        $v3Entries=@()
        foreach($entry in $legacy.files){
            $agents=$entry.PSObject.Copy();$agents.sourcePath=([string]$entry.sourcePath).Replace('.agents/skills/','skills/');$agents|Add-Member -NotePropertyName projectionId -NotePropertyValue 'user-agents';$v3Entries+=$agents
            $claude=$entry.PSObject.Copy();$claude.sourcePath=([string]$entry.sourcePath).Replace('.agents/skills/','skills/');$claude|Add-Member -NotePropertyName projectionId -NotePropertyValue 'user-claude';$claude.targetPath=([string]$entry.targetPath).Replace('.agents/skills/','.claude/skills/');$v3Entries+=$claude
            $claudePath=Join-Path $userHome $claude.targetPath;New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claudePath)|Out-Null;[IO.File]::Copy((Join-Path $userHome $entry.targetPath),$claudePath)
        }
        $v3=[ordered]@{schemaVersion=3;catalogRepository=$legacy.catalogRepository;catalogCommit=$legacy.catalogCommit;catalogId=$legacy.catalogId;lockSha256=$legacy.lockSha256;projectionContractSha256=('d'*64);generation=1;projections=@('user-agents','user-claude');files=$v3Entries}
        [IO.File]::WriteAllText($userManifestPath,($v3|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $plan=@(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
        $plan[0].removable | Should Be $true

        Remove-Item -LiteralPath (Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md') -Force
        $protected=@(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
        $protected[0].removable | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.claude/skills/syp214-fixture/SKILL.md') | Should Be $true
    }

    # Scenario: Legacy recovery JSON or any canonical new-transaction residue appears during planning or after the plan was created.
    # Purpose: Treat legacy, valid, malformed, canonical orphan, and invalid-name evidence uniformly as missing W11 USER evidence while preserving REPO bytes.
    It 'InterT62_requires_an_empty_USER_transaction_root_during_plan_and_revalidation' {
        $transactionRoot=Join-Path $userHome '.ai-instructions-txn';$legacyPath=Join-Path $userHome '.agents/update-agent-environment.recovery.json'
        $repoFile=Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md';$repoBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($repoFile))
        $clearResidue={Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue}
        foreach($kind in @('legacy','valid','malformed','orphan','invalid-name')){
            & $clearResidue
            if($kind-ceq'legacy'){
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyPath)|Out-Null
                [IO.File]::WriteAllText($legacyPath,'{}')
                $residue=$legacyPath
            }else{
                $name=if($kind-ceq'invalid-name'){'invalid-name'}else{'0123456789abcdef0123456789abcdef'}
                $residue=Join-Path $transactionRoot $name
                New-Item -ItemType Directory -Force -Path $residue|Out-Null
                if($kind-ceq'malformed'){[IO.File]::WriteAllText((Join-Path $residue 'journal.json'),'{')}
                elseif($kind-ceq'valid'){$journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String;$journal.transactionId=$name;[IO.File]::WriteAllText((Join-Path $residue 'journal.json'),($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
            }
            $blocked=@(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
            $blocked[0].removable|Should Be $false
            Test-Path -LiteralPath $residue|Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($repoFile))|Should Be $repoBytes

            & $clearResidue
            $plan=@(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
            $plan[0].removable|Should Be $true
            if($kind-ceq'legacy'){
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyPath)|Out-Null
                [IO.File]::WriteAllText($legacyPath,'{}')
                $residue=$legacyPath
            }else{
                $name=if($kind-ceq'invalid-name'){'invalid-name'}else{'0123456789abcdef0123456789abcdef'}
                $residue=Join-Path $transactionRoot $name
                New-Item -ItemType Directory -Force -Path $residue|Out-Null
                if($kind-ceq'malformed'){[IO.File]::WriteAllText((Join-Path $residue 'journal.json'),'{')}
                elseif($kind-ceq'valid'){$journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String;$journal.transactionId=$name;[IO.File]::WriteAllText((Join-Path $residue 'journal.json'),($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
            }
            {Assert-RepoSharedSkillsMigrationEvidence -Repository $targetRoot -Skill $plan[0]}|Should Throw 'USER state changed concurrently'
            Test-Path -LiteralPath $residue|Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($repoFile))|Should Be $repoBytes
        }
        & $clearResidue
    }

    # Scenario: The migration planner receives a REPO managed manifest v4.
    # Purpose: Defer v4 ownership to the projection-aware bootstrap before observing or mutating migration state.
    It 'InterT15_rejects_a_repo_v4_manifest_before_mutation' {
        $manifest.schemaVersion = 4
        $manifestPath = Join-Path $targetRoot $script:ManifestPath
        $excludePath = Join-Path $targetRoot '.git/info/exclude'
        $skillPath = Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md'
        [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))
        $manifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))
        $excludeBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))
        $skillBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($skillPath))

        { Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome } |
            Should Throw 'REPO managed manifest schema version 4 requires a projection-aware bootstrap.'

        [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath)) | Should Be $manifestBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath)) | Should Be $excludeBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($skillPath)) | Should Be $skillBefore
    }

    # Scenario: One prerequisite is missing, customized, tracked, incomplete or unreadable.
    # Purpose: Fail closed for the entire Skill, retaining every file and manifest entry.
    It 'InterT20_protects_the_entire_Skill_for_<State>' -TestCases @(
        @{State='missing-user'}, @{State='corrupt-user'}, @{State='unreadable-user'}, @{State='unknown-user-schema'},
        @{State='customized'}, @{State='extra-file'}, @{State='tracked'}, @{State='staged'},
        @{State='not-ignored'}, @{State='unknown-ownership'}, @{State='incomplete-source'}, @{State='mixed-source'},
        @{State='newer-unverified-user'}, @{State='legacy-unowned-repo'}, @{State='mixed-version'}, @{State='reparse'}
    ) {
        param($State)
        # Given
        $locked = $null
        $repoFile = Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md'
        $userFile = Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md'
        $userManifestPath = Join-Path $userHome '.agents/catalog-skills.manifest.json'
        switch ($State) {
            'missing-user' { Remove-Item -LiteralPath $userFile }
            'corrupt-user' { Set-TestText $userFile 'corrupt' }
            'unreadable-user' { $locked = [IO.File]::Open($userFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            'unknown-user-schema' { $doc=Get-Content -Raw $userManifestPath|ConvertFrom-Json; $doc.schemaVersion=999; $doc|ConvertTo-Json -Depth 10|Set-Content $userManifestPath }
            'customized' { Set-TestText $repoFile 'customized' }
            'extra-file' { Set-TestText (Join-Path (Split-Path $repoFile) 'personal.txt') 'personal' }
            'tracked' { Invoke-TestGit $targetRoot @('add','-f','--','.agents/skills/syp214-fixture/SKILL.md')|Out-Null; Invoke-TestGit $targetRoot @('commit','-qm','project-owned')|Out-Null }
            'staged' { Invoke-TestGit $targetRoot @('add','-f','--','.agents/skills/syp214-fixture/SKILL.md')|Out-Null }
            'not-ignored' { [IO.File]::WriteAllText((Join-Path $targetRoot '.git/info/exclude'), '') }
            'unknown-ownership' { $trusted.sourceRepository='https://example.com/different.git' }
            'incomplete-source' { $trusted.files=@($entries[0]) }
            'mixed-source' { $manifest.files[0].sourceId='other-source' }
            'mixed-version' { $manifest.files[0].sourceVersion='different' }
            'reparse' { New-Item -ItemType Junction -Path (Join-Path (Split-Path $repoFile) 'linked') -Target $userHome | Out-Null }
            'newer-unverified-user' { $doc=Get-Content -Raw $userManifestPath|ConvertFrom-Json; foreach($entry in $doc.files){$entry.sourceCommit=('d'*40)}; $doc|ConvertTo-Json -Depth 10|Set-Content $userManifestPath }
            'legacy-unowned-repo' { $manifest.schemaVersion=1 }
        }
        # When / Then
        try {
            $plan = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
            $plan[0].removable | Should Be $false
            $plan[0].reason | Should Not BeNullOrEmpty
            Test-Path $repoFile | Should Be $true
            @($plan[0].entries).Count | Should Be 2
        }
        finally { if ($locked) { $locked.Dispose() } }
    }

    # Scenario: USER content, an extra REPO file, or Git index changes after the inventory.
    # Purpose: Stop before precise mutation and leave the new content intact.
    It 'InterT30_revalidates_<State>_before_mutation' -TestCases @(@{State='user' }, @{State='repo-extra'}, @{State='index'}, @{State='ignore'}) {
        param($State)
        # Given
        $plan = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
        $plan[0].removable | Should Be $true
        switch ($State) {
            'user' { Set-TestText (Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md') 'changed' }
            'repo-extra' { Set-TestText (Join-Path $targetRoot '.agents/skills/syp214-fixture/new.txt') 'new personal file' }
            'ignore' { [IO.File]::WriteAllText((Join-Path $targetRoot '.git/info/exclude'), '') }
            'index' { Set-TestText (Join-Path $targetRoot 'README.md') 'staged'; Invoke-TestGit $targetRoot @('add','README.md') | Out-Null }
        }
        # When / Then
        { Assert-RepoSharedSkillsMigrationEvidence -Repository $targetRoot -Skill $plan[0] } | Should Throw 'concurrently'
        Test-Path (Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md') | Should Be $true
    }

    Context 'Repository and USER root aliases are isolated' {
    # Scenario: Repository and USER roots identify the same physical directory through different path spellings.
    # Purpose: Reject migration eligibility before USER or Git evidence is observed, regardless of lexical or filesystem aliases.
    It 'InterT40_rejects_<Alias>_Repository_and_USER_roots_before_observation' -TestCases @(
        @{Alias='identical'},@{Alias='case-only'},@{Alias='trailing-separator'},@{Alias='junction'},@{Alias='subst'}
    ) {
        param($Alias)
        $substAlias=$null
        try {
        # Given
        $singleEntry=Set-Syp214SingleFileSkillFixture -Repository $targetRoot -UserHome $userHome -Entries $entries
        $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $trusted.files=@($singleEntry)
        Copy-Item -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json') `
            -Destination (Join-Path $targetRoot '.agents/catalog-skills.manifest.json') -Force
        $userAlias=$targetRoot
        switch($Alias){
            'case-only' { $userAlias=$targetRoot.ToUpperInvariant() }
            'trailing-separator' { $userAlias=$targetRoot.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))+[IO.Path]::DirectorySeparatorChar }
            'junction' {
                $userAlias=Join-Path $caseRoot 'consumer-alias'
                New-Item -ItemType Junction -Path $userAlias -Target $targetRoot | Out-Null
            }
            'subst' {
                $substAlias=New-Syp214SubstAlias -TargetRoot $targetRoot
                $userAlias=[string]$substAlias.path
            }
        }
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $targetRoot -Entries $singleEntry
        $separateUserBefore=Get-Syp214TreeInventory -Root $userHome
        $observationCounts=[pscustomobject]@{user=0;git=0}
        $userObservationMock={ $observationCounts.user++; throw 'SYP214 USER observation reached before root-alias guard.' }.GetNewClosure()
        $gitObservationMock={ $observationCounts.git++; throw 'SYP214 Git observation reached before root-alias guard.' }.GetNewClosure()
        Mock Get-UserSharedSkillObservation $userObservationMock -ModuleName repo-shared-skills-migration
        Mock Get-RepoSkillMigrationGitState $gitObservationMock -ModuleName repo-shared-skills-migration
        $planningFailure=''
        $plan=@()
        # When
        try {
            $plan=@(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest `
                -TrustedSkills @($trusted) -UserHome $userAlias)
        }
        catch { $planningFailure=$_.Exception.Message }
        # Then
        $observationCounts.user | Should Be 0
        $observationCounts.git | Should Be 0
        if($planningFailure){
            $planningFailure | Should Match '(?i)((same|identical|overlapping|aliased|distinct|separate|physical).*(root|directory)|(root|directory).*(same|identical|overlap|alias|distinct|separate|physical)|must (be )?distinct|must differ)'
        }
        else{
            $plan.Count | Should Be 1
            $plan[0].removable | Should Be $false
            $plan[0].reason | Should Not BeNullOrEmpty
        }
        $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $targetRoot -Entries $singleEntry
        (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.fullTree -Right $snapshotAfter.repository.fullTree) | Should Be $true
        (Test-Syp214PointInventoryEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
        (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
        (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
        (Test-Syp214InventoryEqual -Left $snapshotBefore.user.fullTree -Right $snapshotAfter.user.fullTree) | Should Be $true
        (Test-Syp214InventoryEqual -Left $separateUserBefore -Right (Get-Syp214TreeInventory -Root $userHome)) | Should Be $true
        }
        finally { if($substAlias){Remove-Syp214SubstAlias -Alias $substAlias} }
    }

    # Register only on the native host; keep this file's Core CI skip count at zero.
    if($IsLinux -or $IsMacOS){
        # Scenario: Repository and USER roots are separate existing Unix directories.
        # Purpose: Permit migration when native device and inode observations prove the roots are distinct.
        It 'InterT46_allows_distinct_Unix_repository_and_USER_roots' {
            $unixRepository=Join-Path $caseRoot 'unix-repository'
            $unixUser=Join-Path $caseRoot 'unix-user'
            [void][IO.Directory]::CreateDirectory($unixRepository)
            [void][IO.Directory]::CreateDirectory($unixUser)

            (Assert-RepoAndUserRootsDistinct -Repository $unixRepository -UserHome $unixUser) | Should Be $true
        }

        # Scenario: The USER path is a symbolic-link alias of the repository root.
        # Purpose: Compare resolved directory identities and reject a lexical alias before migration.
        It 'InterT47_rejects_a_Unix_USER_symlink_to_the_repository_root' {
            $unixRepository=Join-Path $caseRoot 'unix-repository'
            $unixUserAlias=Join-Path $caseRoot 'unix-user-alias'
            [void][IO.Directory]::CreateDirectory($unixRepository)
            New-Item -ItemType SymbolicLink -Path $unixUserAlias -Target $unixRepository | Out-Null

            { Assert-RepoAndUserRootsDistinct -Repository $unixRepository -UserHome $unixUserAlias } |
                Should Throw 'Repository and USER roots resolve to the same physical directory; aliased roots are not eligible for Skill migration.'
        }

        # Scenario: The repository path is a symbolic-link alias of the USER root.
        # Purpose: Apply the same physical-identity rejection regardless of which root is the alias.
        It 'InterT48_rejects_a_Unix_repository_symlink_to_the_USER_root' {
            $unixUser=Join-Path $caseRoot 'unix-user'
            $unixRepositoryAlias=Join-Path $caseRoot 'unix-repository-alias'
            [void][IO.Directory]::CreateDirectory($unixUser)
            New-Item -ItemType SymbolicLink -Path $unixRepositoryAlias -Target $unixUser | Out-Null

            { Assert-RepoAndUserRootsDistinct -Repository $unixRepositoryAlias -UserHome $unixUser } |
                Should Throw 'Repository and USER roots resolve to the same physical directory; aliased roots are not eligible for Skill migration.'
        }

        # Scenario: Two existing Unix directories differ only by letter case on a case-sensitive filesystem.
        # Purpose: Keep canonical-path comparison ordinal so distinct case variants remain eligible.
        It 'InterT49_allows_distinct_case_variant_Unix_roots' {
            $lowerRoot=Join-Path $caseRoot 'case-root'
            $upperRoot=Join-Path $caseRoot 'CASE-ROOT'
            [void][IO.Directory]::CreateDirectory($lowerRoot)
            if([IO.Directory]::Exists($upperRoot)){
                Set-TestInconclusive 'The test filesystem is case-insensitive; distinct case-variant directories cannot be created.'
                return
            }
            [void][IO.Directory]::CreateDirectory($upperRoot)

            (Assert-RepoAndUserRootsDistinct -Repository $lowerRoot -UserHome $upperRoot) | Should Be $true
        }

        # Scenario: One Unix root is absent while the other root exists.
        # Purpose: Fail closed for a missing repository while preserving the supported missing-USER state.
        It 'InterT50_distinguishes_missing_Unix_repository_and_USER_roots' {
            $existingRoot=Join-Path $caseRoot 'existing-root'
            $missingRepository=Join-Path $caseRoot 'missing-repository'
            $missingUser=Join-Path $caseRoot 'missing-user'
            [void][IO.Directory]::CreateDirectory($existingRoot)

            { Assert-RepoAndUserRootsDistinct -Repository $missingRepository -UserHome $existingRoot } |
                Should Throw 'Repository physical root is missing; migration fails closed.'
            (Assert-RepoAndUserRootsDistinct -Repository $existingRoot -UserHome $missingUser) | Should Be $true
        }
    }

    }

    # Scenario: USER is a parent directory of a valid single-file Skill consumer.
    # Purpose: Keep distinct nested roots eligible while rejecting only identities that resolve to the same directory.
    It 'InterT45_allows_a_distinct_USER_parent_and_Repository_child' {
        # Given
        $pairRoot=Join-Path $caseRoot 'nested-pair'
        $nestedRepository=Join-Path $pairRoot 'consumer'
        New-TestRepository -Path $nestedRepository
        $nestedEntries=New-Syp214LegacySkill -Repository $nestedRepository -UserHome $pairRoot
        $nestedEntries=Set-Syp214SingleFileSkillFixture -Repository $nestedRepository -UserHome $pairRoot -Entries $nestedEntries
        $nestedManifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $nestedRepository $script:ManifestPath) | ConvertFrom-Json
        $nestedTrusted=[pscustomobject]@{id='syp214-fixture';sourceId='test-skills';sourceRepository='https://example.com/test-skills.git'
            sourceCommit=('b'*40);sourceVersion='test@bbbbbbbb';files=@($nestedEntries)}
        # When
        $nestedPlan=@(Get-RepoSharedSkillsMigrationPlan -Repository $nestedRepository -Manifest $nestedManifest `
            -TrustedSkills @($nestedTrusted) -UserHome $pairRoot)
        # Then
        $nestedPlan.Count | Should Be 1
        $nestedPlan[0].removable | Should Be $true
    }
}

function New-Syp214BootstrapMutationPrefix {
    $bootstrapPath = (Resolve-Path -LiteralPath $script:BootstrapScript).Path
    $bootstrapText = [IO.File]::ReadAllText($bootstrapPath)
    $prefixEnd = $bootstrapText.IndexOf('$syncStartPath = ', [StringComparison]::Ordinal)
    if ($prefixEnd -lt 0) { throw 'Could not find the bootstrap definition prefix boundary.' }
    $bootstrapRoot = Split-Path -Parent $bootstrapPath
    $bootstrapRootLiteral = "'" + $bootstrapRoot.Replace("'", "''") + "'"
    $prefixText = $bootstrapText.Substring(0, $prefixEnd).Replace('$PSScriptRoot', $bootstrapRootLiteral)
    return ,([scriptblock]::Create($prefixText))
}

function Invoke-Syp214UnifiedBootstrapFixture {
    param(
        [Parameter(Mandatory=$true)][string]$BootstrapPath,
        [Parameter(Mandatory=$true)][string]$SourceArchivePath,
        [Parameter(Mandatory=$true)][string]$TargetRoot,
        [Parameter(Mandatory=$true)][string]$UserHome,
        [Parameter(Mandatory=$true)][string]$ConfigurationPath,
        [Parameter(Mandatory=$true)][string]$ProvenancePath,
        [string]$InstructionCommit=('d'*40)
    )
    New-TestProvenance -ArchivePath $SourceArchivePath -Path $ProvenancePath -InstructionCommit $InstructionCommit
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$BootstrapPath,
        '-SourceArchivePath',$SourceArchivePath,'-TargetRoot',$TargetRoot,
        '-ConfigurationPath',$ConfigurationPath,'-ProvenancePath',$ProvenancePath,
        '-UserHome',$UserHome)
    $output=& $script:TestPowerShellExecutable @arguments 2>&1
    return [pscustomobject][ordered]@{exitCode=$LASTEXITCODE;output=@($output|ForEach-Object{[string]$_})}
}

function Get-Syp214UnifiedTransactionFixture {
    param([Parameter(Mandatory=$true)][string]$Repository)
    $root=Get-Syp214RepositoryTransactionRoot -Repository $Repository
    $transactions=@(Get-ChildItem -Force -Directory -LiteralPath $root -ErrorAction SilentlyContinue)
    if($transactions.Count-ne1){throw "Expected one unified repository transaction, found $($transactions.Count)."}
    $journalPath=Join-Path $transactions[0].FullName 'journal.json'
    if(-not(Test-Path -LiteralPath $journalPath -PathType Leaf)){throw 'Unified repository transaction journal is missing.'}
    return [pscustomobject][ordered]@{root=$root;path=$transactions[0].FullName;journalPath=$journalPath
        journal=(Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath|ConvertFrom-Json)}
}

function Test-Syp214UnifiedStateEqual {
    param([Parameter(Mandatory=$true)][object]$Before,[Parameter(Mandatory=$true)][object]$After)
    $tree=Test-Syp214InventoryEqual -Left $Before.repository.fullTree -Right $After.repository.fullTree
    $point=Test-Syp214PointInventoryEqual -Left $Before.repository -Right $After.repository
    $exclude=Test-Syp214InventoryEqual -Left $Before.repository.gitInfoExclude -Right $After.repository.gitInfoExclude
    $git=Test-Syp214GitCoreStateEqual -Left $Before.repository -Right $After.repository
    $user=Test-Syp214InventoryEqual -Left $Before.user.fullTree -Right $After.user.fullTree
    return ($tree-and$point-and$exclude-and$git-and$user)
}

function Get-Syp214RawDaclRecord {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ValidateSet('Target','Exclude')][string]$Kind,
        [string]$TargetRoot,
        [string]$RelativePath
    )
    $handle=$null
    try {
        $handle=if($Kind-ceq'Target'){
            [CodexAiInstructions.NativeFileMutation]::OpenForMetadata($TargetRoot,$Path,$RelativePath)
        }else{
            [CodexAiInstructions.NativeFileMutation]::OpenStandaloneForMetadata($Path)
        }
        return Get-FileDaclJournalRecord -Handle $handle
    }
    finally { if($null-ne$handle){$handle.Dispose()} }
}

function Test-Syp214RawDaclRecordEqual {
    param([Parameter(Mandatory=$true)][object]$Left,[Parameter(Mandatory=$true)][object]$Right)
    return [CodexAiInstructions.NativeFileMutation]::DaclEquals(
        (ConvertFrom-FileDaclJournalRecord $Left),(ConvertFrom-FileDaclJournalRecord $Right))
}

Describe 'SYP214 generic managed Instructions deletion recovery' {
    BeforeAll {
        $fixtureRoot=Join-Path $TestDrive 'generic-unified';$baselineSource=Join-Path $fixtureRoot 'baseline-source';$changedSource=Join-Path $fixtureRoot 'changed-source'
        $script:Syp214GenericBaselineArchive=Join-Path $fixtureRoot 'baseline.zip';$script:Syp214GenericChangedArchive=Join-Path $fixtureRoot 'changed.zip'
        $script:Syp214GenericConfiguration=Join-Path $fixtureRoot 'config.json';$script:Syp214GenericSeedTarget=Join-Path $fixtureRoot 'seed/consumer'
        $script:Syp214GenericSeedUser=Join-Path $fixtureRoot 'seed/user';$script:Syp214GenericRuntimeRoot=Join-Path $fixtureRoot 'runtimes';$script:Syp214GenericRuntimeCache=@{}
        New-TestSource $baselineSource;Set-TestText (Join-Path $baselineSource '.codex/AI-Rules/Obsolete.en.md') '# stale managed Instructions';Copy-Item $baselineSource $changedSource -Recurse
        Remove-Item (Join-Path $changedSource '.codex/AI-Rules/Obsolete.en.md') -Force;Set-TestText (Join-Path $changedSource '.codex/AGENTS.en.md') '# Codex English Base changed'
        Compress-TestSource $baselineSource $script:Syp214GenericBaselineArchive;Compress-TestSource $changedSource $script:Syp214GenericChangedArchive
        New-TestConfiguration $script:Syp214GenericConfiguration;New-TestRepository $script:Syp214GenericSeedTarget
        New-Item -ItemType Directory -Force -Path $script:Syp214GenericSeedUser,$script:Syp214GenericRuntimeRoot|Out-Null
        $seed=Invoke-Syp214UnifiedBootstrapFixture -BootstrapPath $script:BootstrapScript -SourceArchivePath $script:Syp214GenericBaselineArchive -TargetRoot $script:Syp214GenericSeedTarget -UserHome $script:Syp214GenericSeedUser -ConfigurationPath $script:Syp214GenericConfiguration -ProvenancePath (Join-Path $fixtureRoot 'seed.json') -InstructionCommit ('c'*40)
        if($seed.exitCode-ne0){throw "Seed failed: $($seed.output-join[Environment]::NewLine)"}
        $script:Syp214GenericEntries=@([pscustomobject]@{targetPath='.codex/AI-Rules/Obsolete.en.md'},[pscustomobject]@{targetPath='AGENTS.md'})
        $script:Syp214GetRuntime={param([string]$Failpoint)
            if(-not$script:Syp214GenericRuntimeCache.ContainsKey($Failpoint)){$script:Syp214GenericRuntimeCache[$Failpoint]=New-Syp214UnifiedTransactionBootstrap (Join-Path $script:Syp214GenericRuntimeRoot ($Failpoint-replace'[^A-Za-z0-9._-]','-')) $Failpoint}
            [string]$script:Syp214GenericRuntimeCache[$Failpoint]}
        $discoveryTarget=Join-Path $fixtureRoot 'discovery-target';$discoveryUser=Join-Path $fixtureRoot 'discovery-user'
        Copy-Item $script:Syp214GenericSeedTarget $discoveryTarget -Recurse;Copy-Item $script:Syp214GenericSeedUser $discoveryUser -Recurse
        $discovery=Invoke-Syp214UnifiedBootstrapFixture -BootstrapPath (&$script:Syp214GetRuntime 'after-journal-prepared') -SourceArchivePath $script:Syp214GenericChangedArchive -TargetRoot $discoveryTarget -UserHome $discoveryUser -ConfigurationPath $script:Syp214GenericConfiguration -ProvenancePath (Join-Path $fixtureRoot 'discover.json')
        if($discovery.exitCode-eq0){throw 'Discovery unexpectedly succeeded.'}
        if(@(Get-ChildItem -Force -Directory -LiteralPath (Get-Syp214RepositoryTransactionRoot $discoveryTarget) -ErrorAction SilentlyContinue).Count-ne1){throw "Discovery retained no transaction: $($discovery.output-join[Environment]::NewLine)"}
        $fixture=Get-Syp214UnifiedTransactionFixture $discoveryTarget;$ops=@($fixture.journal.operations)
        $script:Syp214GenericOperations=[ordered]@{
            remove=@($ops|Where-Object{[string]$_.role-ceq'instruction'-and[string]$_.kind-ceq'remove-file'-and[string]$_.target.value-ceq'.codex/AI-Rules/Obsolete.en.md'})[0]
            write=@($ops|Where-Object{[string]$_.role-ceq'instruction'-and[string]$_.kind-ceq'write-file'-and[string]$_.target.value-ceq'AGENTS.md'})[0]
            exclude=@($ops|Where-Object{[string]$_.role-ceq'shared-exclude'})[0]
            manifest=@($ops|Where-Object{[string]$_.role-ceq'manifest'})[0]}
        foreach($name in @('remove','write','exclude','manifest')){if($null-eq$script:Syp214GenericOperations[$name]){throw "Missing $name operation."}}
        $cleanup=Invoke-Syp214UnifiedBootstrapFixture -BootstrapPath (&$script:Syp214GetRuntime 'RecoveryOnly') -SourceArchivePath $script:Syp214GenericChangedArchive -TargetRoot $discoveryTarget -UserHome $discoveryUser -ConfigurationPath $script:Syp214GenericConfiguration -ProvenancePath (Join-Path $fixtureRoot 'recover.json')
        if($cleanup.exitCode-eq0-or@(Get-ChildItem -Force -Directory -LiteralPath (Get-Syp214RepositoryTransactionRoot $discoveryTarget) -ErrorAction SilentlyContinue).Count-ne0){throw 'Discovery recovery failed.'}
    }
    BeforeEach {
        $caseRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$targetRoot=Join-Path $caseRoot 'consumer';$userHome=Join-Path $caseRoot 'user'
        Copy-Item $script:Syp214GenericSeedTarget $targetRoot -Recurse;Copy-Item $script:Syp214GenericSeedUser $userHome -Recurse
        $provenancePath=Join-Path $caseRoot 'provenance.json';$relativePath='.codex/AI-Rules/Obsolete.en.md';$targetPath=Join-Path $targetRoot $relativePath
        $excludePath=Get-Syp214GitInfoExcludeFixturePath $targetRoot;$unrelatedPath=Join-Path $targetRoot 'project-notes/personal.txt';New-Item -ItemType Directory -Force (Split-Path $unrelatedPath)|Out-Null;Set-TestText $unrelatedPath 'unrelated original bytes'
        $before=Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries;$originalTarget=[IO.File]::ReadAllBytes($targetPath);$originalManagedTarget=[IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md'));$originalExclude=[IO.File]::ReadAllBytes($excludePath)
        $script:Syp214Run={param([string]$Failpoint) Invoke-Syp214UnifiedBootstrapFixture -BootstrapPath (&$script:Syp214GetRuntime $Failpoint) -SourceArchivePath $script:Syp214GenericChangedArchive -TargetRoot $targetRoot -UserHome $userHome -ConfigurationPath $script:Syp214GenericConfiguration -ProvenancePath $provenancePath}
        $script:Syp214Recover={&$script:Syp214Run 'RecoveryOnly'}
    }

    # Scenario: Atomic managed deletion dies before its durable operation generation.
    # Purpose: Restore exact Instructions bytes from the unified transaction.
    It 'InterT10_restores_stale_Instructions_after_atomic_delete_interruption' {
        $op=$script:Syp214GenericOperations.remove;(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0;Test-Path $targetPath|Should Be $false
        $txn=Get-Syp214UnifiedTransactionFixture $targetRoot;[string]$txn.journal.phase|Should Be 'applying';[string]@($txn.journal.operations|Where-Object sequence -eq $op.sequence)[0].state|Should Be 'pending';Test-Path (Join-Path $txn.path ([string]$op.backupLeaf))|Should Be $true
        (&$script:Syp214Recover).exitCode|Should Not Be 0;[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be ([Convert]::ToBase64String($originalTarget))
        (Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
    }
    # Scenario: A later edit recreates deleted Instructions.
    # Purpose: Fail closed and preserve that edit.
    It 'InterT20_preserves_later_Instructions_edit_after_atomic_delete_interruption' {
        $op=$script:Syp214GenericOperations.remove;(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0;Set-TestText $targetPath '# later user Instructions edit';$later=[IO.File]::ReadAllBytes($targetPath)
        $recovery=&$script:Syp214Recover;$recovery.exitCode|Should Not Be 0;($recovery.output-join[Environment]::NewLine)|Should Match 'third state|ambiguous or changed';[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be ([Convert]::ToBase64String($later));(Get-Syp214UnifiedTransactionFixture $targetRoot).journalPath|Should Not BeNullOrEmpty
    }
    # Scenario: Target publication dies after atomic publication and before its journal generation.
    # Purpose: Never publish partial target bytes and preserve later unrelated bytes.
    It 'InterT30_recovers_managed_writer_prefix_without_publishing_partial_target_bytes' {
        $op=$script:Syp214GenericOperations.write;(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0;$path=Join-Path $targetRoot ([string]$op.target.value)
        (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$op.after.sha256);(Get-Item $path).Length|Should Be ([long]$op.after.length);Set-TestText $unrelatedPath 'later unrelated bytes';$later=[IO.File]::ReadAllBytes($unrelatedPath)
        (&$script:Syp214Recover).exitCode|Should Not Be 0;[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))|Should Be ([Convert]::ToBase64String($originalManagedTarget));[Convert]::ToBase64String([IO.File]::ReadAllBytes($unrelatedPath))|Should Be ([Convert]::ToBase64String($later))
        $after=Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries;(Test-Syp214GitCoreStateEqual $before.repository $after.repository)|Should Be $true;(Test-Syp214InventoryEqual $before.repository.gitInfoExclude $after.repository.gitInfoExclude)|Should Be $true
    }
    # Scenario: Exclude publication dies after atomic publication and before its journal generation.
    # Purpose: Never publish partial ignore bytes and preserve later project bytes.
    It 'InterT40_recovers_exclude_writer_prefix_without_publishing_partial_ignore_bytes' {
        $op=$script:Syp214GenericOperations.exclude;(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0;(Get-FileHash $excludePath -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$op.after.sha256);(Get-Item $excludePath).Length|Should Be ([long]$op.after.length)
        Set-TestText $unrelatedPath 'later unrelated bytes';$later=[IO.File]::ReadAllBytes($unrelatedPath);(&$script:Syp214Recover).exitCode|Should Not Be 0;[Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))|Should Be ([Convert]::ToBase64String($originalExclude));[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $targetRoot 'AGENTS.md')))|Should Be ([Convert]::ToBase64String($originalManagedTarget));[Convert]::ToBase64String([IO.File]::ReadAllBytes($unrelatedPath))|Should Be ([Convert]::ToBase64String($later))
        $after=Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries;(Test-Syp214GitCoreStateEqual $before.repository $after.repository)|Should Be $true;(Test-Syp214InventoryEqual $before.user.fullTree $after.user.fullTree)|Should Be $true
    }
    # Scenario: Unified rollback dies after one target or exclude restore.
    # Purpose: Retain strict-WAL evidence and retry the exact original state.
    It 'InterT50_retries_<WriterKind>_restore_after_a_flushed_prefix_fault' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind);(&$script:Syp214Run 'before-committed-journal-write').exitCode|Should Not Be 0;$op=if($WriterKind-ceq'target'){$script:Syp214GenericOperations.write}else{$script:Syp214GenericOperations.exclude}
        (&$script:Syp214Run ("after-rollback-operation-"+$op.sequence)).exitCode|Should Not Be 0;(Get-Syp214UnifiedTransactionFixture $targetRoot).journalPath|Should Not BeNullOrEmpty;(&$script:Syp214Recover).exitCode|Should Not Be 0;(Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
    }
    # Scenario: A real bootstrap process dies after complete target or exclude publication.
    # Purpose: Recover only complete original bytes.
    It 'InterT70_recovers_<WriterKind>_after_the_writer_process_dies' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind);$op=if($WriterKind-ceq'target'){$script:Syp214GenericOperations.write}else{$script:Syp214GenericOperations.exclude};(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0
        $txn=Get-Syp214UnifiedTransactionFixture $targetRoot;[string]$txn.journal.phase|Should Be 'applying';$path=if($WriterKind-ceq'target'){Join-Path $targetRoot ([string]$op.target.value)}else{$excludePath};(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$op.after.sha256)
        (&$script:Syp214Recover).exitCode|Should Not Be 0;(Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
    }
    # Scenario: Death leaves the original in transaction backup after atomic publication.
    # Purpose: Restore exact target or exclude bytes from strict-WAL evidence.
    It 'InterT80_recovers_<WriterKind>_after_process_death_in_the_old_to_tombstone_window' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind);$op=if($WriterKind-ceq'target'){$script:Syp214GenericOperations.remove}else{$script:Syp214GenericOperations.exclude};(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0;$txn=Get-Syp214UnifiedTransactionFixture $targetRoot
        Test-Path (Join-Path $txn.path ([string]$op.backupLeaf))|Should Be $true;if($WriterKind-ceq'target'){Test-Path $targetPath|Should Be $false}else{(Get-FileHash $excludePath -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$op.after.sha256)}
        (&$script:Syp214Recover).exitCode|Should Not Be 0;[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be ([Convert]::ToBase64String($originalTarget));[Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))|Should Be ([Convert]::ToBase64String($originalExclude));(Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
    }
    # Scenario: Unified recovery dies after two distinct reverse operations.
    # Purpose: Re-enter rollback twice and finish the exact before-state.
    It 'InterT96_reenters_<WriterKind>_restore_after_two_recovery_process_deaths' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind);(&$script:Syp214Run 'before-committed-journal-write').exitCode|Should Not Be 0;$seq=@((Get-Syp214UnifiedTransactionFixture $targetRoot).journal.operations|Sort-Object sequence -Descending|ForEach-Object{[int]$_.sequence});$a=if($WriterKind-ceq'target'){$seq[0]}else{$seq[-1]};$b=if($WriterKind-ceq'target'){$seq[1]}else{$seq[0]}
        foreach($n in @($a,$b)){(&$script:Syp214Run "after-rollback-operation-$n").exitCode|Should Not Be 0;(Get-Syp214UnifiedTransactionFixture $targetRoot).journalPath|Should Not BeNullOrEmpty};(&$script:Syp214Recover).exitCode|Should Not Be 0;(Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
    }
    # Scenario: A schema-v2 remove-file operation is durable while its target is missing.
    # Purpose: Restore verified originals and remove all residue.
    It 'InterT97_restores_original_bytes_from_a_schema_v2_missing_applied_state' {
        $op=$script:Syp214GenericOperations.remove;(&$script:Syp214Run "after-operation-$($op.sequence)-before-journal").exitCode|Should Not Be 0;Test-Path $targetPath|Should Be $false;$txn=Get-Syp214UnifiedTransactionFixture $targetRoot;[int]$txn.journal.schemaVersion|Should Be 2;[string]@($txn.journal.operations|Where-Object sequence -eq $op.sequence)[0].state|Should Be 'pending'
        (&$script:Syp214Recover).exitCode|Should Not Be 0;[Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be ([Convert]::ToBase64String($originalTarget));@(Get-ChildItem -Force -Directory -LiteralPath (Get-Syp214RepositoryTransactionRoot $targetRoot) -ErrorAction SilentlyContinue).Count|Should Be 0;(Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
    }
    # Scenario: Schema-v1 target/exclude recovery faults after flushing a stage prefix, then re-enters.
    # Purpose: Preserve applied state after the first failure and restore exact originals without inventing schema-v2 metadata.
    It 'InterT98_recovers_schema_v1_<WriterKind>_<AppliedType>_without_inventing_historic_metadata_after_a_prefix_fault' -TestCases @(
        @{WriterKind='target';AppliedType='file'},@{WriterKind='target';AppliedType='missing'},@{WriterKind='exclude';AppliedType='file'}) {
        param($WriterKind,$AppliedType)
        $backupRoot=Join-Path $caseRoot 'legacy-v1/target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        New-Item -ItemType Directory -Force $backupRoot|Out-Null
        $writerPath=if($WriterKind-ceq'target'){'Function:\Write-TargetMutationStreamBytes'}else{'Function:\Write-GitInfoExcludeStreamBytes'}
        $unrelatedBytesBefore=[IO.File]::ReadAllBytes($unrelatedPath)
        $beforeStatusAll=Get-Syp214GitStatusAll -Repository $targetRoot
        $realWriter=$null
        try {
            $prefix=New-Syp214BootstrapMutationPrefix
            . $prefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git' -ProvenancePath $provenancePath
            $targetDaclBefore=Get-Syp214RawDaclRecord -Path $targetPath -Kind Target -TargetRoot $targetRoot -RelativePath $relativePath
            $excludeDaclBefore=Get-Syp214RawDaclRecord -Path $excludePath -Kind Exclude
            $targetReadOnlyBefore=(([IO.File]::GetAttributes($targetPath)-band[IO.FileAttributes]::ReadOnly)-ne0)
            $excludeReadOnlyBefore=(([IO.File]::GetAttributes($excludePath)-band[IO.FileAttributes]::ReadOnly)-ne0)
            $snapshot=New-TargetMutationSnapshot $targetRoot @($relativePath) $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot $targetRoot
            $gitState=Get-RepoSkillMigrationGitState $targetRoot 'git'
            $applied=[Text.UTF8Encoding]::new($false).GetBytes("# legacy applied`n")
            if($WriterKind-ceq'target'){
                $state=$snapshot.FileStates[0]
                $state.MutationApplied=$true
                $state.AppliedType=$AppliedType
                if($AppliedType-ceq'file'){$state.AppliedBytes=$applied;[IO.File]::WriteAllBytes($targetPath,$applied)}
                else{$state.AppliedBytes=$null;Remove-Item $targetPath -Force}
            }else{
                $excludeSnapshot.MutationApplied=$true
                $excludeSnapshot.AppliedBytes=$applied
                [IO.File]::WriteAllBytes($excludePath,$applied)
            }
            $stateRecord=[ordered]@{relativePath=$relativePath;originalType='file'
                backupName=(Split-Path -Leaf ([string]$snapshot.FileStates[0].BackupPath))
                backupSha256=(Get-RawContentHash ([string]$snapshot.FileStates[0].BackupPath))
                mutationApplied=($WriterKind-ceq'target');appliedType=$(if($WriterKind-ceq'target'){$AppliedType}else{$null})
                appliedBase64=$(if($WriterKind-ceq'target'-and$AppliedType-ceq'file'){[Convert]::ToBase64String($applied)}else{$null})}
            $excludeRecord=[ordered]@{Path=$excludeSnapshot.Path;Repository=$excludeSnapshot.Repository
                MutationApplied=($WriterKind-ceq'exclude');Existed=[bool]$excludeSnapshot.Existed;Bytes=$excludeSnapshot.Bytes
                AppliedBytes=$(if($WriterKind-ceq'exclude'){$applied}else{$null})}
            $journal=[ordered]@{schemaVersion=1;targetRoot=$targetRoot;phase='mutating';head=$gitState.head
                indexSha256=$gitState.indexSha256;states=@($stateRecord);exclude=$excludeRecord}
            [IO.File]::WriteAllText($journalPath,($journal|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
            $appliedSnapshot=Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries
            $appliedStatusAll=Get-Syp214GitStatusAll -Repository $targetRoot
            $faultSentinel='SYP214 legacy v1 prefix fault '+[guid]::NewGuid().ToString('N')
            $prefixFault={
                param([IO.FileStream]$Stream,[byte[]]$Bytes)
                $Stream.Position=0;$Stream.SetLength(0)
                $prefixLength=[Math]::Min(3,$Bytes.Length)
                if($prefixLength-gt0){$Stream.Write($Bytes,0,$prefixLength)}
                $Stream.Flush($true)
                throw $faultSentinel
            }.GetNewClosure()
            $realWriter=(Get-Command ($writerPath-replace'^Function:\\','') -CommandType Function).ScriptBlock
            Set-Item -Path $writerPath -Value $prefixFault
            $prefixFailure=''
            try { Restore-SkillMigrationJournal $targetRoot $journalPath|Out-Null }
            catch { $prefixFailure=$_.Exception.Message }
            finally { Set-Item -Path $writerPath -Value $realWriter }

            $prefixFailure|Should Match ([regex]::Escape($faultSentinel))
            $afterFault=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath|ConvertFrom-Json
            [int]$afterFault.schemaVersion|Should Be 1
            [string]$afterFault.phase|Should Be 'mutating'
            $publishedPath=if($WriterKind-ceq'target'){$targetPath}else{$excludePath}
            $expectedAppliedBytes=if($WriterKind-ceq'target'){$applied}else{[byte[]]$excludeSnapshot.AppliedBytes}
            if($WriterKind-ceq'target'-and$AppliedType-ceq'missing'){
                Test-Path -LiteralPath $publishedPath|Should Be $false
            }else{
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($publishedPath))|Should Be ([Convert]::ToBase64String($expectedAppliedBytes))
                $appliedDacl=Get-Syp214RawDaclRecord -Path $publishedPath -Kind $(if($WriterKind-ceq'target'){'Target'}else{'Exclude'}) -TargetRoot $targetRoot -RelativePath $relativePath
                $expectedAppliedDacl=if($WriterKind-ceq'target'){$targetDaclBefore}else{$excludeDaclBefore}
                (Test-Syp214RawDaclRecordEqual $expectedAppliedDacl $appliedDacl)|Should Be $true
                (([IO.File]::GetAttributes($publishedPath)-band[IO.FileAttributes]::ReadOnly)-ne0)|Should Be $(if($WriterKind-ceq'target'){$targetReadOnlyBefore}else{$excludeReadOnlyBefore})
            }
            $afterFaultState=@($afterFault.states|Where-Object{[string]$_.relativePath-ceq$relativePath})[0]
            if($WriterKind-ceq'target'){$afterFaultState.appliedType|Should Be $AppliedType}
            else{$afterFault.exclude.MutationApplied|Should Be $true}
            $afterFaultState.PSObject.Properties['publication']|Should BeNullOrEmpty
            $afterFaultState.PSObject.Properties['originalDacl']|Should BeNullOrEmpty
            $afterFaultState.PSObject.Properties['originalIdentity']|Should BeNullOrEmpty
            $afterFault.exclude.PSObject.Properties['publication']|Should BeNullOrEmpty
            $afterFault.exclude.PSObject.Properties['dacl']|Should BeNullOrEmpty
            $afterFault.exclude.PSObject.Properties['originalIdentity']|Should BeNullOrEmpty
            $stageParent=Split-Path -Parent $publishedPath
            $partialStages=@(Get-ChildItem -LiteralPath $stageParent -Force -File -Filter '.syp214-*-stage')
            $partialStages.Count|Should Be 1
            [byte[]]$prefixBytes=[IO.File]::ReadAllBytes($partialStages[0].FullName)
            $prefixBytes.Length|Should Be 3
            [byte[]]$expectedRestoreBytes=if($WriterKind-ceq'target'){$originalTarget}else{$originalExclude}
            [byte[]]$expectedPrefix=$expectedRestoreBytes[0..2]
            (Test-TargetMutationBytesEqual $prefixBytes $expectedPrefix)|Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($unrelatedPath))|Should Be ([Convert]::ToBase64String($unrelatedBytesBefore))
            $afterFaultSnapshot=Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries
            [string]$afterFaultSnapshot.repository.head|Should Be ([string]$appliedSnapshot.repository.head)
            (Test-Syp214InventoryEqual $appliedSnapshot.repository.indexEntries $afterFaultSnapshot.repository.indexEntries)|Should Be $true
            $stageRelative=[IO.Path]::GetRelativePath($targetRoot,$partialStages[0].FullName).Replace('\','/')
            $stageStatus='?? '+$stageRelative
            $afterFaultStatusAll=Get-Syp214GitStatusAll -Repository $targetRoot
            @($afterFaultStatusAll|Where-Object{[string]$_-ceq$stageStatus}).Count|Should Be $(if($WriterKind-ceq'target'){1}else{0})
            $afterFaultStatusWithoutStage=@($afterFaultStatusAll|Where-Object{[string]$_-cne$stageStatus})
            (Test-Syp214InventoryEqual $appliedStatusAll $afterFaultStatusWithoutStage)|Should Be $true
            (Test-Syp214InventoryEqual $appliedSnapshot.user.fullTree $afterFaultSnapshot.user.fullTree)|Should Be $true

            $retryFailure=''
            try { Restore-SkillMigrationJournal $targetRoot $journalPath|Out-Null }
            catch { $retryFailure=$_.Exception.Message }
            $retryFailure|Should BeNullOrEmpty
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath))|Should Be ([Convert]::ToBase64String($originalTarget))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($excludePath))|Should Be ([Convert]::ToBase64String($originalExclude))
            $targetDaclAfter=Get-Syp214RawDaclRecord -Path $targetPath -Kind Target -TargetRoot $targetRoot -RelativePath $relativePath
            $excludeDaclAfter=Get-Syp214RawDaclRecord -Path $excludePath -Kind Exclude
            (Test-Syp214RawDaclRecordEqual $targetDaclBefore $targetDaclAfter)|Should Be $true
            (Test-Syp214RawDaclRecordEqual $excludeDaclBefore $excludeDaclAfter)|Should Be $true
            (([IO.File]::GetAttributes($targetPath)-band[IO.FileAttributes]::ReadOnly)-ne0)|Should Be $targetReadOnlyBefore
            (([IO.File]::GetAttributes($excludePath)-band[IO.FileAttributes]::ReadOnly)-ne0)|Should Be $excludeReadOnlyBefore
            Test-Path -LiteralPath $partialStages[0].FullName -PathType Leaf|Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($partialStages[0].FullName))|Should Be ([Convert]::ToBase64String($prefixBytes))
            $final=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath|ConvertFrom-Json
            [int]$final.schemaVersion|Should Be 1
            [string]$final.phase|Should Be 'recovered'
            $finalState=@($final.states|Where-Object{[string]$_.relativePath-ceq$relativePath})[0]
            $finalState.PSObject.Properties['originalDacl']|Should BeNullOrEmpty
            $finalState.PSObject.Properties['originalIdentity']|Should BeNullOrEmpty
            $finalState.PSObject.Properties['publication']|Should BeNullOrEmpty
            $final.exclude.PSObject.Properties['dacl']|Should BeNullOrEmpty
            $final.exclude.PSObject.Properties['originalIdentity']|Should BeNullOrEmpty
            $final.exclude.PSObject.Properties['publication']|Should BeNullOrEmpty
            $finalSnapshot=Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries
            (Test-Syp214PointInventoryEqual $before.repository $finalSnapshot.repository)|Should Be $true
            [string]$finalSnapshot.repository.head|Should Be ([string]$before.repository.head)
            (Test-Syp214InventoryEqual $before.repository.indexEntries $finalSnapshot.repository.indexEntries)|Should Be $true
            $finalStatusAll=Get-Syp214GitStatusAll -Repository $targetRoot
            @($finalStatusAll|Where-Object{[string]$_-ceq$stageStatus}).Count|Should Be $(if($WriterKind-ceq'target'){1}else{0})
            $finalStatusWithoutStage=@($finalStatusAll|Where-Object{[string]$_-cne$stageStatus})
            (Test-Syp214InventoryEqual $beforeStatusAll $finalStatusWithoutStage)|Should Be $true
            (Test-Syp214InventoryEqual $before.repository.stashes $finalSnapshot.repository.stashes)|Should Be $true
            (Test-Syp214InventoryEqual $before.repository.gitInfoExclude $finalSnapshot.repository.gitInfoExclude)|Should Be $true
            (Test-Syp214InventoryEqual $before.user.fullTree $finalSnapshot.user.fullTree)|Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($unrelatedPath))|Should Be ([Convert]::ToBase64String($unrelatedBytesBefore))
        }
        finally {
            if($realWriter){Set-Item -Path $writerPath -Value $realWriter}
            $script:SkillMigrationJournalContext=$null
            Set-StrictMode -Off
        }
    }
    # Scenario: Applied state is replaced by unrelated bytes or removed.
    # Purpose: Fail closed while preserving third-state bytes, backup, and journal.
    It 'InterT90_rejects_<CompetingState>_without_clobbering_unrelated_or_owned_bytes' -TestCases @(@{CompetingState='unrelated-final'},@{CompetingState='consumed-stage-then-deleted-final'}) {
        param($CompetingState);(&$script:Syp214Run 'before-committed-journal-write').exitCode|Should Not Be 0;$path=Join-Path $targetRoot 'AGENTS.md';if($CompetingState-ceq'unrelated-final'){$third=[Text.UTF8Encoding]::new($false).GetBytes("unrelated final collision`n");[IO.File]::WriteAllBytes($path,$third)}else{Remove-Item $path -Force}
        $txn=Get-Syp214UnifiedTransactionFixture $targetRoot;$journal=[IO.File]::ReadAllBytes($txn.journalPath);$recovery=&$script:Syp214Recover;$recovery.exitCode|Should Not Be 0;($recovery.output-join[Environment]::NewLine)|Should Match 'third state|ambiguous or changed';[Convert]::ToBase64String([IO.File]::ReadAllBytes($txn.journalPath))|Should Be ([Convert]::ToBase64String($journal))
        if($CompetingState-ceq'unrelated-final'){[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))|Should Be ([Convert]::ToBase64String($third))}else{Test-Path $path|Should Be $false};Test-Path (Join-Path $txn.path ([string]$script:Syp214GenericOperations.write.backupLeaf))|Should Be $true
    }
    # Scenario: Unified target/exclude publication is applied with inherited/protected DACL and read-only final before interruption.
    # Purpose: Exercise real rollback and preserve raw DACL bytes, protection, readonly, and original bytes.
    It 'InterT95_preserves_<Protection>_DACL_and_readonly_after_<WriterKind>_staging_prefix_fault' -TestCases @(
        @{Protection='inherited';Protected=$false;WriterKind='target'},@{Protection='protected';Protected=$true;WriterKind='target'},@{Protection='inherited';Protected=$false;WriterKind='exclude'},@{Protection='protected';Protected=$true;WriterKind='exclude'}) {
        param($Protection,$Protected,$WriterKind)
        $prefix=New-Syp214BootstrapMutationPrefix
        . $prefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git' -ProvenancePath $provenancePath
        $path=if($WriterKind-ceq'target'){Join-Path $targetRoot 'AGENTS.md'}else{$excludePath}
        $kind=if($WriterKind-ceq'target'){'Target'}else{'Exclude'}
        $pathRelative=if($WriterKind-ceq'target'){'AGENTS.md'}else{[IO.Path]::GetFileName($excludePath)}
        $acl=Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection([bool]$Protected,$true)
        Set-Acl -LiteralPath $path -AclObject $acl
        [IO.File]::SetAttributes($path,[IO.File]::GetAttributes($path)-bor[IO.FileAttributes]::ReadOnly)
        $rawDaclBefore=Get-Syp214RawDaclRecord -Path $path -Kind $kind -TargetRoot $targetRoot -RelativePath $pathRelative
        [bool]$rawDaclBefore.isProtected|Should Be ([bool]$Protected)
        $bytesBefore=[IO.File]::ReadAllBytes($path)
        $operation=if($WriterKind-ceq'target'){$script:Syp214GenericOperations.write}else{$script:Syp214GenericOperations.exclude}

        (&$script:Syp214Run "after-operation-$($operation.sequence)-before-journal").exitCode|Should Not Be 0
        $txn=Get-Syp214UnifiedTransactionFixture $targetRoot
        $journalOperation=@($txn.journal.operations|Where-Object{[int]$_.sequence-eq[int]$operation.sequence})[0]
        [string]$journalOperation.state|Should Be 'pending'
        [string]$journalOperation.displacedMetadata.kind|Should Be 'windows-sddl'
        [string]$journalOperation.displacedMetadata.sddl|Should Be ([string]$journalOperation.before.permissions.sddl)
        [bool]$journalOperation.displacedMetadata.readOnly|Should Be $true
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()|Should Be ([string]$operation.after.sha256)
        (Get-Item -LiteralPath $path).Length|Should Be ([long]$operation.after.length)
        $rawDaclApplied=Get-Syp214RawDaclRecord -Path $path -Kind $kind -TargetRoot $targetRoot -RelativePath $pathRelative
        (Test-Syp214RawDaclRecordEqual $rawDaclBefore $rawDaclApplied)|Should Be $true
        [bool]$rawDaclApplied.isProtected|Should Be ([bool]$Protected)
        (([IO.File]::GetAttributes($path)-band[IO.FileAttributes]::ReadOnly)-ne0)|Should Be $true

        (&$script:Syp214Recover).exitCode|Should Not Be 0
        $rawDaclAfter=Get-Syp214RawDaclRecord -Path $path -Kind $kind -TargetRoot $targetRoot -RelativePath $pathRelative
        (Test-Syp214RawDaclRecordEqual $rawDaclBefore $rawDaclAfter)|Should Be $true
        [bool]$rawDaclAfter.isProtected|Should Be ([bool]$Protected)
        (([IO.File]::GetAttributes($path)-band[IO.FileAttributes]::ReadOnly)-ne0)|Should Be $true
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))|Should Be ([Convert]::ToBase64String($bytesBefore))
        (Test-Syp214UnifiedStateEqual $before (Get-Syp214FixtureSnapshot $targetRoot $userHome $script:Syp214GenericEntries))|Should Be $true
        Set-StrictMode -Off
    }
}

Describe 'SYP214 USER migration serialization' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        $sourceArchive = Join-Path $caseRoot 'source.zip'
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        $script:TestConfigurationPath = Join-Path $caseRoot 'config.json'
        $script:TestProvenancePath = Join-Path $caseRoot 'provenance.json'
        New-TestSource -Path $sourceRoot
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $script:TestConfigurationPath
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) {
            $destination = Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath), $destination, $true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $userLockPath = Join-Path $userHome '.agents/update-agent-environment.lock'
    }

    # Scenario: A valid legacy USER installation has no updater coordination file yet.
    # Purpose: Keep WhatIf mutation-free and limit first Apply's USER change to the explicit empty lock file.
    It 'InterT05_creates_only_the_coordination_file_on_first_apply_and_keeps_WhatIf_read_only' {
        # Given
        Remove-Item -LiteralPath $userLockPath -Force
        $userFiles = @(Get-ChildItem -LiteralPath $userHome -Recurse -Force -File | ForEach-Object {
            [pscustomobject]@{path=$_.FullName; sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
        })
        # When / Then
        Invoke-Syp214Bootstrap -WhatIf | Out-Null
        Test-Path -LiteralPath $userLockPath | Should Be $false
        Invoke-Syp214Bootstrap | Out-Null
        Test-Path -LiteralPath $userLockPath -PathType Leaf | Should Be $true
        (Get-Item -LiteralPath $userLockPath).Length | Should Be 0
        foreach ($file in $userFiles) { (Get-FileHash -LiteralPath $file.path).Hash | Should Be $file.sha256 }
        @(Get-ChildItem -LiteralPath $userHome -Recurse -Force -File).Count | Should Be ($userFiles.Count + 1)
    }

    # Scenario: USER updater holds its exclusive lock before consumer bootstrap starts.
    # Purpose: Preserve every REPO Skill and ownership entry while Instructions continue, then allow retirement after release.
    It 'InterT10_preserves_the_entire_Skill_while_the_USER_updater_holds_its_lock' {
        # Given
        $userManifestPath = Join-Path $userHome '.agents/catalog-skills.manifest.json'
        $userManifestHash = (Get-FileHash -LiteralPath $userManifestPath).Hash
        $heldLock = [IO.File]::Open($userLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            # When
            $output = @(Invoke-Syp214Bootstrap)
            # Then
            foreach ($entry in $entries) {
                (Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256
            }
            $after = Get-Content -Raw -LiteralPath (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
            @($after.files | Where-Object { $_.targetPath -like '.agents/skills/*' }).Count | Should Be $entries.Count
            (Get-Content -Raw -LiteralPath (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
            (Get-FileHash -LiteralPath $userManifestPath).Hash | Should Be $userManifestHash
            ($output -join "`n") | Should Match 'USER.*lock'
        }
        finally { $heldLock.Dispose() }
        Invoke-Syp214Bootstrap | Out-Null
        foreach ($entry in $entries) { Test-Path -LiteralPath (Join-Path $targetRoot $entry.targetPath) | Should Be $false }
    }

    # Scenario: Another updater attempts its actual OS lock after evidence collection, deletion and manifest publication, or during rollback.
    # Purpose: Protect the final check/delete gap and keep USER evidence stable throughout success and failure paths; release on return.
    It 'InterT20_holds_the_USER_lock_through_<MigrationOutcome>_and_releases_it_afterward' -TestCases @(@{MigrationOutcome='apply'}, @{MigrationOutcome='rollback'}) {
        param([string]$MigrationOutcome)
        # Given: Wrap existing production boundaries in a disposable child, without changing the runtime under test.
        $originalBootstrap = $script:BootstrapScript
        $bootstrapText = [IO.File]::ReadAllText($originalBootstrap)
        $runtimeRoot = Split-Path -Parent $originalBootstrap
        $bootstrapText = $bootstrapText.Replace('$PSScriptRoot', ("'" + $runtimeRoot.Replace("'", "''") + "'"))
        $probePath = Join-Path $caseRoot 'user-lock-probes.json'
        $probeLiteral = "'" + $probePath.Replace("'", "''") + "'"
        $wrappers = @'
$script:LockProbeResults = @()
function Assert-Syp214UpdaterLockBlocked {
    param([string]$Checkpoint,[Nullable[int64]]$Sequence=$null)
    $blocked = $false
    try {
        $contender = [IO.File]::Open((Join-Path $UserHome '.agents/update-agent-environment.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $contender.Dispose()
    }
    catch [IO.IOException] { $blocked = $true }
    $script:LockProbeResults += [pscustomobject]@{checkpoint=$Checkpoint; sequence=$Sequence; blocked=$blocked}
    [IO.File]::WriteAllText(PROBE_PATH, (ConvertTo-Json -InputObject @($script:LockProbeResults)))
    if (-not $blocked) { throw "Competing USER updater acquired the lock at $Checkpoint." }
}
$script:OriginalMigrationPlan = (Get-Command Get-RepoSharedSkillsMigrationPlan).ScriptBlock
function Get-RepoSharedSkillsMigrationPlan {
    param([string]$Repository,[object]$Manifest,[object[]]$TrustedSkills,[string]$UserHome,[string]$GitExecutable='git')
    $result = @(& $script:OriginalMigrationPlan @PSBoundParameters)
    Assert-Syp214UpdaterLockBlocked 'evidence-collected'
    return $result
}
$script:OriginalRepositoryOperation = (Get-Command Invoke-RepositoryTransactionOperation).ScriptBlock
$script:InjectRepositoryRollback = '__SYP214_MIGRATION_OUTCOME__' -ceq 'rollback'
function Invoke-RepositoryTransactionOperation {
    param([object]$Context,[object]$Journal,[object]$Operation,[string]$Direction)
    $skillOperation=$Direction -ceq 'redo' -and [string]$Operation.role -ceq 'project-skill' -and [string]$Operation.kind -ceq 'remove-file'
    $manifestOperation=$Direction -ceq 'redo' -and [string]$Operation.role -ceq 'manifest'
    if($skillOperation){Assert-Syp214UpdaterLockBlocked 'before-skill-removal' ([int64]$Operation.sequence)}
    if($manifestOperation){Assert-Syp214UpdaterLockBlocked 'before-manifest-publication' ([int64]$Operation.sequence)}
    $result=& $script:OriginalRepositoryOperation @PSBoundParameters
    if($skillOperation){
        Assert-Syp214UpdaterLockBlocked 'after-skill-removal' ([int64]$Operation.sequence)
        if($script:InjectRepositoryRollback){$script:InjectRepositoryRollback=$false;throw 'Injected unified repository rollback.'}
    }
    if($manifestOperation){Assert-Syp214UpdaterLockBlocked 'after-manifest-publication' ([int64]$Operation.sequence)}
    return $result
}
$script:OriginalRepositoryRollback = (Get-Command Invoke-RepositoryTransactionRollback).ScriptBlock
function Invoke-RepositoryTransactionRollback {
    param([object]$Context)
    Assert-Syp214UpdaterLockBlocked 'rollback'
    & $script:OriginalRepositoryRollback @PSBoundParameters
}
'@
        $wrappers = $wrappers.Replace('PROBE_PATH', $probeLiteral)
        $wrappers = $wrappers.Replace('__SYP214_MIGRATION_OUTCOME__', $MigrationOutcome)
        $boundary = $bootstrapText.IndexOf('$repositoryOperationLock = $null', [StringComparison]::Ordinal)
        if ($boundary -lt 0) { throw 'Bootstrap definition boundary is missing.' }
        $childPath = Join-Path $caseRoot 'serialized-bootstrap.ps1'
        [IO.File]::WriteAllText($childPath, $bootstrapText.Insert($boundary, $wrappers + "`n"), [Text.UTF8Encoding]::new($false))
        $script:BootstrapScript = $childPath
        try {
            # When
            $run = Invoke-Syp214Bootstrap -CaptureFailure
            # Then
            if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
                throw "USER lock probe was not reached: $($run.output -join [Environment]::NewLine)"
            }
            $probes = @(Get-Content -Raw -LiteralPath $probePath | ConvertFrom-Json)
            @($probes | Where-Object { -not $_.blocked }).Count | Should Be 0
            @($probes | Where-Object { $_.checkpoint -eq 'evidence-collected' }).Count | Should Be 1
            if ($MigrationOutcome -eq 'apply') {
                $run.exitCode | Should Be 0
                @($probes | Where-Object { $_.checkpoint -eq 'after-skill-removal' } | Select-Object -ExpandProperty sequence -Unique).Count | Should Be $entries.Count
                @($probes | Where-Object { $_.checkpoint -eq 'after-manifest-publication' } | Select-Object -ExpandProperty sequence -Unique).Count | Should Be 1
                foreach ($entry in $entries) { Test-Path -LiteralPath (Join-Path $targetRoot $entry.targetPath) | Should Be $false }
            }
            else {
                $run.exitCode | Should Not Be 0
                ($run.output -join "`n") | Should Match 'Injected unified repository rollback'
                @($probes | Where-Object { $_.checkpoint -eq 'rollback' }).Count | Should Be 1
                foreach ($entry in $entries) {
                    (Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256
                }
            }
            $released = [IO.File]::Open($userLockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $released.Dispose()
        }
        finally { $script:BootstrapScript = $originalBootstrap }
    }
}

Describe 'SYP214 USER-only bootstrap boundary' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        $sourceArchive = Join-Path $caseRoot 'source.zip'
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        $script:TestConfigurationPath = Join-Path $caseRoot 'config.json'
        $script:TestProvenancePath = Join-Path $caseRoot 'provenance.json'
        New-TestSource -Path $sourceRoot
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $script:TestConfigurationPath
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture/SKILL.md') -Value '# Shared fixture'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
    }

    # Scenario: A direct entry receives a legacy composed archive with selected Skills.
    # Purpose: Enforce the final consumer scope regardless of USER availability or archive age.
    It 'InterT10_legacy_archive_never_installs_shared_Skills_but_updates_Instructions' {
        # Given / When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot | Out-Null
        # Then
        Test-Path (Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md') | Should Be $false
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
    }

    # Scenario: An old ignored manifest-owned Skill has no trusted USER installation.
    # Purpose: Neither stale pruning nor an archive update may delete or replace it.
    It 'InterT20_missing_USER_preserves_the_entire_legacy_Skill_and_ownership' {
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot
        Remove-Item -LiteralPath (Join-Path $sourceRoot '.agents/skills/syp214-fixture') -Recurse -Force
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        # When
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        # Then
        foreach ($entry in $entries) {
            Test-Path (Join-Path $targetRoot $entry.targetPath) | Should Be $true
            (Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256
        }
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 2
        ($output -join ' ') | Should Match 'USER.*repair|USER.*unavailable'
    }


    # Scenario: A clean consumer sees missing, corrupt or unreadable USER Skills.
    # Purpose: Continue Instructions updates with repair guidance and no REPO fallback or USER mutation.
    It 'InterT25_no_USER_fallback_for_<State>' -TestCases @(@{State='missing'},@{State='corrupt'},@{State='unreadable'}) {
        param($State)
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) { Remove-Item -LiteralPath (Join-Path $targetRoot $entry.targetPath) }
        Remove-Item -LiteralPath (Join-Path $targetRoot $script:ManifestPath)
        $userFile = Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md'
        $userManifest = Join-Path $userHome '.agents/catalog-skills.manifest.json'
        $beforeManifest = (Get-FileHash -LiteralPath $userManifest).Hash
        $locked = $null
        switch ($State) {
            'missing' { Remove-Item -LiteralPath $userFile }
            'corrupt' { Set-TestText $userFile 'personal corrupt bytes' }
            'unreadable' { $locked=[IO.File]::Open($userFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        }
        # When / Then
        try {
            $output = Invoke-Syp214Bootstrap
            ($output -join ' ') | Should Match 'USER Skill repair/update required.*REPO fallback is disabled'
            Test-Path (Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md') | Should Be $false
            Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
            (Get-FileHash -LiteralPath $userManifest).Hash | Should Be $beforeManifest
        }
        finally { if ($locked) { $locked.Dispose() } }
    }

    # Scenario: WhatIf or normal bootstrap receives a valid one-file Skill while USER resolves to the consumer directory itself.
    # Purpose: Fail closed before observation or mutation, and never report the same physical Skill as removable.
    It 'InterT28_<Mode>_preserves_a_valid_Skill_when_USER_and_Repository_are_identical' -TestCases @(@{Mode='WhatIf'},@{Mode='Apply'}) {
        param($Mode)
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $entries=Set-Syp214SingleFileSkillFixture -Repository $targetRoot -UserHome $userHome -Entries $entries
        Copy-Item -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json') `
            -Destination (Join-Path $targetRoot '.agents/catalog-skills.manifest.json') -Force
        $userHome=$targetRoot
        $sourceSkillPath='.agents/skills/syp214-fixture/SKILL.md'
        $sourceSkill=Join-Path $sourceRoot $sourceSkillPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceSkill) | Out-Null
        [IO.File]::Copy((Join-Path $targetRoot $sourceSkillPath),$sourceSkill,$true)
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $entriesForSnapshot=@($entries)
        $before=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entriesForSnapshot
        $sourceBefore=@(Get-Syp214FileInventory -Root $sourceRoot -RelativePaths @($sourceSkillPath))
        $sourceTreeBefore=@(Get-Syp214TreeInventory -Root $sourceRoot)
        # When
        if($Mode -ceq 'WhatIf'){$run=Invoke-Syp214Bootstrap -WhatIf -CaptureFailure}
        else{$run=Invoke-Syp214Bootstrap -CaptureFailure}
        $outputLines=@($run.output | ForEach-Object { [string]$_ })
        $outputText=$outputLines -join [Environment]::NewLine
        $migrationLines=@($outputLines | Where-Object { $_ -match '^Skill migration syp214-fixture: ' })
        # Then
        if([int]$run.exitCode -eq 0){
            if($Mode -ceq 'WhatIf'){
                $migrationLines.Count | Should Be 1
                $migrationLines[0] | Should Match '^Skill migration syp214-fixture: preserve:'
            }
            $outputText | Should Not Match 'retire verified ignored/untracked copy'
        }
        else{
            $outputText | Should Match '(?i)((same|identical|overlapping|aliased).*(root|directory)|(root|directory).*(same|identical|overlap|alias|distinct|separate)|must (be )?distinct|must differ)'
            $outputText | Should Not Match 'retire verified ignored/untracked copy'
        }
        $after=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entriesForSnapshot
        (Test-Syp214InventoryEqual -Left $before.repository.fullTree -Right $after.repository.fullTree) | Should Be $true
        (Test-Syp214PointInventoryEqual -Left $before.repository -Right $after.repository) | Should Be $true
        (Test-Syp214GitStateEqual -Left $before.repository -Right $after.repository) | Should Be $true
        (Test-Syp214InventoryEqual -Left $before.repository.gitInfoExclude -Right $after.repository.gitInfoExclude) | Should Be $true
        (Test-Syp214InventoryEqual -Left $before.user.fullTree -Right $after.user.fullTree) | Should Be $true
        (Test-Syp214InventoryEqual -Left $sourceBefore -Right (Get-Syp214FileInventory -Root $sourceRoot -RelativePaths @($sourceSkillPath))) | Should Be $true
        (Test-Syp214InventoryEqual -Left $sourceTreeBefore -Right (Get-Syp214TreeInventory -Root $sourceRoot)) | Should Be $true
    }

    # Scenario: A historical manifest lists the same tracked project Skill as a selected shared Skill.
    # Purpose: Preserve project bytes and Git ownership rather than remediate or reclassify the Skill.
    It 'InterT35_tracked_manifest_Skill_is_preserved' {
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $path='.agents/skills/syp214-fixture/SKILL.md'
        Invoke-TestGit $targetRoot @('add','-f','--',$path) | Out-Null
        Invoke-TestGit $targetRoot @('commit','-qm','project Skill with stale ownership') | Out-Null
        $head=Invoke-TestGit $targetRoot @('rev-parse','HEAD')
        $index=(Get-FileHash (Join-Path $targetRoot '.git/index')).Hash
        # When
        Invoke-Syp214Bootstrap | Out-Null
        # Then
        (Invoke-TestGit $targetRoot @('rev-parse','HEAD')) | Should Be $head
        (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash | Should Be $index
        foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
    }

    # Scenario: A project owns a tracked/staged Skill in a name also selected by the Catalog.
    # Purpose: Preserve project content, index and HEAD before reserved remediation runs.
    It 'InterT30_tracked_project_Skill_survives_remediation_and_bootstrap' {
        # Given
        $path = Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-TestText -Path $path -Value '# Project-owned'
        Invoke-TestGit $targetRoot @('add','--','.agents/skills/syp214-fixture/SKILL.md') | Out-Null
        Invoke-TestGit $targetRoot @('commit','-qm','project Skill') | Out-Null
        Set-TestText -Path $path -Value '# Staged project-owned'
        Invoke-TestGit $targetRoot @('add','--','.agents/skills/syp214-fixture/SKILL.md') | Out-Null
        $head = Invoke-TestGit $targetRoot @('rev-parse','HEAD')
        $index = (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash
        # When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot | Out-Null
        # Then
        (Get-Content -Raw $path).Trim() | Should Be '# Staged project-owned'
        (Invoke-TestGit $targetRoot @('rev-parse','HEAD')) | Should Be $head
        (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash | Should Be $index
    }

    # Scenario: An ignored REPO copy has identical USER bytes but no historical manifest.
    # Purpose: Report unknown ownership without adopting or deleting any Skill files.
    It 'InterT32_identical_unowned_copy_is_preserved_without_inferred_ownership' {
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        Remove-Item -LiteralPath (Join-Path $targetRoot $script:ManifestPath)
        # When
        $output=Invoke-Syp214Bootstrap
        # Then
        ($output -join ' ') | Should Match 'preserved without provable shared ownership'
        foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $manifest=Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
    }

    # Scenario: A real schema-v1 consumer manifest has no per-file shared source ownership.
    # Purpose: Keep the historical Skill and schema while still updating Instructions.
    It 'InterT36_preserves_unprovable_v1_Skill_ownership_and_updates_Instructions' {
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $legacy=[ordered]@{schemaVersion=1;sourceRepository='https://example.com/ai-instructions.git';sourceRef='legacy-pin';files=@($entries | Select-Object sourcePath,targetPath,sha256)}
        Set-TestText (Join-Path $targetRoot $script:ManifestPath) ($legacy | ConvertTo-Json -Depth 10)
        # When
        Invoke-Syp214Bootstrap | Out-Null
        # Then
        $manifest=Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $manifest.schemaVersion | Should Be 1
        @($manifest.files | Where-Object targetPath -like '.agents/skills/*').Count | Should Be 2
        Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
        foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
    }

}

Describe 'SYP214 USER-only bootstrap sync v5 preflight' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        $sourceArchive = Join-Path $caseRoot 'source.zip'
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        $script:TestConfigurationPath = Join-Path $caseRoot 'config.json'
        $script:TestProvenancePath = Join-Path $caseRoot 'provenance.json'
        New-TestSource -Path $sourceRoot
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $script:TestConfigurationPath
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture/SKILL.md') -Value '# Shared fixture'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
    }

    # Scenario: Recovery is requested while the installed sync configuration already uses schema v5.
    # Purpose: Reject the projection-aware contract before opening or applying the recovery journal.
    It 'InterT39_rejects_sync_v5_before_recovery_mutation' {
        $markerPath = Join-Path $targetRoot 'recovery-marker.bin'
        $journalPath = Join-Path $caseRoot 'recovery/skill-migration.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPath) | Out-Null
        [IO.File]::WriteAllBytes($markerPath,[byte[]]@(0x10,0x20,0x30,0x40))
        [IO.File]::WriteAllBytes($journalPath,[byte[]]@(0x7b,0x7d,0x0a))
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:TestConfigurationPath | ConvertFrom-Json
        $configuration.schemaVersion = 5
        [IO.File]::WriteAllText($script:TestConfigurationPath,($configuration | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $markerLength = (Get-Item -LiteralPath $markerPath).Length
        $markerHash = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash
        $journalLength = (Get-Item -LiteralPath $journalPath).Length
        $journalHash = (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash

        $result = Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath -CaptureFailure

        $result.exitCode | Should Not Be 0
        ($result.output -join [Environment]::NewLine) | Should Match 'AI Instructions sync configuration schema version 5 requires a projection-aware installer\.'
        (Get-Item -LiteralPath $markerPath).Length | Should Be $markerLength
        (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash | Should Be $markerHash
        (Get-Item -LiteralPath $journalPath).Length | Should Be $journalLength
        (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash | Should Be $journalHash
    }
}

Describe 'SYP214 USER-only bootstrap fixture evidence' -Tag 'Syp214FixtureEvidence' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        $sourceArchive = Join-Path $caseRoot 'source.zip'
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        $script:TestConfigurationPath = Join-Path $caseRoot 'config.json'
        $script:TestProvenancePath = Join-Path $caseRoot 'provenance.json'
        New-TestSource -Path $sourceRoot
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $script:TestConfigurationPath
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture/SKILL.md') -Value '# Shared fixture'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
    }

    # Scenario: Valid USER and old REPO manifests own the same complete immutable Skill.
    # Purpose: Retire only ignored unchanged files, retain backup, and never rebuild after a branch change.
    It 'InterT40_verified_USER_allows_exact_migration_after_a_mutation_free_dry_run' {
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $unrelatedEvidencePaths=New-Syp214UnrelatedEvidenceFiles -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) {
            $full = Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath), $full, $true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $head = Invoke-TestGit $targetRoot @('rev-parse','HEAD')
        $index = (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash
        $manifestBefore = [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $beforeSnapshot = Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $unrelatedRepositoryBefore=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserBefore=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $bootstrapAndBranchRuns=0
        $dryRunCount=0
        # When / Then
        $dryRunOutput=@(Invoke-Syp214Bootstrap -WhatIf | ForEach-Object { [string]$_ })
        $dryRunCount++
        $dryRunSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $dryRunQualification=@($dryRunOutput | Where-Object { $_ -match '^Skill migration syp214-fixture: ' })
        $dryRunQualification.Count | Should Be 1
        $dryRunQualification[0] | Should Match '^Skill migration syp214-fixture: retire verified ignored/untracked copy$'
        $dryRunQualificationReason=$dryRunQualification[0].Substring($dryRunQualification[0].IndexOf(':') + 1).Trim()
        $dryRunWhatIfOutput=@($dryRunOutput | Where-Object { $_ -match '^WhatIf: consumer Instructions-only synchronization;' })
        $dryRunWhatIfOutput.Count | Should Be 1
        $dryRunConsumerTreeStable=Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.fullTree -Right $dryRunSnapshot.repository.fullTree
        $dryRunUserTreeStable=Test-Syp214InventoryEqual -Left $beforeSnapshot.user.fullTree -Right $dryRunSnapshot.user.fullTree
        $dryRunPointInventoryStable=(Test-Syp214PointInventoryEqual -Left $beforeSnapshot.repository -Right $dryRunSnapshot.repository) -and
            (Test-Syp214PointInventoryEqual -Left $beforeSnapshot.user -Right $dryRunSnapshot.user)
        $dryRunGitStateStable=Test-Syp214GitStateEqual -Left $beforeSnapshot.repository -Right $dryRunSnapshot.repository
        $dryRunExcludeStable=Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.gitInfoExclude -Right $dryRunSnapshot.repository.gitInfoExclude
        $dryRunExcludeRegularFile=Test-Syp214RegularFileInventory -Inventory $dryRunSnapshot.repository.gitInfoExclude
        $dryRunMutationFree=($dryRunConsumerTreeStable -and $dryRunUserTreeStable -and $dryRunPointInventoryStable -and
            $dryRunGitStateStable -and $dryRunExcludeStable -and $dryRunExcludeRegularFile)
        $dryRunMutationFree | Should Be $true
        $manifestAfterDryRun = [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $manifestAfterDryRun | Should Be $manifestBefore
        Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        $dryRunOutputText=$dryRunOutput -join [Environment]::NewLine
        $dryRunOutputBytes=[Text.Encoding]::UTF8.GetBytes($dryRunOutputText)
        $dryRunOutputSha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($dryRunOutputBytes)).Replace('-','').ToLowerInvariant())
        $dryRunOutputSafe=Get-Syp214SafeOutputText -Text $dryRunOutputText -PrivateRoots @(
            $caseRoot,$targetRoot,$userHome,$sourceRoot,[IO.Path]::GetTempPath(),$PSHOME,$script:TestPowerShellExecutable,
            (Split-Path -Parent (Split-Path -Parent $script:BootstrapScript)))
        $dryRunExcludeBeforeToApply=@($beforeSnapshot.repository.gitInfoExclude)
        $output = Invoke-Syp214Bootstrap
        $bootstrapAndBranchRuns++
        $afterApplySnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $stashEvidenceAfterApply=@($afterApplySnapshot.repository.stashes)
        $personalAgentStashEvidenceRecorded=@($stashEvidenceAfterApply | Where-Object { [string]$_ -match 'CodexPersonalAgent:.*:PersonalAgent$' }).Count -gt 0
        $personalAgentStashEvidenceRecorded | Should Be $true
        foreach ($entry in $entries) { Test-Path (Join-Path $targetRoot $entry.targetPath) | Should Be $false }
        ($output -join ' ') | Should Match 'Skill migration syp214-fixture: retire verified ignored/untracked copy'
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
        $after = (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash
        $transactionRoot=Get-Syp214RepositoryTransactionRoot -Repository $targetRoot
        $transactionResidueBeforeNoOpRuns=@(Get-ChildItem -Force -LiteralPath $transactionRoot -ErrorAction SilentlyContinue)
        $transactionResidueBeforeNoOpRuns.Count | Should Be 0
        Invoke-Syp214Bootstrap | Out-Null
        $bootstrapAndBranchRuns++
        Invoke-TestGit $targetRoot @('checkout','-qb','other') | Out-Null
        Invoke-Syp214Bootstrap | Out-Null
        $bootstrapAndBranchRuns++
        (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash | Should Be $after
        (Invoke-TestGit $targetRoot @('rev-parse','HEAD')) | Should Be $head
        (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash | Should Be $index
        foreach ($entry in $entries) { (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $afterSnapshot = Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $userBytesStable = Test-Syp214InventoryEqual -Left $beforeSnapshot.user.fullTree -Right $afterSnapshot.user.fullTree
        $manifestDryRunStable = $manifestAfterDryRun -ceq $manifestBefore
        $indexPreserved = ([string]$afterSnapshot.repository.indexSha256 -ceq ([string]$beforeSnapshot.repository.indexSha256))
        $headPreserved = ([string]$afterSnapshot.repository.head -ceq ([string]$beforeSnapshot.repository.head))
        $gitCoreStatePreserved=Test-Syp214GitCoreStateEqual -Left $beforeSnapshot.repository -Right $afterSnapshot.repository
        $stashEvidenceStableAfterNoOpRuns=Test-Syp214InventoryEqual -Left $stashEvidenceAfterApply -Right $afterSnapshot.repository.stashes
        $unrelatedRepositoryAfter=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserAfter=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $unrelatedFilesPreserved=(Test-Syp214InventoryEqual -Left $unrelatedRepositoryBefore -Right $unrelatedRepositoryAfter) -and
            (Test-Syp214InventoryEqual -Left $unrelatedUserBefore -Right $unrelatedUserAfter)
        $applyExcludeRegularFile=Test-Syp214RegularFileInventory -Inventory $afterSnapshot.repository.gitInfoExclude
        $applyExcludeChanged= -not (Test-Syp214InventoryEqual -Left $dryRunExcludeBeforeToApply -Right $afterSnapshot.repository.gitInfoExclude)
        $transactionResidueAfterNoOpRuns=@(Get-ChildItem -Force -LiteralPath $transactionRoot -ErrorAction SilentlyContinue)
        $transactionCleanupStable=$transactionResidueBeforeNoOpRuns.Count -eq 0 -and $transactionResidueAfterNoOpRuns.Count -eq 0
        $userBytesStable | Should Be $true
        $manifestDryRunStable | Should Be $true
        $gitCoreStatePreserved | Should Be $true
        $stashEvidenceStableAfterNoOpRuns | Should Be $true
        $unrelatedFilesPreserved | Should Be $true
        $applyExcludeRegularFile | Should Be $true
        $transactionCleanupStable | Should Be $true
        $runIdentity=Get-Syp214RunIdentity
        Save-Syp214FixtureEvidence 'migration' ([ordered]@{
            schemaVersion=2; scope='disposable integration fixture'; skillId='syp214-fixture'; runIdentity=$runIdentity
            before=$beforeSnapshot; after=$afterSnapshot; userBytesStable=$userBytesStable
            unrelatedFiles=[ordered]@{repositoryBefore=$unrelatedRepositoryBefore;repositoryAfter=$unrelatedRepositoryAfter
                userBefore=$unrelatedUserBefore;userAfter=$unrelatedUserAfter;preserved=$unrelatedFilesPreserved}
            dryRun=[ordered]@{before=$beforeSnapshot;after=$dryRunSnapshot;output=$dryRunOutputSafe
                outputByteLength=$dryRunOutputBytes.Length;outputSha256=$dryRunOutputSha256
                qualificationOutput=$dryRunQualification[0];qualificationReason=$dryRunQualificationReason;whatIfOutput=$dryRunWhatIfOutput[0]
                consumerTreeStable=$dryRunConsumerTreeStable;userTreeStable=$dryRunUserTreeStable
                pointInventoryStable=$dryRunPointInventoryStable;gitStateStable=$dryRunGitStateStable
                gitInfoExcludeStable=$dryRunExcludeStable;gitInfoExcludeRegularFile=$dryRunExcludeRegularFile
                zeroMutationVerified=$dryRunMutationFree}
            repoBefore=@($entries); repoAfter=@($entries | ForEach-Object { [ordered]@{targetPath=$_.targetPath; exists=(Test-Path (Join-Path $targetRoot $_.targetPath))} })
            userAfter=@($entries | ForEach-Object { [ordered]@{targetPath=$_.targetPath; sha256=(Get-FileHash (Join-Path $userHome $_.targetPath)).Hash.ToLowerInvariant()} })
            manifestBeforeSha256=([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestBefore)) | ForEach-Object ToString x2) -join ''
            manifestAfterSha256=(Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash.ToLowerInvariant()
            instructionAfter=@($manifest.files | Select-Object targetPath,sha256)
            unifiedTransaction=[ordered]@{residueBeforeNoOpRuns=$transactionResidueBeforeNoOpRuns.Count
                residueAfterNoOpRuns=$transactionResidueAfterNoOpRuns.Count;cleanupStable=$transactionCleanupStable}
            dryRunPreservedManifest=$manifestDryRunStable
            dryRunManifestSha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestAfterDryRun))).Replace('-','').ToLowerInvariant())
            dryRunCount=$dryRunCount; bootstrapAndBranchRuns=$bootstrapAndBranchRuns
            indexPreserved=$indexPreserved; headPreserved=$headPreserved;gitCoreStatePreserved=$gitCoreStatePreserved
            stashEvidence=[ordered]@{beforeApply=$beforeSnapshot.repository.stashes;afterApply=$stashEvidenceAfterApply
                afterNoOpRuns=$afterSnapshot.repository.stashes;personalAgentRecorded=$personalAgentStashEvidenceRecorded
                stableAfterNoOpRuns=$stashEvidenceStableAfterNoOpRuns}
            applyGitInfoExclude=$afterSnapshot.repository.gitInfoExclude;applyGitInfoExcludeRegularFile=$applyExcludeRegularFile
            applyGitInfoExcludeChanged=$applyExcludeChanged
        })
    }

    # Scenario: A failure occurs after the first verified Skill removal is planned, before durable apply.
    # Purpose: Keep the original files and manifest byte-identical without leaving transaction residue.
    It 'InterT50_failure_during_migration_restores_exact_files_and_manifest' {
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $unrelatedEvidencePaths=New-Syp214UnrelatedEvidenceFiles -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) {
            $full = Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath), $full, $true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $before = [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $beforeSnapshot = Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $unrelatedRepositoryBefore=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserBefore=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        # When
        $failureMessage=''
        $failureRun=Invoke-Syp214Bootstrap -FailureAfterSkillRemovalCount 1 -CaptureFailure
        $failureExitCode=[int]$failureRun.exitCode
        $failureOutputLines=@($failureRun.output | ForEach-Object { [string]$_ })
        $failureOutputText=$failureOutputLines -join [Environment]::NewLine
        $failureMessageLines=@($failureOutputLines | Where-Object { $_ -match 'Injected Skill migration failure' })
        $failureMessageLines.Count | Should BeGreaterThan 0
        $failureMessage=$failureMessageLines[-1]
        $failureMessage | Should Match 'Injected Skill migration failure'
        $failureExitCode | Should Not Be 0
        $transactionRoot=Get-Syp214RepositoryTransactionRoot -Repository $targetRoot
        $transactionResidue=@(Get-ChildItem -Force -LiteralPath $transactionRoot -ErrorAction SilentlyContinue)
        $transactionResidue.Count | Should Be 0
        $failureOutputBytes=[Text.Encoding]::UTF8.GetBytes($failureOutputText)
        $failureOutputSha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($failureOutputBytes)).Replace('-','').ToLowerInvariant())
        $privateRoots=@(
            $caseRoot,$targetRoot,$userHome,$sourceRoot,[IO.Path]::GetTempPath(),$PSHOME,$script:TestPowerShellExecutable,
            (Split-Path -Parent (Split-Path -Parent $script:BootstrapScript)))
        $failureOutputSafe=Get-Syp214SafeOutputText -Text $failureOutputText -PrivateRoots $privateRoots
        $failureMessageSafe=Get-Syp214SafeOutputText -Text $failureMessage -PrivateRoots $privateRoots
        # Then
        $manifestAfter=[IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $manifestAfter | Should Be $before
        foreach ($entry in $entries) { (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $afterSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $restoredFiles=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths @($entries | ForEach-Object { [string]$_.targetPath }))
        $filesRestored=(@($restoredFiles | Where-Object { $_.type -ne 'file' }).Count -eq 0 -and
            @($entries | Where-Object { $expected=$_; @($restoredFiles | Where-Object { $_.relativePath -ceq $expected.targetPath -and $_.sha256 -ceq $expected.sha256 }).Count -ne 1 }).Count -eq 0)
        $manifestRestored=($manifestAfter -ceq $before)
        $userBytesPreserved=Test-Syp214InventoryEqual -Left $beforeSnapshot.user.fullTree -Right $afterSnapshot.user.fullTree
        $repositoryTreeRestored=Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.fullTree -Right $afterSnapshot.repository.fullTree
        $repositoryPointInventoryRestored=Test-Syp214PointInventoryEqual -Left $beforeSnapshot.repository -Right $afterSnapshot.repository
        $userPointInventoryPreserved=Test-Syp214PointInventoryEqual -Left $beforeSnapshot.user -Right $afterSnapshot.user
        $repositoryGitStatePreserved=Test-Syp214GitStateEqual -Left $beforeSnapshot.repository -Right $afterSnapshot.repository
        $repositoryExcludeRestored=Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.gitInfoExclude -Right $afterSnapshot.repository.gitInfoExclude
        $unrelatedRepositoryAfter=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserAfter=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $unrelatedFilesPreserved=(Test-Syp214InventoryEqual -Left $unrelatedRepositoryBefore -Right $unrelatedRepositoryAfter) -and
            (Test-Syp214InventoryEqual -Left $unrelatedUserBefore -Right $unrelatedUserAfter)
        $verified=($failureExitCode -ne 0 -and $failureMessage -match 'Injected Skill migration failure' -and
            $transactionResidue.Count -eq 0 -and
            $filesRestored -and $manifestRestored -and $userBytesPreserved -and $repositoryTreeRestored -and
            $repositoryPointInventoryRestored -and $userPointInventoryPreserved -and
            $repositoryGitStatePreserved -and $repositoryExcludeRestored -and $unrelatedFilesPreserved)
        $verified | Should Be $true
        Save-Syp214FixtureEvidence 'failure-rollback' ([ordered]@{
            schemaVersion=2;scope='disposable integration fixture';runIdentity=(Get-Syp214RunIdentity)
            failureAfterRemovedFiles=1;failureProcessExitCode=$failureExitCode;failureMessage=$failureMessageSafe
            capturedOutput=[ordered]@{redactedText=$failureOutputSafe;byteLength=$failureOutputBytes.Length;sha256=$failureOutputSha256}
            unifiedTransaction=[ordered]@{durable=$false;residueCount=$transactionResidue.Count}
            before=$beforeSnapshot;after=$afterSnapshot
            originalManifestRestored=$manifestRestored;restoredFiles=$restoredFiles;userBytesPreserved=$userBytesPreserved
            repositoryTreeRestored=$repositoryTreeRestored;repositoryPointInventoryRestored=$repositoryPointInventoryRestored
            userPointInventoryPreserved=$userPointInventoryPreserved;repositoryGitStatePreserved=$repositoryGitStatePreserved
            repositoryExcludeRestored=$repositoryExcludeRestored
            unrelatedFiles=[ordered]@{repositoryBefore=$unrelatedRepositoryBefore;repositoryAfter=$unrelatedRepositoryAfter
                userBefore=$unrelatedUserBefore;userAfter=$unrelatedUserAfter;preserved=$unrelatedFilesPreserved}
            verified=$verified
        })
    }

    # Scenario: A unified repository transaction is interrupted at a durable apply failpoint.
    # Purpose: Recover exact pre-migration state and refuse later edits or a corrupt backup.
    It 'InterT60_durable_recovery_<State>' -TestCases @(@{State='exact'},@{State='later-edit'},@{State='corrupt-backup'},@{State='pending-intent'}) {
        param($State)
        # Given: retain the production unified repository transaction at a durable failpoint.
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $unrelatedEvidencePaths=New-Syp214UnrelatedEvidenceFiles -Repository $targetRoot -UserHome $userHome
        foreach($entry in $entries){
            $full=Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath),$full,$true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $beforeSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $unrelatedRepositoryBefore=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserBefore=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $originalBootstrap=$script:BootstrapScript
        $failpoint=if($State -ceq 'pending-intent'){'after-journal-prepared'}else{'before-committed-journal-write'}
        try{
            $script:BootstrapScript=New-Syp214UnifiedTransactionBootstrap -Root (Join-Path $caseRoot 'failpoint-runtime') -Failpoint $failpoint
            $crashRun=Invoke-Syp214Bootstrap -CaptureFailure
        }
        finally{$script:BootstrapScript=$originalBootstrap}
        $crashRun.exitCode | Should Not Be 0
        $transactionRoot=Get-Syp214RepositoryTransactionRoot -Repository $targetRoot
        $transactions=@(Get-ChildItem -Force -Directory -LiteralPath $transactionRoot -ErrorAction Stop)
        $transactions.Count | Should Be 1
        $transactionPath=$transactions[0].FullName
        $journalPath=Join-Path $transactionPath 'journal.json'
        Test-Path -LiteralPath $journalPath -PathType Leaf | Should Be $true
        $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
        [int]$journal.schemaVersion | Should Be 2
        @($journal.operations | Where-Object { [string]$_.role -ceq 'project-skill' -and [string]$_.kind -ceq 'remove-file' }).Count | Should Be $entries.Count
        $manifestOperations=@($journal.operations | Where-Object { [string]$_.role -ceq 'manifest' })
        $manifestOperations.Count | Should Be 1
        $manifestOperation=$manifestOperations[0]
        [string]$manifestOperation.kind | Should Be 'write-file'
        [string]$manifestOperation.target.value | Should Be $script:ManifestPath.Replace('\','/')
        [bool]$manifestOperation.before.exists | Should Be $true
        [string]$manifestOperation.before.identity.kind | Should Be 'windows-file-id'
        [string]$manifestOperation.before.sha256 | Should Match '^[0-9a-f]{64}$'
        [string]$manifestOperation.after.sha256 | Should Match '^[0-9a-f]{64}$'
        [long]$manifestOperation.after.length | Should BeGreaterThan 0
        $manifestPublicationPath=if($State -ceq 'pending-intent'){
            Join-Path $transactionPath ([string]$manifestOperation.stageLeaf)
        }else{Join-Path $targetRoot $script:ManifestPath}
        Test-Path -LiteralPath $manifestPublicationPath -PathType Leaf | Should Be $true
        (Get-FileHash -LiteralPath $manifestPublicationPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$manifestOperation.after.sha256)
        (Get-Item -LiteralPath $manifestPublicationPath).Length | Should Be ([long]$manifestOperation.after.length)
        $manifestBackupPath=Join-Path $transactionPath ([string]$manifestOperation.backupLeaf)
        if($State -ceq 'pending-intent'){
            Test-Path -LiteralPath $manifestBackupPath | Should Be $false
            (Get-FileHash -LiteralPath (Join-Path $targetRoot $script:ManifestPath) -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$manifestOperation.before.sha256)
            (Get-Item -LiteralPath (Join-Path $targetRoot $script:ManifestPath)).Length | Should Be ([long]$manifestOperation.before.length)
        }
        else{
            Test-Path -LiteralPath $manifestBackupPath -PathType Leaf | Should Be $true
            (Get-FileHash -LiteralPath $manifestBackupPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$manifestOperation.before.sha256)
        }
        [string]$manifestOperation.displacedMetadata.kind | Should Be 'windows-sddl'
        [string]$manifestOperation.displacedMetadata.sddl | Should Be ([string]$manifestOperation.before.permissions.sddl)
        [bool]$manifestOperation.displacedMetadata.readOnly | Should Be ([bool]$manifestOperation.before.permissions.readOnly)

        $driftRelativePath=$null
        $corruptBackupName=$null
        if($State -ceq 'later-edit'){
            $driftRelativePath=[string]$entries[0].targetPath
            Set-TestText -Path (Join-Path $targetRoot $driftRelativePath) -Value 'later project edit'
        }
        elseif($State -ceq 'corrupt-backup'){
            $removal=@($journal.operations | Where-Object { [string]$_.role -ceq 'project-skill' -and -not[string]::IsNullOrWhiteSpace([string]$_.backupLeaf) })[0]
            $corruptBackupName=[string]$removal.backupLeaf
            Set-TestText -Path (Join-Path $transactionPath $corruptBackupName) -Value 'corrupt backup'
        }
        $preRecoverySnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $journalBytesBefore=[IO.File]::ReadAllBytes($journalPath)

        # When: the next process performs only automatic unified-transaction recovery.
        try{
            $script:BootstrapScript=New-Syp214UnifiedTransactionBootstrap -Root (Join-Path $caseRoot 'recovery-runtime') -Failpoint RecoveryOnly
            $recoveryRun=Invoke-Syp214Bootstrap -CaptureFailure
        }
        finally{$script:BootstrapScript=$originalBootstrap}
        $recoveryRun.exitCode | Should Not Be 0
        $afterSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $residueAfter=@(Get-ChildItem -Force -Directory -LiteralPath $transactionRoot -ErrorAction SilentlyContinue)
        $recoveryOutputText=@($recoveryRun.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $userBytesPreserved=Test-Syp214InventoryEqual -Left $beforeSnapshot.user.fullTree -Right $afterSnapshot.user.fullTree
        $unrelatedRepositoryAfter=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserAfter=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $unrelatedFilesPreserved=(Test-Syp214InventoryEqual -Left $unrelatedRepositoryBefore -Right $unrelatedRepositoryAfter) -and
            (Test-Syp214InventoryEqual -Left $unrelatedUserBefore -Right $unrelatedUserAfter)
        $recoveredExact=$false
        $refusedThirdState=$false
        if($State -in @('exact','pending-intent')){
            $treeRestored=Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.fullTree -Right $afterSnapshot.repository.fullTree
            $pointRestored=Test-Syp214PointInventoryEqual -Left $beforeSnapshot.repository -Right $afterSnapshot.repository
            $gitCoreRestored=Test-Syp214GitCoreStateEqual -Left $beforeSnapshot.repository -Right $afterSnapshot.repository
            $stashRestored=if($State -ceq 'exact'){
                Test-Syp214InventoryEqual -Left $preRecoverySnapshot.repository.stashes -Right $afterSnapshot.repository.stashes
            }else{
                Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.stashes -Right $afterSnapshot.repository.stashes
            }
            $gitRestored=$gitCoreRestored -and $stashRestored
            $recoveredExact=$treeRestored -and $pointRestored -and $gitRestored -and $residueAfter.Count -eq 0
            if(-not$recoveredExact){throw "Unified exact recovery mismatch: tree=$treeRestored point=$pointRestored gitCore=$gitCoreRestored stash=$stashRestored residue=$($residueAfter.Count) beforeStash=$($beforeSnapshot.repository.stashes -join '|') afterStash=$($afterSnapshot.repository.stashes -join '|') output=$recoveryOutputText"}
            try{
                $script:BootstrapScript=New-Syp214UnifiedTransactionBootstrap -Root (Join-Path $caseRoot 'repeat-recovery-runtime') -Failpoint RecoveryOnly
                $repeatRecovery=Invoke-Syp214Bootstrap -CaptureFailure
            }
            finally{$script:BootstrapScript=$originalBootstrap}
            $repeatRecovery.exitCode | Should Not Be 0
            @(Get-ChildItem -Force -Directory -LiteralPath $transactionRoot -ErrorAction SilentlyContinue).Count | Should Be 0
            (Test-Syp214InventoryEqual -Left $afterSnapshot.repository.fullTree -Right (Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries).repository.fullTree) | Should Be $true
        }
        else{
            $treePreserved=Test-Syp214InventoryComposedFromSnapshots -Before $beforeSnapshot.repository.fullTree `
                -Applied $preRecoverySnapshot.repository.fullTree -Actual $afterSnapshot.repository.fullTree
            $gitCorePreserved=(Test-Syp214GitCoreStateEqual -Left $beforeSnapshot.repository -Right $afterSnapshot.repository) -or
                (Test-Syp214GitCoreStateEqual -Left $preRecoverySnapshot.repository -Right $afterSnapshot.repository)
            $stashPreserved=(Test-Syp214InventoryEqual -Left $beforeSnapshot.repository.stashes -Right $afterSnapshot.repository.stashes) -or
                (Test-Syp214InventoryEqual -Left $preRecoverySnapshot.repository.stashes -Right $afterSnapshot.repository.stashes)
            $journalExists=Test-Path -LiteralPath $journalPath -PathType Leaf
            $journalPreserved=$journalExists -and [Convert]::ToBase64String($journalBytesBefore) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))
            $expectedRefusal=if($State -ceq 'later-edit'){'Schema-v2 publication state is ambiguous or changed'}else{'Stage hash or length differs|unreadable or invalid'}
            $refusalClassified=$recoveryOutputText -match $expectedRefusal
            $refusedThirdState=$treePreserved -and $gitCorePreserved -and $stashPreserved -and $residueAfter.Count -eq 1 -and $journalPreserved -and $refusalClassified
            if(-not$refusedThirdState){throw "Unified refusal mismatch: tree=$treePreserved gitCore=$gitCorePreserved stash=$stashPreserved residue=$($residueAfter.Count) journal=$journalPreserved classified=$refusalClassified output=$recoveryOutputText"}
            if($State -ceq 'later-edit'){
                (Get-Content -Raw -LiteralPath (Join-Path $targetRoot $driftRelativePath)).Trim() | Should Be 'later project edit'
            }
            else{
                (Get-Content -Raw -LiteralPath (Join-Path $transactionPath $corruptBackupName)).Trim() | Should Be 'corrupt backup'
            }
        }
        $userBytesPreserved | Should Be $true
        $unrelatedFilesPreserved | Should Be $true
        $verified=$userBytesPreserved -and $unrelatedFilesPreserved -and ($recoveredExact -or $refusedThirdState)
        $verified | Should Be $true
        Save-Syp214FixtureEvidence ('recovery-'+$State) ([ordered]@{
            schemaVersion=2;scope='disposable integration fixture';runIdentity=(Get-Syp214RunIdentity);scenario=$State
            before=$beforeSnapshot;preRecovery=$preRecoverySnapshot;after=$afterSnapshot
            unifiedJournal=$journal;failpoint=$failpoint;recoveryOutput=$recoveryOutputText
            residueAfterRecovery=$residueAfter.Count;recoveredExact=$recoveredExact;refusedThirdState=$refusedThirdState
            driftRelativePath=$driftRelativePath;corruptBackupName=$corruptBackupName
            userBytesPreserved=$userBytesPreserved
            unrelatedFiles=[ordered]@{repositoryBefore=$unrelatedRepositoryBefore;repositoryAfter=$unrelatedRepositoryAfter
                userBefore=$unrelatedUserBefore;userAfter=$unrelatedUserAfter;preserved=$unrelatedFilesPreserved}
            verified=$verified
        })
    }
}
