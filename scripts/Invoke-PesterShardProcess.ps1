[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][ValidateSet('3.4.0', '4.10.1')][string] $PesterVersion,
    [Parameter(Mandatory = $true)][int] $ExpectedTotalCount,
    [Parameter(Mandatory = $true)][int] $ExpectedSkippedCount,
    [string[]] $IsolatedTestFileNames = @(
        'standard-validation-runner.Tests.ps1',
        'syp101-production-smoke-contract.Tests.ps1'
    ),
    [int] $OuterTimeoutSeconds = 1800,
    [string] $CancellationPath,
    [string] $TestRoot = './tests',
    [string] $EvidenceRoot
)

$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
    throw 'INVALID|Pester shard executor does not accept a caller-visible CancellationPath; use the supervisor-only cancellation channel.'
}

# The shard boundary is deliberately self-contained.  It cannot rely on the
# central runner being dot-sourced because this script is also the isolated
# Windows PowerShell 5.1/7 entry point.  Keep the same kernel containment and
# bounded-capture primitives as the trusted runner here.
$script:PesterShardChildOutputQuotaCharacters = 1048576

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $null -eq ('PesterShardProcessControlNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class PesterShardProcessControlNative
{
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int JobObjectExtendedLimitInformationClass = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JobObjectExtendedLimitInformation information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnCloseJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
        }
        JobObjectExtendedLimitInformation information = new JobObjectExtendedLimitInformation();
        information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
        if (!SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformationClass,
            ref information,
            (uint)Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation))))
        {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error, "SetInformationJobObject failed.");
        }
        return job;
    }

    public static bool TryAssignProcessToJobObject(IntPtr job, IntPtr process)
    {
        return AssignProcessToJobObject(job, process);
    }

    public static bool TryTerminateJobObject(IntPtr job, uint exitCode)
    {
        return TerminateJobObject(job, exitCode);
    }

    public static bool TryCloseHandle(IntPtr handle)
    {
        return CloseHandle(handle);
    }
}
'@
}

if ($null -eq ('PesterShardBoundedCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class PesterShardBoundedCaptureResult
{
    public string Text { get; private set; }
    public bool Exceeded { get; private set; }
    public int CharacterCount { get; private set; }

    public PesterShardBoundedCaptureResult(string text, bool exceeded, int characterCount)
    {
        Text = text;
        Exceeded = exceeded;
        CharacterCount = characterCount;
    }
}

public static class PesterShardBoundedCapture
{
    public static Task<PesterShardBoundedCaptureResult> Start(StreamReader reader, int quota)
    {
        if (reader == null) throw new ArgumentNullException("reader");
        if (quota < 1) throw new ArgumentOutOfRangeException("quota");
        return Task.Factory.StartNew(
            () => Read(reader, quota),
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    private static PesterShardBoundedCaptureResult Read(StreamReader reader, int quota)
    {
        var builder = new StringBuilder(Math.Min(quota, 4096));
        var buffer = new char[4096];
        var count = 0;
        while (true)
        {
            var read = reader.Read(buffer, 0, buffer.Length);
            if (read == 0) return new PesterShardBoundedCaptureResult(builder.ToString(), false, count);
            var remaining = quota - count;
            if (read > remaining)
            {
                if (remaining > 0) builder.Append(buffer, 0, remaining);
                return new PesterShardBoundedCaptureResult(builder.ToString(), true, quota);
            }
            builder.Append(buffer, 0, read);
            count += read;
        }
    }
}
'@
}

if ($OuterTimeoutSeconds -le 0) { throw 'OuterTimeoutSeconds must be positive.' }
if (-not (Test-Path -LiteralPath $PesterModulePath -PathType Leaf)) {
    throw "Pester module path does not identify a file: $PesterModulePath"
}

function Test-PesterShardReparseItem {
    param([Parameter(Mandatory = $true)] $Item)

    $isReparse = (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    $isHardLink = ($Item.PSObject.Properties.Name -contains 'LinkType' -and
        [string]$Item.LinkType -match '(?i)^HardLink$')
    # A regular executable can be a hardlink on Windows. Hardlink identity is
    # not a symlink/reparse traversal and must not invalidate the controlled
    # child-host path; symbolic links and junctions remain fail-closed.
    if (-not $isReparse -and -not $isHardLink -and $Item.PSObject.Properties.Name -contains 'LinkType' -and
        -not [string]::IsNullOrWhiteSpace([string]$Item.LinkType) -and
        [string]$Item.LinkType -notmatch '(?i)^HardLink$') {
        $isReparse = $true
    }
    if (-not $isReparse -and -not $isHardLink -and $Item.PSObject.Properties.Name -contains 'Target' -and
        $null -ne $Item.Target -and -not [string]::IsNullOrWhiteSpace(([string](@($Item.Target) -join '|')))) {
        $isReparse = $true
    }
    return [bool]$isReparse
}

function Assert-PesterShardPathAncestorsNoReparse {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $existingPath = $fullPath
    while (-not (Test-Path -LiteralPath $existingPath)) {
        $parent = [IO.Path]::GetDirectoryName($existingPath)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $existingPath) { break }
        $existingPath = $parent
    }
    if (-not (Test-Path -LiteralPath $existingPath)) {
        throw "Preflight $Context has no existing ancestor: $fullPath"
    }

    $item = Get-Item -Force -LiteralPath $existingPath -ErrorAction Stop
    while ($null -ne $item) {
        if (Test-PesterShardReparseItem -Item $item) {
            throw "Preflight $Context contains a symlinked or reparse-point ancestor: $($item.FullName)"
        }
        $parent = $item.Parent
        if ($null -eq $parent -or $parent.FullName -ceq $item.FullName) { break }
        $item = $parent
    }
}

$repositoryRoot = (Get-Location).Path
$resolvedTestRoot = (Resolve-Path -LiteralPath $TestRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = $env:RUNNER_TEMP }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path $repositoryRoot '.syp154-pester-evidence' }
Assert-PesterShardPathAncestorsNoReparse -Path $EvidenceRoot -Context 'evidence root'
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
function Test-PesterShardProcessAlive {
    param([Parameter(Mandatory = $true)][int] $ProcessId)

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return (-not [bool]$process.HasExited)
    }
    catch {
        return $false
    }
}

function Get-PesterShardChildEnvironment {
    $safeInheritedNames = @(
        'PATH', 'Path', 'PATHEXT', 'COMSPEC', 'SYSTEMROOT', 'WINDIR', 'OS',
        'TEMP', 'TMP', 'TMPDIR', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_IDENTIFIER', 'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)',
        'PROGRAMW6432', 'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)',
        'COMMONPROGRAMW6432', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'HOME',
        'APPDATA', 'LOCALAPPDATA', 'LANG', 'LC_ALL', 'LC_CTYPE', 'DOTNET_ROOT',
        'DOTNET_ROOT_X64', 'XDG_RUNTIME_DIR', 'PSExecutionPolicyPreference'
    )
    $childEnvironment = [ordered]@{}
    foreach ($name in $safeInheritedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $childEnvironment[$name] = [string]$value }
    }
    foreach ($item in @(Get-ChildItem Env:)) {
        $name = [string]$item.Name
        if ($name -match '^SYP154_PESTER_[A-Za-z0-9_]+$') {
            $childEnvironment[$name] = [string]$item.Value
        }
    }
    return $childEnvironment
}

function Get-PesterShardProcessBootstrapCode {
    return @'
$ErrorActionPreference = 'Stop'
$targetCommand = [string]$env:SYP154_PESTER_BOOTSTRAP_COMMAND
$argumentJson = [string]$env:SYP154_PESTER_BOOTSTRAP_ARGUMENTS
$releasePath = [string]$env:SYP154_PESTER_BOOTSTRAP_RELEASE_PATH
if ([string]::IsNullOrWhiteSpace($targetCommand) -or [string]::IsNullOrWhiteSpace($releasePath)) {
    throw 'Owned Pester shard bootstrap received incomplete target metadata.'
}
$targetArguments = @()
if (-not [string]::IsNullOrWhiteSpace($argumentJson)) {
    $parsedArguments = ConvertFrom-Json -InputObject $argumentJson
    if ($null -ne $parsedArguments) {
        foreach ($item in @($parsedArguments)) {
            if ($item -isnot [string]) { throw 'Owned Pester shard bootstrap arguments must be strings.' }
            $targetArguments += [string]$item
        }
    }
}
while (-not [IO.File]::Exists($releasePath)) { Start-Sleep -Milliseconds 10 }
# The release metadata is supervisor-only. Do not make it visible to the
# actual Pester child even though that child is launched by this bootstrap.
foreach ($name in @(
    'SYP154_PESTER_BOOTSTRAP_COMMAND',
    'SYP154_PESTER_BOOTSTRAP_ARGUMENTS',
    'SYP154_PESTER_BOOTSTRAP_RELEASE_PATH'
)) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
& $targetCommand @targetArguments
if ($null -eq $LASTEXITCODE) { exit 0 }
exit ([int]$LASTEXITCODE)
'@
}

function Get-PesterShardProcessIdentity {
    param([Parameter(Mandatory = $true)][int] $ProcessId)

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        $startTimeUtc = $null
        try { $startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch { }
        return [pscustomobject][ordered]@{
            processId = $ProcessId
            processName = [string]$process.ProcessName
            startTimeUtc = $startTimeUtc
            identityAvailable = (-not [string]::IsNullOrWhiteSpace([string]$startTimeUtc))
        }
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Add-PesterShardProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][hashtable] $IdentityMap
    )

    if ($ProcessId -le 0 -or $IdentityMap.ContainsKey($ProcessId)) { return }
    $identity = Get-PesterShardProcessIdentity -ProcessId $ProcessId
    if ($null -eq $identity) {
        $identity = [pscustomobject][ordered]@{
            processId = $ProcessId
            processName = $null
            startTimeUtc = $null
            identityAvailable = $false
        }
    }
    $IdentityMap[$ProcessId] = $identity
}

