# Reuse the established disposable bootstrap fixtures without executing their Describe blocks.
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
        [string]$Left.indexSha256 -ceq [string]$Right.indexSha256 -and
        (Test-Syp214InventoryEqual -Left @($Left.status) -Right @($Right.status)))
}

function Test-Syp214GitStateEqual {
    param([object]$Left,[object]$Right)
    return ((Test-Syp214GitCoreStateEqual -Left $Left -Right $Right) -and
        (Test-Syp214InventoryEqual -Left @($Left.stashes) -Right @($Right.stashes)))
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
        powershellExecutable=[IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
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

Describe 'SYP214 generic managed Instructions deletion recovery' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        New-TestRepository -Path $targetRoot
        New-Item -ItemType Directory -Force -Path $userHome | Out-Null
        $targetRoot = (Resolve-Path -LiteralPath $targetRoot).Path
        $relativePath = '.codex/AI-Rules/Obsolete.en.md'
        $targetPath = Join-Path $targetRoot $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Set-TestText -Path $targetPath -Value '# stale managed Instructions'
        $originalBytes = [IO.File]::ReadAllBytes($targetPath)
        $originalHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $backupRoot = Join-Path $caseRoot 'target-backup'
        $journalPath = Join-Path $backupRoot 'skill-migration.json'
    }

    # Scenario: Generic managed-file deletion is interrupted after atomic removal but before in-memory mutation state is updated.
    # Purpose: Recover the exact stale Instructions bytes from the durable backup journal.
    It 'InterT10_restores_stale_Instructions_after_atomic_delete_interruption' {
        # Given
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $bootstrapPrefix = New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            $snapshot = New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState = Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext = [pscustomobject]@{
                Snapshot = $snapshot; ExcludeSnapshot = $excludeSnapshot; Path = $journalPath; GitState = $gitState
            }

            $atomicDeletePath = 'Function:\Remove-TargetMutationFileAtomically'
            $realAtomicDelete = (Get-Command Remove-TargetMutationFileAtomically -CommandType Function).ScriptBlock
            $interruptionSentinel = 'SYP214 interruption ' + [guid]::NewGuid().ToString('N')
            $interruptAfterDelete = {
                param(
                    [Parameter(Mandatory = $true)][object] $Snapshot,
                    [Parameter(Mandatory = $true)][string] $RelativePath,
                    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $ExpectedBytes,
                    [Parameter(Mandatory = $true)][string] $Operation
                )
                & $realAtomicDelete @PSBoundParameters
                throw $interruptionSentinel
            }.GetNewClosure()
            # When
            $interruptionObserved = $false
            try {
                Set-Item -Path $atomicDeletePath -Value $interruptAfterDelete
                try {
                    Remove-TargetMutationFile -Snapshot $snapshot -RelativePath $relativePath
                }
                catch {
                    if ($_.Exception.Message -cne $interruptionSentinel) { throw }
                    $interruptionObserved = $true
                }
            }
            finally { Set-Item -Path $atomicDeletePath -Value $realAtomicDelete }

            # Then
            $interruptionObserved | Should Be $true
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $false
            Restore-SkillMigrationJournal -Repository $snapshot.TargetRoot -Path $journalPath | Out-Null
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalBytes) | Should Be $true
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $originalHash
        }
        finally {
            $script:SkillMigrationJournalContext = $null
            $ErrorActionPreference = $previousErrorActionPreference
            Set-StrictMode -Off
        }
    }

    # Scenario: A user edit recreates the stale Instructions path after interrupted deletion but before recovery.
    # Purpose: Stop recovery when current bytes differ and preserve the later edit unchanged.
    It 'InterT20_preserves_later_Instructions_edit_after_atomic_delete_interruption' {
        # Given
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $bootstrapPrefix = New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            $snapshot = New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState = Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext = [pscustomobject]@{
                Snapshot = $snapshot; ExcludeSnapshot = $excludeSnapshot; Path = $journalPath; GitState = $gitState
            }

            $atomicDeletePath = 'Function:\Remove-TargetMutationFileAtomically'
            $realAtomicDelete = (Get-Command Remove-TargetMutationFileAtomically -CommandType Function).ScriptBlock
            $interruptionSentinel = 'SYP214 interruption ' + [guid]::NewGuid().ToString('N')
            $interruptAfterDelete = {
                param(
                    [Parameter(Mandatory = $true)][object] $Snapshot,
                    [Parameter(Mandatory = $true)][string] $RelativePath,
                    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $ExpectedBytes,
                    [Parameter(Mandatory = $true)][string] $Operation
                )
                & $realAtomicDelete @PSBoundParameters
                throw $interruptionSentinel
            }.GetNewClosure()
            # When
            $interruptionObserved = $false
            try {
                Set-Item -Path $atomicDeletePath -Value $interruptAfterDelete
                try {
                    Remove-TargetMutationFile -Snapshot $snapshot -RelativePath $relativePath
                }
                catch {
                    if ($_.Exception.Message -cne $interruptionSentinel) { throw }
                    $interruptionObserved = $true
                }
            }
            finally { Set-Item -Path $atomicDeletePath -Value $realAtomicDelete }

            # Then
            $interruptionObserved | Should Be $true
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $false
            Set-TestText -Path $targetPath -Value '# later user Instructions edit'
            $laterEditBytes = [IO.File]::ReadAllBytes($targetPath)
            $laterEditHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            { Restore-SkillMigrationJournal -Repository $snapshot.TargetRoot -Path $journalPath } | Should Throw 'preserved'
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $laterEditBytes) | Should Be $true
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $laterEditHash
        }
        finally {
            $script:SkillMigrationJournalContext = $null
            $ErrorActionPreference = $previousErrorActionPreference
            Set-StrictMode -Off
        }
    }

    # Scenario: A managed-file write is interrupted after a flushed prefix reaches the writer stream.
    # Purpose: Keep the published target complete, recover from durable intent, and preserve later unrelated bytes.
    It 'InterT30_recovers_managed_writer_prefix_without_publishing_partial_target_bytes' {
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-prefix-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $userHome | Out-Null
        $unrelatedPath=Join-Path $targetRoot 'project-notes/personal.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $unrelatedPath) | Out-Null
        Set-TestText -Path $unrelatedPath -Value 'unrelated original bytes'
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $newBytes=[Text.Encoding]::UTF8.GetBytes('# intended complete replacement'+"`n")
        $writerPath='Function:\Write-TargetMutationStreamBytes'
        $realWriter=$null
        $recoveryRootCreated=$false
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            $realWriter=(Get-Command ($writerPath -replace '^Function:\\','') -CommandType Function).ScriptBlock
            $interruptionSentinel='SYP214 writer interruption '+[guid]::NewGuid().ToString('N')
            $interruptAfterPrefix={
                param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,
                    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
                $Stream.Position=0
                $Stream.SetLength(0)
                $prefixLength=[Math]::Min(3,$Bytes.Length)
                if($prefixLength -gt 0){$Stream.Write($Bytes,0,$prefixLength)}
                $Stream.Flush($true)
                throw $interruptionSentinel
            }.GetNewClosure()
            # When
            $writeFailure=''
            Set-Item -Path $writerPath -Value $interruptAfterPrefix
            try { Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $relativePath -Bytes $newBytes }
            catch { $writeFailure=$_.Exception.Message }
            finally { Set-Item -Path $writerPath -Value $realWriter }
            # Then
            $writeFailure | Should Be $interruptionSentinel
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalBytes) | Should Be $true
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $journalState=@($journal.states | Where-Object { [string]$_.relativePath -ceq $relativePath })
            $journalState.Count | Should Be 1
            $journalState[0].mutationApplied | Should Be $true
            $journalState[0].appliedType | Should Be 'file'
            (Test-TargetMutationBytesEqual -Left ([Convert]::FromBase64String([string]$journalState[0].appliedBase64)) -Right $newBytes) | Should Be $true
            Set-TestText -Path $unrelatedPath -Value 'later unrelated bytes'
            $laterUnrelatedBytes=[IO.File]::ReadAllBytes($unrelatedPath)
            $recoveryWriterWitness=[pscustomobject]@{count=0}
            $rejectInPlaceRecoveryWrite={
                param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,
                    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
                $recoveryWriterWitness.count++
                throw 'SYP214 recovery must publish a complete staged file, not use the in-place writer.'
            }.GetNewClosure()
            $recoveryError=''
            Set-Item -Path $writerPath -Value $rejectInPlaceRecoveryWrite
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $recoveryError=$_.Exception.Message }
            finally { Set-Item -Path $writerPath -Value $realWriter }
            $recoveryError | Should BeNullOrEmpty
            $recoveryWriterWitness.count | Should Be 0
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalBytes) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($unrelatedPath)) -Right $laterUnrelatedBytes) | Should Be $true
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
        }
        finally {
            if($realWriter){Set-Item -Path $writerPath -Value $realWriter}
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-prefix-'}
        }
    }

    # Scenario: Managed .git/info/exclude is interrupted after a flushed prefix reaches its writer stream.
    # Purpose: Keep the existing ignore bytes published and recover without an in-place write or loss of later project bytes.
    It 'InterT40_recovers_exclude_writer_prefix_without_publishing_partial_ignore_bytes' {
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-exclude-prefix-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $userHome | Out-Null
        $unrelatedPath=Join-Path $targetRoot 'project-notes/personal.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $unrelatedPath) | Out-Null
        Set-TestText -Path $unrelatedPath -Value 'unrelated original bytes'
        $targetWriterPath='Function:\Write-TargetMutationStreamBytes'
        $excludeWriterPath='Function:\Write-GitInfoExcludeStreamBytes'
        $realTargetWriter=$null
        $realExcludeWriter=$null
        $recoveryRootCreated=$false
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            $excludePath=Get-GitInfoExcludePath -Repository $targetRoot
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
            [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
            $excludeBefore=[IO.File]::ReadAllBytes($excludePath)
            $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            $targetBefore=[IO.File]::ReadAllBytes($targetPath)
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            $realExcludeWriter=(Get-Command Write-GitInfoExcludeStreamBytes -CommandType Function).ScriptBlock
            $interruptionSentinel='SYP214 exclude writer interruption '+[guid]::NewGuid().ToString('N')
            $interruptAfterPrefix={
                param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,
                    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
                $Stream.Position=0
                $Stream.SetLength(0)
                $prefixLength=[Math]::Min(3,$Bytes.Length)
                if($prefixLength -gt 0){$Stream.Write($Bytes,0,$prefixLength)}
                $Stream.Flush($true)
                throw $interruptionSentinel
            }.GetNewClosure()
            # When
            $writeFailure=''
            Set-Item -Path $excludeWriterPath -Value $interruptAfterPrefix
            try { Set-ManagedGitInfoExclude -Repository $targetRoot -ManagedPaths @($relativePath) -Snapshot $excludeSnapshot }
            catch { $writeFailure=$_.Exception.Message }
            finally { Set-Item -Path $excludeWriterPath -Value $realExcludeWriter }
            # Then
            $writeFailure | Should Be $interruptionSentinel
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $excludeBefore) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $targetBefore) | Should Be $true
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $journal.exclude.mutationApplied | Should Be $true
            Set-TestText -Path $unrelatedPath -Value 'later unrelated bytes'
            $laterUnrelatedBytes=[IO.File]::ReadAllBytes($unrelatedPath)
            $recoveryTargetWriterWitness=[pscustomobject]@{count=0}
            $recoveryExcludeWriterWitness=[pscustomobject]@{count=0}
            $rejectTargetInPlaceWrite={
                param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,
                    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
                $recoveryTargetWriterWitness.count++
                throw 'SYP214 recovery must not mutate a managed target in place.'
            }.GetNewClosure()
            $rejectExcludeInPlaceWrite={
                param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,
                    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
                $recoveryExcludeWriterWitness.count++
                throw 'SYP214 recovery must publish a complete staged exclude file.'
            }.GetNewClosure()
            $recoveryError=''
            $realTargetWriter=(Get-Command Write-TargetMutationStreamBytes -CommandType Function).ScriptBlock
            Set-Item -Path $targetWriterPath -Value $rejectTargetInPlaceWrite
            Set-Item -Path $excludeWriterPath -Value $rejectExcludeInPlaceWrite
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $recoveryError=$_.Exception.Message }
            finally {
                Set-Item -Path $targetWriterPath -Value $realTargetWriter
                Set-Item -Path $excludeWriterPath -Value $realExcludeWriter
            }
            $recoveryError | Should BeNullOrEmpty
            $recoveryTargetWriterWitness.count | Should Be 0
            $recoveryExcludeWriterWitness.count | Should Be 0
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $excludeBefore) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $targetBefore) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($unrelatedPath)) -Right $laterUnrelatedBytes) | Should Be $true
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
        }
        finally {
            if($realTargetWriter){Set-Item -Path $targetWriterPath -Value $realTargetWriter}
            if($realExcludeWriter){Set-Item -Path $excludeWriterPath -Value $realExcludeWriter}
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-exclude-prefix-'}
        }
    }

    # Scenario: A completed target or exclude update is recovered after its restore writer flushes only a prefix.
    # Purpose: Keep the published applied bytes intact through the interrupted restore, then retry to the full original bytes.
    It 'InterT50_retries_<WriterKind>_restore_after_a_flushed_prefix_fault' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-restore-prefix-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $userHome | Out-Null
        $unrelatedPath=Join-Path $targetRoot 'project-notes/personal.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $unrelatedPath) | Out-Null
        Set-TestText -Path $unrelatedPath -Value 'unrelated original bytes'
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
        [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
        $excludeOriginal=[IO.File]::ReadAllBytes($excludePath)
        $originalTarget=[IO.File]::ReadAllBytes($targetPath)
        $newTargetBytes=[Text.Encoding]::UTF8.GetBytes('# fully applied replacement'+"`n")
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $writerPath=if($WriterKind -ceq 'target'){'Function:\Write-TargetMutationStreamBytes'}else{'Function:\Write-GitInfoExcludeStreamBytes'}
        $realWriter=$null
        $recoveryRootCreated=$false
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            if($WriterKind -ceq 'target'){
                Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $relativePath -Bytes $newTargetBytes
                $appliedBytes=[IO.File]::ReadAllBytes($targetPath)
            }
            else{
                Set-ManagedGitInfoExclude -Repository $targetRoot -ManagedPaths @($relativePath) -Snapshot $excludeSnapshot
                $appliedBytes=[IO.File]::ReadAllBytes($excludePath)
            }
            $script:SkillMigrationJournalContext=$null
            Set-TestText -Path $unrelatedPath -Value 'later unrelated bytes'
            $laterUnrelatedBytes=[IO.File]::ReadAllBytes($unrelatedPath)
            $faultWitness=[pscustomobject]@{count=0}
            $faultSentinel='SYP214 restore writer prefix fault '+[guid]::NewGuid().ToString('N')
            $interruptAfterPrefix={
                param([Parameter(Mandatory=$true)][IO.FileStream]$Stream,
                    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
                $faultWitness.count++
                $Stream.Position=0
                $Stream.SetLength(0)
                $prefixLength=[Math]::Min(3,$Bytes.Length)
                if($prefixLength -gt 0){$Stream.Write($Bytes,0,$prefixLength)}
                $Stream.Flush($true)
                throw $faultSentinel
            }.GetNewClosure()
            $restoreFailure=''
            $realWriter=(Get-Command ($writerPath -replace '^Function:\\','') -CommandType Function).ScriptBlock
            Set-Item -Path $writerPath -Value $interruptAfterPrefix
            # When
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $restoreFailure=$_.Exception.Message }
            finally { Set-Item -Path $writerPath -Value $realWriter }
            $publishedTargetStayedApplied=$false
            $publishedExcludeStayedApplied=$false
            if($WriterKind -ceq 'target'){
                $publishedTargetStayedApplied=Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $appliedBytes
            }
            else{
                $publishedExcludeStayedApplied=Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $appliedBytes
            }
            # When
            $retryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $retryFailure=$_.Exception.Message }
            # Then
            $faultWitness.count | Should Be 1
            $restoreFailure | Should Match ([regex]::Escape($faultSentinel))
            $retryFailure | Should BeNullOrEmpty
            $publishedTargetStayedApplied | Should Be ($WriterKind -ceq 'target')
            $publishedExcludeStayedApplied | Should Be ($WriterKind -ceq 'exclude')
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalTarget) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $excludeOriginal) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($unrelatedPath)) -Right $laterUnrelatedBytes) | Should Be $true
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
        }
        finally {
            if($realWriter){Set-Item -Path $writerPath -Value $realWriter}
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-restore-prefix-'}
        }
    }

    # Scenario: A real child process is terminated after a durable mutation intent and a flushed target/exclude prefix.
    # Purpose: Exercise abrupt writer death without finally and require recovery to preserve complete original bytes.
    It 'InterT70_recovers_<WriterKind>_after_the_writer_process_dies' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-process-crash-'+[guid]::NewGuid().ToString('N'))
        $childScriptPath=Join-Path $recoveryRoot 'writer-crash-child.ps1'
        $markerPath=Join-Path $recoveryRoot 'prefix-flushed.marker'
        $completionPath=Join-Path $recoveryRoot 'writer-complete.marker'
        $stdoutPath=Join-Path $recoveryRoot 'child.stdout.log'
        $stderrPath=Join-Path $recoveryRoot 'child.stderr.log'
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        $childProcess=$null
        $recoveryRootCreated=$false
        New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
        $recoveryRootCreated=$true
        New-Item -ItemType Directory -Force -Path $userHome | Out-Null
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        if($WriterKind -ceq 'exclude'){
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
            [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        elseif(-not (Test-Path -LiteralPath $excludePath -PathType Leaf)){
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
            [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
        . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
        $originalTarget=[IO.File]::ReadAllBytes($targetPath)
        $originalExclude=[IO.File]::ReadAllBytes($excludePath)
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $childScriptText=New-Syp214WriterCrashChildScript
        [IO.File]::WriteAllText($childScriptPath,$childScriptText,[Text.UTF8Encoding]::new($false))
        $childArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$childScriptPath,
            $script:BootstrapScript,$targetRoot,$userHome,$recoveryRoot,$relativePath,$WriterKind,$markerPath,$completionPath)
        $argumentLine=[string]::Join(' ',@($childArguments | ForEach-Object { '"'+([string]$_).Replace('"','\"')+'"' }))
        try {
            # When
            $childProcess=Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList $argumentLine `
                -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            if(-not $childProcess.WaitForExit(30000)){
                Stop-Process -Id $childProcess.Id -Force
                throw 'SYP214 writer crash child exceeded its bounded 30-second wait.'
            }
            $childProcess.Refresh()
            $prefixEvidence=$null
            $markerReadFailure=''
            if(Test-Path -LiteralPath $markerPath -PathType Leaf){
                try{$prefixEvidence=Get-Content -Raw -Encoding UTF8 -LiteralPath $markerPath | ConvertFrom-Json}
                catch{$markerReadFailure=$_.Exception.Message}
            }
            $prefixWasFlushed=$null -ne $prefixEvidence
            $writerReturned=Test-Path -LiteralPath $completionPath -PathType Leaf
            $preRecoveryTargetWasOriginal=Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalTarget
            $preRecoveryExcludeWasOriginal=Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $originalExclude
            $writerFinalPath=if($WriterKind -ceq 'target'){$targetPath}else{$excludePath}
            $markerPathIsFinal=$false
            $markerPathSameParent=$false
            $preRecoveryWriterFinalMatchesPrefix=$false
            $preRecoveryWriterStageVerifiedOrCleared=$false
            if($null -ne $prefixEvidence){
                try{
                    $markerFinalPath=ConvertTo-Syp214HandleFinalPath ([string]$prefixEvidence.finalPath)
                    $expectedFinalPath=[IO.Path]::GetFullPath($writerFinalPath)
                    $markerPathIsFinal=$markerFinalPath.Equals($expectedFinalPath,[StringComparison]::OrdinalIgnoreCase)
                    $markerPathSameParent=([IO.Path]::GetDirectoryName($markerFinalPath)).Equals(
                        [IO.Path]::GetDirectoryName($expectedFinalPath),[StringComparison]::OrdinalIgnoreCase)
                    if($markerPathIsFinal){
                        $preRecoveryWriterFinalMatchesPrefix=Test-Syp214CrashWriterEvidenceMatchesPath `
                            -Evidence $prefixEvidence -Path $writerFinalPath
                    }
                    elseif($markerPathSameParent){
                        $preRecoveryWriterStageVerifiedOrCleared=Test-Syp214CrashWriterStageIfRetained `
                            -Evidence $prefixEvidence -FinalPath $writerFinalPath
                    }
                }
                catch{}
            }
            # When
            $recoveryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $recoveryFailure=$_.Exception.Message }
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            $repositoryTreePreserved=$false
            $markerStageValidAfterRecovery=$false
            if($null -ne $prefixEvidence -and ($markerPathIsFinal -or $markerPathSameParent)){
                $markerStageValidAfterRecovery=Test-Syp214CrashWriterStageIfRetained `
                    -Evidence $prefixEvidence -FinalPath $writerFinalPath
                if($WriterKind -ceq 'target'){
                    $repositoryTreePreserved=Test-Syp214CrashRecoveryRepositoryTree `
                        -Before $snapshotBefore.repository.fullTree -After $snapshotAfter.repository.fullTree `
                        -Evidence $prefixEvidence -RepositoryRoot $targetRoot -FinalPath $targetPath
                }
                else{
                    $repositoryTreePreserved=Test-Syp214InventoryEqual `
                        -Left $snapshotBefore.repository.fullTree -Right $snapshotAfter.repository.fullTree
                }
            }
            # Then
            $prefixWasFlushed | Should Be $true
            [string]$markerReadFailure | Should BeNullOrEmpty
            $writerReturned | Should Be $false
            ($null -ne $prefixEvidence -and [string]$prefixEvidence.writerKind -ceq $WriterKind -and
                [string]$prefixEvidence.type -ceq 'file' -and [bool]$prefixEvidence.regularFile -and
                [uint32]$prefixEvidence.nativeFileType -eq 1 -and [uint32]$prefixEvidence.numberOfLinks -eq 1 -and
                [long]$prefixEvidence.length -eq 3 -and [regex]::IsMatch([string]$prefixEvidence.sha256,'^[0-9a-f]{64}$')) | Should Be $true
            ($markerPathIsFinal -or $markerPathSameParent) | Should Be $true
            if($markerPathIsFinal){
                $preRecoveryWriterFinalMatchesPrefix | Should Be $true
            }
            else{
                $preRecoveryWriterStageVerifiedOrCleared | Should Be $true
            }
            $preRecoveryTargetWasOriginal | Should Be $true
            $preRecoveryExcludeWasOriginal | Should Be $true
            $recoveryFailure | Should BeNullOrEmpty
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalTarget) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $originalExclude) | Should Be $true
            $repositoryTreePreserved | Should Be $true
            $markerStageValidAfterRecovery | Should Be $true
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.user.fullTree -Right $snapshotAfter.user.fullTree) | Should Be $true
        }
        finally {
            if($childProcess -and -not $childProcess.HasExited){Stop-Process -Id $childProcess.Id -Force -ErrorAction SilentlyContinue}
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-process-crash-'}
        }
    }

    # Scenario: The writer process dies after the original final file is renamed to its journaled tombstone.
    # Purpose: Reconcile the schema-v2 missing window by restoring the exact original file and retrying safely.
    It 'InterT80_recovers_<WriterKind>_after_process_death_in_the_old_to_tombstone_window' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-rename-window-'+[guid]::NewGuid().ToString('N'))
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $recoveryRoot,$userHome | Out-Null
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
        if(-not (Test-Path -LiteralPath $excludePath -PathType Leaf)){
            [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        $originalTarget=[IO.File]::ReadAllBytes($targetPath)
        $originalExclude=[IO.File]::ReadAllBytes($excludePath)
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $childProcess=$null
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            # When
            $child=Invoke-Syp214RenameCrashChild -RecoveryRoot $recoveryRoot -TargetRoot $targetRoot `
                -UserHome $userHome -RelativePath $relativePath -WriterKind $WriterKind
            # Then / When
            $child.MarkerExists | Should Be $true
            $child.CompletionExists | Should Be $false
            $journalPath=Join-Path (Join-Path $recoveryRoot 'target-backup') 'skill-migration.json'
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $journal.schemaVersion | Should Be 2
            $journal.phase | Should Be 'mutating'
            $publication=if($WriterKind -ceq 'target'){
                @($journal.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0].publication
            }else{$journal.exclude.publication}
            $publication | Should Not BeNullOrEmpty
            $writerPath=if($WriterKind -ceq 'target'){$targetPath}else{$excludePath}
            $parentPath=Split-Path -Parent $writerPath
            $stagePath=Join-Path $parentPath ([string]$publication.stageLeaf)
            $tombstonePath=Join-Path $parentPath ([string]$publication.tombstoneLeaf)
            [IO.Path]::GetFullPath($child.TombstonePath) | Should Be ([IO.Path]::GetFullPath($tombstonePath))
            Test-Path -LiteralPath $writerPath | Should Be $false
            Test-Path -LiteralPath $stagePath -PathType Leaf | Should Be $true
            Test-Path -LiteralPath $tombstonePath -PathType Leaf | Should Be $true
            $oldBytes=if($WriterKind -ceq 'target'){$originalTarget}else{$originalExclude}
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($tombstonePath)) -Right $oldBytes) | Should Be $true
            $stageBytes=[IO.File]::ReadAllBytes($stagePath)
            (Get-ByteArraySha256 -Bytes $stageBytes) | Should Be ([string]$publication.newSha256)
            $recoveryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $recoveryFailure=$_.Exception.Message }
            $recoveryFailure | Should BeNullOrEmpty
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($writerPath)) -Right $oldBytes) | Should Be $true
            Test-Path -LiteralPath $stagePath | Should Be $false
            Test-Path -LiteralPath $tombstonePath | Should Be $false
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.user.fullTree -Right $snapshotAfter.user.fullTree) | Should Be $true
        }
        finally {
            if($childProcess -and -not $childProcess.HasExited){Stop-Process -Id $childProcess.Id -Force -ErrorAction SilentlyContinue}
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-rename-window-'
        }
    }

    # Scenario: Independent recovery dies after its first rename, then again after removing its journaled stage.
    # Purpose: Re-enter the durable restore intent from both the tombstone gap and the completed-old-file cleanup state.
    It 'InterT96_reenters_<WriterKind>_restore_after_two_recovery_process_deaths' -TestCases @(@{WriterKind='target'},@{WriterKind='exclude'}) {
        param($WriterKind)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-restore-reentry-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $recoveryRoot,$userHome | Out-Null
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
        if(-not (Test-Path -LiteralPath $excludePath -PathType Leaf)){
            [IO.File]::WriteAllText($excludePath,"# original project exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        $originalTarget=[IO.File]::ReadAllBytes($targetPath)
        $originalExclude=[IO.File]::ReadAllBytes($excludePath)
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $recoveryRootCreated=$false
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            if($WriterKind -ceq 'target'){
                Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $relativePath `
                    -Bytes ([Text.Encoding]::UTF8.GetBytes('# applied restore-reentry bytes'+"`n"))
            }else{
                Set-ManagedGitInfoExclude -Repository $targetRoot -ManagedPaths @($relativePath) -Snapshot $excludeSnapshot
            }
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=$null
            $appliedTargetBytes=[IO.File]::ReadAllBytes($targetPath)
            $appliedExcludeBytes=[IO.File]::ReadAllBytes($excludePath)
            # When
            $firstDeath=Invoke-Syp214RestoreCrashChild -RecoveryRoot $recoveryRoot -TargetRoot $targetRoot `
                -UserHome $userHome -JournalPath $journalPath -CrashAt 'restore-first-rename'
            # Then / When
            $firstDeath.MarkerExists | Should Be $true
            $firstDeath.CompletionExists | Should Be $false
            $journalAfterFirstDeath=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $firstPublication=if($WriterKind -ceq 'target'){
                @($journalAfterFirstDeath.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0].publication
            }else{$journalAfterFirstDeath.exclude.publication}
            [string]$firstPublication.direction | Should Be 'restore'
            $finalPath=if($WriterKind -ceq 'target'){$targetPath}else{$excludePath}
            $parentPath=Split-Path -Parent $finalPath
            $restoreStagePath=Join-Path $parentPath ([string]$firstPublication.stageLeaf)
            $restoreTombstonePath=Join-Path $parentPath ([string]$firstPublication.tombstoneLeaf)
            Test-Path -LiteralPath $finalPath | Should Be $false
            Test-Path -LiteralPath $restoreStagePath -PathType Leaf | Should Be $true
            Test-Path -LiteralPath $restoreTombstonePath -PathType Leaf | Should Be $true
            (Get-ByteArraySha256 ([IO.File]::ReadAllBytes($restoreStagePath))) | Should Be ([string]$firstPublication.newSha256)
            $secondDeath=Invoke-Syp214RestoreCrashChild -RecoveryRoot $recoveryRoot -TargetRoot $targetRoot `
                -UserHome $userHome -JournalPath $journalPath -CrashAt 'restore-stage-cleanup'
            $secondDeath.MarkerExists | Should Be $true
            $secondDeath.CompletionExists | Should Be $false
            Test-Path -LiteralPath $restoreStagePath | Should Be $false
            Test-Path -LiteralPath $restoreTombstonePath | Should Be $false
            $expectedIntervalBytes=if($WriterKind -ceq 'target'){$appliedTargetBytes}else{$appliedExcludeBytes}
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($finalPath)) -Right $expectedIntervalBytes) | Should Be $true
            $staleJournal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $stalePublication=if($WriterKind -ceq 'target'){
                @($staleJournal.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0].publication
            }else{$staleJournal.exclude.publication}
            [string]$stalePublication.direction | Should Be 'restore'
            Test-Path -LiteralPath ([string]$secondDeath.MarkerValue) | Should Be $false
            # When / Then
            $retryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $retryFailure=$_.Exception.Message }
            $retryFailure | Should BeNullOrEmpty
            $expectedOriginalBytes=if($WriterKind -ceq 'target'){$originalTarget}else{$originalExclude}
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($finalPath)) -Right $expectedOriginalBytes) | Should Be $true
            $finalJournal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $finalJournal.phase | Should Be 'recovered'
            $finalState=if($WriterKind -ceq 'target'){@($finalJournal.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0]}else{$finalJournal.exclude}
            $finalState.publication | Should BeNullOrEmpty
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.repository.gitInfoExclude -Right $snapshotAfter.repository.gitInfoExclude) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.user.fullTree -Right $snapshotAfter.user.fullTree) | Should Be $true
        }
        finally {
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-restore-reentry-'}
        }
    }

    # Scenario: A durable schema-v2 deletion intent records the managed target as missing before restoration starts.
    # Purpose: Publish verified original bytes through an absent-old no-replace stage and accept a legal missing restore intent.
    It 'InterT97_restores_original_bytes_from_a_schema_v2_missing_applied_state' {
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-missing-restore-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $recoveryRoot,$userHome | Out-Null
        $originalTarget=[IO.File]::ReadAllBytes($targetPath)
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $recoveryRootCreated=$false
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            # When
            Remove-TargetMutationFile -Snapshot $snapshot -RelativePath $relativePath
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $missingIntent=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $missingState=@($missingIntent.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0]
            $missingState.originalType | Should Be 'file'
            $missingState.appliedType | Should Be 'missing'
            $missingState.mutationApplied | Should Be $true
            Test-Path -LiteralPath $targetPath | Should Be $false
            $script:SkillMigrationJournalContext=$null
            # Then
            $recoveryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $recoveryFailure=$_.Exception.Message }
            $recoveryFailure | Should BeNullOrEmpty
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalTarget) | Should Be $true
            $restoredJournal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $restoredJournal.schemaVersion | Should Be 2
            $restoredJournal.phase | Should Be 'recovered'
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.user.fullTree -Right $snapshotAfter.user.fullTree) | Should Be $true
        }
        finally {
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-missing-restore-'}
        }
    }

    # Scenario: A schema-v1 target or exclude file/missing state lacks recorded historical identity and DACL metadata.
    # Purpose: Retry staged whole-file recovery after a prefix fault without fabricating v2 history or claiming a missing final.
    It 'InterT98_recovers_schema_v1_<WriterKind>_<AppliedType>_without_inventing_historic_metadata_after_a_prefix_fault' -TestCases @(
        @{WriterKind='target';AppliedType='file'},@{WriterKind='target';AppliedType='missing'},@{WriterKind='exclude';AppliedType='file'}) {
        param($WriterKind,$AppliedType)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-v1-restore-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $recoveryRoot,$userHome | Out-Null
        $originalTarget=[IO.File]::ReadAllBytes($targetPath)
        $appliedBytes=[Text.Encoding]::UTF8.GetBytes('# legacy schema-v1 applied bytes'+"`n")
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
        if(-not (Test-Path -LiteralPath $excludePath -PathType Leaf)){
            [IO.File]::WriteAllText($excludePath,"# schema-v1 existing exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        $originalExclude=[IO.File]::ReadAllBytes($excludePath)
        $snapshotBefore=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
            -Entries @([pscustomobject]@{targetPath=$relativePath})
        $writerPath=if($WriterKind -ceq 'target'){'Function:\Write-TargetMutationStreamBytes'}else{'Function:\Write-GitInfoExcludeStreamBytes'}
        $realWriter=$null
        $recoveryRootCreated=$false
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            if($WriterKind -ceq 'target' -and $AppliedType -ceq 'file'){
                Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $relativePath -Bytes $appliedBytes
            }elseif($WriterKind -ceq 'target'){
                Remove-TargetMutationFile -Snapshot $snapshot -RelativePath $relativePath
            }else{
                Set-ManagedGitInfoExclude -Repository $targetRoot -ManagedPaths @($relativePath) -Snapshot $excludeSnapshot
            }
            $targetStateMutation=$WriterKind -ceq 'target'
            $legacyState=[ordered]@{relativePath=$relativePath;originalType='file'
                backupName=(Split-Path -Leaf ([string]$snapshot.FileStates[0].BackupPath))
                backupSha256=(Get-RawContentHash ([string]$snapshot.FileStates[0].BackupPath))
                mutationApplied=$targetStateMutation;appliedType=$(if($targetStateMutation){$AppliedType}else{$null})
                appliedBase64=$(if($targetStateMutation -and $AppliedType -ceq 'file'){[Convert]::ToBase64String($appliedBytes)}else{$null})}
            $legacyExcludeAppliedBytes=if($WriterKind -ceq 'exclude'){[IO.File]::ReadAllBytes($excludePath)}else{$null}
            $legacyExclude=[ordered]@{Path=$excludeSnapshot.Path;Repository=$excludeSnapshot.Repository
                MutationApplied=($WriterKind -ceq 'exclude');Existed=[bool]$excludeSnapshot.Existed
                Bytes=$excludeSnapshot.Bytes;AppliedBytes=$legacyExcludeAppliedBytes}
            $legacyJournal=[ordered]@{schemaVersion=1;targetRoot=$targetRoot;phase='mutating';head=$gitState.head
                indexSha256=$gitState.indexSha256;states=@($legacyState);exclude=$legacyExclude}
            [IO.File]::WriteAllText($journalPath,($legacyJournal | ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
            $script:SkillMigrationJournalContext=$null
            if($AppliedType -ceq 'file'){
                $liveHandle=if($WriterKind -ceq 'target'){
                    [CodexAiInstructions.NativeFileMutation]::OpenForMetadata($targetRoot,$targetPath,$relativePath)
                }else{[CodexAiInstructions.NativeFileMutation]::OpenStandaloneForMetadata($excludePath)}
                try {
                    $liveDacl=Get-FileDaclJournalRecord -Handle $liveHandle
                    $liveReadOnly=[CodexAiInstructions.NativeFileMutation]::GetReadOnly($liveHandle)
                }finally{$liveHandle.Dispose()}
            }
            $faultSentinel='SYP214 legacy v1 prefix fault '+[guid]::NewGuid().ToString('N')
            $prefixFault={
                param([IO.FileStream]$Stream,[byte[]]$Bytes)
                $Stream.Position=0
                $Stream.SetLength(0)
                $prefixLength=[Math]::Min(3,$Bytes.Length)
                if($prefixLength -gt 0){$Stream.Write($Bytes,0,$prefixLength)}
                $Stream.Flush($true)
                throw $faultSentinel
            }.GetNewClosure()
            $realWriter=(Get-Command ($writerPath -replace '^Function:\\','') -CommandType Function).ScriptBlock
            Set-Item -Path $writerPath -Value $prefixFault
            # When
            $prefixFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $prefixFailure=$_.Exception.Message }
            finally { Set-Item -Path $writerPath -Value $realWriter }
            # Then / When
            $prefixFailure | Should Match ([regex]::Escape($faultSentinel))
            $afterFault=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $afterFault.schemaVersion | Should Be 1
            $publishedPath=if($WriterKind -ceq 'target'){$targetPath}else{$excludePath}
            $expectedAppliedBytes=if($WriterKind -ceq 'target'){$appliedBytes}else{$legacyExcludeAppliedBytes}
            if($WriterKind -ceq 'target' -and $AppliedType -ceq 'missing'){
                Test-Path -LiteralPath $publishedPath | Should Be $false
            }else{
                (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($publishedPath)) -Right $expectedAppliedBytes) | Should Be $true
            }
            if($WriterKind -ceq 'target'){
                $afterFaultState=@($afterFault.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0]
                $afterFaultState.appliedType | Should Be $AppliedType
                $afterFaultState.PSObject.Properties['publication'] | Should BeNullOrEmpty
                $afterFaultState.PSObject.Properties['originalDacl'] | Should BeNullOrEmpty
                $afterFaultState.PSObject.Properties['originalIdentity'] | Should BeNullOrEmpty
            }else{
                $afterFault.exclude.MutationApplied | Should Be $true
                $afterFault.exclude.PSObject.Properties['publication'] | Should BeNullOrEmpty
                $afterFault.exclude.PSObject.Properties['dacl'] | Should BeNullOrEmpty
                $afterFault.exclude.PSObject.Properties['originalIdentity'] | Should BeNullOrEmpty
            }
            $stageParent=Split-Path -Parent $publishedPath
            $unrecordedStages=@(Get-ChildItem -LiteralPath $stageParent -Force -File -Filter '.syp214-*-stage')
            $unrecordedStages.Count | Should BeGreaterThan 0
            [byte[]]$prefixBytes=[IO.File]::ReadAllBytes($unrecordedStages[0].FullName)
            $prefixBytes.Length | Should Be 3
            $script:SkillMigrationJournalContext=$null
            $retryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $retryFailure=$_.Exception.Message }
            $retryFailure | Should BeNullOrEmpty
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalTarget) | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($excludePath)) -Right $originalExclude) | Should Be $true
            Test-Path -LiteralPath $unrecordedStages[0].FullName -PathType Leaf | Should Be $true
            if($AppliedType -ceq 'file'){
                $liveAfterHandle=if($WriterKind -ceq 'target'){
                    [CodexAiInstructions.NativeFileMutation]::OpenForMetadata($targetRoot,$targetPath,$relativePath)
                }else{[CodexAiInstructions.NativeFileMutation]::OpenStandaloneForMetadata($excludePath)}
                try {
                    $afterDacl=Get-FileDaclJournalRecord -Handle $liveAfterHandle
                    [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                        (ConvertFrom-FileDaclJournalRecord $liveDacl),(ConvertFrom-FileDaclJournalRecord $afterDacl)) | Should Be $true
                    [CodexAiInstructions.NativeFileMutation]::GetReadOnly($liveAfterHandle) | Should Be ([bool]$liveReadOnly)
                }finally{$liveAfterHandle.Dispose()}
            }
            $finalJournal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $finalJournal.schemaVersion | Should Be 1
            $finalJournal.phase | Should Be 'recovered'
            $finalState=@($finalJournal.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0]
            $finalState.PSObject.Properties['originalDacl'] | Should BeNullOrEmpty
            $finalState.PSObject.Properties['originalIdentity'] | Should BeNullOrEmpty
            $finalState.PSObject.Properties['publication'] | Should BeNullOrEmpty
            $finalJournal.exclude.PSObject.Properties['dacl'] | Should BeNullOrEmpty
            $finalJournal.exclude.PSObject.Properties['originalIdentity'] | Should BeNullOrEmpty
            $finalJournal.exclude.PSObject.Properties['publication'] | Should BeNullOrEmpty
            $snapshotAfter=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome `
                -Entries @([pscustomobject]@{targetPath=$relativePath})
            (Test-Syp214GitStateEqual -Left $snapshotBefore.repository -Right $snapshotAfter.repository) | Should Be $true
            (Test-Syp214InventoryEqual -Left $snapshotBefore.user.fullTree -Right $snapshotAfter.user.fullTree) | Should Be $true
        }
        finally {
            if($realWriter){Set-Item -Path $writerPath -Value $realWriter}
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            if($recoveryRootCreated){Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-v1-restore-'}
        }
    }

    # Scenario: A completed stage is paired with a later unrelated final or is consumed and later deleted.
    # Purpose: Fail closed on both ambiguous states while preserving the unrelated final and journaled tombstone.
    It 'InterT90_rejects_<CompetingState>_without_clobbering_unrelated_or_owned_bytes' -TestCases @(
        @{CompetingState='unrelated-final'},@{CompetingState='consumed-stage-then-deleted-final'}) {
        param($CompetingState)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-rename-conflict-'+[guid]::NewGuid().ToString('N'))
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $recoveryRoot,$userHome | Out-Null
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
        if(-not (Test-Path -LiteralPath $excludePath -PathType Leaf)){
            [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        $originalBytes=[IO.File]::ReadAllBytes($targetPath)
        $childProcess=$null
        try {
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            # When
            $child=Invoke-Syp214RenameCrashChild -RecoveryRoot $recoveryRoot -TargetRoot $targetRoot `
                -UserHome $userHome -RelativePath $relativePath -WriterKind 'target'
            $child.MarkerExists | Should Be $true
            $child.CompletionExists | Should Be $false
            $journalPath=Join-Path (Join-Path $recoveryRoot 'target-backup') 'skill-migration.json'
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $publication=@($journal.states | Where-Object { [string]$_.relativePath -ceq $relativePath })[0].publication
            $stagePath=Join-Path (Split-Path -Parent $targetPath) ([string]$publication.stageLeaf)
            $tombstonePath=Join-Path (Split-Path -Parent $targetPath) ([string]$publication.tombstoneLeaf)
            $expectedStageBytes=[IO.File]::ReadAllBytes($stagePath)
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($tombstonePath)) -Right $originalBytes) | Should Be $true
            if($CompetingState -ceq 'unrelated-final'){
                $unrelatedBytes=[Text.Encoding]::UTF8.GetBytes('unrelated final collision'+"`n")
                [IO.File]::WriteAllBytes($targetPath,$unrelatedBytes)
            }
            else{
                Move-Item -LiteralPath $stagePath -Destination $targetPath
                Remove-Item -LiteralPath $targetPath -Force
            }
            # When / Then
            $recoveryFailure=''
            try { Restore-SkillMigrationJournal -Repository $targetRoot -Path $journalPath | Out-Null }
            catch { $recoveryFailure=$_.Exception.Message }
            $recoveryFailure | Should Not BeNullOrEmpty
            $afterJournal=Get-Content -Raw -Encoding UTF8 -LiteralPath $journalPath | ConvertFrom-Json
            $afterJournal.phase | Should Be 'mutating'
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($tombstonePath)) -Right $originalBytes) | Should Be $true
            if($CompetingState -ceq 'unrelated-final'){
                (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $unrelatedBytes) | Should Be $true
                (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($stagePath)) -Right $expectedStageBytes) | Should Be $true
            }
            else{
                Test-Path -LiteralPath $targetPath | Should Be $false
                Test-Path -LiteralPath $stagePath | Should Be $false
            }
        }
        finally {
            if($childProcess -and -not $childProcess.HasExited){Stop-Process -Id $childProcess.Id -Force -ErrorAction SilentlyContinue}
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-rename-conflict-'
        }
    }

    # Scenario: A flushed prefix faults while publishing a target or exclude with either inherited or protected DACLs.
    # Purpose: Apply the original DACL before staged payload bytes and preserve the original final DACL and read-only flag.
    It 'InterT95_preserves_<Protection>_DACL_and_readonly_after_<WriterKind>_staging_prefix_fault' -TestCases @(
        @{Protection='inherited';Protected=$false;WriterKind='target'},
        @{Protection='protected';Protected=$true;WriterKind='target'},
        @{Protection='inherited';Protected=$false;WriterKind='exclude'},
        @{Protection='protected';Protected=$true;WriterKind='exclude'}) {
        param($Protection,$Protected,$WriterKind)
        # Given
        $previousErrorActionPreference=$ErrorActionPreference
        $recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp214-dacl-prefix-'+[guid]::NewGuid().ToString('N'))
        $backupRoot=Join-Path $recoveryRoot 'target-backup'
        $journalPath=Join-Path $backupRoot 'skill-migration.json'
        $userHome=Join-Path $caseRoot 'user'
        New-Item -ItemType Directory -Force -Path $recoveryRoot,$userHome | Out-Null
        $excludePath=Get-Syp214GitInfoExcludeFixturePath -Repository $targetRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $excludePath) | Out-Null
        if(-not (Test-Path -LiteralPath $excludePath -PathType Leaf)){
            [IO.File]::WriteAllText($excludePath,"# existing project exclusions`n",[Text.UTF8Encoding]::new($false))
        }
        $writerPath=if($WriterKind -ceq 'target'){'Function:\Write-TargetMutationStreamBytes'}else{'Function:\Write-GitInfoExcludeStreamBytes'}
        $filePath=if($WriterKind -ceq 'target'){$targetPath}else{$excludePath}
        $fileAcl=Get-Acl -LiteralPath $filePath
        $fileAcl.SetAccessRuleProtection([bool]$Protected,$true)
        Set-Acl -LiteralPath $filePath -AclObject $fileAcl
        [IO.File]::SetAttributes($filePath,[IO.File]::GetAttributes($filePath) -bor [IO.FileAttributes]::ReadOnly)
        $originalBytes=[IO.File]::ReadAllBytes($filePath)
        $originalAttributes=[IO.File]::GetAttributes($filePath)
        $realWriter=$null
        $recoveryRootCreated=$false
        try {
            # When
            $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $recoveryRootCreated=$true
            $snapshot=New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot=New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState=Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext=[pscustomobject]@{
                Snapshot=$snapshot;ExcludeSnapshot=$excludeSnapshot;Path=$journalPath;GitState=$gitState
            }
            $expectedDacl=if($WriterKind -ceq 'target'){
                @($snapshot.FileStates | Where-Object { [string]$_.RelativePath -ceq $relativePath })[0].OriginalDacl
            }else{$excludeSnapshot.DaclRecord}
            $expectedNativeDacl=ConvertFrom-FileDaclJournalRecord $expectedDacl
            $writerWitness=[pscustomobject]@{called=$false;daclMatched=$false;protected=$null}
            $faultSentinel='SYP214 DACL staging prefix fault '+[guid]::NewGuid().ToString('N')
            $faultAfterDaclCheck={
                param([IO.FileStream]$Stream,[byte[]]$Bytes)
                $writerWitness.called=$true
                $stageDacl=[CodexAiInstructions.NativeFileMutation]::CaptureDacl($Stream.SafeFileHandle)
                $writerWitness.daclMatched=[CodexAiInstructions.NativeFileMutation]::DaclEquals(
                    $expectedNativeDacl,$stageDacl)
                $writerWitness.protected=[bool]$stageDacl.isProtected
                $Stream.Position=0
                $Stream.SetLength(0)
                $prefixLength=[Math]::Min(3,$Bytes.Length)
                if($prefixLength -gt 0){$Stream.Write($Bytes,0,$prefixLength)}
                $Stream.Flush($true)
                throw $faultSentinel
            }.GetNewClosure()
            $realWriter=(Get-Command ($writerPath -replace '^Function:\\','') -CommandType Function).ScriptBlock
            Set-Item -Path $writerPath -Value $faultAfterDaclCheck
            $writeFailure=''
            try {
                if($WriterKind -ceq 'target'){
                    Set-TargetMutationFileBytes -Snapshot $snapshot -RelativePath $relativePath `
                        -Bytes ([Text.Encoding]::UTF8.GetBytes('# intended replacement'+"`n"))
                }else{
                    Set-ManagedGitInfoExclude -Repository $targetRoot -ManagedPaths @($relativePath) -Snapshot $excludeSnapshot
                }
            }
            catch { $writeFailure=$_.Exception.Message }
            finally { Set-Item -Path $writerPath -Value $realWriter }
            # Then
            $writeFailure | Should Match ([regex]::Escape($faultSentinel))
            $writerWitness.called | Should Be $true
            $writerWitness.daclMatched | Should Be $true
            $writerWitness.protected | Should Be ([bool]$Protected)
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($filePath)) -Right $originalBytes) | Should Be $true
            ([IO.File]::GetAttributes($filePath) -band [IO.FileAttributes]::ReadOnly) -ne 0 | Should Be $true
            $finalHandle=if($WriterKind -ceq 'target'){
                [CodexAiInstructions.NativeFileMutation]::OpenForMetadata($targetRoot,$filePath,$relativePath)
            }else{[CodexAiInstructions.NativeFileMutation]::OpenStandaloneForMetadata($filePath)}
            try {
                $finalDacl=Get-FileDaclJournalRecord -Handle $finalHandle
                [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                    (ConvertFrom-FileDaclJournalRecord $expectedDacl),(ConvertFrom-FileDaclJournalRecord $finalDacl)) | Should Be $true
                [CodexAiInstructions.NativeFileMutation]::GetReadOnly($finalHandle) | Should Be $true
            }
            finally { $finalHandle.Dispose() }
            [byte[]]$finalBytes=[IO.File]::ReadAllBytes($filePath)
            (Get-ByteArraySha256 -Bytes $finalBytes) | Should Be (Get-ByteArraySha256 -Bytes $originalBytes)
            [bool]($originalAttributes -band [IO.FileAttributes]::ReadOnly) | Should Be $true
        }
        finally {
            if($realWriter){Set-Item -Path $writerPath -Value $realWriter}
            $script:SkillMigrationJournalContext=$null
            $ErrorActionPreference=$previousErrorActionPreference
            Set-StrictMode -Off
            Remove-Syp214TemporaryRecoveryRoot -Path $recoveryRoot -ExpectedPrefix 'syp214-dacl-prefix-'
        }
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
        ($output -join ' ') | Should Match 'Skill migration.*Backup'
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
        $after = (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash
        $line=@($output | ForEach-Object {[string]$_} | Where-Object {$_ -match '^Skill migration transaction retained\.'})[0]
        $journalPath=$line.Substring($line.IndexOf('journal: ') + 9).Trim()
        $journal=Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
        $journalFilesBeforeNoOpRuns=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $journalInventoryVerifiedBeforeNoOpRuns=Test-Syp214JournalInventory -Inventory $journalFilesBeforeNoOpRuns -Journal $journal
        $journalInventoryVerifiedBeforeNoOpRuns | Should Be $true
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
        $journalFilesAfterNoOpRuns=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $journalInventoryVerifiedAfterNoOpRuns=Test-Syp214JournalInventory -Inventory $journalFilesAfterNoOpRuns -Journal $journal
        $journalInventoryStable=(ConvertTo-Json -InputObject $journalFilesBeforeNoOpRuns -Depth 6 -Compress) -ceq
            (ConvertTo-Json -InputObject $journalFilesAfterNoOpRuns -Depth 6 -Compress)
        $userBytesStable | Should Be $true
        $manifestDryRunStable | Should Be $true
        $gitCoreStatePreserved | Should Be $true
        $stashEvidenceStableAfterNoOpRuns | Should Be $true
        $unrelatedFilesPreserved | Should Be $true
        $applyExcludeRegularFile | Should Be $true
        $journalInventoryVerifiedAfterNoOpRuns | Should Be $true
        $journalInventoryStable | Should Be $true
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
            backupInventory=@($journal.states | Where-Object originalType -eq 'file' | Select-Object relativePath,backupName,backupSha256)
            journalFilesBeforeNoOpRuns=$journalFilesBeforeNoOpRuns;journalFilesAfterNoOpRuns=$journalFilesAfterNoOpRuns
            journalInventoryVerifiedBeforeNoOpRuns=$journalInventoryVerifiedBeforeNoOpRuns
            journalInventoryVerifiedAfterNoOpRuns=$journalInventoryVerifiedAfterNoOpRuns;journalInventoryStable=$journalInventoryStable
            journalPhase=$journal.phase; dryRunPreservedManifest=$manifestDryRunStable
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

    # Scenario: A failure occurs after the first verified Skill file removal.
    # Purpose: Restore exact original files and manifest through the existing mutation transaction.
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
        $failureOutputForParsing=[regex]::Replace($failureOutputText,'\x1B\[[0-?]*[ -/]*[@-~]','')
        $retainedPathMatch=[regex]::Match($failureOutputForParsing,'(?im)AI instruction sync temporary recovery files were preserved at:\s*(?<path>[^\r\n]+)')
        $retainedPathMatch.Success | Should Be $true
        $retainedWorkingPath=[IO.Path]::GetFullPath($retainedPathMatch.Groups['path'].Value.Trim())
        $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar
        $retainedWorkingPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) | Should Be $true
        $failureJournalPath=Join-Path $retainedWorkingPath 'target-backup/skill-migration.json'
        Test-Path -LiteralPath $failureJournalPath -PathType Leaf | Should Be $true
        $failureJournal=Get-Content -Raw -Encoding UTF8 -LiteralPath $failureJournalPath | ConvertFrom-Json
        $failureJournal.phase | Should Be 'rolled-back'
        $failureJournalInventory=@(Get-Syp214JournalInventory -JournalPath $failureJournalPath -Journal $failureJournal)
        $failureJournalInventoryVerified=Test-Syp214JournalInventory -Inventory $failureJournalInventory -Journal $failureJournal
        $failureJournalInventoryVerified | Should Be $true
        $failureJournalEvidence=[ordered]@{
            schemaVersion=$failureJournal.schemaVersion;phase=$failureJournal.phase;head=$failureJournal.head
            indexSha256=$failureJournal.indexSha256
            states=@($failureJournal.states | ForEach-Object {
                [ordered]@{relativePath=$_.relativePath;originalType=$_.originalType;backupName=$_.backupName
                    backupSha256=$_.backupSha256;mutationApplied=$_.mutationApplied;appliedType=$_.appliedType}
            })
        }
        $failureOutputBytes=[Text.Encoding]::UTF8.GetBytes($failureOutputText)
        $failureOutputSha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($failureOutputBytes)).Replace('-','').ToLowerInvariant())
        $privateRoots=@(
            $caseRoot,$targetRoot,$userHome,$sourceRoot,[IO.Path]::GetTempPath(),$retainedWorkingPath,$PSHOME,$script:TestPowerShellExecutable,
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
            $failureJournalInventoryVerified -and [string]$failureJournal.phase -ceq 'rolled-back' -and
            $filesRestored -and $manifestRestored -and $userBytesPreserved -and $repositoryTreeRestored -and
            $repositoryPointInventoryRestored -and $userPointInventoryPreserved -and
            $repositoryGitStatePreserved -and $repositoryExcludeRestored -and $unrelatedFilesPreserved)
        $verified | Should Be $true
        Save-Syp214FixtureEvidence 'failure-rollback' ([ordered]@{
            schemaVersion=2;scope='disposable integration fixture';runIdentity=(Get-Syp214RunIdentity)
            failureAfterRemovedFiles=1;failureProcessExitCode=$failureExitCode;failureMessage=$failureMessageSafe
            capturedOutput=[ordered]@{redactedText=$failureOutputSafe;byteLength=$failureOutputBytes.Length;sha256=$failureOutputSha256}
            failureJournal=$failureJournalEvidence;journalFiles=$failureJournalInventory
            journalInventoryVerified=$failureJournalInventoryVerified;before=$beforeSnapshot;after=$afterSnapshot
            originalManifestRestored=$manifestRestored;restoredFiles=$restoredFiles;userBytesPreserved=$userBytesPreserved
            repositoryTreeRestored=$repositoryTreeRestored;repositoryPointInventoryRestored=$repositoryPointInventoryRestored
            userPointInventoryPreserved=$userPointInventoryPreserved;repositoryGitStatePreserved=$repositoryGitStatePreserved
            repositoryExcludeRestored=$repositoryExcludeRestored
            unrelatedFiles=[ordered]@{repositoryBefore=$unrelatedRepositoryBefore;repositoryAfter=$unrelatedRepositoryAfter
                userBefore=$unrelatedUserBefore;userAfter=$unrelatedUserAfter;preserved=$unrelatedFilesPreserved}
            verified=$verified
        })
    }

    # Scenario: A completed or interrupted transaction is recovered from its durable backup.
    # Purpose: Restore exact pre-migration state and refuse later edits or a corrupt backup.
    It 'InterT60_durable_recovery_<State>' -TestCases @(@{State='exact'},@{State='later-edit'},@{State='corrupt-backup'},@{State='pending-intent'}) {
        param($State)
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $unrelatedEvidencePaths=New-Syp214UnrelatedEvidenceFiles -Repository $targetRoot -UserHome $userHome
        foreach($entry in $entries){
            $full=Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath),$full,$true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $manifestBefore=[IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $manifestBeforeBytes=[IO.File]::ReadAllBytes((Join-Path $targetRoot $script:ManifestPath))
        $beforeSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $unrelatedRepositoryBefore=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserBefore=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $pendingIntentChild=$null
        $pendingIntentEvidenceVerified=$null
        $output=@()
        if($State -eq 'pending-intent'){
            New-TestProvenance -ArchivePath $sourceArchive -Path $script:TestProvenancePath
            $pendingIntentChild=Invoke-Syp214ManifestIntentExitChild -RecoveryRoot $caseRoot `
                -SourceArchivePath $sourceArchive -TargetRoot $targetRoot -ConfigurationPath $script:TestConfigurationPath `
                -ProvenancePath $script:TestProvenancePath -UserHome $userHome
            $pendingIntentChild.ExitCode | Should Be 0
            $pendingIntentChild.MarkerExists | Should Be $true
            $journalPath=[string]$pendingIntentChild.Marker.journalPath
            $output=@(Get-Content -Encoding UTF8 -LiteralPath $pendingIntentChild.StdoutPath)
        }
        else{
            $output=Invoke-Syp214Bootstrap
            $line=@($output | ForEach-Object {[string]$_} | Where-Object {$_ -match '^Skill migration transaction retained\.'})[0]
            $journalPath=$line.Substring($line.IndexOf('journal: ') + 9).Trim()
        }
        Test-Path -LiteralPath $journalPath | Should Be $true
        $journal=Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
        $repoFile=Join-Path $targetRoot $entries[0].targetPath
        switch($State){
            'later-edit' { Set-TestText $repoFile 'later project edit' }
            'corrupt-backup' { Set-TestText (Join-Path (Split-Path $journalPath) $journal.states[0].backupName) 'corrupt backup' }
            'pending-intent' {
                $pendingManifestRelativePath=$script:ManifestPath.Replace('\','/')
                $pendingManifestFullPath=Join-Path $targetRoot $pendingManifestRelativePath
                $bootstrapPrefix=New-Syp214BootstrapMutationPrefix
                . $bootstrapPrefix -TargetRoot $targetRoot -UserHome $userHome -GitExecutable 'git'
                $manifestState=@($journal.states | Where-Object { [string]$_.relativePath -ceq $pendingManifestRelativePath })[0]
                $manifestState | Should Not BeNullOrEmpty
                $manifestState.mutationApplied | Should Be $true
                $manifestState.appliedType | Should Be 'file'
                $manifestState.publication.direction | Should Be 'apply'
                $manifestState.publication.expectedOldExists | Should Be $true
                [string]$manifestState.publication.expectedOldIdentity | Should Be ([string]$manifestState.originalIdentity)
                [string]$pendingIntentChild.Marker.relativePath | Should Be $pendingManifestRelativePath
                [string]$pendingIntentChild.Marker.direction | Should Be 'apply'
                [string]$pendingIntentChild.Marker.expectedOldIdentity | Should Be ([string]$manifestState.originalIdentity)
                [string]$pendingIntentChild.Marker.stageIdentity | Should Be ([string]$manifestState.publication.stageIdentity)
                $manifestEvidence=Get-PublicationFileEvidence -Root $targetRoot -Path $pendingManifestFullPath `
                    -RelativePath $pendingManifestRelativePath -Kind Target
                (Test-TargetMutationBytesEqual -Left ([byte[]]$manifestEvidence.bytes) -Right $manifestBeforeBytes) | Should Be $true
                [string]$manifestEvidence.identity | Should Be ([string]$manifestState.publication.expectedOldIdentity)
                $manifestStagePath=Join-Path (Split-Path -Parent $pendingManifestFullPath) ([string]$manifestState.publication.stageLeaf)
                $manifestStageRelative=([IO.Path]::GetRelativePath($targetRoot,$manifestStagePath)).Replace('\','/')
                $manifestStageEvidence=Get-PublicationFileEvidence -Root $targetRoot -Path $manifestStagePath `
                    -RelativePath $manifestStageRelative -Kind Target
                [string]$manifestStageEvidence.identity | Should Be ([string]$manifestState.publication.stageIdentity)
                [long]$manifestStageEvidence.length | Should Be ([long]$manifestState.publication.newLength)
                [string]$manifestStageEvidence.sha256 | Should Be ([string]$manifestState.publication.newSha256)
                [CodexAiInstructions.NativeFileMutation]::DaclEquals(
                    (ConvertFrom-FileDaclJournalRecord $manifestState.publicationDacl),
                    (ConvertFrom-FileDaclJournalRecord $manifestStageEvidence.dacl)) | Should Be $true
                [bool]$manifestStageEvidence.readOnly | Should Be ([bool]$manifestState.publicationReadOnly)
                $pendingIntentEvidenceVerified=$true
            }
        }
        $preRecoverySnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $journalFilesBeforeRecovery=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $corruptBackupName=if($State -eq 'corrupt-backup'){[string]$journal.states[0].backupName}else{''}
        $journalInventoryVerifiedBeforeRecovery=Test-Syp214JournalInventory -Inventory $journalFilesBeforeRecovery -Journal $journal -ExpectedCorruptBackupName $corruptBackupName
        $journalInventoryVerifiedBeforeRecovery | Should Be $true
        $corruptBackupRecords=@($journalFilesBeforeRecovery | Where-Object { [string]$_.relativePath -ceq $corruptBackupName })
        $corruptBackupWitnessMatchesInventory=$true
        if($corruptBackupName){
            $corruptBackupRecords.Count | Should Be 1
            $corruptBackupRecord=$corruptBackupRecords[0]
            $corruptBackupWitness=[ordered]@{
                relativePath=[string]$corruptBackupRecord['relativePath']
                expectedSha256=[string]$corruptBackupRecord['expectedSha256']
                sha256=[string]$corruptBackupRecord['sha256']
                matchesJournalSha256=[bool]$corruptBackupRecord['matchesJournalSha256']
            }
            $corruptBackupWitnessMatchesInventory=([string]$corruptBackupWitness.relativePath -ceq [string]$corruptBackupRecord['relativePath'] -and
                [string]$corruptBackupWitness.expectedSha256 -ceq [string]$corruptBackupRecord['expectedSha256'] -and
                [string]$corruptBackupWitness.sha256 -ceq [string]$corruptBackupRecord['sha256'] -and
                [bool]$corruptBackupWitness.matchesJournalSha256 -eq [bool]$corruptBackupRecord['matchesJournalSha256'])
            $corruptBackupWitnessMatchesInventory | Should Be $true
            $corruptBackupWitness.relativePath | Should Be $corruptBackupName
            $corruptBackupWitness.expectedSha256 | Should Not Be $corruptBackupWitness.sha256
            $corruptBackupWitness.matchesJournalSha256 | Should Be $false
        }
        else{$corruptBackupWitness=$null}
        $recoveryError=''
        $recoveryOutput=@()
        # When / Then
        if($State -eq 'later-edit'){
            try { $recoveryOutput=@(Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath) }
            catch { $recoveryError=$_.Exception.Message }
            $recoveryError | Should Match 'preserved'
            (Get-Content -Raw $repoFile).Trim() | Should Be 'later project edit'
        }
        elseif($State -eq 'corrupt-backup'){
            $after=(Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash
            try { $recoveryOutput=@(Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath) }
            catch { $recoveryError=$_.Exception.Message }
            $recoveryError | Should Match 'backup hash mismatch'
            (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash | Should Be $after
            Test-Path -LiteralPath $repoFile | Should Be $false
        }
        else {
            $recoveryOutput=@(Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath)
            [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath)) | Should Be $manifestBefore
            Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
            foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
            Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath | Out-Null
        }
        foreach($entry in $entries){ (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $afterSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $journalFilesAfterRecovery=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $journalInventoryVerifiedAfterRecovery=Test-Syp214JournalInventory -Inventory $journalFilesAfterRecovery -Journal $journal -ExpectedCorruptBackupName $corruptBackupName
        $journalInventoryVerifiedAfterRecovery | Should Be $true
        $journalAfterRecovery=if(Test-Path -LiteralPath $journalPath -PathType Leaf){Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json}else{$null}
        $userBytesPreserved=Test-Syp214InventoryEqual -Left $beforeSnapshot.user.fullTree -Right $afterSnapshot.user.fullTree
        $repositoryStateVerified=$false
        if($State -eq 'later-edit'){
            $repositoryStateVerified=((Get-Content -Raw $repoFile).Trim() -ceq 'later project edit' -and $recoveryError -match 'preserved')
        }
        elseif($State -eq 'corrupt-backup'){
            $manifestPath=Join-Path $targetRoot $script:ManifestPath
            $manifestBeforeRecoveryHash=[string](@($preRecoverySnapshot.repository.files | Where-Object { $_.relativePath -ceq '.codex/ai-instructions.manifest.json' })[0].sha256)
            $repositoryStateVerified=(-not (Test-Path -LiteralPath $repoFile) -and
                (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifestBeforeRecoveryHash)
        }
        else{
            $manifestAfter=[IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
            $filesRestored=@($entries | Where-Object {
                $entry=$_
                (Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.targetPath) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256
            }).Count -eq 0
            $repositoryStateVerified=($manifestAfter -ceq $manifestBefore -and -not (Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) -and $filesRestored)
        }
        $expectedRepositorySnapshot=if($State -in @('later-edit','corrupt-backup')){$preRecoverySnapshot.repository}else{$beforeSnapshot.repository}
        $expectedExcludeBasis=if($State -eq 'later-edit'){'pre-recovery snapshot; drift stops target restore before exclude recovery'}elseif($State -eq 'corrupt-backup'){'pre-recovery snapshot; recovery preflight rejected the corrupt backup'}else{'apply-before snapshot; journal recovery restores the original exclude'}
        $expectedExcludeSnapshot=if($State -in @('later-edit','corrupt-backup')){$preRecoverySnapshot.repository}else{$beforeSnapshot.repository}
        $laterEditTreeRecordBeforeRecovery=$null
        $laterEditPointRecordBeforeRecovery=$null
        $laterEditTreeRecordAfterRecovery=$null
        $laterEditPointRecordAfterRecovery=$null
        $laterEditDriftInventoryPreserved=$null
        if($State -eq 'later-edit'){
            $driftRelativePath=[string]$entries[0].targetPath
            $laterEditTreeRecordBeforeRecovery=@($preRecoverySnapshot.repository.fullTree | Where-Object { [string]$_.relativePath -ceq $driftRelativePath })
            $laterEditPointRecordBeforeRecovery=@($preRecoverySnapshot.repository.files | Where-Object { [string]$_.relativePath -ceq $driftRelativePath })
            $laterEditTreeRecordBeforeRecovery.Count | Should Be 1
            $laterEditPointRecordBeforeRecovery.Count | Should Be 1
            $laterEditTreeRecordBeforeRecovery[0].type | Should Be 'file'
            $laterEditTreeRecordBeforeRecovery[0].regularFile | Should Be $true
            $laterEditTreeRecordBeforeRecovery[0].length | Should BeGreaterThan 0
            $laterEditTreeRecordBeforeRecovery[0].sha256 | Should Match '^[0-9a-f]{64}$'
            (Test-Syp214FileInventoryRecordEqual -Left $laterEditTreeRecordBeforeRecovery[0] -Right $laterEditPointRecordBeforeRecovery[0]) | Should Be $true
            (Get-Content -Raw -LiteralPath $repoFile).Trim() | Should Be 'later project edit'
            $expectedRepositorySnapshot=New-Syp214RepositorySnapshotWithFileOverride `
                -Snapshot $beforeSnapshot.repository -TreeFileRecord $laterEditTreeRecordBeforeRecovery[0] `
                -PointFileRecord $laterEditPointRecordBeforeRecovery[0]
            $laterEditTreeRecordAfterRecovery=@($afterSnapshot.repository.fullTree | Where-Object { [string]$_.relativePath -ceq $driftRelativePath })
            $laterEditPointRecordAfterRecovery=@($afterSnapshot.repository.files | Where-Object { [string]$_.relativePath -ceq $driftRelativePath })
            $laterEditTreeRecordAfterRecovery.Count | Should Be 1
            $laterEditPointRecordAfterRecovery.Count | Should Be 1
            $laterEditTreeRecordPreserved=Test-Syp214FileInventoryRecordEqual -Left $laterEditTreeRecordBeforeRecovery[0] -Right $laterEditTreeRecordAfterRecovery[0]
            $laterEditPointRecordPreserved=Test-Syp214FileInventoryRecordEqual -Left $laterEditPointRecordBeforeRecovery[0] -Right $laterEditPointRecordAfterRecovery[0]
            $laterEditDriftInventoryPreserved=($laterEditTreeRecordPreserved -and $laterEditPointRecordPreserved)
            $laterEditDriftInventoryPreserved | Should Be $true
        }
        $laterEditDriftInventoryVerified=($State -ne 'later-edit' -or [bool]$laterEditDriftInventoryPreserved)
        $repositoryTreeSemanticallyStable=Test-Syp214InventoryEqual -Left $expectedRepositorySnapshot.fullTree -Right $afterSnapshot.repository.fullTree
        $repositoryPointInventorySemanticallyStable=Test-Syp214PointInventoryEqual -Left $expectedRepositorySnapshot -Right $afterSnapshot.repository
        $userPointInventoryPreserved=Test-Syp214PointInventoryEqual -Left $beforeSnapshot.user -Right $afterSnapshot.user
        $expectedGitCoreSnapshot=if($State -eq 'pending-intent'){$beforeSnapshot.repository}else{$preRecoverySnapshot.repository}
        $expectedGitCoreBasis=if($State -eq 'pending-intent'){'apply-before snapshot; recovery restores the interrupted transaction to its original Git state'}else{'pre-recovery snapshot'}
        $repositoryGitCoreStateSemanticallyStable=Test-Syp214GitCoreStateEqual -Left $expectedGitCoreSnapshot -Right $afterSnapshot.repository
        $repositoryStashEvidenceStable=Test-Syp214InventoryEqual -Left $preRecoverySnapshot.repository.stashes -Right $afterSnapshot.repository.stashes
        $repositoryExcludeSemanticallyStable=Test-Syp214InventoryEqual -Left $expectedExcludeSnapshot.gitInfoExclude -Right $afterSnapshot.repository.gitInfoExclude
        $unrelatedRepositoryAfter=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths $unrelatedEvidencePaths.repository)
        $unrelatedUserAfter=@(Get-Syp214FileInventory -Root $userHome -RelativePaths $unrelatedEvidencePaths.user)
        $unrelatedFilesPreserved=(Test-Syp214InventoryEqual -Left $unrelatedRepositoryBefore -Right $unrelatedRepositoryAfter) -and
            (Test-Syp214InventoryEqual -Left $unrelatedUserBefore -Right $unrelatedUserAfter)
        $recoveryCheckResults=[ordered]@{
            userBytesPreserved=[bool]$userBytesPreserved;repositoryStateVerified=[bool]$repositoryStateVerified
            journalInventoryVerifiedBeforeRecovery=[bool]$journalInventoryVerifiedBeforeRecovery
            journalInventoryVerifiedAfterRecovery=[bool]$journalInventoryVerifiedAfterRecovery
            repositoryTreeSemanticallyStable=[bool]$repositoryTreeSemanticallyStable
            repositoryPointInventorySemanticallyStable=[bool]$repositoryPointInventorySemanticallyStable
            userPointInventoryPreserved=[bool]$userPointInventoryPreserved
            repositoryGitCoreStateSemanticallyStable=[bool]$repositoryGitCoreStateSemanticallyStable
            repositoryStashEvidenceStable=[bool]$repositoryStashEvidenceStable
            repositoryExcludeSemanticallyStable=[bool]$repositoryExcludeSemanticallyStable
            unrelatedFilesPreserved=[bool]$unrelatedFilesPreserved
            laterEditDriftInventoryVerified=[bool]$laterEditDriftInventoryVerified
            corruptBackupWitnessMatchesInventory=[bool]$corruptBackupWitnessMatchesInventory
            pendingManifestIntentEvidenceVerified=([bool]($State -ne 'pending-intent' -or $pendingIntentEvidenceVerified))
        }
        $failedRecoveryChecks=@($recoveryCheckResults.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object { [string]$_.Key })
        $verified=($failedRecoveryChecks.Count -eq 0)
        Save-Syp214FixtureEvidence ('recovery-'+$State) ([ordered]@{
            schemaVersion=2;scope='disposable integration fixture';runIdentity=(Get-Syp214RunIdentity);scenario=$State
            before=$beforeSnapshot;preRecovery=$preRecoverySnapshot;after=$afterSnapshot
            journalBeforeRecovery=$journal;journalAfterRecovery=$journalAfterRecovery
            journalFilesBeforeRecovery=$journalFilesBeforeRecovery;journalFilesAfterRecovery=$journalFilesAfterRecovery
            journalInventoryVerifiedBeforeRecovery=$journalInventoryVerifiedBeforeRecovery
            journalInventoryVerifiedAfterRecovery=$journalInventoryVerifiedAfterRecovery;corruptBackupWitness=$corruptBackupWitness
            corruptBackupWitnessMatchesInventory=$corruptBackupWitnessMatchesInventory
            recoveryOutput=@($recoveryOutput | ForEach-Object { [string]$_ });recoveryError=$recoveryError
            repositoryTreeSemanticallyStable=$repositoryTreeSemanticallyStable
            repositoryPointInventorySemanticallyStable=$repositoryPointInventorySemanticallyStable
            expectedRepositoryAfterRecovery=[ordered]@{basis=$(if($State -eq 'later-edit'){'apply-before snapshot plus pre-recovery measured drift file'}elseif($State -eq 'corrupt-backup'){'pre-recovery snapshot'}else{'apply-before snapshot'})
                fullTree=$expectedRepositorySnapshot.fullTree;files=$expectedRepositorySnapshot.files
                missingFileWitness=$expectedRepositorySnapshot.missingFileWitness
                laterEditDriftRecordBeforeRecovery=[ordered]@{fullTree=$laterEditTreeRecordBeforeRecovery;pointInventory=$laterEditPointRecordBeforeRecovery}
                laterEditDriftRecordAfterRecovery=[ordered]@{fullTree=$laterEditTreeRecordAfterRecovery;pointInventory=$laterEditPointRecordAfterRecovery}
                laterEditDriftInventoryPreserved=$laterEditDriftInventoryPreserved}
            userPointInventoryPreserved=$userPointInventoryPreserved
            repositoryGitCoreStateSemanticallyStable=$repositoryGitCoreStateSemanticallyStable
            expectedGitCoreState=[ordered]@{basis=$expectedGitCoreBasis
                head=$expectedGitCoreSnapshot.head;indexSha256=$expectedGitCoreSnapshot.indexSha256
                status=@($expectedGitCoreSnapshot.status)
                afterRecovery=[ordered]@{head=$afterSnapshot.repository.head;indexSha256=$afterSnapshot.repository.indexSha256
                    status=@($afterSnapshot.repository.status)}
                stable=$repositoryGitCoreStateSemanticallyStable}
            repositoryStashEvidenceStable=$repositoryStashEvidenceStable
            repositoryStashesBeforeRecovery=$preRecoverySnapshot.repository.stashes
            repositoryStashesAfterRecovery=$afterSnapshot.repository.stashes
            repositoryExcludeSemanticallyStable=$repositoryExcludeSemanticallyStable
            expectedGitInfoExclude=[ordered]@{basis=$expectedExcludeBasis
                expectedInventory=$expectedExcludeSnapshot.gitInfoExclude;afterRecoveryInventory=$afterSnapshot.repository.gitInfoExclude
                stable=$repositoryExcludeSemanticallyStable}
            pendingManifestIntent=[ordered]@{child=$pendingIntentChild;interruptionEvidenceVerified=$pendingIntentEvidenceVerified}
            recoveryCheckResults=$recoveryCheckResults;failedChecks=$failedRecoveryChecks
            unrelatedFiles=[ordered]@{repositoryBefore=$unrelatedRepositoryBefore;repositoryAfter=$unrelatedRepositoryAfter
                userBefore=$unrelatedUserBefore;userAfter=$unrelatedUserAfter;preserved=$unrelatedFilesPreserved}
            verified=$verified;repositoryStateVerified=$repositoryStateVerified;userBytesPreserved=$userBytesPreserved
            processKillExecuted=$false;interruptionModel=$(if($State -eq 'pending-intent'){'controlled child exit after durable manifest publication intent before the first rename'}else{'no process termination'})
        })
        if($failedRecoveryChecks.Count -gt 0){ throw "Recovery fixture checks failed: $($failedRecoveryChecks -join ', ')" }
        $verified | Should Be $true
    }
}
