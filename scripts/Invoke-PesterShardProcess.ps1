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

$repositoryRoot = (Get-Location).Path
$resolvedTestRoot = (Resolve-Path -LiteralPath $TestRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = $env:RUNNER_TEMP }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path $repositoryRoot '.syp154-pester-evidence' }
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$ownsCancellationPath = $false
if ([string]::IsNullOrWhiteSpace($CancellationPath)) {
    do {
        $CancellationPath = Join-Path $EvidenceRoot ("syp154-pester-shard-{0}.cancel" -f ([guid]::NewGuid().ToString('N')))
    } while (Test-Path -LiteralPath $CancellationPath)
    $ownsCancellationPath = $true
}

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

function Get-PesterShardFailureSummary {
    param(
        [Parameter(Mandatory = $true)][string[]] $Paths,
        [int] $MaxLines = 8,
        [int] $MaxLineLength = 512,
        [int] $MaxTotalLength = 4096
    )

    $ansiPattern = ([string][char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    foreach ($path in $Paths) {
        $text = Read-PesterShardOutputPrefix -Path $path
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $lines = @($text -split "`r?`n")
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $candidate = [regex]::Replace([string]$lines[$index], $ansiPattern, '')
            if ($candidate -notmatch '(?i)\[-\]|^\s*(Expected|But was|Exception:)|\bat\s+.+\.ps1:\d+') { continue }
            $selected = New-Object 'System.Collections.Generic.List[string]'
            $start = [Math]::Max(0, $index - 1)
            $end = [Math]::Min($lines.Count - 1, $index + $MaxLines - 2)
            for ($lineIndex = $start; $lineIndex -le $end -and $selected.Count -lt $MaxLines; $lineIndex++) {
                $line = [regex]::Replace([string]$lines[$lineIndex], $ansiPattern, '').Trim()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -match '(?i)secret|password|token|authorization|api[-_]?key|bearer') {
                    $line = '[redacted sensitive diagnostic line]'
                }
                if ($line.Length -gt $MaxLineLength) { $line = $line.Substring(0, $MaxLineLength) }
                if (-not $selected.Contains($line)) { $selected.Add($line) }
            }
            $summary = ($selected.ToArray() -join ' | ')
            if ($summary.Length -gt $MaxTotalLength) { $summary = $summary.Substring(0, $MaxTotalLength) }
            return $summary
        }
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
        if (-not $rootAlive -and $liveKnownIds.Count -eq 0 -and $liveCurrentDescendants.Count -eq 0) { break }

        if ($jobObjectAvailable) {
            # The Job Object is the authoritative containment boundary. Parent
            # enumeration is retained for diagnostics only and is never used
            # to discover the complete owned process set.
            if (-not $jobObjectTerminationAttempted -and ($rootAlive -or $liveCurrentDescendants.Count -gt 0)) {
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
    $cleanup = [pscustomobject][ordered]@{
        cleanedUp = $true
        reason = 'process-not-started'
    }
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
                    if ($null -ne $captureSpec.Task -and $captureSpec.Task.IsCompleted) {
                        try {
                            if ([bool]$captureSpec.Task.GetAwaiter().GetResult().Exceeded) { $quotaStream = [string]$captureSpec.Name }
                        }
                        catch { }
                    }
                    if ($null -ne $quotaStream) { break }
                }
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
        if ($null -eq $process) {
            if ($status -notin @('cancelled', 'timeout')) { $status = 'startup-failed' }
        }
        elseif ($status -notin @('cancelled', 'timeout', 'failed')) { $status = 'failed' }
    }
    finally {
        if ($null -ne $process) {
            try {
                $cleanup = Stop-PesterShardOwnedProcessTree `
                    -RootProcessId ([int]$process.Id) `
                    -RootProcess $process `
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
                    rootProcessId = [int]$process.Id
                    initialDescendantProcessIds = @()
                    observedProcessIds = @([int]$process.Id)
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
            if ($process.HasExited -and $null -eq $exitCode -and
                $status -notin @('cancelled', 'timeout', 'cleanup-failed')) {
                $exitCode = [int]$process.ExitCode
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
                $captureErrors.Add("$($captureSpec.Name) bounded output capture failed: $($_.Exception.Message)")
            }
        }
        if ($outputCaptureTimedOut) {
            $cleanup.errors = @($cleanup.errors) + @($captureErrors.ToArray())
            $cleanup.cleanedUp = $false
            $status = 'cleanup-failed'
        }
        if ($outputQuotaExceeded -and $status -notin @('cancelled', 'timeout', 'cleanup-failed')) {
            $status = 'failed'
            if ([string]::IsNullOrWhiteSpace($exceptionText)) {
                $exceptionText = "Owned Pester shard output capture quota exceeded for $($outputQuotaStreams -join ' and ') (limit=$($script:PesterShardChildOutputQuotaCharacters) characters per stream)."
            }
        }
        if ($captureErrors.Count -gt 0 -and -not $outputCaptureTimedOut) {
            $exceptionText = if ([string]::IsNullOrWhiteSpace($exceptionText)) {
                ($captureErrors -join ' | ')
            }
            else {
                "$exceptionText | $($captureErrors -join ' | ')"
            }
        }
        try { Write-PesterShardBoundedOutput -Path $StdoutPath -Text $stdout }
        catch { $outputWriteError = "stdout evidence write failed: $($_.Exception.ToString())" }
        try { Write-PesterShardBoundedOutput -Path $StderrPath -Text $stderr }
        catch {
            $outputWriteError = if ($null -eq $outputWriteError) { "stderr evidence write failed: $($_.Exception.ToString())" } else { "$outputWriteError | stderr evidence write failed: $($_.Exception.ToString())" }
        }
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
                    $cleanup.cleanedUp = $false
                    $status = 'cleanup-failed'
                    $cleanup.errors = @($cleanup.errors) + @('The owned Windows Job Object handle could not be closed safely.')
                }
            }
            catch {
                $jobClosed = $false
                $cleanup.cleanedUp = $false
                $status = 'cleanup-failed'
                $cleanup.errors = @($cleanup.errors) + @("The owned Windows Job Object handle could not be closed safely: $($_.Exception.Message)")
            }
            $jobHandle = [IntPtr]::Zero
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$windowsBootstrapReleasePath) -and
            [IO.File]::Exists($windowsBootstrapReleasePath)) {
            try { [IO.File]::Delete($windowsBootstrapReleasePath) }
            catch {
                $cleanup.cleanedUp = $false
                $status = 'cleanup-failed'
                $cleanup.errors = @($cleanup.errors) + @("The owned Pester shard bootstrap signal could not be removed: $($_.Exception.Message)")
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
            failureSummary = Get-PesterShardFailureSummary -Paths @($StdoutPath, $StderrPath)
            stdoutPrefix = Read-PesterShardOutputPrefix -Path $StdoutPath
            stderrPrefix = Read-PesterShardOutputPrefix -Path $StderrPath
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
    if ($status -notin @('completed', 'failed')) {
        throw "Pester shard process ended with status '$status'; evidence='$ProcessEvidencePath'. $exceptionText"
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "Pester shard process '$status' exited without a result file; evidence='$ProcessEvidencePath'; exit='$exitCode'."
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
    '$paths = @($env:SYP154_PESTER_SHARD_PATHS | ConvertFrom-Json)'
    'if ($paths.Count -eq 0) { throw ''Pester shard has no test paths.'' }'
    'Import-Module $env:SYP154_PESTER_MODULE_PATH -Force'
    ('$invoke = Get-Command Invoke-Pester -ErrorAction Stop | Where-Object {{ $_.Module.Version -eq [version]''{0}'' }} | Select-Object -First 1' -f $PesterVersion)
    ('if ($null -eq $invoke) {{ throw ''Pester shard could not resolve version {0}.'' }}' -f $PesterVersion)
    '$invokeParameters = @{ Script = $paths; PassThru = $true }'
    '$result = & $invoke @invokeParameters'
    'if ($null -eq $result) { throw ''Pester shard did not return a result object.'' }'
    '$summary = [ordered]@{'
    '    TotalCount = [int]$result.TotalCount'
    '    PassedCount = [int]$result.PassedCount'
    '    FailedCount = [int]$result.FailedCount'
    '    SkippedCount = [int]$result.SkippedCount'
    '    PendingCount = [int]$result.PendingCount'
    '    InconclusiveCount = [int]$result.InconclusiveCount'
    '}'
    '[IO.File]::WriteAllText($env:SYP154_PESTER_RESULT_PATH, ($summary | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))'
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
    $resultPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.json" -f $safeName, $runToken)
    $processEvidencePath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.process.json" -f $safeName, $runToken)
    $stdoutPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stdout.log" -f $safeName, $runToken)
    $stderrPath = Join-Path $EvidenceRoot ("pester-shard-{0}-{1}.stderr.log" -f $safeName, $runToken)
    $previous = @{}
    $environment = @{
        SYP154_PESTER_SHARD_PATHS = ($shard.Paths | ConvertTo-Json -Compress)
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
    }

    $resultPath = [string]$shardRun.resultPath
    $summary = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $processEvidence = Get-Content -LiteralPath ([string]$shardRun.processEvidencePath) -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$shardRun.exitCode -ne 0 -or [int]$summary.FailedCount -gt 0) {
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
    if ([int]$shardRun.exitCode -ne 0) { $failedShardProcess = $true }
}

if ($failedShardProcess) { throw 'At least one isolated Pester shard exited nonzero.' }
if ($total -ne $ExpectedTotalCount) { throw "Pester discovered $total tests across shards; expected exactly $ExpectedTotalCount." }
if ($failed -gt 0) { throw "Pester reported $failed failed tests." }
if ($pending -ne 0) { throw "Pester reported $pending pending tests." }
if ($inconclusive -ne 0) { throw "Pester reported $inconclusive inconclusive tests." }
if ($skipped -ne $ExpectedSkippedCount) { throw "Pester expected exactly $ExpectedSkippedCount platform/version skips; got $skipped." }
if (($passed + $skipped) -ne $total) { throw 'Pester aggregate result counts are incomplete.' }
Write-Host "Aggregate - Total: $total Passed: $passed Failed: $failed Skipped: $skipped"