function Write-PesterShardBoundedOutput {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowEmptyString()][string] $Text
    )

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($Path, [string]$Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-PesterShardPreflight {
    param(
        [Parameter(Mandatory = $true)][string] $PesterModulePath,
        [Parameter(Mandatory = $true)][string] $PesterVersion,
        [Parameter(Mandatory = $true)][string] $ChildPowerShell,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][string] $ResultPath,
        [Parameter(Mandatory = $true)][string] $ProcessEvidencePath,
        [Parameter(Mandatory = $true)][string] $StdoutPath,
        [Parameter(Mandatory = $true)][string] $StderrPath,
        [Parameter(Mandatory = $true)][string] $CancelPath,
        [string] $BootstrapSignalPath
    )

    $isWindowsPlatform = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
    $paths = [ordered]@{
        workingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
        childPowerShell = [IO.Path]::GetFullPath($ChildPowerShell)
        pesterModule = [IO.Path]::GetFullPath($PesterModulePath)
        result = [IO.Path]::GetFullPath($ResultPath)
        processEvidence = [IO.Path]::GetFullPath($ProcessEvidencePath)
        stdout = [IO.Path]::GetFullPath($StdoutPath)
        stderr = [IO.Path]::GetFullPath($StderrPath)
        cancellation = [IO.Path]::GetFullPath($CancelPath)
        bootstrapSignal = if ([string]::IsNullOrWhiteSpace($BootstrapSignalPath)) { $null } else { [IO.Path]::GetFullPath($BootstrapSignalPath) }
    }
    $pathLengths = [ordered]@{}
    foreach ($entry in $paths.GetEnumerator()) {
        $pathLengths[$entry.Key] = if ($null -eq $entry.Value) { $null } else { ([string]$entry.Value).Length }
    }
    if ($isWindowsPlatform) {
        foreach ($entry in $pathLengths.GetEnumerator()) {
            if ($null -ne $entry.Value -and [int]$entry.Value -ge 240) {
                throw "Preflight path '$($entry.Key)' is $($entry.Value) characters; the controlled Windows shard boundary requires fewer than 240 characters."
            }
        }
    }

    foreach ($entry in $paths.GetEnumerator()) {
        if ($null -ne $entry.Value) {
            Assert-PesterShardPathAncestorsNoReparse -Path ([string]$entry.Value) -Context ([string]$entry.Key)
        }
    }

    foreach ($filePath in @($paths.childPowerShell, $paths.pesterModule)) {
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Preflight file does not exist: $filePath"
        }
        $item = Get-Item -Force -LiteralPath $filePath -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Preflight file is not a direct regular file: $filePath"
        }
    }
    foreach ($directoryPath in @($paths.workingDirectory, [IO.Path]::GetDirectoryName($paths.result), [IO.Path]::GetDirectoryName($paths.processEvidence))) {
        if ([string]::IsNullOrWhiteSpace($directoryPath) -or -not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            throw "Preflight directory does not exist: $directoryPath"
        }
        $item = Get-Item -Force -LiteralPath $directoryPath -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Preflight directory is a reparse point: $directoryPath"
        }
    }

    $permissionResults = New-Object 'System.Collections.Generic.List[object]'
    foreach ($directoryPath in @($paths.workingDirectory, [IO.Path]::GetDirectoryName($paths.processEvidence) | Select-Object -Unique)) {
        $probePath = Join-Path $directoryPath (".syp154-pester-preflight-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        $probeCreated = $false
        try {
            $probeStream = [IO.File]::Open($probePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $probeStream.Flush() } finally { $probeStream.Dispose() }
            $probeCreated = $true
            $permissionResults.Add([pscustomobject][ordered]@{ directory = $directoryPath; writeCreateDelete = 'passed' })
        }
        catch {
            $permissionResults.Add([pscustomobject][ordered]@{ directory = $directoryPath; writeCreateDelete = 'failed'; error = $_.Exception.Message })
            throw "Preflight could not create a temporary file in '$directoryPath': $($_.Exception.Message)"
        }
        finally {
            if ($probeCreated -and [IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) }
        }
    }

    $jobObjectProbe = 'not-applicable'
    if ($isWindowsPlatform) {
        $probeJobHandle = [IntPtr]::Zero
        try {
            $probeJobHandle = [PesterShardProcessControlNative]::CreateKillOnCloseJob()
            if (-not [PesterShardProcessControlNative]::TryCloseHandle($probeJobHandle)) {
                throw 'The preflight Job Object handle could not be closed.'
            }
            $probeJobHandle = [IntPtr]::Zero
            $jobObjectProbe = 'create-close-passed'
        }
        finally {
            if ($probeJobHandle -ne [IntPtr]::Zero) {
                try { [void][PesterShardProcessControlNative]::TryCloseHandle($probeJobHandle) } catch { }
            }
        }
    }
    $childEnvironment = Get-PesterShardChildEnvironment
    $childEnvironmentNames = @($childEnvironment.Keys | Sort-Object)
    $excludedSensitiveNames = @($childEnvironmentNames | Where-Object { $_ -match '(?i)secret|password|token|authorization|api[-_]?key|bearer' })
    if ($excludedSensitiveNames.Count -gt 0) {
        throw "Preflight child environment unexpectedly contains sensitive names: $($excludedSensitiveNames -join ', ')"
    }
    $loadedPester = @(Get-Module -Name Pester | Where-Object { $_.Version -eq [version]$PesterVersion } | Select-Object -First 1)[0]
    return [ordered]@{
        schemaVersion = 1
        osPlatform = [string][Environment]::OSVersion.Platform
        powershellVersion = [string]$PSVersionTable.PSVersion
        powershellEdition = [string]$PSVersionTable.PSEdition
        pesterVersion = $PesterVersion
        loadedPesterVersion = if ($null -eq $loadedPester) { $null } else { [string]$loadedPester.Version }
        loadedPesterPath = if ($null -eq $loadedPester) { $null } else { [string]$loadedPester.Path }
        childPowerShell = [string]$paths.childPowerShell
        workingDirectory = [string]$paths.workingDirectory
        paths = $paths
        pathLengths = $pathLengths
        childEnvironmentNames = $childEnvironmentNames
        excludedSensitiveNames = @($excludedSensitiveNames)
        permissions = @($permissionResults.ToArray())
        isolation = [ordered]@{
            jobObject = $jobObjectProbe
            bootstrapSignal = if ($isWindowsPlatform) { 'private-supervisor-path' } else { 'not-applicable' }
            cancellationPathExposedToChild = $false
            candidateProcessContainment = if ($isWindowsPlatform) { 'kill-on-close-job-object' } else { 'identity-checked-fallback' }
        }
    }
}

function Get-PesterShardDescendantProcessIds {
    param([Parameter(Mandatory = $true)][int] $RootProcessId)

    $processes = @(
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Select-Object -Property ProcessId, ParentProcessId
    )
    $frontier = @($RootProcessId)
    $descendants = New-Object 'System.Collections.Generic.List[int]'
    while ($frontier.Count -gt 0) {
        $next = New-Object 'System.Collections.Generic.List[int]'
        foreach ($process in $processes) {
            $processId = [int]$process.ProcessId
            if (($frontier -contains [int]$process.ParentProcessId) -and
                $processId -ne $RootProcessId -and -not $descendants.Contains($processId)) {
                $descendants.Add($processId)
                $next.Add($processId)
            }
        }
        $frontier = @($next.ToArray())
    }
    return @($descendants.ToArray())
}

function Read-PesterShardOutputPrefix {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [int] $MaxChars = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    $reader = $null
    $builder = New-Object System.Text.StringBuilder
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::UTF8), $true
        $buffer = New-Object char[] 4096
        $remaining = [Math]::Max(0, $MaxChars)
        while ($remaining -gt 0) {
            $read = $reader.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
            if ($read -le 0) { break }
            [void]$builder.Append($buffer, 0, $read)
            $remaining -= $read
        }
        return $builder.ToString()
    }
    catch {
        return "<output-read-error: $($_.Exception.Message)>"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-PesterShardOutputTail {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [int] $MaxBytes = 65536,
        [int] $MaxChars = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    if ($MaxBytes -lt 1 -or $MaxChars -lt 1) { return '' }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $start = [Math]::Max([int64]0, $stream.Length - [int64]$MaxBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $requested = [int]($stream.Length - $start)
        $buffer = New-Object byte[] $requested
        $total = 0
        while ($total -lt $requested) {
            $read = $stream.Read($buffer, $total, $requested - $total)
            if ($read -le 0) { break }
            $total += $read
        }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $total)
        if ($start -gt 0) {
            $firstNewline = $text.IndexOf("`n", [StringComparison]::Ordinal)
            if ($firstNewline -ge 0) { $text = $text.Substring($firstNewline + 1) }
        }
        if ($text.Length -gt $MaxChars) { $text = $text.Substring($text.Length - $MaxChars) }
        return $text
    }
    catch {
        return "<output-tail-read-error: $($_.Exception.Message)>"
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertFrom-PesterShardCliXmlDiagnostic {
    param([Parameter()][AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $trimmed = $Text.TrimStart()
    $marker = '#< CLIXML'
    if (-not $trimmed.StartsWith($marker, [StringComparison]::Ordinal)) { return $Text }
    $payload = $trimmed.Substring($marker.Length).Trim()
    if ([string]::IsNullOrWhiteSpace($payload)) { return $Text }

    $stringReader = $null
    $xmlReader = $null
    try {
        $document = New-Object Xml.XmlDocument
        $document.PreserveWhitespace = $false
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $maxCharactersInDocument = 1048577
        $quotaVariable = Get-Variable -Name PesterShardChildOutputQuotaCharacters -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $quotaVariable) {
            $configuredQuota = [int64]$quotaVariable.Value
            if ($configuredQuota -gt 0 -and $configuredQuota -lt [int64]::MaxValue) {
                $maxCharactersInDocument = $configuredQuota + 1
            }
        }
        $settings.MaxCharactersInDocument = $maxCharactersInDocument
        $stringReader = New-Object IO.StringReader($payload)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $document.Load($xmlReader)

        $diagnosticLines = New-Object 'System.Collections.Generic.List[string]'
        $diagnosticLineSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $sawStreamNode = $false
        $sawNonProgressStream = $false
        foreach ($streamNode in @($document.DocumentElement.ChildNodes)) {
            if ($null -eq $streamNode.Attributes) { continue }
            $streamAttribute = $streamNode.Attributes.GetNamedItem('S')
            if ($null -eq $streamAttribute) { continue }
            $sawStreamNode = $true
            $streamName = [string]$streamAttribute.Value
            if ([string]::Equals($streamName, 'progress', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $sawNonProgressStream = $true
            $value = ''
            foreach ($childNode in @($streamNode.ChildNodes)) {
                if ([string]$childNode.LocalName -ceq 'ToString') {
                    $value = [string]$childNode.InnerText
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($value) -and [string]$streamNode.LocalName -ceq 'S') {
                $value = [string]$streamNode.InnerText
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                foreach ($messageNode in @($streamNode.SelectNodes('.//*[local-name()="S"]'))) {
                    if ($null -eq $messageNode.Attributes) { continue }
                    $nameAttribute = $messageNode.Attributes.GetNamedItem('N')
                    if ($null -eq $nameAttribute -or [string]$nameAttribute.Value -notmatch '(?i)message|exception|error') { continue }
                    $value = [string]$messageNode.InnerText
                    if (-not [string]::IsNullOrWhiteSpace($value)) { break }
                }
            }
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $value = [System.Xml.XmlConvert]::DecodeName($value)
            foreach ($line in @($value -split "`r?`n")) {
                $line = ([string]$line).TrimEnd()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($diagnosticLineSet.Add($line)) { [void]$diagnosticLines.Add($line) }
            }
        }
        if ($diagnosticLines.Count -gt 0) { return ($diagnosticLines.ToArray() -join [Environment]::NewLine) }
        if ($sawStreamNode -and -not $sawNonProgressStream) { return '' }
        return $Text
    }
    catch {
        # Preserve unparseable or bounded/truncated CLIXML verbatim. Losing a
        # possible error record is worse than returning serialization markup.
        return $Text
    }
    finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }
}

# Scan left-to-right so quota-sized control strings cannot trigger regex
# backtracking. Unterminated strings consume the remainder fail closed.
# Cursor controls that can reinterpret emitted text taint the whole line.
function Remove-PesterShardTerminalControlSequences {
    param([Parameter()][AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $out = New-Object Text.StringBuilder
    [void]$out.EnsureCapacity($Text.Length)
    $taint = [char]0xE000
    $sgrSafe = {
        param($p)
        $a = $p.Split(';')
        for ($i = 0; $i -lt $a.Count; $i++) {
            $n = 0
            if ($a[$i] -and -not [int]::TryParse($a[$i], [ref]$n)) { return $false }
            if ($n -eq 8) { return $false }
            if ($n -in 38, 48, 58) {
                $i++
                if ($i -ge $a.Count) { return $false }
                $c = if ($a[$i] -ceq '5') { 1 } elseif ($a[$i] -ceq '2') { 3 } else { return $false }
                for ($j = 0; $j -lt $c; $j++) {
                    $i++; $v = 0
                    if ($i -ge $a.Count -or -not [int]::TryParse($a[$i], [ref]$v) -or $v -gt 255) { return $false }
                }
            }
        }
        $true
    }
    $index = 0
    while ($index -lt $Text.Length) {
        $code = [int][char]$Text[$index]

        if ($code -eq 0x08 -or $code -eq 0x0B -or $code -eq 0x0C -or $code -eq 0x0E -or $code -eq 0x0F -or
            ($code -eq 0x0D -and (($index + 1) -ge $Text.Length -or [int][char]$Text[$index + 1] -ne 0x0A))) {
            [void]$out.Append($taint)
            $index++
            continue
        }

        if ($code -eq 0x1B) {
            $index++
            if ($index -ge $Text.Length) { continue }
            $next = [int][char]$Text[$index]

            if ($next -eq 0x5D -or $next -eq 0x50 -or $next -eq 0x58 -or $next -eq 0x5E -or $next -eq 0x5F) {
                $index++
                while ($index -lt $Text.Length) {
                    $stringCode = [int][char]$Text[$index]
                    if ($stringCode -eq 0x07 -or $stringCode -eq 0x9C) {
                        $index++
                        break
                    }
                    if ($stringCode -eq 0x1B -and ($index + 1) -lt $Text.Length -and [int][char]$Text[$index + 1] -eq 0x5C) {
                        $index += 2
                        break
                    }
                    $index++
                }
                continue
            }

            if ($next -eq 0x5B) {
                $index++
                $p = $index
                while ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x30 -and [int][char]$Text[$index] -le 0x3F) { $index++ }
                $sgr = $Text.Substring($p, $index - $p)
                $intermediate = $index
                while ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x20 -and [int][char]$Text[$index] -le 0x2F) { $index++ }
                if ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x40 -and [int][char]$Text[$index] -le 0x7E) {
                    $finalCode = [int][char]$Text[$index]
                    $index++
                    $safeSgr = ($finalCode -eq 0x6D -and $index - 1 -eq $intermediate -and (& $sgrSafe $sgr))
                    if (-not $safeSgr) { [void]$out.Append($taint) }
                    continue
                }
                [void]$out.Append($taint)
                if ($index -lt $Text.Length -and ([int][char]$Text[$index] -eq 0x0D -or [int][char]$Text[$index] -eq 0x0A)) {
                    if ([int][char]$Text[$index] -eq 0x0D -and ($index + 1) -lt $Text.Length -and [int][char]$Text[$index + 1] -eq 0x0A) { $index++ }
                    $index++
                }
                continue
            }

            while ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x20 -and [int][char]$Text[$index] -le 0x2F) { $index++ }
            if ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x30 -and [int][char]$Text[$index] -le 0x7E) {
                $index++
                [void]$out.Append($taint)
                continue
            }
            [void]$out.Append($taint)
            if ($index -lt $Text.Length -and ([int][char]$Text[$index] -eq 0x0D -or [int][char]$Text[$index] -eq 0x0A)) {
                if ([int][char]$Text[$index] -eq 0x0D -and ($index + 1) -lt $Text.Length -and [int][char]$Text[$index + 1] -eq 0x0A) { $index++ }
                $index++
            }
            continue
        }

        if ($code -eq 0x90 -or $code -eq 0x98 -or $code -eq 0x9D -or $code -eq 0x9E -or $code -eq 0x9F) {
            $index++
            while ($index -lt $Text.Length) {
                $stringCode = [int][char]$Text[$index]
                if ($stringCode -eq 0x07 -or $stringCode -eq 0x9C) {
                    $index++
                    break
                }
                if ($stringCode -eq 0x1B -and ($index + 1) -lt $Text.Length -and [int][char]$Text[$index + 1] -eq 0x5C) {
                    $index += 2
                    break
                }
                $index++
            }
            continue
        }

        if ($code -eq 0x9B) {
            $index++
            $p = $index
            while ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x30 -and [int][char]$Text[$index] -le 0x3F) { $index++ }
            $sgr = $Text.Substring($p, $index - $p)
            $intermediate = $index
            while ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x20 -and [int][char]$Text[$index] -le 0x2F) { $index++ }
            if ($index -lt $Text.Length -and [int][char]$Text[$index] -ge 0x40 -and [int][char]$Text[$index] -le 0x7E) {
                $finalCode = [int][char]$Text[$index]
                $index++
                $safeSgr = ($finalCode -eq 0x6D -and $index - 1 -eq $intermediate -and (& $sgrSafe $sgr))
                if (-not $safeSgr) { [void]$out.Append($taint) }
                continue
            }
            [void]$out.Append($taint)
            if ($index -lt $Text.Length -and ([int][char]$Text[$index] -eq 0x0D -or [int][char]$Text[$index] -eq 0x0A)) {
                if ([int][char]$Text[$index] -eq 0x0D -and ($index + 1) -lt $Text.Length -and [int][char]$Text[$index + 1] -eq 0x0A) { $index++ }
                $index++
            }
            continue
        }

        if ($code -ge 0x80 -and $code -le 0x9F) {
            [void]$out.Append($taint)
            $index++
            continue
        }

        if (($code -ge 0x00 -and $code -le 0x08) -or $code -eq 0x0B -or $code -eq 0x0C -or ($code -ge 0x0E -and $code -le 0x1F) -or $code -eq 0x7F) {
            $index++
            continue
        }

        [void]$out.Append($Text[$index])
        $index++
    }
    return $out.ToString()
}

function ConvertTo-PesterShardSanitizedDiagnosticText {
    param([Parameter()][AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $normalizedText = Remove-PesterShardTerminalControlSequences -Text $Text
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $redactSensitiveContinuation = $false
    foreach ($rawLine in @($normalizedText -split "`r?`n")) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($redactSensitiveContinuation) {
            $line = if ($line -match '(?i)^\s*\[-\]') {
                '[-] [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)^\s*Expected') {
                'Expected: [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)^\s*But was') {
                'But was: [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)^\s*Exception:') {
                'Exception: [redacted sensitive diagnostic continuation]'
            }
            elseif ($line -match '(?i)\bat\s+.+\.ps1:\d+') {
                'at [redacted sensitive diagnostic continuation]'
            }
            else {
                '[redacted sensitive diagnostic continuation]'
            }
        }
        else {
            if ($line.IndexOf([char]0xE000) -ge 0 -or $line -match '(?i)secret|password|token|authorization|api[-_]?key|bearer') {
                $redactSensitiveContinuation = $true
                $line = '[redacted sensitive diagnostic line]'
            }
        }
        [void]$lines.Add($line)
    }
    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-PesterShardFailureSummary {
    param(
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [int] $MaxLines = 8,
        [int] $MaxLineLength = 512,
        [int] $MaxTotalLength = 4096
    )

    $deferredCliXml = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        $rawText = Read-PesterShardOutputPrefix `
            -Path $path `
            -MaxChars ($script:PesterShardChildOutputQuotaCharacters + 1)
        $text = ConvertFrom-PesterShardCliXmlDiagnostic -Text $rawText
        if (-not [string]::IsNullOrWhiteSpace($rawText) -and
            $text -ceq $rawText -and
            $rawText.TrimStart().StartsWith('#< CLIXML', [StringComparison]::Ordinal)) {
            if (-not $deferredCliXml.Contains($rawText)) { [void]$deferredCliXml.Add($rawText) }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $sanitizedText = ConvertTo-PesterShardSanitizedDiagnosticText -Text $text
        if ([string]::IsNullOrWhiteSpace($sanitizedText)) { continue }
        $tailStart = [Math]::Max(0, $sanitizedText.Length - 65536)
        $tailWindow = $sanitizedText.Substring($tailStart)
        $prefixWindow = $sanitizedText.Substring(0, [Math]::Min(32768, $sanitizedText.Length))
        $diagnosticWindows = New-Object 'System.Collections.Generic.List[string]'
        [void]$diagnosticWindows.Add($tailWindow)
        if ($prefixWindow -cne $tailWindow) { [void]$diagnosticWindows.Add($prefixWindow) }
        foreach ($window in $diagnosticWindows) {
            $lines = @($window -split "`r?`n")
            for ($index = 0; $index -lt $lines.Count; $index++) {
                $candidate = [string]$lines[$index]
                if ($candidate -notmatch '(?i)\[-\]|^\s*(Expected|But was|Exception:)|\bat\s+.+\.ps1:\d+') { continue }
                $selected = New-Object 'System.Collections.Generic.List[string]'
                $start = [Math]::Max(0, $index - 1)
                $end = [Math]::Min($lines.Count - 1, $index + $MaxLines - 2)
                for ($lineIndex = $start; $lineIndex -le $end -and $selected.Count -lt $MaxLines; $lineIndex++) {
                    $line = [string]$lines[$lineIndex]
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($line.Length -gt $MaxLineLength) { $line = $line.Substring(0, $MaxLineLength) }
                    if (-not $selected.Contains($line)) { $selected.Add($line) }
                }
                $summary = ($selected.ToArray() -join ' | ')
                if ($summary.Length -gt $MaxTotalLength) { $summary = $summary.Substring(0, $MaxTotalLength) }
                return $summary
            }
        }
    }

    $allowlistedFallback = New-Object 'System.Collections.Generic.List[string]'
    $sawUnrecognizedDiagnostic = $false
    foreach ($path in $Paths) {
        $rawText = Read-PesterShardOutputTail -Path $path
        $text = $rawText
        $text = ConvertFrom-PesterShardCliXmlDiagnostic -Text $text
        if (-not [string]::IsNullOrWhiteSpace($rawText) -and
            $text -ceq $rawText -and
            $rawText.TrimStart().StartsWith('#< CLIXML', [StringComparison]::Ordinal)) {
            if (-not $deferredCliXml.Contains($rawText)) { [void]$deferredCliXml.Add($rawText) }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $sawUnrecognizedDiagnostic = $true
        $text = Remove-PesterShardTerminalControlSequences -Text $text
        $lines = @($text -split "`r?`n")
        for ($index = $lines.Count - 1; $index -ge 0 -and $allowlistedFallback.Count -lt $MaxLines; $index--) {
            $line = ([string]$lines[$index]).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.IndexOf([char]0xE000) -ge 0 -or $line -match '(?i)secret|password|token|authorization|api[-_]?key|bearer') {
                continue
            }
            $safeLine = if ($line -match '^PowerShell (?:5\.1|7(?:\.\d+)*) shard exited before writing its result file\.$') {
                $line
            }
            elseif ($line -match '^Pester shard child early failure \((initialization|invoke-pester|summary)\):') {
                "Pester shard child early failure ($($Matches[1]))."
            }
            elseif ($line -match '^Pester shard result evidence write failure:') {
                'Pester shard result evidence write failed.'
            }
            elseif ($line -match '^Tests (Passed|Failed|Skipped|Pending|Inconclusive):\s*([0-9]+)\s*$') {
                "Tests $($Matches[1]): $($Matches[2])"
            }
            elseif ($line -match '^Tests completed in\s+([0-9]+(?:\.[0-9]+)?)(ms|s)\s*$') {
                "Tests completed in $($Matches[1])$($Matches[2])"
            }
            elseif ($line -match '^Executing script\b') {
                'Pester progress: executing script.'
            }
            elseif ($line -match '^(Describing|Context)\b') {
                "Pester progress: $($Matches[1].ToLowerInvariant())."
            }
            else {
                $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$safeLine)) { continue }
            if ($safeLine.Length -gt $MaxLineLength) { $safeLine = $safeLine.Substring(0, $MaxLineLength) }
            $allowlistedFallback.Insert(0, $safeLine)
        }
        if ($allowlistedFallback.Count -gt 0) { break }
    }
    if ($allowlistedFallback.Count -gt 0) {
        $summary = ($allowlistedFallback.ToArray() -join ' | ')
        if ($summary.Length -gt $MaxTotalLength) { $summary = $summary.Substring(0, $MaxTotalLength) }
        return $summary
    }
    if ($deferredCliXml.Count -gt 0) {
        return 'PowerShell CLIXML diagnostic could not be safely decoded.'
    }
    if ($sawUnrecognizedDiagnostic) {
        return 'No allowlisted Pester diagnostic was found in the bounded output tail.'
    }
    return ''
}

function Stop-PesterShardOwnedProcessTree {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [System.Diagnostics.Process] $RootProcess,
        [IntPtr] $JobHandle = [IntPtr]::Zero,
        [int[]] $ObservedDescendantProcessIds = @(),
        [hashtable] $ObservedProcessIdentities = @{},
        [int] $CleanupTimeoutSeconds = 15
    )

    if ($CleanupTimeoutSeconds -le 0) { throw 'CleanupTimeoutSeconds must be positive.' }
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $knownIds = New-Object 'System.Collections.Generic.List[int]'
    $processKillResults = New-Object 'System.Collections.Generic.List[object]'
    $lastKillErrors = New-Object 'System.Collections.Generic.Dictionary[int,string]'
    $jobObjectAvailable = ($JobHandle -ne [IntPtr]::Zero)
    $jobObjectTerminationAttempted = $false
    $jobObjectTerminationSucceeded = $false
    $rootTerminationAttempted = $false
    foreach ($processId in @($RootProcessId) + @($ObservedDescendantProcessIds)) {
        if ($processId -gt 0 -and -not $knownIds.Contains([int]$processId)) {
            $knownIds.Add([int]$processId)
        }
    }

    $initialDescendants = @()
    try {
        $initialDescendants = @(Get-PesterShardDescendantProcessIds -RootProcessId $RootProcessId)
        foreach ($processId in $initialDescendants) {
            if ($processId -gt 0 -and -not $knownIds.Contains([int]$processId)) {
                $knownIds.Add([int]$processId)
            }
            Add-PesterShardProcessIdentity -ProcessId ([int]$processId) -IdentityMap $ObservedProcessIdentities
        }
    }
    catch {
        $warnings.Add("initial descendant enumeration failed: $($_.Exception.Message)")
    }

    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds($CleanupTimeoutSeconds)
    $cleanupTimedOut = $false
    while ([DateTime]::UtcNow -lt $cleanupDeadline) {
        $currentDescendants = @()
        try {
            $currentDescendants = @(Get-PesterShardDescendantProcessIds -RootProcessId $RootProcessId)
            foreach ($processId in $currentDescendants) {
                if ($processId -gt 0 -and -not $knownIds.Contains([int]$processId)) {
                    $knownIds.Add([int]$processId)
                }
                Add-PesterShardProcessIdentity -ProcessId ([int]$processId) -IdentityMap $ObservedProcessIdentities
            }
        }
        catch {
            $warnings.Add("descendant enumeration after cleanup failed: $($_.Exception.Message)")
        }

        $rootAlive = $false
        if ($null -ne $RootProcess) { try { $rootAlive = -not $RootProcess.HasExited } catch { $rootAlive = $true } }
        $liveCurrentDescendants = @($currentDescendants | Where-Object {
            Test-PesterShardProcessAlive -ProcessId ([int]$_)
        })
        $liveKnownIds = if ($jobObjectAvailable) {
            @($liveCurrentDescendants)
        }
        else {
            @($knownIds.ToArray() | Where-Object {
                Test-PesterShardProcessAlive -ProcessId ([int]$_)
            })
        }
        $noLiveOwnedProcessObserved = (-not $rootAlive -and $liveKnownIds.Count -eq 0 -and $liveCurrentDescendants.Count -eq 0)
        if ($noLiveOwnedProcessObserved -and (-not $jobObjectAvailable -or $jobObjectTerminationAttempted)) { break }

        if ($jobObjectAvailable) {
            # The Job Object is the authoritative containment boundary. Parent
            # enumeration is retained for diagnostics only and is never used
            # to discover the complete owned process set.
            if (-not $jobObjectTerminationAttempted -and ($rootAlive -or $liveCurrentDescendants.Count -gt 0 -or $noLiveOwnedProcessObserved)) {
                # Terminate the Job Object before draining inherited output pipes.
                # A short-lived intermediary can hide a live grandchild from the
                # parent tree even though the kernel-owned Job Object still owns it.
                $jobObjectTerminationAttempted = $true
                try {
                    $jobObjectTerminationSucceeded = [PesterShardProcessControlNative]::TryTerminateJobObject($JobHandle, 1)
                    $processKillResults.Add([pscustomobject][ordered]@{
                            processId = $RootProcessId
                            method = 'PesterShardProcessControlNative.TryTerminateJobObject'
                            identityValidated = $true
                            error = if ($jobObjectTerminationSucceeded) { $null } else { 'TerminateJobObject returned false.' }
                            stillAlive = $false
                        })
                    if (-not $jobObjectTerminationSucceeded) {
                        $errors.Add('The owned Windows Job Object could not terminate the shard process group.')
                    }
                }
                catch {
                    $processKillResults.Add([pscustomobject][ordered]@{
                            processId = $RootProcessId
                            method = 'PesterShardProcessControlNative.TryTerminateJobObject'
                            identityValidated = $true
                            error = $_.Exception.ToString()
                            stillAlive = $true
                        })
                    $errors.Add("owned Windows Job Object termination failed: $($_.Exception.Message)")
                }
            }
            if ($rootAlive -and -not $rootTerminationAttempted) {
                $rootTerminationAttempted = $true
                if ($null -eq $RootProcess) {
                    $errors.Add('The owned shard root process handle was unavailable; PID-only root termination was refused.')
                }
                else {
                    try {
                        if (-not $RootProcess.HasExited) {
                            $RootProcess.Kill()
                            [void]$RootProcess.WaitForExit(500)
                        }
                        $processKillResults.Add([pscustomobject][ordered]@{
                                processId = $RootProcessId
                                method = 'System.Diagnostics.Process.Kill(root-handle)'
                                identityValidated = $true
                                error = $null
                                stillAlive = (-not $RootProcess.HasExited)
                            })
                    }
                    catch {
                        $errors.Add("direct root process termination failed: $($_.Exception.Message)")
                    }
                }
            }
        }
        else {
            # PID-only cleanup is a fallback for non-Job-Object hosts. Every
            # retained PID must match the immutable start-time/name identity
            # captured while it was owned; otherwise it is never terminated.
            $killOrder = New-Object 'System.Collections.Generic.List[int]'
            $killOrderSeen = New-Object 'System.Collections.Generic.HashSet[int]'
            for ($index = $currentDescendants.Count - 1; $index -ge 0; $index--) {
                $processId = [int]$currentDescendants[$index]
                if ($processId -gt 0 -and $killOrderSeen.Add($processId)) { $killOrder.Add($processId) }
            }
            $knownSnapshot = @($knownIds.ToArray())
            for ($index = $knownSnapshot.Count - 1; $index -ge 0; $index--) {
                $processId = [int]$knownSnapshot[$index]
                if ($processId -ne $RootProcessId -and $processId -gt 0 -and $killOrderSeen.Add($processId)) {
                    $killOrder.Add($processId)
                }
            }
            foreach ($processId in @($killOrder.ToArray())) {
                if (-not (Test-PesterShardProcessAlive -ProcessId ([int]$processId))) { continue }
                $method = 'none'
                $errorText = $null
                $identityValidated = $false
                $target = $null
                try {
                    $expected = $ObservedProcessIdentities[[int]$processId]
                    if ($null -eq $expected -or -not [bool]$expected.identityAvailable) {
                        $method = 'identity-unavailable-refused'
                        $errorText = 'No immutable process identity was captured for this retained PID.'
                    }
                    else {
                        # Keep the Process handle obtained for the identity
                        # check and terminate that same handle; do not look up
                        # the PID again after validation.
                        $target = [System.Diagnostics.Process]::GetProcessById([int]$processId)
                        $actualStartTime = $target.StartTime.ToUniversalTime().ToString('o')
                        $actualName = [string]$target.ProcessName
                        if ($actualStartTime -cne [string]$expected.startTimeUtc -or
                            $actualName -cne [string]$expected.processName) {
                            $method = 'identity-mismatch-refused'
                            $errorText = 'Current process identity did not match the retained start-time/name identity.'
                        }
                        elseif (-not $target.HasExited) {
                            $identityValidated = $true
                            $target.Kill()
                            $method = 'System.Diagnostics.Process.Kill(identity-validated)'
                            [void]$target.WaitForExit(500)
                        }
                        else {
                            $method = 'already-exited'
                        }
                    }
                }
                catch [ArgumentException] { $method = 'already-exited' }
                catch { $errorText = $_.Exception.ToString() }
                finally {
                    if ($null -ne $target) { $target.Dispose() }
                }
                $stillAlive = Test-PesterShardProcessAlive -ProcessId ([int]$processId)
                $processKillResults.Add([pscustomobject][ordered]@{
                        processId = [int]$processId
                        method = $method
                        identityValidated = $identityValidated
                        error = $errorText
                        stillAlive = $stillAlive
                    })
                if ($stillAlive) {
                    $lastKillErrors[[int]$processId] = if ($null -eq $errorText) { 'process remained alive after identity-validated termination.' } else { $errorText }
                }
                elseif ($lastKillErrors.ContainsKey([int]$processId)) {
                    [void]$lastKillErrors.Remove([int]$processId)
                }
            }
            if ($rootAlive -and -not $rootTerminationAttempted) {
                $rootTerminationAttempted = $true
                if ($null -eq $RootProcess) {
                    $errors.Add('The owned shard root process handle was unavailable; PID-only root termination was refused.')
                }
                else {
                    try {
                        if (-not $RootProcess.HasExited) {
                            $RootProcess.Kill()
                            [void]$RootProcess.WaitForExit(500)
                        }
                        $processKillResults.Add([pscustomobject][ordered]@{
                                processId = $RootProcessId
                                method = 'System.Diagnostics.Process.Kill(root-handle)'
                                identityValidated = $true
                                error = $null
                                stillAlive = (-not $RootProcess.HasExited)
                            })
                    }
                    catch { $errors.Add("direct root process termination failed: $($_.Exception.Message)") }
                }
            }
        }

        Start-Sleep -Milliseconds 100
    }

    $rootAlive = $false
    if ($null -ne $RootProcess) { try { $rootAlive = -not $RootProcess.HasExited } catch { $rootAlive = $true } }
    $finalDescendants = @()
    $finalEnumerationFailed = $false
    try {
        $finalDescendants = @(Get-PesterShardDescendantProcessIds -RootProcessId $RootProcessId |
            Where-Object { Test-PesterShardProcessAlive -ProcessId ([int]$_) })
        foreach ($processId in $finalDescendants) {
            Add-PesterShardProcessIdentity -ProcessId ([int]$processId) -IdentityMap $ObservedProcessIdentities
        }
    }
    catch {
        $finalEnumerationFailed = $true
        $warnings.Add("final descendant enumeration failed: $($_.Exception.Message)")
    }
    $remainingIds = if ($jobObjectAvailable) {
        @(
            @($finalDescendants | Where-Object { Test-PesterShardProcessAlive -ProcessId ([int]$_) })
            if ($rootAlive) { $RootProcessId }
        ) | Sort-Object -Unique
    }
    else {
        @($knownIds.ToArray() | Where-Object {
            Test-PesterShardProcessAlive -ProcessId ([int]$_)
        })
    }
    if (($remainingIds.Count -gt 0 -or $finalDescendants.Count -gt 0) -and [DateTime]::UtcNow -ge $cleanupDeadline) {
        $cleanupTimedOut = $true
        $errors.Add("owned process cleanup deadline exceeded after $CleanupTimeoutSeconds seconds.")
    }
    foreach ($entry in @($lastKillErrors.GetEnumerator())) {
        if ($remainingIds -contains [int]$entry.Key) {
            $errors.Add("direct process termination failed for owned process $($entry.Key): $($entry.Value)")
        }
    }
    if (-not $jobObjectAvailable -and $finalEnumerationFailed) {
        $errors.Add('PID-only cleanup could not verify the final owned process set.')
    }
    if ($jobObjectAvailable -and $jobObjectTerminationAttempted -and -not $jobObjectTerminationSucceeded) {
        $errors.Add('The authoritative Job Object termination did not succeed.')
    }
    $cleanedUp = ($errors.Count -eq 0 -and $remainingIds.Count -eq 0 -and
        (($jobObjectAvailable -and ($jobObjectTerminationSucceeded -or (-not $jobObjectTerminationAttempted))) -or
         (-not $jobObjectAvailable -and $finalDescendants.Count -eq 0 -and -not $finalEnumerationFailed)))
    return [pscustomobject][ordered]@{
        rootProcessId = $RootProcessId
        initialDescendantProcessIds = @($initialDescendants)
        observedProcessIds = @($knownIds.ToArray())
        observedProcessIdentities = @($ObservedProcessIdentities.Values | Sort-Object processId)
        remainingProcessIds = @($remainingIds)
        finalDescendantProcessIds = @($finalDescendants)
        cleanupTimeoutSeconds = $CleanupTimeoutSeconds
        cleanupTimedOut = $cleanupTimedOut
        jobObject = [ordered]@{
            available = $jobObjectAvailable
            terminationAttempted = $jobObjectTerminationAttempted
            terminationSucceeded = $jobObjectTerminationSucceeded
            authoritative = $jobObjectAvailable
        }
        processKillResults = @($processKillResults.ToArray())
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
        cleanedUp = $cleanedUp
    }
}

function Get-PesterShardLiveCaptureState {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter()] $Task
    )

    if ($null -eq $Task -or -not [bool]$Task.IsCompleted) {
        return [pscustomobject][ordered]@{
            isCompleted = $false
            faulted = $false
            exceeded = $false
            error = $null
        }
    }
    try {
        $captureResult = $Task.GetAwaiter().GetResult()
        return [pscustomobject][ordered]@{
            isCompleted = $true
            faulted = $false
            exceeded = [bool]$captureResult.Exceeded
            error = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            isCompleted = $true
            faulted = $true
            exceeded = $false
            error = "$Name bounded output capture failed: $($_.Exception.Message)"
        }
    }
}

function Resolve-PesterShardOutputFailure {
    param(
        [Parameter(Mandatory = $true)] $Cleanup,
        [string[]] $Errors,
        [Parameter(Mandatory = $true)][string] $Status,
        [AllowNull()][string] $ExceptionText
    )

    $outputErrors = @($Errors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($outputErrors.Count -eq 0) {
        return [pscustomobject][ordered]@{
            cleanup = $Cleanup
            status = $Status
            exceptionText = $ExceptionText
        }
    }

    $existingCleanupErrors = if ($Cleanup.PSObject.Properties.Name -contains 'errors') { @($Cleanup.errors) } else { @() }
    $resolvedCleanupErrors = $existingCleanupErrors + $outputErrors
    if ($Cleanup.PSObject.Properties.Name -contains 'errors') {
        $Cleanup.errors = $resolvedCleanupErrors
    }
    else {
        $Cleanup | Add-Member -MemberType NoteProperty -Name errors -Value $resolvedCleanupErrors
    }
    $Cleanup.cleanedUp = $false
    $captureMessage = $outputErrors -join ' | '
    $resolvedException = if ([string]::IsNullOrWhiteSpace($ExceptionText)) {
        $captureMessage
    }
    else {
        "$ExceptionText | $captureMessage"
    }
    return [pscustomobject][ordered]@{
        cleanup = $Cleanup
        status = 'cleanup-failed'
        exceptionText = $resolvedException
    }
}

function New-PesterShardNotStartedCleanup {
    return [pscustomobject][ordered]@{
        rootProcessId = $null
        initialDescendantProcessIds = @()
        observedProcessIds = @()
        observedProcessIdentities = @()
        remainingProcessIds = @()
        finalDescendantProcessIds = @()
        cleanupTimeoutSeconds = 15
        cleanupTimedOut = $false
        jobObject = [ordered]@{
            available = $false
            terminationAttempted = $false
            terminationSucceeded = $false
            authoritative = $false
        }
        processKillResults = @()
        warnings = @()
        errors = @()
        cleanedUp = $true
        reason = 'process-not-started'
    }
}

function Get-PesterShardCleanupTarget {
    param(
        [Parameter()][AllowNull()] $Process,
        [Parameter(Mandatory = $true)][bool] $ProcessStarted,
        [Parameter()][AllowNull()] $RootProcessId
    )

    if (-not $ProcessStarted -or $null -eq $Process -or $null -eq $RootProcessId) { return $null }
    return [pscustomobject][ordered]@{
        rootProcessId = [int]$RootProcessId
        process = $Process
    }
}

function Invoke-PesterShardProcess {
    param(
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [Parameter(Mandatory = $true)][string] $ModulePath,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $ChildPowerShell,
        [Parameter(Mandatory = $true)][string] $EncodedChildScript,
        [Parameter(Mandatory = $true)][string] $ResultPath,
        [Parameter(Mandatory = $true)][string] $ProcessEvidencePath,
        [Parameter(Mandatory = $true)][string] $StdoutPath,
        [Parameter(Mandatory = $true)][string] $StderrPath,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $CancelPath,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory
    )

    $process = $null
    $processDisposed = $false
    $processStarted = $false
    $rootProcessId = $null
    $status = 'not-started'
    $exitCode = $null
    $startedAt = $null
    $finishedAt = $null
    $exceptionText = $null
    $observedDescendantProcessIds = New-Object 'System.Collections.Generic.List[int]'
    $observedProcessIdentities = @{}
    $observationErrors = New-Object 'System.Collections.Generic.List[string]'
    $captureErrors = New-Object 'System.Collections.Generic.List[string]'
    $cleanup = New-PesterShardNotStartedCleanup
    $evidenceWriteError = $null
    $outputWriteError = $null
    $outputCaptureTimedOut = $false
    $outputQuotaExceeded = $false
    $outputQuotaStreams = New-Object 'System.Collections.Generic.List[string]'
    $stdout = ''
    $stderr = ''
    $stdoutTask = $null
    $stderrTask = $null
    $jobHandle = [IntPtr]::Zero
    $jobClosed = $true
    $jobObjectCreated = $false
    $jobObjectAssigned = $false
    $windowsBootstrapReleasePath = $null
    $preflight = $null
    $deadline = $null

    try {
        if (Test-Path -LiteralPath $CancelPath -PathType Leaf) {
            $status = 'cancelled'
            $exceptionText = "Cancellation marker already exists: $CancelPath"
        }
        else {
            $startedAt = [DateTime]::UtcNow.ToString('o')
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            $launchCommand = $ChildPowerShell
            $launchArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $EncodedChildScript)
            $launchEnvironment = Get-PesterShardChildEnvironment
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                $windowsBootstrapReleasePath = Join-Path $WorkingDirectory ("pester-shard-bootstrap-{0}.signal" -f ([guid]::NewGuid().ToString('N')))
                if (Test-Path -LiteralPath $windowsBootstrapReleasePath) {
                    throw 'The owned Pester shard bootstrap signal path already exists.'
                }
                $launchEnvironment.SYP154_PESTER_BOOTSTRAP_COMMAND = $ChildPowerShell
                $launchEnvironment.SYP154_PESTER_BOOTSTRAP_ARGUMENTS = ConvertTo-Json -InputObject ([string[]]$launchArguments) -Compress
                $launchEnvironment.SYP154_PESTER_BOOTSTRAP_RELEASE_PATH = $windowsBootstrapReleasePath
            }
            $preflight = Get-PesterShardPreflight `
                -PesterModulePath $ModulePath `
                -PesterVersion $Version `
                -ChildPowerShell $ChildPowerShell `
                -WorkingDirectory $WorkingDirectory `
                -ResultPath $ResultPath `
                -ProcessEvidencePath $ProcessEvidencePath `
                -StdoutPath $StdoutPath `
                -StderrPath $StderrPath `
                -CancelPath $CancelPath `
                -BootstrapSignalPath $windowsBootstrapReleasePath
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                $jobHandle = [PesterShardProcessControlNative]::CreateKillOnCloseJob()
                $jobClosed = $false
                $jobObjectCreated = $true
                $bootstrapCode = Get-PesterShardProcessBootstrapCode
                $encodedBootstrapCode = [Convert]::ToBase64String(([Text.Encoding]::Unicode).GetBytes($bootstrapCode))
                $launchArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedBootstrapCode)
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                $status = 'timeout'
                $exceptionText = "Outer shard deadline exceeded before process start after $TimeoutSeconds seconds."
                throw $exceptionText
            }

            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $launchCommand
            $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $launchArguments[$launchArguments.Count - 1]
            $startInfo.WorkingDirectory = $WorkingDirectory
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.EnvironmentVariables.Clear()
            foreach ($entry in $launchEnvironment.GetEnumerator()) {
                $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
            }
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw 'Process.Start returned false.' }
            $processStarted = $true
            $rootProcessId = [int]$process.Id
            Add-PesterShardProcessIdentity -ProcessId $rootProcessId -IdentityMap $observedProcessIdentities

            if ($jobObjectCreated) {
                if (-not [PesterShardProcessControlNative]::TryAssignProcessToJobObject($jobHandle, $process.Handle)) {
                    throw 'AssignProcessToJobObject returned false.'
                }
                $jobObjectAssigned = $true
                # The bootstrap is held in the Job Object before this release.
                # Every candidate descendant is therefore kernel-contained even
                # if it is created and reparented between observations.
                if (Test-Path -LiteralPath $CancelPath -PathType Leaf) {
                    $status = 'cancelled'
                    $exceptionText = "Cancellation marker observed before bootstrap release: $CancelPath"
                    throw $exceptionText
                }
                $releaseBytes = (New-Object Text.UTF8Encoding($false)).GetBytes('release' + [Environment]::NewLine)
                $releaseStream = [IO.File]::Open(
                    $windowsBootstrapReleasePath,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
                try {
                    $releaseStream.Write($releaseBytes, 0, $releaseBytes.Length)
                    $releaseStream.Flush()
                }
                finally { $releaseStream.Dispose() }
            }

            $stdoutTask = [PesterShardBoundedCapture]::Start(
                $process.StandardOutput,
                $script:PesterShardChildOutputQuotaCharacters
            )
            $stderrTask = [PesterShardBoundedCapture]::Start(
                $process.StandardError,
                $script:PesterShardChildOutputQuotaCharacters
            )
            $status = 'running'
            try {
                foreach ($processId in @(Get-PesterShardDescendantProcessIds -RootProcessId $rootProcessId)) {
                    if ($processId -gt 0 -and -not $observedDescendantProcessIds.Contains([int]$processId)) {
                        $observedDescendantProcessIds.Add([int]$processId)
                    }
                    Add-PesterShardProcessIdentity -ProcessId ([int]$processId) -IdentityMap $observedProcessIdentities
                }
            }
            catch {
                if ($observationErrors.Count -lt 32) { $observationErrors.Add("initial live descendant observation failed: $($_.Exception.Message)") }
            }
            $captureFaultDetected = $false
            while (-not $process.HasExited) {
                try {
                    foreach ($processId in @(Get-PesterShardDescendantProcessIds -RootProcessId $rootProcessId)) {
                        if ($processId -gt 0 -and -not $observedDescendantProcessIds.Contains([int]$processId)) {
                            $observedDescendantProcessIds.Add([int]$processId)
                        }
                        Add-PesterShardProcessIdentity -ProcessId ([int]$processId) -IdentityMap $observedProcessIdentities
                    }
                }
                catch {
                    if ($observationErrors.Count -lt 32) { $observationErrors.Add("live descendant observation failed: $($_.Exception.Message)") }
                }
                $quotaStream = $null
                foreach ($captureSpec in @(
                    [pscustomobject]@{ Name = 'stdout'; Task = $stdoutTask },
                    [pscustomobject]@{ Name = 'stderr'; Task = $stderrTask }
                )) {
                    $captureState = Get-PesterShardLiveCaptureState -Name ([string]$captureSpec.Name) -Task $captureSpec.Task
                    if ([bool]$captureState.faulted) {
                        $captureError = [string]$captureState.error
                        if (-not $captureErrors.Contains($captureError)) { $captureErrors.Add($captureError) }
                        $status = 'failed'
                        $exceptionText = $captureError
                        $captureFaultDetected = $true
                        break
                    }
                    if ([bool]$captureState.exceeded) { $quotaStream = [string]$captureSpec.Name }
                    if ($null -ne $quotaStream) { break }
                }
                if ($captureFaultDetected) { break }
                if ($null -ne $quotaStream) {
                    $status = 'failed'
                    $outputQuotaExceeded = $true
                    if (-not $outputQuotaStreams.Contains([string]$quotaStream)) { $outputQuotaStreams.Add([string]$quotaStream) }
                    $exceptionText = "Owned Pester shard output capture quota exceeded for $quotaStream (limit=$($script:PesterShardChildOutputQuotaCharacters) characters per stream)."
                    break
                }
                if (Test-Path -LiteralPath $CancelPath -PathType Leaf) {
                    $status = 'cancelled'
                    $exceptionText = "Cancellation marker observed: $CancelPath"
                    break
                }
                if ([DateTime]::UtcNow -ge $deadline) {
                    $status = 'timeout'
                    $exceptionText = "Outer shard deadline exceeded after $TimeoutSeconds seconds."
                    break
                }
                [void]$process.WaitForExit(100)
            }
            if ($process.HasExited -and $status -notin @('cancelled', 'timeout', 'failed')) {
                [void]$process.WaitForExit()
                $exitCode = [int]$process.ExitCode
                $status = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
            }
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($exceptionText)) { $exceptionText = $_.Exception.ToString() }
        if (-not $processStarted) {
            if ($status -notin @('cancelled', 'timeout')) { $status = 'startup-failed' }
        }
        elseif ($status -notin @('cancelled', 'timeout', 'failed')) { $status = 'failed' }
    }
    finally {
        $cleanupTarget = Get-PesterShardCleanupTarget `
            -Process $process `
            -ProcessStarted $processStarted `
            -RootProcessId $rootProcessId
        if ($null -ne $cleanupTarget) {
            try {
                $cleanup = Stop-PesterShardOwnedProcessTree `
                    -RootProcessId ([int]$cleanupTarget.rootProcessId) `
                    -RootProcess $cleanupTarget.process `
                    -JobHandle $jobHandle `
                    -ObservedDescendantProcessIds @($observedDescendantProcessIds.ToArray()) `
                    -ObservedProcessIdentities $observedProcessIdentities
                if ($observationErrors.Count -gt 0) {
                    $cleanup.warnings = @($cleanup.warnings) + @($observationErrors.ToArray())
                    if (-not [bool]$cleanup.jobObject.authoritative) { $cleanup.cleanedUp = $false }
                }
            }
            catch {
                $cleanup = [pscustomobject][ordered]@{
                    rootProcessId = [int]$cleanupTarget.rootProcessId
                    initialDescendantProcessIds = @()
                    observedProcessIds = @([int]$cleanupTarget.rootProcessId)
                    observedProcessIdentities = @($observedProcessIdentities.Values | Sort-Object processId)
                    remainingProcessIds = @()
                    finalDescendantProcessIds = @()
                    cleanupTimeoutSeconds = 15
                    cleanupTimedOut = $true
                    jobObject = [ordered]@{
                        available = ($jobHandle -ne [IntPtr]::Zero)
                        terminationAttempted = $false
                        terminationSucceeded = $false
                        authoritative = ($jobHandle -ne [IntPtr]::Zero)
                    }
                    processKillResults = @()
                    warnings = @($observationErrors.ToArray())
                    errors = @("cleanup executor exception: $($_.Exception.ToString())")
                    cleanedUp = $false
                }
            }
            if ($outputCaptureTimedOut) {
                $cleanup.errors = @($cleanup.errors) + @('bounded shard output capture did not finish within its drain deadline.')
                $cleanup.cleanedUp = $false
            }
            if (-not $cleanup.cleanedUp) { $status = 'cleanup-failed' }
            if ($cleanupTarget.process.HasExited -and $null -eq $exitCode -and
                $status -notin @('cancelled', 'timeout', 'cleanup-failed')) {
                $exitCode = [int]$cleanupTarget.process.ExitCode
            }
        }
        $captureDeadline = [DateTime]::UtcNow.AddSeconds(5)
        foreach ($captureSpec in @(
            [pscustomobject]@{ Name = 'stdout'; Task = $stdoutTask },
            [pscustomobject]@{ Name = 'stderr'; Task = $stderrTask }
        )) {
            if ($null -eq $captureSpec.Task) { continue }
            try {
                $remainingMilliseconds = [Math]::Max(0, [int](([DateTime]::UtcNow - $captureDeadline).TotalMilliseconds * -1))
                if (-not $captureSpec.Task.Wait($remainingMilliseconds)) {
                    $outputCaptureTimedOut = $true
                    $captureErrors.Add("$($captureSpec.Name) bounded output capture did not finish before the drain deadline.")
                    continue
                }
                $captureResult = $captureSpec.Task.GetAwaiter().GetResult()
                if ($captureSpec.Name -ceq 'stdout') { $stdout = [string]$captureResult.Text }
                else { $stderr = [string]$captureResult.Text }
                if ([bool]$captureResult.Exceeded) {
                    $outputQuotaExceeded = $true
                    if (-not $outputQuotaStreams.Contains([string]$captureSpec.Name)) { $outputQuotaStreams.Add([string]$captureSpec.Name) }
                }
            }
            catch {
                $captureError = "$($captureSpec.Name) bounded output capture failed: $($_.Exception.Message)"
                if (-not $captureErrors.Contains($captureError)) { $captureErrors.Add($captureError) }
            }
        }
        $captureFailure = Resolve-PesterShardOutputFailure `
            -Cleanup $cleanup `
            -Errors @($captureErrors.ToArray()) `
            -Status $status `
            -ExceptionText $exceptionText
        $cleanup = $captureFailure.cleanup
        $status = [string]$captureFailure.status
        $exceptionText = [string]$captureFailure.exceptionText
        if ($outputQuotaExceeded -and $status -notin @('cancelled', 'timeout', 'cleanup-failed')) {
            $status = 'failed'
            if ([string]::IsNullOrWhiteSpace($exceptionText)) {
                $exceptionText = "Owned Pester shard output capture quota exceeded for $($outputQuotaStreams -join ' and ') (limit=$($script:PesterShardChildOutputQuotaCharacters) characters per stream)."
            }
        }
        try { Write-PesterShardBoundedOutput -Path $StdoutPath -Text $stdout }
        catch { $outputWriteError = "stdout evidence write failed: $($_.Exception.ToString())" }
        try { Write-PesterShardBoundedOutput -Path $StderrPath -Text $stderr }
        catch {
            $outputWriteError = if ($null -eq $outputWriteError) { "stderr evidence write failed: $($_.Exception.ToString())" } else { "$outputWriteError | stderr evidence write failed: $($_.Exception.ToString())" }
        }
        $outputWriteFailure = Resolve-PesterShardOutputFailure `
            -Cleanup $cleanup `
            -Errors @($outputWriteError) `
            -Status $status `
            -ExceptionText $exceptionText
        $cleanup = $outputWriteFailure.cleanup
        $status = [string]$outputWriteFailure.status
        $exceptionText = [string]$outputWriteFailure.exceptionText
        if ($null -ne $process -and -not $processDisposed) {
            try {
                if ($process.HasExited -and $null -eq $exitCode -and
                    $status -notin @('cancelled', 'timeout', 'cleanup-failed')) {
                    $exitCode = [int]$process.ExitCode
                }
            }
            catch { }
            try { $process.Dispose() } catch { }
            $processDisposed = $true
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            try {
                if (-not $jobClosed -and -not $cleanup.cleanedUp) {
                    try { [void][PesterShardProcessControlNative]::TryTerminateJobObject($jobHandle, 1) } catch { }
                }
                $jobClosed = [bool][PesterShardProcessControlNative]::TryCloseHandle($jobHandle)
                if (-not $jobClosed) {
                    $jobCloseFailure = Resolve-PesterShardOutputFailure `
                        -Cleanup $cleanup `
                        -Errors @('The owned Windows Job Object handle could not be closed safely.') `
                        -Status $status `
                        -ExceptionText $exceptionText
                    $cleanup = $jobCloseFailure.cleanup
                    $status = [string]$jobCloseFailure.status
                    $exceptionText = [string]$jobCloseFailure.exceptionText
                }
            }
            catch {
                $jobClosed = $false
                $jobCloseFailure = Resolve-PesterShardOutputFailure `
                    -Cleanup $cleanup `
                    -Errors @("The owned Windows Job Object handle could not be closed safely: $($_.Exception.Message)") `
                    -Status $status `
                    -ExceptionText $exceptionText
                $cleanup = $jobCloseFailure.cleanup
                $status = [string]$jobCloseFailure.status
                $exceptionText = [string]$jobCloseFailure.exceptionText
            }
            $jobHandle = [IntPtr]::Zero
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$windowsBootstrapReleasePath) -and
            [IO.File]::Exists($windowsBootstrapReleasePath)) {
            try { [IO.File]::Delete($windowsBootstrapReleasePath) }
            catch {
                $bootstrapCleanupFailure = Resolve-PesterShardOutputFailure `
                    -Cleanup $cleanup `
                    -Errors @("The owned Pester shard bootstrap signal could not be removed: $($_.Exception.Message)") `
                    -Status $status `
                    -ExceptionText $exceptionText
                $cleanup = $bootstrapCleanupFailure.cleanup
                $status = [string]$bootstrapCleanupFailure.status
                $exceptionText = [string]$bootstrapCleanupFailure.exceptionText
            }
        }
        $finishedAt = [DateTime]::UtcNow.ToString('o')
        $resultExists = Test-Path -LiteralPath $ResultPath -PathType Leaf
        $diagnostic = [ordered]@{
            schemaVersion = 1
            kind = 'syp154-pester-shard-process'
            status = $status
            pesterVersion = $Version
            powershellVersion = [string]$PSVersionTable.PSVersion
            powershellEdition = [string]$PSVersionTable.PSEdition
            workingDirectory = $WorkingDirectory
            paths = @($Paths)
            modulePath = $ModulePath
            childPowerShell = $ChildPowerShell
            timeoutSeconds = $TimeoutSeconds
            preflight = $preflight
            outputQuotaCharacters = $script:PesterShardChildOutputQuotaCharacters
            outputQuotaExceeded = [bool]$outputQuotaExceeded
            outputQuotaStreams = @($outputQuotaStreams.ToArray())
            outputCaptureTimedOut = [bool]$outputCaptureTimedOut
            cancellationPath = $CancelPath
            cancellationPathOwnership = if ($ownsCancellationPath) { 'runner-owned' } else { 'caller-owned' }
            environmentNames = @(
                'SYP154_PESTER_SHARD_PATHS',
                'SYP154_PESTER_MODULE_PATH',
                'SYP154_PESTER_RESULT_PATH'
            )
            supervisorOnlyEnvironmentNames = @(
                'SYP154_PESTER_BOOTSTRAP_COMMAND',
                'SYP154_PESTER_BOOTSTRAP_ARGUMENTS',
                'SYP154_PESTER_BOOTSTRAP_RELEASE_PATH'
            )
            startedAt = $startedAt
            finishedAt = $finishedAt
            processId = if ($null -eq $rootProcessId) { $null } else { [int]$rootProcessId }
            exitCode = $exitCode
            resultPath = $ResultPath
            resultExists = $resultExists
            stdoutPath = $StdoutPath
            stderrPath = $StderrPath
            pathLengths = [ordered]@{
                result = $ResultPath.Length
                stdout = $StdoutPath.Length
                stderr = $StderrPath.Length
                cancellation = $CancelPath.Length
            }
            jobObject = [ordered]@{
                created = [bool]$jobObjectCreated
                assignedBeforeBootstrapRelease = [bool]($jobObjectCreated -and $jobObjectAssigned)
                closed = [bool]$jobClosed
                bootstrapReleasePath = $windowsBootstrapReleasePath
            }
            cleanup = $cleanup
            exception = $exceptionText
            outputWriteError = $outputWriteError
            observedProcessIdentities = @($observedProcessIdentities.Values | Sort-Object processId)
            failureSummary = Get-PesterShardFailureSummary -Paths @($StderrPath, $StdoutPath)
            stdoutPrefix = Read-PesterShardOutputPrefix -Path $StdoutPath
            stderrPrefix = Read-PesterShardOutputPrefix -Path $StderrPath
            stdoutTail = Read-PesterShardOutputTail -Path $StdoutPath
            stderrTail = Read-PesterShardOutputTail -Path $StderrPath
        }
        try {
            [IO.File]::WriteAllText(
                $ProcessEvidencePath,
                ($diagnostic | ConvertTo-Json -Depth 12),
                (New-Object Text.UTF8Encoding($false))
            )
        }
        catch {
            $evidenceWriteError = $_.Exception.ToString()
        }
    }

    if ($null -ne $evidenceWriteError) {
        throw "Could not save Pester shard process evidence '$ProcessEvidencePath': $evidenceWriteError"
    }
    if ($status -notin @('completed', 'failed') -or -not $resultExists -or -not $cleanup.cleanedUp) {
        Write-Host ("Pester shard process evidence summary: status={0}; exitCode={1}; resultExists={2}; cleanedUp={3}; remainingProcessIds={4}; pathLengths=result:{5},stdout:{6},stderr:{7},cancel:{8}; evidence={9}" -f `
            $status, $exitCode, $resultExists, $cleanup.cleanedUp,
            (@($cleanup.remainingProcessIds) -join ','), $ResultPath.Length, $StdoutPath.Length,
            $StderrPath.Length, $CancelPath.Length, $ProcessEvidencePath)
        if (@($cleanup.errors).Count -gt 0) {
            Write-Host ("Pester shard cleanup errors: {0}" -f (@($cleanup.errors) -join ' | '))
        }
    }
    $firstFailureContext = if ([string]::IsNullOrWhiteSpace([string]$diagnostic.failureSummary)) {
        ''
    }
    else {
        " firstFailure=$($diagnostic.failureSummary)"
    }
    if ($status -notin @('completed', 'failed')) {
        throw "Pester shard process ended with status '$status'; evidence='$ProcessEvidencePath'.$firstFailureContext $exceptionText"
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "Pester shard process '$status' exited without a result file; evidence='$ProcessEvidencePath'; exit='$exitCode'.$firstFailureContext"
    }
    if (-not $cleanup.cleanedUp) {
        throw "Pester shard process cleanup failed; evidence='$ProcessEvidencePath'."
    }
    return [pscustomobject][ordered]@{
        resultPath = $ResultPath
        processEvidencePath = $ProcessEvidencePath
        stdoutPath = $StdoutPath
        stderrPath = $StderrPath
        status = $status
        exitCode = $exitCode
        cleanedUp = [bool]$cleanup.cleanedUp
        processStarted = [bool]$processStarted
        outputQuotaExceeded = [bool]$outputQuotaExceeded
    }
}

Assert-PesterShardPathAncestorsNoReparse -Path $PesterModulePath -Context 'Pester module path'
Import-Module $PesterModulePath -Force -ErrorAction Stop
$loadedPester = Get-Module -Name Pester |
    Where-Object { $_.Version -eq [version]$PesterVersion } |
    Select-Object -First 1
if ($null -eq $loadedPester) {
    throw "Pester module version mismatch. Expected $PesterVersion at '$PesterModulePath'."
}
$invokePester = Get-Command Invoke-Pester -ErrorAction Stop |
    Where-Object { $_.Module.Version -eq [version]$PesterVersion } |
    Select-Object -First 1
if ($null -eq $invokePester) { throw "Invoke-Pester $PesterVersion could not be resolved." }

$allTestPaths = @(
    Get-ChildItem -LiteralPath $resolvedTestRoot -Filter '*.Tests.ps1' -File |
        Sort-Object FullName |
        ForEach-Object { [string]$_.FullName }
)
if ($allTestPaths.Count -eq 0) { throw 'No Pester test files were discovered.' }

$isolatedPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($name in $IsolatedTestFileNames) {
    $matches = @($allTestPaths | Where-Object { (Split-Path -Leaf $_) -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected exactly one isolated test file named '$name'; found $($matches.Count)." }
    $isolatedPaths.Add([string]$matches[0])
}
$bulkPaths = @($allTestPaths | Where-Object { $isolatedPaths -notcontains [string]$_ })
$partitionedPaths = @($isolatedPaths.ToArray()) + @($bulkPaths)
if (($partitionedPaths.Count -ne $allTestPaths.Count) -or
    ((($partitionedPaths | Sort-Object) -join [Environment]::NewLine) -cne
     (($allTestPaths | Sort-Object) -join [Environment]::NewLine))) {
    throw 'Pester shard inventory is not an exact partition of the discovered test files.'
}

$shards = New-Object 'System.Collections.Generic.List[object]'
foreach ($name in $IsolatedTestFileNames) {
    $shards.Add([pscustomobject]@{
        Name = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($name))
        Paths = @($isolatedPaths | Where-Object { (Split-Path -Leaf $_) -ceq $name })
    })
}
$shards.Add([pscustomobject]@{ Name = 'bulk'; Paths = $bulkPaths })

$childPowerShell = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    (Get-Command powershell -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
else {
    (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
$childScript = @(
    '$ErrorActionPreference = ''Stop'''
    'function Remove-PesterShardTerminalControlSequences {'
    (Get-Command Remove-PesterShardTerminalControlSequences -CommandType Function -ErrorAction Stop).Definition
    '}'
    'function ConvertTo-PesterShardEarlyFailureDiagnostic {'
    '    param([Parameter()][AllowNull()][object] $ErrorRecord)'
    '    $text = if ($null -eq $ErrorRecord) { ''Pester shard child failed before producing a result.'' } else { [string]$ErrorRecord.Exception.ToString() }'
    '    if ([string]::IsNullOrWhiteSpace($text)) { $text = ''Pester shard child failed before producing a result.'' }'
    '    $normalizedText = Remove-PesterShardTerminalControlSequences -Text $text'
    '    $lines = New-Object ''System.Collections.Generic.List[string]'''
    '    $redactSensitiveContinuation = $false'
    '    foreach ($rawLine in @($normalizedText -split "`r?`n")) {'
    '        if ($lines.Count -ge 8) { break }'
    '        $line = ([string]$rawLine).Trim()'
    '        if ([string]::IsNullOrWhiteSpace($line)) {'
    '            continue'
    '        }'
    '        if ($redactSensitiveContinuation) {'
    '            $line = if ($line -match ''(?i)^\s*\[-\]'') {'
    '                ''[-] [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)^\s*Expected'') {'
    '                ''Expected: [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)^\s*But was'') {'
    '                ''But was: [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)^\s*Exception:'') {'
    '                ''Exception: [redacted sensitive diagnostic continuation]'''
    '            }'
    '            elseif ($line -match ''(?i)\bat\s+.+\.ps1:\d+'') {'
    '                ''at [redacted sensitive diagnostic continuation]'''
    '            }'
    '            else {'
    '                ''[redacted sensitive diagnostic continuation]'''
    '            }'
    '        }'
    '        else {'
    '            if ($line.IndexOf([char]0xE000) -ge 0 -or $line -match ''(?i)secret|password|token|authorization|api[-_]?key|bearer'') {'
    '                $redactSensitiveContinuation = $true'
    '                $line = ''[redacted sensitive diagnostic line]'''
    '            }'
    '        }'
    '        if ($line.Length -gt 512) { $line = $line.Substring(0, 512) }'
    '        if (-not $lines.Contains($line)) { [void]$lines.Add($line) }'
    '    }'
    '    $diagnostic = ($lines.ToArray() -join '' | '')'
    '    if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = ''Pester shard child failed before producing a result.'' }'
    '    if ($diagnostic.Length -gt 4096) { $diagnostic = $diagnostic.Substring(0, 4096) }'
    '    return $diagnostic'
    '}'
    '$childFailurePhase = ''initialization'''
    '$summary = $null'
    '$childExitCode = 0'
    'try {'
    '    $paths = ConvertFrom-Json -InputObject $env:SYP154_PESTER_SHARD_PATHS'
    '    if ($paths.Count -eq 0) { throw ''Pester shard has no test paths.'' }'
    '    Import-Module $env:SYP154_PESTER_MODULE_PATH -Force'
    ('    $invoke = Get-Command Invoke-Pester -ErrorAction Stop | Where-Object {{ $_.Module.Version -eq [version]''{0}'' }} | Select-Object -First 1' -f $PesterVersion)
    ('    if ($null -eq $invoke) {{ throw ''Pester shard could not resolve version {0}.'' }}' -f $PesterVersion)
    '    $invokeParameters = @{ Script = $paths; PassThru = $true }'
    '    if ($invoke.Parameters.ContainsKey(''Show'')) { $invokeParameters.Show = ''All'' }'
    '    $childFailurePhase = ''invoke-pester'''
    '    $savedPesterErrorActionPreference = $ErrorActionPreference'
    '    try {'
    '        # Preserve the original workflow contract: Pester and its fixtures may emit non-terminating native stderr warnings.'
    '        $ErrorActionPreference = ''Continue'''
    '        $result = & $invoke @invokeParameters'
    '    }'
    '    finally {'
    '        $ErrorActionPreference = $savedPesterErrorActionPreference'
    '    }'
    '    if ($null -eq $result) { throw ''Pester shard did not return a result object.'' }'
    '    $childFailurePhase = ''summary'''
    '    $summary = [ordered]@{'
    '        schemaVersion = 1'
    '        status = ''completed'''
    '        TotalCount = [int]$result.TotalCount'
    '        PassedCount = [int]$result.PassedCount'
    '        FailedCount = [int]$result.FailedCount'
    '        SkippedCount = [int]$result.SkippedCount'
    '        PendingCount = [int]$result.PendingCount'
    '        InconclusiveCount = [int]$result.InconclusiveCount'
    '    }'
    '}'
    'catch {'
    '    $childExitCode = 3'
    '    $failureMessage = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_'
    '    try { [Console]::Error.WriteLine((''Pester shard child early failure ({0}): {1}'' -f $childFailurePhase, $failureMessage)) } catch { }'
    '    $summary = [ordered]@{'
    '        schemaVersion = 1'
    '        status = ''failed'''
    '        failureKind = ''early-child-failure'''
    '        failurePhase = $childFailurePhase'
    '        failureMessage = $failureMessage'
    '        TotalCount = 0'
    '        PassedCount = 0'
    '        FailedCount = 1'
    '        SkippedCount = 0'
    '        PendingCount = 0'
    '        InconclusiveCount = 0'
    '    }'
    '}'
    'try {'
    '    [IO.File]::WriteAllText($env:SYP154_PESTER_RESULT_PATH, ($summary | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))'
    '}'
    'catch {'
    '    $childExitCode = 4'
    '    $failureMessage = ConvertTo-PesterShardEarlyFailureDiagnostic -ErrorRecord $_'
    '    try { [Console]::Error.WriteLine((''Pester shard result evidence write failure: {0}'' -f $failureMessage)) } catch { }'
    '}'
    'if ($childExitCode -ne 0) { exit $childExitCode }'
    'if ($summary.FailedCount -gt 0 -or $summary.PendingCount -gt 0 -or $summary.InconclusiveCount -gt 0) { exit 2 }'
    'exit 0'
) -join [Environment]::NewLine
$encodedChildScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

$total = 0
$passed = 0
$failed = 0
$skipped = 0
$pending = 0
$inconclusive = 0
$failedShardProcess = $false
foreach ($shard in @($shards.ToArray())) {
    $runToken = [guid]::NewGuid().ToString('N')
    $safeName = ($shard.Name -replace '[^A-Za-z0-9_.-]', '-')
    $CancellationPath = $null
    $ownsCancellationPath = $false
    if ([string]::IsNullOrWhiteSpace($CancellationPath)) {
        do {
            # The normal CI path is supervisor-owned and unique to this shard
            # run. External cancellation uses the supervisor-only control
            # channel; no caller-visible marker is accepted by this wrapper.
            $CancellationPath = Join-Path $EvidenceRoot ("syp154-pester-shard-{0}-{1}-{2}.cancel" -f $safeName, $runToken, ([guid]::NewGuid().ToString('N')))
        } while (Test-Path -LiteralPath $CancellationPath)
        $ownsCancellationPath = $true
    }
    $resultPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.json" -f $safeName, $runToken)
    $processEvidencePath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.process.json" -f $safeName, $runToken)
    $stdoutPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stdout.log" -f $safeName, $runToken)
    $stderrPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stderr.log" -f $safeName, $runToken)
    $previous = @{}
    $environment = @{
        SYP154_PESTER_SHARD_PATHS = ConvertTo-Json -InputObject ([string[]]$shard.Paths) -Compress
        SYP154_PESTER_MODULE_PATH = [string]$PesterModulePath
        SYP154_PESTER_RESULT_PATH = $resultPath
    }
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        $shardParameters = @{
            Paths = $shard.Paths
            ModulePath = $PesterModulePath
            Version = $PesterVersion
            ChildPowerShell = $childPowerShell
            EncodedChildScript = $encodedChildScript
            ResultPath = $resultPath
            ProcessEvidencePath = $processEvidencePath
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
            TimeoutSeconds = $OuterTimeoutSeconds
            CancelPath = $CancellationPath
            WorkingDirectory = $repositoryRoot
        }
        $shardRun = Invoke-PesterShardProcess @shardParameters
    }
    finally {
        foreach ($entry in $environment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $previous[$entry.Key], 'Process')
        }
        if ($ownsCancellationPath -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
            Remove-Item -LiteralPath $CancellationPath -Force -ErrorAction SilentlyContinue
        }
    }

    $resultPath = [string]$shardRun.resultPath
    $summary = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $processEvidence = Get-Content -LiteralPath ([string]$shardRun.processEvidencePath) -Raw -Encoding UTF8 | ConvertFrom-Json
    $shardOutputQuotaExceeded = $false
    if ($shardRun.PSObject.Properties.Name -contains 'outputQuotaExceeded') {
        $shardOutputQuotaExceeded = [bool]$shardRun.outputQuotaExceeded
    }
    $processOutputQuotaExceeded = $false
    if ($processEvidence.PSObject.Properties.Name -contains 'outputQuotaExceeded') {
        $processOutputQuotaExceeded = [bool]$processEvidence.outputQuotaExceeded
    }
    $shardProcessStatusInvalid = ([string]$shardRun.status -cne 'completed' -or
        [string]$processEvidence.status -cne 'completed' -or
        $shardOutputQuotaExceeded -or $processOutputQuotaExceeded)
    if ($shardProcessStatusInvalid -or [int]$shardRun.exitCode -ne 0 -or [int]$summary.FailedCount -gt 0) {
        if ($shardProcessStatusInvalid) {
            Write-Host "Pester shard process status is not completed or output quota was exceeded: shard=$($shardRun.status), evidence=$($processEvidence.status), shardQuota=$shardOutputQuotaExceeded, evidenceQuota=$processOutputQuotaExceeded"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$processEvidence.failureSummary)) {
            Write-Host "Pester shard first failure (sanitized): $($processEvidence.failureSummary)"
        }
    }
    foreach ($field in @('TotalCount', 'PassedCount', 'FailedCount', 'SkippedCount', 'PendingCount', 'InconclusiveCount')) {
        if ($summary.$field -isnot [int] -and $summary.$field -isnot [long]) {
            throw "Pester shard '$($shard.Name)' returned a non-integer $field. Process evidence='$($shardRun.processEvidencePath)'."
        }
    }
    Write-Host "$($shard.Name) - Total: $($summary.TotalCount) Passed: $($summary.PassedCount) Failed: $($summary.FailedCount) Skipped: $($summary.SkippedCount)"
    $total += [int]$summary.TotalCount
    $passed += [int]$summary.PassedCount
    $failed += [int]$summary.FailedCount
    $skipped += [int]$summary.SkippedCount
    $pending += [int]$summary.PendingCount
    $inconclusive += [int]$summary.InconclusiveCount
    if ($shardProcessStatusInvalid -or [int]$shardRun.exitCode -ne 0) { $failedShardProcess = $true }
}

if ($failedShardProcess) { throw 'At least one isolated Pester shard exited nonzero.' }
if ($total -ne $ExpectedTotalCount) { throw "Pester discovered $total tests across shards; expected exactly $ExpectedTotalCount." }
if ($failed -gt 0) { throw "Pester reported $failed failed tests." }
if ($pending -ne 0) { throw "Pester reported $pending pending tests." }
if ($inconclusive -ne 0) { throw "Pester reported $inconclusive inconclusive tests." }
if ($skipped -ne $ExpectedSkippedCount) { throw "Pester expected exactly $ExpectedSkippedCount platform/version skips; got $skipped." }
if (($passed + $skipped) -ne $total) { throw 'Pester aggregate result counts are incomplete.' }
Write-Host "Aggregate - Total: $total Passed: $passed Failed: $failed Skipped: $skipped"
