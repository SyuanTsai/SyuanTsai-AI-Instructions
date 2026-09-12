[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $AdapterPath,
    [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
    [string] $OutputPath,
    [Parameter(Mandatory = $true)][string] $SourceRepository,
    [Parameter(Mandatory = $true)][string] $SourceRevision,
    [Parameter(Mandatory = $true)][string] $BaseRevision,
    [ValidateSet('local', 'pre-push', 'pull_request', 'push', 'workflow_dispatch')]
    [string] $EventName = 'local',
    [string] $CandidateArchivePath,
    [string] $CandidateAcquisitionEvidencePath,
    [string] $CandidateArchiveSha256,
    [string] $AuthorityRevision,
    [string] $AuthorityArchivePath,
    [string] $AuthoritySnapshotEvidencePath,
    [int] $TimeoutSeconds = 300,
    [string] $CancellationPath,
    [string] $TrustedToolRoot,
    [switch] $DevelopmentHarness,
    [switch] $SemanticTriggered,
    [switch] $SemanticConsent,
    [string] $SemanticProvider,
    [string] $SemanticPurpose,
    [string] $SemanticScope,
    [string] $SemanticEvidencePath,
    [string] $AiReviewEvidencePath,
    [string] $HumanApprovalEvidencePath,
    [string] $PublishInstallEvidencePath,
    [string] $PostInstallEvidencePath,
    [switch] $CompleteLifecycle,
    [switch] $DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TrustedToolRoot)) {
    $scriptRoot = [string]$PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptPath = [string]$MyInvocation.MyCommand.Path
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            throw 'Cannot derive the validation runner script root.'
        }
        $scriptRoot = Split-Path -Parent $scriptPath
    }
    $TrustedToolRoot = Split-Path -Parent $scriptRoot
}

$script:StandardValidationStageDefinitions = @(
    [ordered]@{ order = 1; id = 'controlled-acquisition'; condition = 'always' },
    [ordered]@{ order = 2; id = 'integrity-verification'; condition = 'always' },
    [ordered]@{ order = 3; id = 'package-validation'; condition = 'always' },
    [ordered]@{ order = 4; id = 'skillspector-static'; condition = 'always' },
    [ordered]@{ order = 5; id = 'repository-tests'; condition = 'always' },
    [ordered]@{ order = 6; id = 'conditional-semantic-scan'; condition = 'when-triggered' },
    [ordered]@{ order = 7; id = 'ai-review'; condition = 'lifecycle-evidence' },
    [ordered]@{ order = 8; id = 'human-approval'; condition = 'lifecycle-evidence' },
    [ordered]@{ order = 9; id = 'publish-or-install'; condition = 'approved-release-or-authorized-install' },
    [ordered]@{ order = 10; id = 'post-install-verification'; condition = 'after-install' }
)

$script:StandardValidationExitCodes = [ordered]@{
    PASS = 0
    BLOCKED = 10
    FAILED = 20
    INVALID = 30
    CANCELLED = 40
}
$script:StandardValidationLastEvent = $null
$script:StandardValidationAuthorityEvidence = $null
$script:StandardValidationRepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:StandardValidationAuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:StandardValidationTrustAnchorDefinitions = [ordered]@{
    supervisor = [ordered]@{
        relativePath = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'
        fileName = 'trusted-supervisor-public-key.xml'
        sha256 = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27'
    }
    humanApproval = [ordered]@{
        relativePath = 'docs/standards/trust-anchors/human-approval-public-key.xml'
        fileName = 'human-approval-public-key.xml'
        sha256 = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b'
    }
}

if ([Environment]::OSVersion.Platform -in @([PlatformID]::Win32NT, [PlatformID]::Unix)) {
    if ($null -eq ('StandardValidationProcessControlNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class StandardValidationProcessControlNative
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

    [DllImport("libc", SetLastError = true)]
    private static extern int kill(int processId, int signal);

    [DllImport("libc", SetLastError = true)]
    private static extern int getpgid(int processId);

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

    public static int GetProcessGroupId(int processId)
    {
        return getpgid(processId);
    }

    public static bool TryKillProcessGroup(int processGroupId, int signal)
    {
        return kill(-processGroupId, signal) == 0;
    }

    public static bool IsProcessGroupAlive(int processGroupId)
    {
        int result = kill(-processGroupId, 0);
        if (result == 0) return true;
        return Marshal.GetLastWin32Error() != 3; // ESRCH means the group is gone.
    }
}
'@
    }
}

function Get-StandardValidationProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) { return ,$DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ,$DefaultValue }
    return ,$property.Value
}

function Get-StandardValidationRequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "INVALID|$Context is not a JSON object."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "INVALID|$Context is missing required property '$Name'."
    }
    return ,$property.Value
}

function Assert-StandardValidationExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "INVALID|$Context must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "INVALID|$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-StandardValidationSha256 {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "INVALID|$Context must be a lowercase SHA-256 value."
    }
}

function Assert-StandardValidationRevision {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ($Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "INVALID|$Context must be a lowercase immutable commit SHA."
    }
}

function Assert-StandardValidationSourceRepository {
    param([Parameter(Mandatory = $true)][string] $Value)

    if ($Value -cnotmatch '^https://[^/?#]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
        throw 'INVALID|SourceRepository must be a canonical HTTPS repository URL.'
    }
}

function Get-StandardValidationFullPath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    try { return [System.IO.Path]::GetFullPath($Path) }
    catch { throw "INVALID|$Context is not a valid path: $($_.Exception.Message)" }
}

function Test-StandardValidationPathWithin {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [switch] $IncludeRoot
    )

    $fullPath = Get-StandardValidationFullPath -Path $Path -Context 'path'
    $fullRoot = (Get-StandardValidationFullPath -Path $Root -Context 'root').TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else { [System.StringComparison]::Ordinal }
    if ($IncludeRoot -and [string]::Equals($fullPath, $fullRoot, $comparison)) { return $true }
    return $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::AltDirectorySeparatorChar, $comparison)
}

function Assert-StandardValidationOutsideRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (Test-StandardValidationPathWithin -Path $Path -Root $Root -IncludeRoot) {
        throw "INVALID|$Context must not be under the candidate root."
    }
}

function Assert-StandardValidationDistinctRoots {
    param(
        [Parameter(Mandatory = $true)][string] $First,
        [Parameter(Mandatory = $true)][string] $Second,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ((Test-StandardValidationPathWithin -Path $First -Root $Second -IncludeRoot) -or
        (Test-StandardValidationPathWithin -Path $Second -Root $First -IncludeRoot)) {
        throw "INVALID|$Context must be outside both candidate and artifact roots."
    }
}

function Get-StandardValidationFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INVALID|$Context file is missing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-StandardValidationTextSha256 {
    param([Parameter(Mandatory = $true)][string] $Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-StandardValidationJson {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INVALID|$Context JSON file is missing: $Path"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    }
    catch { throw "INVALID|$Context is not parseable JSON: $($_.Exception.Message)" }
}

function Assert-StandardValidationRegularFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INVALID|$Context file is missing: $Path"
    }
    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "INVALID|$Context must be a regular non-reparse file: $Path"
    }
}

function Get-StandardValidationTrustAnchorPath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('supervisor', 'humanApproval')][string] $KeyId,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot
    )

    $definition = $script:StandardValidationTrustAnchorDefinitions[$KeyId]
    if ($null -eq $definition) { throw "BLOCKED|Unknown validation trust anchor '$KeyId'." }
    $rootFull = Get-StandardValidationFullPath -Path $TrustAnchorRoot -Context 'validation trust-anchor root'
    $path = Get-StandardValidationFullPath -Path (Join-Path $rootFull ([string]$definition.fileName)) -Context "$KeyId validation trust anchor"
    # Production callers pass the immutable authority trust-anchor directory. A
    # caller-selected TrustedToolRoot is only used by the development harness;
    # the fixed authority path is additionally pinned to the checked-in hash.
    $fixedRoot = Get-StandardValidationFullPath -Path (Join-Path $script:StandardValidationRepositoryRoot 'docs/standards/trust-anchors') -Context 'immutable validation trust-anchor root'
    if ([string]::Equals($rootFull, $fixedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Assert-StandardValidationRegularFile -Path $path -Context "$KeyId validation trust anchor"
        $actual = Get-StandardValidationFileSha256 -Path $path -Context "$KeyId validation trust anchor"
        if ($actual -cne [string]$definition.sha256) {
            throw "BLOCKED|$KeyId validation trust anchor hash is not the immutable approved value."
        }
    }
    return $path
}

function Get-StandardValidationTrustAnchorEvidence {
    $anchors = @()
    foreach ($keyId in @('supervisor', 'humanApproval')) {
        $definition = $script:StandardValidationTrustAnchorDefinitions[$keyId]
        $path = Join-Path $script:StandardValidationRepositoryRoot ([string]$definition.relativePath)
        Assert-StandardValidationRegularFile -Path $path -Context "$keyId validation trust anchor"
        $sha256 = Get-StandardValidationFileSha256 -Path $path -Context "$keyId validation trust anchor"
        if ($sha256 -cne [string]$definition.sha256) {
            throw "INVALID|$keyId validation trust anchor hash is not the immutable approved value."
        }
        $anchors += [ordered]@{
            id = $keyId
            path = [string]$definition.relativePath
            sha256 = $sha256
        }
    }
    return ,$anchors
}

function Get-StandardValidationSelectedFilesSha256 {
    param([Parameter(Mandatory = $true)] $Files)

    $canonical = (@($Files | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join '')
    return Get-StandardValidationTextSha256 -Value $canonical
}

function Get-StandardValidationSignedReceiptPayload {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('candidate-acquisition-v1', 'authority-snapshot-v1', 'publish-install-v1', 'post-install-v1')][string] $ReceiptType,
        [Parameter(Mandatory = $true)][hashtable] $Fields
    )

    $orderedNames = @($Fields.Keys | Sort-Object)
    return (@("receiptType=$ReceiptType" + ($orderedNames | ForEach-Object { "$_=$([string]$Fields[$_])" })) -join "`n")
}

function Assert-StandardValidationSignedReceipt {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $ReceiptType,
        [Parameter(Mandatory = $true)][hashtable] $Fields,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $signature = Get-StandardValidationRequiredProperty -Object $Receipt -Name 'signature' -Context $Context
    if ($signature -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$signature) -or
        [string]$signature -notmatch '^[A-Za-z0-9+/]+={0,2}$' -or ([string]$signature).Length % 4 -ne 0) {
        throw "BLOCKED|$Context signature is not valid base64."
    }
    $publicKeyPath = Get-StandardValidationTrustAnchorPath -KeyId 'supervisor' -TrustAnchorRoot $TrustAnchorRoot
    Assert-StandardValidationRegularFile -Path $publicKeyPath -Context "$Context trusted public key"
    $publicKeyXml = Get-Content -Raw -Encoding UTF8 -LiteralPath $publicKeyPath
    if ([string]::IsNullOrWhiteSpace($publicKeyXml) -or
        $publicKeyXml -notmatch '(?is)^\s*<RSAKeyValue>\s*<Modulus>[^<]+</Modulus>\s*<Exponent>[^<]+</Exponent>\s*</RSAKeyValue>\s*$' -or
        $publicKeyXml -match '(?i)<D(?:\s|>)') {
        throw "BLOCKED|$Context trusted public key must be an RSA XML public key."
    }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        try { $rsa.FromXmlString($publicKeyXml) }
        catch { throw "BLOCKED|$Context trusted public key could not be parsed as RSA XML: $($_.Exception.Message)" }
        $signatureBytes = $null
        try { $signatureBytes = [Convert]::FromBase64String([string]$signature) }
        catch { throw "BLOCKED|$Context signature is not valid base64." }
        $payload = Get-StandardValidationSignedReceiptPayload -ReceiptType $ReceiptType -Fields $Fields
        $payloadBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload)
        if (-not $rsa.VerifyData($payloadBytes, 'SHA256', $signatureBytes)) {
            throw "BLOCKED|$Context trusted supervisor signature verification failed."
        }
    }
    finally { $rsa.Dispose() }
}

function Assert-StandardValidationArchivePrefix {
    param([AllowEmptyString()][string] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ([string]::IsNullOrEmpty($Value)) { return }
    Assert-StandardValidationSafeRelativePath -Value $Value -Context $Context
}

function Assert-StandardValidationImmutableArchiveUrl {
    param(
        [Parameter(Mandatory = $true)][string] $SourceRepository,
        [Parameter(Mandatory = $true)][string] $SourceRevision,
        [Parameter(Mandatory = $true)][string] $ArchiveUrl,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $sourceUri = $null
    $archiveUri = $null
    if (-not [Uri]::TryCreate($SourceRepository, [UriKind]::Absolute, [ref]$sourceUri) -or
        -not [Uri]::TryCreate($ArchiveUrl, [UriKind]::Absolute, [ref]$archiveUri) -or
        $sourceUri.Scheme -cne 'https' -or $archiveUri.Scheme -cne 'https' -or
        -not [string]::IsNullOrEmpty($archiveUri.Query) -or -not [string]::IsNullOrEmpty($archiveUri.Fragment)) {
        throw "BLOCKED|$Context archive URL must be an HTTPS immutable URL without query or fragment."
    }
    $revisionMarker = '/' + $SourceRevision
    if ($archiveUri.AbsolutePath.IndexOf($revisionMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "BLOCKED|$Context archive URL must contain the exact immutable source revision."
    }
    $sourcePath = ($sourceUri.AbsolutePath.TrimEnd('/') -replace '(?i)\.git$', '')
    $archiveHostAccepted = [string]::Equals($sourceUri.Host, $archiveUri.Host, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals(('codeload.' + $sourceUri.Host), $archiveUri.Host, [StringComparison]::OrdinalIgnoreCase)
    if (-not $archiveHostAccepted -or -not $archiveUri.AbsolutePath.StartsWith($sourcePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "BLOCKED|$Context archive URL is not bound to the source repository."
    }
}

function Get-StandardValidationArchiveInventory {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $ExtractionRoot,
        [AllowEmptyString()][string] $ArchivePrefix,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-StandardValidationRegularFile -Path $ArchivePath -Context $Context
    [void](New-Item -ItemType Directory -Path $ExtractionRoot -Force)
    $archive = $null
    try {
        try { $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath) }
        catch { throw "INVALID|$Context must be a readable ZIP archive: $($_.Exception.Message)" }
        $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($entry in @($archive.Entries)) {
            $entryName = ([string]$entry.FullName).Replace('\\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.EndsWith('/')) { continue }
            if ($entryName.StartsWith('/') -or $entryName -match '^[A-Za-z]:/' -or
                $entryName -match '(^|/)\.\.?(/|$)') {
                throw "INVALID|$Context contains an unsafe archive entry '$entryName'."
            }
            $relative = $entryName
            if (-not [string]::IsNullOrEmpty($ArchivePrefix)) {
                $prefix = $ArchivePrefix.TrimEnd('/') + '/'
                if (-not $relative.StartsWith($prefix, [StringComparison]::Ordinal)) {
                    throw "INVALID|$Context archive entry '$entryName' is outside the signed archive prefix."
                }
                $relative = $relative.Substring($prefix.Length)
            }
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            Assert-StandardValidationSafeRelativePath -Value $relative -Context "$Context archive path"
            if (-not $paths.Add($relative)) { throw "INVALID|$Context contains duplicate archive path '$relative'." }
            $unixMode = ([int64]$entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000) { throw "INVALID|$Context contains a symbolic-link archive entry '$entryName'." }
        }
        try { [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $ExtractionRoot) }
        catch { throw "INVALID|$Context could not be safely extracted: $($_.Exception.Message)" }
    }
    finally { if ($null -ne $archive) { $archive.Dispose() } }
    $contentRoot = if ([string]::IsNullOrEmpty($ArchivePrefix)) { $ExtractionRoot } else { Join-Path $ExtractionRoot $ArchivePrefix }
    if (-not (Test-Path -LiteralPath $contentRoot -PathType Container)) { throw "INVALID|$Context signed archive prefix is missing after extraction." }
    return [pscustomobject][ordered]@{
        root = $contentRoot
        inventory = @(Get-StandardValidationInventory -Root $contentRoot -Context "$Context extracted archive")
    }
}

function Assert-StandardValidationCandidateAcquisition {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $CandidateArchivePath,
        [Parameter(Mandatory = $true)][string] $CandidateAcquisitionEvidencePath,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $StagingRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSourceRepository,
        [Parameter(Mandatory = $true)][string] $ExpectedSourceRevision,
        [Parameter(Mandatory = $true)][string] $ExpectedBaseRevision,
        [Parameter(Mandatory = $true)][string] $ExpectedEventName,
        [Parameter(Mandatory = $true)][string] $CandidateArchiveSha256,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $archiveFull = Get-StandardValidationFullPath -Path $CandidateArchivePath -Context "$Context archive"
    $evidenceFull = Get-StandardValidationFullPath -Path $CandidateAcquisitionEvidencePath -Context "$Context evidence"
    Assert-StandardValidationOutsideRoot -Path $archiveFull -Root $CandidateRoot -Context "$Context archive"
    Assert-StandardValidationOutsideRoot -Path $archiveFull -Root $ArtifactsRoot -Context "$Context archive"
    Assert-StandardValidationOutsideRoot -Path $evidenceFull -Root $CandidateRoot -Context "$Context evidence"
    Assert-StandardValidationOutsideRoot -Path $evidenceFull -Root $ArtifactsRoot -Context "$Context evidence"
    Assert-StandardValidationRegularFile -Path $evidenceFull -Context "$Context evidence"
    $receipt = Get-StandardValidationJson -Path $evidenceFull -Context $Context
    Assert-StandardValidationExactPropertySet -Object $receipt -Expected @('schemaVersion', 'evidenceType', 'status', 'sourceRepository', 'sourceRevision', 'baseRevision', 'eventName', 'archiveUrl', 'archivePrefix', 'archiveSha256', 'contentSha256', 'signature') -Context $Context
    if ($receipt.schemaVersion -ne 1 -or [string]$receipt.evidenceType -cne 'candidate-acquisition' -or [string]$receipt.status -cne 'acquired') {
        throw "BLOCKED|$Context is not a successful candidate acquisition receipt."
    }
    foreach ($pair in @(
        @{ Name = 'sourceRepository'; Value = $ExpectedSourceRepository },
        @{ Name = 'sourceRevision'; Value = $ExpectedSourceRevision },
        @{ Name = 'baseRevision'; Value = $ExpectedBaseRevision },
        @{ Name = 'eventName'; Value = $ExpectedEventName }
    )) {
        if ([string]$receipt.($pair.Name) -cne [string]$pair.Value) { throw "BLOCKED|$Context is bound to a different $($pair.Name)." }
    }
    Assert-StandardValidationSourceRepository -Value ([string]$receipt.sourceRepository)
    Assert-StandardValidationRevision -Value ([string]$receipt.sourceRevision) -Context "$Context sourceRevision"
    Assert-StandardValidationRevision -Value ([string]$receipt.baseRevision) -Context "$Context baseRevision"
    Assert-StandardValidationArchivePrefix -Value ([string]$receipt.archivePrefix) -Context "$Context archivePrefix"
    Assert-StandardValidationSha256 -Value $receipt.archiveSha256 -Context "$Context archiveSha256"
    Assert-StandardValidationSha256 -Value $receipt.contentSha256 -Context "$Context contentSha256"
    Assert-StandardValidationSha256 -Value $CandidateArchiveSha256 -Context 'CandidateArchiveSha256'
    if ([string]$receipt.archiveSha256 -cne $CandidateArchiveSha256) { throw "BLOCKED|$Context archive hash does not match the invocation." }
    if ($receipt.archivePrefix -isnot [string] -or $receipt.archiveUrl -isnot [string]) { throw "BLOCKED|$Context archivePrefix and archiveUrl must be explicit strings." }
    Assert-StandardValidationImmutableArchiveUrl -SourceRepository ([string]$receipt.sourceRepository) -SourceRevision ([string]$receipt.sourceRevision) -ArchiveUrl ([string]$receipt.archiveUrl) -Context $Context
    $archiveHash = Get-StandardValidationFileSha256 -Path $archiveFull -Context "$Context archive"
    if ($archiveHash -cne [string]$receipt.archiveSha256) { throw "FAILED|$Context acquired archive hash changed or was not provider-verified." }
    $payloadFields = @{
        archivePrefix = [string]$receipt.archivePrefix; archiveSha256 = [string]$receipt.archiveSha256; archiveUrl = [string]$receipt.archiveUrl
        baseRevision = [string]$receipt.baseRevision; contentSha256 = [string]$receipt.contentSha256; eventName = [string]$receipt.eventName
        sourceRepository = [string]$receipt.sourceRepository; sourceRevision = [string]$receipt.sourceRevision
    }
    Assert-StandardValidationSignedReceipt -Receipt $receipt -ReceiptType 'candidate-acquisition-v1' -Fields $payloadFields -TrustAnchorRoot $TrustAnchorRoot -Context $Context
    $archiveResult = Get-StandardValidationArchiveInventory -ArchivePath $archiveFull -ExtractionRoot $StagingRoot -ArchivePrefix ([string]$receipt.archivePrefix) -Context $Context
    $candidateInventory = Get-StandardValidationInventory -Root $CandidateRoot -Context 'candidate acquisition target'
    $archiveContentSha256 = Get-StandardValidationInventorySha256 -Inventory $archiveResult.inventory
    $candidateContentSha256 = Get-StandardValidationInventorySha256 -Inventory $candidateInventory
    if ($archiveContentSha256 -cne [string]$receipt.contentSha256 -or $candidateContentSha256 -cne [string]$receipt.contentSha256 -or
        $archiveContentSha256 -cne $candidateContentSha256) {
        throw 'BLOCKED|Candidate root does not match the signed provider-acquired archive tree.'
    }
    return [pscustomobject][ordered]@{
        verified = $true; status = 'verified'; evidencePath = $evidenceFull; evidenceSha256 = Get-StandardValidationFileSha256 -Path $evidenceFull -Context "$Context evidence"
        archivePath = $archiveFull; archiveUrl = [string]$receipt.archiveUrl; archiveSha256 = [string]$receipt.archiveSha256
        sourceRepository = [string]$receipt.sourceRepository; sourceRevision = [string]$receipt.sourceRevision; baseRevision = [string]$receipt.baseRevision; eventName = [string]$receipt.eventName
        contentSha256 = [string]$receipt.contentSha256; archivePrefix = [string]$receipt.archivePrefix
    }
}

function Assert-StandardValidationAuthoritySnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $AuthorityRevision,
        [Parameter(Mandatory = $true)][string] $AuthorityArchivePath,
        [Parameter(Mandatory = $true)][string] $AuthoritySnapshotEvidencePath,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $StagingRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-StandardValidationRevision -Value $AuthorityRevision -Context 'AuthorityRevision'
    $archiveFull = Get-StandardValidationFullPath -Path $AuthorityArchivePath -Context "$Context archive"
    $evidenceFull = Get-StandardValidationFullPath -Path $AuthoritySnapshotEvidencePath -Context "$Context evidence"
    foreach ($path in @($archiveFull, $evidenceFull)) {
        Assert-StandardValidationOutsideRoot -Path $path -Root $RepositoryRoot -Context "$Context external artifact"
        Assert-StandardValidationOutsideRoot -Path $path -Root $ArtifactsRoot -Context "$Context external artifact"
    }
    Assert-StandardValidationRegularFile -Path $evidenceFull -Context "$Context evidence"
    $receipt = Get-StandardValidationJson -Path $evidenceFull -Context $Context
    Assert-StandardValidationExactPropertySet -Object $receipt -Expected @('schemaVersion', 'evidenceType', 'status', 'repository', 'revision', 'archiveUrl', 'archivePrefix', 'archiveSha256', 'snapshotInventorySha256', 'selectedFiles', 'signature') -Context $Context
    if ($receipt.schemaVersion -ne 1 -or [string]$receipt.evidenceType -cne 'authority-snapshot' -or [string]$receipt.status -cne 'acquired') {
        throw "BLOCKED|$Context is not a successful authority snapshot receipt."
    }
    if ([string]$receipt.repository -cne $script:StandardValidationAuthorityRepository -or [string]$receipt.revision -cne $AuthorityRevision) {
        throw "BLOCKED|$Context is not bound to the fixed central authority revision."
    }
    if ([string]$receipt.archiveUrl -notmatch ("^https://(?:github\\.com/SyuanTsai/SyuanTsai-AI-Instructions/archive/{0}\\.zip|codeload\\.github\\.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/{0})$" -f [regex]::Escape($AuthorityRevision))) {
        throw "BLOCKED|$Context archive URL is not an immutable central-authority URL."
    }
    if ($receipt.archivePrefix -isnot [string]) { throw "BLOCKED|$Context archivePrefix must be an explicit string." }
    Assert-StandardValidationArchivePrefix -Value ([string]$receipt.archivePrefix) -Context "$Context archivePrefix"
    Assert-StandardValidationSha256 -Value $receipt.archiveSha256 -Context "$Context archiveSha256"
    Assert-StandardValidationSha256 -Value $receipt.snapshotInventorySha256 -Context "$Context snapshotInventorySha256"
    $expectedFiles = @(
        'scripts/Invoke-StandardValidation.ps1',
        'docs/standards/standard-validation-contract-v1.json',
        'docs/standards/validation-security-gate.json',
        'scripts/Invoke-StandardAuthorityGate.ps1',
        'scripts/Resolve-StandardValidationTool.ps1',
        'docs/standards/trust-anchors/trusted-supervisor-public-key.xml',
        'docs/standards/trust-anchors/human-approval-public-key.xml'
    )
    if ($receipt.selectedFiles -isnot [array] -or @($receipt.selectedFiles).Count -ne $expectedFiles.Count) { throw "BLOCKED|$Context selected file inventory is incomplete." }
    $selected = @()
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        $entry = $receipt.selectedFiles[$index]
        Assert-StandardValidationExactPropertySet -Object $entry -Expected @('path', 'sha256') -Context "$Context selected file $($index + 1)"
        if ([string]$entry.path -cne $expectedFiles[$index]) { throw "BLOCKED|$Context selected file order or path is not canonical." }
        Assert-StandardValidationSha256 -Value $entry.sha256 -Context "$Context selected file $($entry.path)"
        $selected += [pscustomobject][ordered]@{ path = [string]$entry.path; sha256 = [string]$entry.sha256 }
    }
    if ((Get-StandardValidationSelectedFilesSha256 -Files $selected) -cne [string]$receipt.snapshotInventorySha256) { throw "BLOCKED|$Context selected file inventory is not self-consistent." }
    $payloadFields = @{
        archivePrefix = [string]$receipt.archivePrefix; archiveSha256 = [string]$receipt.archiveSha256; archiveUrl = [string]$receipt.archiveUrl
        repository = [string]$receipt.repository; revision = [string]$receipt.revision; selectedFilesSha256 = [string]$receipt.snapshotInventorySha256
    }
    Assert-StandardValidationSignedReceipt -Receipt $receipt -ReceiptType 'authority-snapshot-v1' -Fields $payloadFields -TrustAnchorRoot $TrustAnchorRoot -Context $Context
    $archiveHash = Get-StandardValidationFileSha256 -Path $archiveFull -Context "$Context archive"
    if ($archiveHash -cne [string]$receipt.archiveSha256) { throw "FAILED|$Context authority archive hash changed or was not provider-verified." }
    $archiveResult = Get-StandardValidationArchiveInventory -ArchivePath $archiveFull -ExtractionRoot $StagingRoot -ArchivePrefix ([string]$receipt.archivePrefix) -Context $Context
    foreach ($entry in $selected) {
        $currentPath = Join-Path $RepositoryRoot $entry.path
        Assert-StandardValidationRegularFile -Path $currentPath -Context "$Context current selected file"
        if ((Get-StandardValidationFileSha256 -Path $currentPath -Context "$Context current selected file") -cne $entry.sha256) {
            throw "FAILED|$Context current authority file changed: $($entry.path)"
        }
        $archivePath = Join-Path $archiveResult.root $entry.path
        if ((Get-StandardValidationFileSha256 -Path $archivePath -Context "$Context archive selected file") -cne $entry.sha256) {
            throw "BLOCKED|$Context archive selected file does not match the signed authority snapshot: $($entry.path)"
        }
    }
    return [pscustomobject][ordered]@{
        verified = $true; status = 'verified'; repository = [string]$receipt.repository; revision = [string]$receipt.revision
        archivePath = $archiveFull; archiveUrl = [string]$receipt.archiveUrl; archivePrefix = [string]$receipt.archivePrefix; archiveSha256 = [string]$receipt.archiveSha256
        snapshotEvidencePath = $evidenceFull; snapshotEvidenceSha256 = Get-StandardValidationFileSha256 -Path $evidenceFull -Context "$Context evidence"
        snapshotInventorySha256 = [string]$receipt.snapshotInventorySha256; selectedFiles = $selected
    }
}

function Assert-StandardValidationSafeRelativePath {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -match '\\' -or $Value -match '^[A-Za-z]:' -or $Value.StartsWith('/') -or
        $Value -match '(^|/)\.\.?(/|$)' -or
        $Value -notmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$') {
        throw "INVALID|$Context must be a safe repository-relative path."
    }
}

function Assert-StandardValidationNoReparsePoints {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Context)

    $rootItem = Get-Item -LiteralPath $Root -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "INVALID|$Context root must not be a reparse point."
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "INVALID|$Context contains a reparse point: $($item.FullName)"
        }
    }
}

function Get-StandardValidationInventory {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Context)

    Assert-StandardValidationNoReparsePoints -Root $Root -Context $Context
    $fullRoot = (Get-StandardValidationFullPath -Path $Root -Context $Context).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $entries = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($fullRoot.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ).Replace([System.IO.Path]::DirectorySeparatorChar, '/').Replace([System.IO.Path]::AltDirectorySeparatorChar, '/')
        Assert-StandardValidationSafeRelativePath -Value $relative -Context "$Context inventory path"
        $entries += [pscustomobject][ordered]@{
            path = $relative
            sha256 = (Get-StandardValidationFileSha256 -Path $file.FullName -Context $Context)
            length = [int64]$file.Length
        }
    }
    if ($entries.Count -eq 0) { throw "INVALID|$Context must contain at least one file." }
    return ,$entries
}

function Get-StandardValidationInventorySha256 {
    param([Parameter(Mandatory = $true)] $Inventory)

    $ordered = @($Inventory | Sort-Object path)
    $canonical = ($ordered | ForEach-Object { "$($_.path)`t$($_.sha256)`t$($_.length)`n" }) -join ''
    return Get-StandardValidationTextSha256 -Value $canonical
}

function Copy-StandardValidationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force -ErrorAction Stop
    }
}

function Assert-StandardValidationCandidateUnchanged {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedContentSha256,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ExpectedAdapterSha256
    )

    $currentInventory = Get-StandardValidationInventory -Root $CandidateRoot -Context 'candidate revalidation'
    $currentContentSha256 = Get-StandardValidationInventorySha256 -Inventory $currentInventory
    if ($currentContentSha256 -cne $ExpectedContentSha256) {
        throw 'FAILED|Candidate content changed during validation.'
    }
    $currentAdapterSha256 = Get-StandardValidationFileSha256 -Path $AdapterPath -Context 'adapter revalidation'
    if ($currentAdapterSha256 -cne $ExpectedAdapterSha256) {
        throw 'FAILED|Adapter configuration changed during validation.'
    }
}

function Assert-StandardValidationSnapshotUnchanged {
    param(
        [Parameter(Mandatory = $true)][string] $SnapshotRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSnapshotContentSha256
    )

    $currentInventory = Get-StandardValidationInventory -Root $SnapshotRoot -Context 'candidate snapshot revalidation'
    $currentContentSha256 = Get-StandardValidationInventorySha256 -Inventory $currentInventory
    if ($currentContentSha256 -cne $ExpectedSnapshotContentSha256) {
        throw 'FAILED|Candidate snapshot changed during validation.'
    }
}

function Assert-StandardValidationCommandSpec {
    param(
        [Parameter(Mandatory = $true)] $Spec,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][bool] $DevelopmentHarness
    )

    Assert-StandardValidationExactPropertySet -Object $Spec -Expected @('command', 'arguments') -Context $Context
    $command = Get-StandardValidationRequiredProperty -Object $Spec -Name 'command' -Context $Context
    if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$command)) {
        throw "INVALID|$Context command must be a non-empty path."
    }
    $commandPath = Get-StandardValidationFullPath -Path ([string]$command) -Context "$Context command"
    if (-not [System.IO.Path]::IsPathRooted([string]$command)) {
        throw "INVALID|$Context command must be an absolute path resolved by the trusted supervisor."
    }
    if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
        throw "INVALID|$Context command is not an installed file: $commandPath"
    }
    $commandItem = Get-Item -Force -LiteralPath $commandPath -ErrorAction Stop
    if (($commandItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "INVALID|$Context command must not be a reparse point: $commandPath"
    }
    Assert-StandardValidationOutsideRoot -Path $commandPath -Root $CandidateRoot -Context "$Context command"
    $arguments = Get-StandardValidationRequiredProperty -Object $Spec -Name 'arguments' -Context $Context
    if ($arguments -isnot [array]) { throw "INVALID|$Context arguments must be an array." }
    foreach ($argument in @($arguments)) {
        if ($argument -isnot [string]) { throw "INVALID|$Context arguments must contain only strings." }
        if ([string]$argument -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "INVALID|$Context arguments may not contain parent-directory traversal."
        }
        if ([System.IO.Path]::IsPathRooted([string]$argument) -and
            (Test-StandardValidationPathWithin -Path ([string]$argument) -Root $CandidateRoot -IncludeRoot)) {
            throw "INVALID|$Context argument reaches into the candidate root."
        }
    }
    $commandName = [System.IO.Path]::GetFileName($commandPath).ToLowerInvariant()
    $genericInterpreterNames = @(
        'pwsh', 'pwsh.exe', 'powershell', 'powershell.exe',
        'bash', 'bash.exe', 'sh', 'sh.exe', 'cmd', 'cmd.exe',
        'node', 'node.exe', 'nodejs', 'nodejs.exe',
        'python', 'python.exe', 'python3', 'python3.exe',
        'perl', 'perl.exe', 'ruby', 'ruby.exe', 'php', 'php.exe'
    )
    if ($commandName -in $genericInterpreterNames) {
        if (@($arguments | Where-Object { [string]$_ -in @('-Command', '-EncodedCommand', '/c', '-c') }).Count -gt 0) {
            throw "INVALID|$Context may not use an inline command interpreter before the central barriers."
        }
        if (-not $DevelopmentHarness) {
            throw "INVALID|$Context production adapters may not use a generic interpreter; provide a directly executable trusted tool."
        }
    }
    if (-not $DevelopmentHarness -and [System.IO.Path]::GetExtension($commandPath).ToLowerInvariant() -in @(
            '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.cmd', '.bat', '.py', '.pyc', '.js', '.mjs', '.cjs',
            '.pl', '.rb', '.php'
        )) {
        throw "INVALID|$Context production adapters may not execute a script payload as the command."
    }
    if (-not $DevelopmentHarness) {
        $allowedRoots = @($TrustedToolRoot, $ArtifactsRoot, $PSScriptRoot, $PSHOME)
        $allowed = $false
        foreach ($allowedRoot in $allowedRoots) {
            if (Test-StandardValidationPathWithin -Path $commandPath -Root $allowedRoot -IncludeRoot) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) { throw "INVALID|$Context command is outside the trusted tool roots." }
    }
    return [pscustomobject][ordered]@{
        command = $commandPath
        arguments = @($arguments | ForEach-Object { [string]$_ })
        commandSha256 = Get-StandardValidationFileSha256 -Path $commandPath -Context "$Context command"
    }
}

function Get-StandardValidationSkillSet {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $SkillsRootRelative,
        [Parameter(Mandatory = $true)] $DeclaredSkills
    )

    Assert-StandardValidationSafeRelativePath -Value $SkillsRootRelative -Context 'adapter skillsRoot'
    if ($DeclaredSkills -isnot [array] -or @($DeclaredSkills).Count -eq 0) {
        throw 'INVALID|adapter activeSkills must be a non-empty array.'
    }
    $declared = @()
    $declaredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($skill in @($DeclaredSkills)) {
        if ($skill -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$skill) -or
            [string]$skill -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            -not $declaredSet.Add([string]$skill)) {
            throw 'INVALID|adapter activeSkills must contain unique safe Skill IDs.'
        }
        $declared += [string]$skill
    }
    $skillsRoot = Get-StandardValidationFullPath -Path (Join-Path $CandidateRoot $SkillsRootRelative) -Context 'adapter skillsRoot'
    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
        throw "INVALID|adapter skillsRoot does not exist: $SkillsRootRelative"
    }
    Assert-StandardValidationNoReparsePoints -Root $skillsRoot -Context 'active Skill root'
    $discovered = @()
    $discoveredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($directory in @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | Sort-Object Name)) {
        if (-not $discoveredSet.Add([string]$directory.Name)) {
            throw "INVALID|active Skill IDs are duplicated: $($directory.Name)"
        }
        $skillMd = Join-Path $directory.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
            throw "INVALID|active Skill directory '$($directory.Name)' has no SKILL.md."
        }
        if ([string]$directory.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "INVALID|active Skill directory '$($directory.Name)' has an unsafe ID."
        }
        $discovered += [string]$directory.Name
    }
    $declaredSorted = @($declared | Sort-Object)
    $discoveredSorted = @($discovered | Sort-Object)
    if (($declaredSorted -join "`n") -cne ($discoveredSorted -join "`n")) {
        throw "INVALID|adapter activeSkills does not exactly match the discovered active Skill set. Declared='$($declaredSorted -join ',')' Discovered='$($discoveredSorted -join ',')'."
    }
    $records = @()
    foreach ($skillId in $discoveredSorted) {
        $root = Join-Path $skillsRoot $skillId
        $inventory = Get-StandardValidationInventory -Root $root -Context "Skill '$skillId'"
        $records += [pscustomobject][ordered]@{
            id = $skillId
            root = $root
            inventory = $inventory
            inventorySha256 = Get-StandardValidationInventorySha256 -Inventory $inventory
        }
    }
    return [pscustomobject][ordered]@{
        root = $skillsRoot
        relative = $SkillsRootRelative
        ids = $discoveredSorted
        records = $records
    }
}

function Assert-StandardValidationAdapter {
    param(
        [Parameter(Mandatory = $true)] $Adapter,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][bool] $DevelopmentHarness
    )

    Assert-StandardValidationExactPropertySet -Object $Adapter -Expected @(
        'schemaVersion', 'adapter', 'mode', 'skillsRoot', 'activeSkills',
        'canonicalValidatorPath', 'packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer', 'repositoryTests'
    ) -Context 'standard validation adapter'
    if ((Get-StandardValidationRequiredProperty -Object $Adapter -Name 'schemaVersion' -Context 'adapter') -ne 1 -or
        [string](Get-StandardValidationRequiredProperty -Object $Adapter -Name 'adapter' -Context 'adapter') -cne 'standard-validation-adapter-v1') {
        throw 'INVALID|adapter has an unsupported schema identity.'
    }
    $mode = Get-StandardValidationRequiredProperty -Object $Adapter -Name 'mode' -Context 'adapter'
    if ($mode -notin @('production', 'development-harness') -or
        ($DevelopmentHarness -and [string]$mode -cne 'development-harness') -or
        (-not $DevelopmentHarness -and [string]$mode -cne 'production')) {
        throw 'INVALID|adapter mode does not match the selected supervisor mode.'
    }
    $canonicalValidatorPath = [string](Get-StandardValidationRequiredProperty -Object $Adapter -Name 'canonicalValidatorPath' -Context 'adapter canonicalValidatorPath')
    Assert-StandardValidationSafeRelativePath -Value $canonicalValidatorPath -Context 'adapter canonicalValidatorPath'
    $canonicalValidatorFullPath = Get-StandardValidationFullPath -Path (Join-Path $CandidateRoot $canonicalValidatorPath) -Context 'adapter canonicalValidatorPath'
    if (-not (Test-Path -LiteralPath $canonicalValidatorFullPath -PathType Leaf)) {
        throw "INVALID|adapter canonicalValidatorPath does not identify a repository file: $canonicalValidatorPath"
    }
    $canonicalValidatorItem = Get-Item -Force -LiteralPath $canonicalValidatorFullPath -ErrorAction Stop
    if (($canonicalValidatorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'INVALID|adapter canonicalValidatorPath must not be a reparse point.'
    }
    $skills = Get-StandardValidationSkillSet `
        -CandidateRoot $CandidateRoot `
        -SkillsRootRelative ([string](Get-StandardValidationRequiredProperty -Object $Adapter -Name 'skillsRoot' -Context 'adapter')) `
        -DeclaredSkills (Get-StandardValidationRequiredProperty -Object $Adapter -Name 'activeSkills' -Context 'adapter')
    $commands = [ordered]@{}
    foreach ($name in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
        $commands[$name] = Assert-StandardValidationCommandSpec `
            -Spec (Get-StandardValidationRequiredProperty -Object $Adapter -Name $name -Context "adapter $name") `
            -Context "adapter $name" `
            -CandidateRoot $CandidateRoot `
            -ArtifactsRoot $ArtifactsRoot `
            -TrustedToolRoot $TrustedToolRoot `
            -DevelopmentHarness $DevelopmentHarness
    }
    $repositoryTests = Get-StandardValidationRequiredProperty -Object $Adapter -Name 'repositoryTests' -Context 'adapter repositoryTests'
    if ($repositoryTests -isnot [array] -or @($repositoryTests).Count -eq 0) {
        throw 'INVALID|adapter repositoryTests must contain at least one test dispatch.'
    }
    $testIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $testCommands = @()
    foreach ($test in @($repositoryTests)) {
        Assert-StandardValidationExactPropertySet -Object $test -Expected @('id', 'command', 'arguments') -Context 'adapter repository test'
        $testId = Get-StandardValidationRequiredProperty -Object $test -Name 'id' -Context 'adapter repository test'
        if ($testId -isnot [string] -or [string]$testId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or -not $testIds.Add([string]$testId)) {
            throw 'INVALID|adapter repository test IDs must be unique safe values.'
        }
        $testCommand = Assert-StandardValidationCommandSpec `
            -Spec ([pscustomobject][ordered]@{ command = $test.command; arguments = $test.arguments }) `
            -Context "adapter repository test '$testId'" `
            -CandidateRoot $CandidateRoot `
            -ArtifactsRoot $ArtifactsRoot `
            -TrustedToolRoot $TrustedToolRoot `
            -DevelopmentHarness $DevelopmentHarness
        $testCommands += [pscustomobject][ordered]@{ id = [string]$testId; command = $testCommand }
    }
    return [pscustomobject][ordered]@{
        mode = [string]$mode
        canonicalValidatorPath = $canonicalValidatorPath
        skills = $skills
        commands = $commands
        repositoryTests = $testCommands
    }
}

function New-StandardValidationStages {
    $stages = @()
    foreach ($definition in $script:StandardValidationStageDefinitions) {
        $stages += [pscustomobject][ordered]@{
            order = [int]$definition.order
            id = [string]$definition.id
            condition = [string]$definition.condition
            status = 'not-run'
            startedAt = $null
            endedAt = $null
            reason = $null
            triggerDecision = $null
            events = @()
        }
    }
    return ,$stages
}

function Get-StandardValidationStage {
    param([Parameter(Mandatory = $true)] $Stages, [Parameter(Mandatory = $true)][string] $Id)
    return @($Stages | Where-Object { [string]$_.id -ceq $Id })[0]
}

function Start-StandardValidationStage {
    param([Parameter(Mandatory = $true)] $Stage)
    $Stage.startedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function Complete-StandardValidationStage {
    param(
        [Parameter(Mandatory = $true)] $Stage,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'blocked', 'cancelled', 'not-run', 'not-applicable')][string] $Status,
        [string] $Reason
    )
    $Stage.status = $Status
    $Stage.reason = $Reason
    $Stage.endedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function ConvertTo-StandardValidationProcessArguments {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $quoted = @()
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]' -and $argument.Length -gt 0) {
            $quoted += $argument
            continue
        }
        $escaped = $argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $quoted += ('"' + $escaped + '"')
    }
    return ($quoted -join ' ')
}

function Get-StandardValidationDescendantProcessIds {
    param([Parameter(Mandatory = $true)][int] $RootProcessId)

    $relations = @()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $relations = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ ProcessId = [int]$_.ProcessId; ParentProcessId = [int]$_.ParentProcessId }
                })
        }
        catch { $relations = @() }
    }
    elseif (Test-Path -LiteralPath '/proc' -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction SilentlyContinue)) {
            if ($directory.Name -notmatch '^[0-9]+$') { continue }
            $statPath = Join-Path $directory.FullName 'stat'
            try {
                $stat = [IO.File]::ReadAllText($statPath)
                if ($stat -match '^\s*(?<pid>[0-9]+)\s+\(.*\)\s+\S\s+(?<ppid>[0-9]+)\s+') {
                    $relations += [pscustomobject]@{ ProcessId = [int]$Matches.pid; ParentProcessId = [int]$Matches.ppid }
                }
            }
            catch { }
        }
    }
    $childrenByParent = @{}
    foreach ($relation in @($relations)) {
        $parent = [int]$relation.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parent)) { $childrenByParent[$parent] = New-Object 'System.Collections.Generic.List[int]' }
        [void]$childrenByParent[$parent].Add([int]$relation.ProcessId)
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $pending = New-Object 'System.Collections.Generic.Queue[int]'
    [void]$pending.Enqueue($RootProcessId)
    $result = New-Object 'System.Collections.Generic.List[int]'
    while ($pending.Count -gt 0) {
        $parent = $pending.Dequeue()
        if (-not $childrenByParent.ContainsKey($parent)) { continue }
        foreach ($child in @($childrenByParent[$parent])) {
            if ($child -eq $RootProcessId -or -not $seen.Add($child)) { continue }
            [void]$result.Add($child)
            [void]$pending.Enqueue($child)
        }
    }
    return @($result.ToArray())
}

function Stop-StandardValidationProcessTree {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [System.Diagnostics.Process] $RootProcess,
        [int[]] $KnownProcessIds = @(),
        [int] $ProcessGroupId = 0,
        [IntPtr] $JobHandle = [IntPtr]::Zero,
        [Parameter(Mandatory = $true)][int] $WaitMilliseconds
    )

    $known = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$known.Add($RootProcessId)
    foreach ($processId in @($KnownProcessIds)) { [void]$known.Add([int]$processId) }
    foreach ($processId in @(Get-StandardValidationDescendantProcessIds -RootProcessId $RootProcessId)) { [void]$known.Add([int]$processId) }
    $cleanupAttempted = $false
    if ($JobHandle -ne [IntPtr]::Zero) {
        try {
            if ([StandardValidationProcessControlNative]::TryTerminateJobObject($JobHandle, 1)) {
                $cleanupAttempted = $true
            }
        }
        catch { }
    }
    if ($ProcessGroupId -gt 0) {
        try {
            if ([StandardValidationProcessControlNative]::TryKillProcessGroup($ProcessGroupId, 9)) {
                $cleanupAttempted = $true
            }
        }
        catch { }
    }
    try {
        if ($null -ne $RootProcess) {
            try {
                if (-not $RootProcess.HasExited) {
                    $RootProcess.Kill($true)
                    $cleanupAttempted = $true
                }
            }
            catch {
                try { if (-not $RootProcess.HasExited) { $RootProcess.Kill(); $cleanupAttempted = $true } } catch { }
            }
        }
    }
    catch { }
    foreach ($processId in @($known | Where-Object { $_ -ne $RootProcessId } | Sort-Object -Descending)) {
        try {
            $child = [System.Diagnostics.Process]::GetProcessById([int]$processId)
            try { $child.Kill(); $cleanupAttempted = $true } finally { $child.Dispose() }
        }
        catch { }
    }
    if ($null -ne $RootProcess) { try { [void]$RootProcess.WaitForExit([Math]::Max(0, $WaitMilliseconds)) } catch { } }
    $deadline = (Get-Date).AddMilliseconds([Math]::Max(0, $WaitMilliseconds))
    do {
        $remaining = @(Get-StandardValidationDescendantProcessIds -RootProcessId $RootProcessId)
        foreach ($processId in $remaining) {
            try {
                $child = [System.Diagnostics.Process]::GetProcessById([int]$processId)
                try { $child.Kill(); $cleanupAttempted = $true } finally { $child.Dispose() }
            }
            catch { }
        }
        $rootAlive = $false
        if ($null -ne $RootProcess) { try { $rootAlive = -not $RootProcess.HasExited } catch { } }
        $processGroupAlive = $false
        if ($ProcessGroupId -gt 0) {
            try { $processGroupAlive = [StandardValidationProcessControlNative]::IsProcessGroupAlive($ProcessGroupId) }
            catch { $processGroupAlive = $true }
        }
        if (-not $rootAlive -and $remaining.Count -eq 0 -and -not $processGroupAlive) { return $true }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 50
    } while ($true)
    $remaining = @(Get-StandardValidationDescendantProcessIds -RootProcessId $RootProcessId)
    $rootAlive = $false
    if ($null -ne $RootProcess) { try { $rootAlive = -not $RootProcess.HasExited } catch { } }
    $processGroupAlive = $false
    if ($ProcessGroupId -gt 0) {
        try { $processGroupAlive = [StandardValidationProcessControlNative]::IsProcessGroupAlive($ProcessGroupId) }
        catch { $processGroupAlive = $true }
    }
    return (-not $rootAlive -and $remaining.Count -eq 0 -and -not $processGroupAlive)
}

function Get-StandardValidationUnixProcessGroupLauncher {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return $null }
    foreach ($candidate in @('/usr/bin/setsid', '/bin/setsid')) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $item = Get-Item -Force -LiteralPath $candidate -ErrorAction Stop
            if (-not $item.PSIsContainer -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                return [string]$item.FullName
            }
        }
    }
    return $null
}

function Get-StandardValidationWindowsBootstrapHost {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    $hostName = if ([string]$PSVersionTable.PSEdition -ceq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    if ([string]::IsNullOrWhiteSpace([string]$PSHOME)) {
        throw 'The current PowerShell host path is unavailable for owned Windows process bootstrap.'
    }
    $hostPath = Get-StandardValidationFullPath -Path (Join-Path $PSHOME $hostName) -Context 'Windows process bootstrap host'
    Assert-StandardValidationRegularFile -Path $hostPath -Context 'Windows process bootstrap host'
    return $hostPath
}

function Get-StandardValidationWindowsBootstrapCode {
    return @'
$ErrorActionPreference = 'Stop'
$targetCommand = [string]$env:STANDARD_VALIDATION_BOOTSTRAP_COMMAND
$argumentJson = [string]$env:STANDARD_VALIDATION_BOOTSTRAP_ARGUMENTS
$releasePath = [string]$env:STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH
if ([string]::IsNullOrWhiteSpace($targetCommand) -or [string]::IsNullOrWhiteSpace($releasePath)) {
    throw 'Owned Windows process bootstrap received incomplete target metadata.'
}
$targetArguments = @()
if (-not [string]::IsNullOrWhiteSpace($argumentJson)) {
    $parsedArguments = ConvertFrom-Json -InputObject $argumentJson
    if ($null -ne $parsedArguments) {
        foreach ($item in @($parsedArguments)) {
            if ($item -isnot [string]) { throw 'Owned Windows process bootstrap arguments must be strings.' }
            $targetArguments += [string]$item
        }
    }
}
while (-not [IO.File]::Exists($releasePath)) { Start-Sleep -Milliseconds 10 }
& $targetCommand @targetArguments
if ($null -eq $LASTEXITCODE) { exit 0 }
exit ([int]$LASTEXITCODE)
'@
}

function Get-StandardValidationChildEnvironment {
    param([Parameter(Mandatory = $true)][hashtable] $Environment)

    # ProcessStartInfo starts with the supervisor's entire environment. Clear it
    # and copy only the small OS/runtime surface required to launch a trusted
    # tool, plus the runner's explicitly namespaced variables. In particular,
    # credentials and transport/configuration variables are never inherited by
    # candidate-controlled child code.
    $safeInheritedNames = @(
        'PATH', 'Path', 'PATHEXT', 'COMSPEC', 'SYSTEMROOT', 'WINDIR', 'OS',
        'TEMP', 'TMP', 'TMPDIR', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_IDENTIFIER', 'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)',
        'PROGRAMW6432', 'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)',
        'COMMONPROGRAMW6432', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'HOME',
        'APPDATA', 'LOCALAPPDATA', 'LANG', 'LC_ALL', 'LC_CTYPE', 'DOTNET_ROOT',
        'DOTNET_ROOT_X64', 'LD_LIBRARY_PATH', 'XDG_RUNTIME_DIR', 'PSExecutionPolicyPreference'
    )
    $childEnvironment = [ordered]@{}
    foreach ($name in $safeInheritedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $childEnvironment[$name] = [string]$value }
    }
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name -match '^STANDARD_VALIDATION_[A-Za-z0-9_]+$') {
            $childEnvironment[$name] = [string]$entry.Value
        }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name -notmatch '^STANDARD_VALIDATION_[A-Za-z0-9_]+$') {
            throw "INVALID|Validation child environment key '$name' is outside the runner namespace."
        }
        $childEnvironment[$name] = [string]$entry.Value
    }
    return $childEnvironment
}

function Invoke-StandardValidationProcess {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][hashtable] $Environment,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [string] $CancellationPath
    )

    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    $status = 'failed'
    $exitCode = -1
    $stdout = ''
    $stderr = ''
    $cleanedUp = $true
    $process = $null
    $rootProcessId = $null
    $jobHandle = [IntPtr]::Zero
    $jobClosed = $true
    $processGroupId = 0
    $processGroupLaunch = $false
    $windowsBootstrapLaunch = $false
    $windowsBootstrapReleasePath = $null
    $observedProcessIds = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
            return [pscustomobject][ordered]@{
                startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                status = 'cancelled'; stdout = ''; stderr = 'Cancellation requested before process start.'; cleanedUp = $true
            }
        }
        $launchCommand = $Command
        $launchArguments = @($Arguments)
        $launchEnvironment = @{}
        foreach ($entry in $Environment.GetEnumerator()) { $launchEnvironment[[string]$entry.Key] = [string]$entry.Value }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            try {
                $jobHandle = [StandardValidationProcessControlNative]::CreateKillOnCloseJob()
                $jobClosed = $false
                $bootstrapHost = Get-StandardValidationWindowsBootstrapHost
                $windowsBootstrapReleasePath = Join-Path $WorkingDirectory ("process-bootstrap-{0}.signal" -f ([guid]::NewGuid().ToString('N')))
                if (Test-Path -LiteralPath $windowsBootstrapReleasePath) {
                    throw 'The owned Windows process bootstrap signal path already exists.'
                }
                $launchEnvironment.STANDARD_VALIDATION_BOOTSTRAP_COMMAND = $Command
                $launchEnvironment.STANDARD_VALIDATION_BOOTSTRAP_ARGUMENTS = if (@($Arguments).Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject ([string[]]$Arguments) -Compress }
                $launchEnvironment.STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH = $windowsBootstrapReleasePath
                $bootstrapCode = Get-StandardValidationWindowsBootstrapCode
                $encodedBootstrapCode = [Convert]::ToBase64String(([Text.Encoding]::Unicode).GetBytes($bootstrapCode))
                $launchCommand = $bootstrapHost
                $launchArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedBootstrapCode)
                $windowsBootstrapLaunch = $true
            }
            catch {
                return [pscustomobject][ordered]@{
                    startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                    status = 'startup-failed'; stdout = ''; stderr = "Could not create an owned Windows job object: $($_.Exception.Message)"; cleanedUp = $true
                }
            }
        }
        elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
            $unixLauncher = Get-StandardValidationUnixProcessGroupLauncher
            if ([string]::IsNullOrWhiteSpace([string]$unixLauncher)) {
                return [pscustomobject][ordered]@{
                    startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                    status = 'startup-failed'; stdout = ''; stderr = 'No trusted setsid launcher is available for an owned Unix process group.'; cleanedUp = $true
                }
            }
            $launchCommand = [string]$unixLauncher
            $launchArguments = @($Command) + @($Arguments)
            $processGroupLaunch = $true
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $launchCommand
        $startInfo.Arguments = ConvertTo-StandardValidationProcessArguments -Arguments $launchArguments
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables.Clear()
        foreach ($entry in (Get-StandardValidationChildEnvironment -Environment $launchEnvironment).GetEnumerator()) {
            $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
        }
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                return [pscustomobject][ordered]@{
                    startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                    status = 'startup-failed'; stdout = ''; stderr = 'Process.Start returned false.'; cleanedUp = $true
                }
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                startedAt = $startedAt; endedAt = (Get-Date).ToUniversalTime().ToString('o'); exitCode = -1
                status = 'startup-failed'; stdout = ''; stderr = $_.Exception.Message; cleanedUp = $true
            }
        }
        $rootProcessId = [int]$process.Id
        $protectionSetupFailed = $false
        $terminationStatus = $null
        if ($jobHandle -ne [IntPtr]::Zero) {
            try {
                if (-not [StandardValidationProcessControlNative]::TryAssignProcessToJobObject($jobHandle, $process.Handle)) {
                    throw 'AssignProcessToJobObject returned false.'
                }
            }
            catch {
                $protectionSetupFailed = $true
                $terminationStatus = 'startup-failed'
                $stderr = "Could not assign the validator to the owned Windows job object: $($_.Exception.Message)"
                $cleanedUp = Stop-StandardValidationProcessTree `
                    -RootProcessId $rootProcessId `
                    -RootProcess $process `
                    -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) `
                    -JobHandle $jobHandle `
                    -WaitMilliseconds 5000
            }
            if (-not $protectionSetupFailed -and $windowsBootstrapLaunch) {
                try {
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
                catch {
                    $protectionSetupFailed = $true
                    $terminationStatus = 'startup-failed'
                    $stderr = "Could not release the owned Windows process bootstrap: $($_.Exception.Message)"
                    $cleanedUp = Stop-StandardValidationProcessTree `
                        -RootProcessId $rootProcessId `
                        -RootProcess $process `
                        -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) `
                        -JobHandle $jobHandle `
                        -WaitMilliseconds 5000
                }
            }
        }
        elseif ($processGroupLaunch) {
            try {
                $processGroupId = [StandardValidationProcessControlNative]::GetProcessGroupId($rootProcessId)
                if ($processGroupId -ne $rootProcessId) {
                    throw "setsid did not create a process group owned by PID $rootProcessId (actual group $processGroupId)."
                }
            }
            catch {
                $alreadyExited = $false
                try { $alreadyExited = [bool]$process.HasExited } catch { }
                if (-not $alreadyExited) {
                    $protectionSetupFailed = $true
                    $terminationStatus = 'startup-failed'
                    $stderr = "Could not establish the owned Unix process group: $($_.Exception.Message)"
                    $cleanedUp = Stop-StandardValidationProcessTree `
                        -RootProcessId $rootProcessId `
                        -RootProcess $process `
                        -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) `
                        -ProcessGroupId $processGroupId `
                        -WaitMilliseconds 5000
                }
                else {
                    $processGroupId = 0
                }
            }
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
        while (-not $protectionSetupFailed -and -not $process.HasExited) {
            foreach ($childPid in @(Get-StandardValidationDescendantProcessIds -RootProcessId $rootProcessId)) { [void]$observedProcessIds.Add([int]$childPid) }
            if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
                $terminationStatus = 'cancelled'
                [void](Stop-StandardValidationProcessTree -RootProcessId $rootProcessId -RootProcess $process -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) -ProcessGroupId $processGroupId -JobHandle $jobHandle -WaitMilliseconds 5000)
                break
            }
            if ((Get-Date) -gt $deadline) {
                $terminationStatus = 'timeout'
                [void](Stop-StandardValidationProcessTree -RootProcessId $rootProcessId -RootProcess $process -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) -ProcessGroupId $processGroupId -JobHandle $jobHandle -WaitMilliseconds 5000)
                break
            }
            Start-Sleep -Milliseconds 50
        }
        if ($protectionSetupFailed) {
            # The failed protection setup was already terminated above; keep a
            # second cleanup pass to catch descendants spawned during startup.
            $cleanedUp = $cleanedUp -and (Stop-StandardValidationProcessTree -RootProcessId $rootProcessId -RootProcess $process -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) -ProcessGroupId $processGroupId -JobHandle $jobHandle -WaitMilliseconds 5000)
        }
        elseif ($null -ne $terminationStatus) {
            $cleanedUp = Stop-StandardValidationProcessTree -RootProcessId $rootProcessId -RootProcess $process -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) -ProcessGroupId $processGroupId -JobHandle $jobHandle -WaitMilliseconds 5000
        }
        else {
            $process.WaitForExit()
            $cleanedUp = Stop-StandardValidationProcessTree -RootProcessId $rootProcessId -RootProcess $process -KnownProcessIds @($observedProcessIds | ForEach-Object { [int]$_ }) -ProcessGroupId $processGroupId -JobHandle $jobHandle -WaitMilliseconds 1000
        }
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { $stdout = '' }
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = '' }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        if (-not $cleanedUp) {
            $status = 'cleanup-failed'
            if ([string]::IsNullOrWhiteSpace($stderr)) { $stderr = 'The owned validator process group or descendant process tree did not fully terminate.' }
        }
        elseif ($protectionSetupFailed) { $status = 'startup-failed' }
        elseif ($null -ne $terminationStatus) { $status = $terminationStatus }
        elseif ($exitCode -eq 0) { $status = 'passed' }
        else { $status = 'failed' }
    }
    finally {
        $jobHandleBeforeClose = $jobHandle
        if ($jobHandle -ne [IntPtr]::Zero) {
            try {
                $jobCloseResult = [StandardValidationProcessControlNative]::TryCloseHandle($jobHandle)
                $jobClosed = [bool]$jobCloseResult
                if (-not $jobClosed) { $stderr = "The owned Windows job object could not be closed safely (handle=$($jobHandle.ToInt64()))." }
            }
            catch { $jobClosed = $false; $stderr = "The owned Windows job object could not be closed safely: $($_.Exception.Message)" }
            $jobHandle = [IntPtr]::Zero
        }
        if ($null -ne $process) { $process.Dispose() }
        if (-not [string]::IsNullOrWhiteSpace([string]$windowsBootstrapReleasePath) -and
            [IO.File]::Exists($windowsBootstrapReleasePath)) {
            try { [IO.File]::Delete($windowsBootstrapReleasePath) }
            catch {
                $cleanedUp = $false
                $status = 'cleanup-failed'
                if ([string]::IsNullOrWhiteSpace($stderr)) { $stderr = "The owned Windows process bootstrap signal could not be removed: $($_.Exception.Message)" }
            }
        }
        if (-not $jobClosed) {
            $cleanedUp = $false
            $status = 'cleanup-failed'
            if ([string]::IsNullOrWhiteSpace($stderr)) { $stderr = "The owned Windows job object could not be closed safely (handle=$($jobHandleBeforeClose.ToInt64()))." }
        }
    }
    return [pscustomobject][ordered]@{
        startedAt = $startedAt
        endedAt = (Get-Date).ToUniversalTime().ToString('o')
        exitCode = [int]$exitCode
        status = [string]$status
        stdout = [string]$stdout
        stderr = [string]$stderr
        cleanedUp = [bool]$cleanedUp
    }
}

function New-StandardValidationOutputReservation {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = Get-StandardValidationFullPath -Path $Path -Context 'OutputPath'
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $token = 'standard-validation-output-reservation-v1:' + [guid]::NewGuid().ToString('N')
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($token + [Environment]::NewLine)
    try {
        $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        catch {
            $stream.Dispose()
            throw
        }
        return [pscustomobject][ordered]@{ path = $fullPath; token = $token; stream = $stream }
    }
    catch [System.IO.IOException] {
        throw 'INVALID|OutputPath could not be reserved exclusively; it already exists or was substituted concurrently.'
    }
}

function Assert-StandardValidationOutputReservation {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][string] $Token,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Stream.SafeFileHandle.IsClosed -or -not $Stream.CanRead -or -not $Stream.CanWrite) {
        throw "FAILED|$Context output reservation handle is no longer valid."
    }
    $tokenBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Token + [Environment]::NewLine)
    if ($Stream.Length -ne $tokenBytes.Length) {
        throw "FAILED|$Context output reservation was modified before finalization."
    }
    $position = $Stream.Position
    try {
        $Stream.Position = 0
        $actualBytes = New-Object byte[] $tokenBytes.Length
        $read = $Stream.Read($actualBytes, 0, $actualBytes.Length)
        if ($read -ne $tokenBytes.Length -or
            [Convert]::ToBase64String($actualBytes) -cne [Convert]::ToBase64String($tokenBytes)) {
            throw "FAILED|$Context output reservation contents were substituted."
        }
    }
    finally { $Stream.Position = $position }

    Assert-StandardValidationRegularFile -Path $Path -Context "$Context output reservation"
    $pathItem = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if ([int64]$pathItem.Length -ne [int64]$tokenBytes.Length) {
        throw "FAILED|$Context output reservation path was modified before finalization."
    }
    # Windows denies a second open while FileShare.None is held. Unix-like
    # systems use advisory sharing, so also compare the path bytes there to
    # detect unlink/replace or an in-place tamper by a child process.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        try {
            $pathBytes = [System.IO.File]::ReadAllBytes($Path)
            if ([Convert]::ToBase64String($pathBytes) -cne [Convert]::ToBase64String($tokenBytes)) {
                throw "FAILED|$Context output reservation path was substituted."
            }
        }
        catch [System.IO.IOException] {
            throw "FAILED|$Context output reservation path could not be revalidated."
        }
    }
}

function Write-StandardValidationJsonReserved {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][string] $Token,
        [Parameter(Mandatory = $true)] $Value
    )

    Assert-StandardValidationOutputReservation -Path $Path -Stream $Stream -Token $Token -Context 'Final evidence'
    $json = $Value | ConvertTo-Json -Depth 100
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
    $Stream.SetLength(0)
    $Stream.Position = 0
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        try {
            $pathBytes = [System.IO.File]::ReadAllBytes($Path)
            if ([Convert]::ToBase64String($pathBytes) -cne [Convert]::ToBase64String($bytes)) {
                throw 'FAILED|Final evidence output path was substituted while writing.'
            }
        }
        catch [System.IO.IOException] {
            throw 'FAILED|Final evidence output path could not be revalidated after writing.'
        }
    }
}

function Write-StandardValidationJsonCreate {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)] $Value)

    $fullPath = Get-StandardValidationFullPath -Path $Path -Context 'artifact output'
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $json = $Value | ConvertTo-Json -Depth 100
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    return $fullPath
}

function Write-StandardValidationStageReceipt {
    param([Parameter(Mandatory = $true)][string] $RunRoot, [Parameter(Mandatory = $true)] $Stage)

    $stageRoot = Join-Path $RunRoot ([string]$Stage.id)
    [void](New-Item -ItemType Directory -Path $stageRoot -Force)
    [void](Write-StandardValidationJsonCreate -Path (Join-Path $stageRoot 'receipt.json') -Value $Stage)
}

function Get-StandardValidationOutputHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Stdout, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Stderr)
    return Get-StandardValidationTextSha256 -Value ([string]$Stdout + "`n---stderr---`n" + [string]$Stderr)
}

function Assert-StandardValidationToolEnvelope {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Stdout,
        [Parameter(Mandatory = $true)] $ProcessResult,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $SkillId,
        [string] $SkillInventorySha256,
        [string[]] $ExpectedActiveSkills
    )

    if ([string]$ProcessResult.status -ne 'passed') {
        if ([string]$ProcessResult.status -eq 'cancelled') { throw 'CANCELLED|A validation child process was cancelled.' }
        throw "FAILED|$Context process status was '$($ProcessResult.status)'."
    }
    if ([int]$ProcessResult.exitCode -ne 0) { throw "FAILED|$Context returned exit code $($ProcessResult.exitCode)." }
    if ([string]::IsNullOrWhiteSpace($Stdout)) { throw "FAILED|$Context produced no output envelope." }
    try { $envelope = $Stdout.Trim() | ConvertFrom-Json }
    catch { throw "FAILED|$Context produced unparsable output: $($_.Exception.Message)" }
    if ($envelope -is [array] -or $null -eq $envelope) { throw "FAILED|$Context output envelope must be an object." }
    if ((Get-StandardValidationProperty -Object $envelope -Name 'schemaVersion') -ne 1 -or
        [string](Get-StandardValidationProperty -Object $envelope -Name 'status') -cne 'passed' -or
        [string](Get-StandardValidationProperty -Object $envelope -Name 'decision') -cne 'PASS') {
        throw "FAILED|$Context did not report a passed versioned result."
    }
    if ([string](Get-StandardValidationProperty -Object $envelope -Name 'candidateIdentity') -cne $CandidateId) {
        throw "FAILED|$Context evidence is bound to a different candidate."
    }
    if (-not [string]::IsNullOrWhiteSpace($SkillId) -and
        [string](Get-StandardValidationProperty -Object $envelope -Name 'skillId') -cne $SkillId) {
        throw "FAILED|$Context evidence is missing the expected Skill identity '$SkillId'."
    }
    if (-not [string]::IsNullOrWhiteSpace($SkillInventorySha256) -and
        [string](Get-StandardValidationProperty -Object $envelope -Name 'skillInventorySha256') -cne $SkillInventorySha256) {
        throw "FAILED|$Context evidence is missing the expected Skill inventory identity."
    }
    if ($null -ne $ExpectedActiveSkills) {
        $actualSkills = Get-StandardValidationProperty -Object $envelope -Name 'activeSkills'
        if ($actualSkills -isnot [array] -or (@($actualSkills | Sort-Object) -join "`n") -cne (@($ExpectedActiveSkills | Sort-Object) -join "`n")) {
            throw "FAILED|$Context evidence does not cover the complete active Skill set."
        }
    }
    return ,$envelope
}

function Assert-StandardValidationFindings {
    param([Parameter(Mandatory = $true)] $Envelope, [Parameter(Mandatory = $true)][string] $Context)

    $findings = Get-StandardValidationProperty -Object $Envelope -Name 'findings'
    $requiresHuman = $false
    if ($null -eq $findings) { return $requiresHuman }
    if ($findings -isnot [array]) { throw "FAILED|$Context findings are not an array." }
    foreach ($finding in @($findings)) {
        $severity = [string](Get-StandardValidationProperty -Object $finding -Name 'severity')
        if ($severity -notin @('critical', 'high', 'medium', 'low', 'informational')) {
            throw "FAILED|$Context contains an unknown severity '$severity'."
        }
        if ($severity -in @('critical', 'high')) { throw "FAILED|$Context contains a $severity finding." }
        if ($severity -ceq 'medium') { $requiresHuman = $true }
    }
    return $requiresHuman
}

function Get-StandardValidationSemanticRequirement {
    param([Parameter(Mandatory = $true)] $Envelope, [Parameter(Mandatory = $true)][string] $Context)

    $value = Get-StandardValidationProperty -Object $Envelope -Name 'semanticRequired'
    if ($null -eq $value) { return $false }
    if ($value -isnot [bool]) { throw "FAILED|$Context semanticRequired must be a typed boolean when present." }
    return [bool]$value
}

function Assert-StandardValidationAiReviewEvidence {
    param(
        [Parameter(Mandatory = $true)] $Evidence,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-StandardValidationExactPropertySet -Object $Evidence -Expected @(
        'schemaVersion', 'evidenceType', 'candidateId', 'status', 'decision',
        'reviewedCandidate', 'reviewFindings', 'findingDisposition'
    ) -Context $Context
    $schemaVersion = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'schemaVersion' -Context $Context
    $evidenceType = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'evidenceType' -Context $Context
    $evidenceCandidate = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'candidateId' -Context $Context
    $status = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'status' -Context $Context
    $decision = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'decision' -Context $Context
    $reviewedCandidate = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'reviewedCandidate' -Context $Context
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1 -or
        $evidenceType -isnot [string] -or [string]$evidenceType -cne 'ai-review' -or
        $evidenceCandidate -isnot [string] -or [string]$evidenceCandidate -cne $CandidateId -or
        $status -isnot [string] -or [string]$status -cne 'passed' -or
        $decision -isnot [string] -or [string]$decision -cne 'PASS' -or
        $reviewedCandidate -isnot [string] -or [string]$reviewedCandidate -cne $CandidateId) {
        throw "BLOCKED|$Context must report a typed PASS decision for this reviewed candidate."
    }
    $reviewFindings = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'reviewFindings' -Context $Context
    $findingDisposition = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'findingDisposition' -Context $Context
    if ($reviewFindings -isnot [array] -or $findingDisposition -isnot [array]) {
        throw "BLOCKED|$Context reviewFindings and findingDisposition must both be arrays."
    }
    if (@($reviewFindings).Count -ne @($findingDisposition).Count) {
        throw "BLOCKED|$Context reviewFindings and findingDisposition must have matching counts."
    }
    $canonicalFindings = @()
    foreach ($finding in @($reviewFindings)) {
        if ($null -eq $finding -or $finding -is [array]) {
            throw "BLOCKED|$Context contains a malformed review finding."
        }
        $severityValue = Get-StandardValidationProperty -Object $finding -Name 'severity'
        if ($severityValue -isnot [string] -or [string]$severityValue -notin @('critical', 'high', 'medium', 'low', 'informational')) {
            throw "BLOCKED|$Context contains a review finding with a non-canonical severity."
        }
        # Reduce the external review shape to the same canonical finding
        # envelope used by package/static/semantic evidence before applying the
        # central severity policy. Disposition never downgrades severity.
        $canonicalFindings += [pscustomobject][ordered]@{ severity = [string]$severityValue }
    }
    foreach ($disposition in @($findingDisposition)) {
        if ($null -eq $disposition -or $disposition -is [array] -or $disposition -is [string] -or $disposition -is [ValueType]) {
            throw "BLOCKED|$Context contains a malformed finding disposition."
        }
    }
    return [bool](Assert-StandardValidationFindings `
            -Envelope ([pscustomobject][ordered]@{ findings = @($canonicalFindings) }) `
            -Context $Context)
}

function Invoke-StandardValidationCommandAndRecord {
    param(
        [Parameter(Mandatory = $true)] $CommandSpec,
        [Parameter(Mandatory = $true)][string] $RunRoot,
        [Parameter(Mandatory = $true)][string] $StageId,
        [Parameter(Mandatory = $true)][string] $ToolId,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [string] $SkillId,
        [string] $SkillInventorySha256,
        [string[]] $ExpectedActiveSkills,
        [Parameter(Mandatory = $true)][string] $SnapshotRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSnapshotContentSha256,
        [Parameter(Mandatory = $true)][string] $SkillsRoot,
        [Parameter(Mandatory = $true)][string] $ActiveSkillsText,
        [Parameter(Mandatory = $true)][string] $OriginalCandidateRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedCandidateContentSha256,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ExpectedAdapterSha256,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [string] $CancellationPath,
        [System.IO.FileStream] $OutputReservationStream,
        [string] $OutputReservationPath,
        [string] $OutputReservationToken
    )

    $eventId = [guid]::NewGuid().ToString()
    $script:StandardValidationLastEvent = $null
    if ($null -ne $script:StandardValidationAuthorityEvidence) {
        Assert-StandardValidationAuthorityUnchanged -Authority $script:StandardValidationAuthorityEvidence
    }
    $commandSha256Before = Get-StandardValidationFileSha256 -Path ([string]$CommandSpec.command) -Context "$StageId/$ToolId command"
    if ([string]$CommandSpec.commandSha256 -cne $commandSha256Before) {
        throw "FAILED|$StageId/$ToolId command changed after adapter resolution."
    }
    Assert-StandardValidationSnapshotUnchanged -SnapshotRoot $SnapshotRoot -ExpectedSnapshotContentSha256 $ExpectedSnapshotContentSha256
    $environment = @{
        STANDARD_VALIDATION_STAGE_ID = $StageId
        STANDARD_VALIDATION_TOOL_ID = $ToolId
        STANDARD_VALIDATION_SKILL_ID = if ([string]::IsNullOrWhiteSpace($SkillId)) { '' } else { $SkillId }
        STANDARD_VALIDATION_CANDIDATE_ID = $CandidateId
        STANDARD_VALIDATION_CANDIDATE_ROOT = $SnapshotRoot
        STANDARD_VALIDATION_SKILLS_ROOT = $SkillsRoot
        STANDARD_VALIDATION_ACTIVE_SKILLS = $ActiveSkillsText
        STANDARD_VALIDATION_SKILL_ROOT = if ([string]::IsNullOrWhiteSpace($SkillId)) { '' } else { Join-Path $SkillsRoot $SkillId }
        STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 = if ([string]::IsNullOrWhiteSpace($SkillInventorySha256)) { '' } else { $SkillInventorySha256 }
        STANDARD_VALIDATION_EVENT_ID = $eventId
        STANDARD_VALIDATION_OUTPUT_PATH = if ([string]::IsNullOrWhiteSpace($OutputReservationPath)) { '' } else { $OutputReservationPath }
    }
    $processResult = Invoke-StandardValidationProcess `
        -Command ([string]$CommandSpec.command) `
        -Arguments @($CommandSpec.arguments) `
        -WorkingDirectory $RunRoot `
        -Environment $environment `
        -TimeoutSeconds $TimeoutSeconds `
        -CancellationPath $CancellationPath
    if ($null -ne $OutputReservationStream) {
        Assert-StandardValidationOutputReservation `
            -Path $OutputReservationPath `
            -Stream $OutputReservationStream `
            -Token $OutputReservationToken `
            -Context "$StageId/$ToolId"
    }
    Assert-StandardValidationSnapshotUnchanged -SnapshotRoot $SnapshotRoot -ExpectedSnapshotContentSha256 $ExpectedSnapshotContentSha256
    if ($null -ne $script:StandardValidationAuthorityEvidence) {
        Assert-StandardValidationAuthorityUnchanged -Authority $script:StandardValidationAuthorityEvidence
    }
    $commandSha256After = Get-StandardValidationFileSha256 -Path ([string]$CommandSpec.command) -Context "$StageId/$ToolId command"
    if ($commandSha256After -cne $commandSha256Before) {
        throw "FAILED|$StageId/$ToolId command changed during validation."
    }
    $eventDirectory = Join-Path $RunRoot ([string]$StageId)
    [void](New-Item -ItemType Directory -Path $eventDirectory -Force)
    $rawOutput = [ordered]@{
        schemaVersion = 1
        eventId = $eventId
        stageId = $StageId
        toolId = $ToolId
        skillId = if ([string]::IsNullOrWhiteSpace($SkillId)) { $null } else { $SkillId }
        candidateId = $CandidateId
        process = $processResult
        stdout = [string]$processResult.stdout
        stderr = [string]$processResult.stderr
    }
    $rawOutputPath = Join-Path $eventDirectory ("event-$eventId.json")
    [void](Write-StandardValidationJsonCreate -Path $rawOutputPath -Value $rawOutput)
    $event = [pscustomobject][ordered]@{
        eventId = $eventId
        stageId = $StageId
        toolId = $ToolId
        skillId = if ([string]::IsNullOrWhiteSpace($SkillId)) { $null } else { $SkillId }
        candidateId = $CandidateId
        commandSha256 = $commandSha256Before
        exitCode = [int]$processResult.exitCode
        status = [string]$processResult.status
        outputSha256 = Get-StandardValidationOutputHash -Stdout ([string]$processResult.stdout) -Stderr ([string]$processResult.stderr)
        outputPath = $rawOutputPath
        cleanedUp = [bool]$processResult.cleanedUp
    }
    $script:StandardValidationLastEvent = $event
    if (-not [bool]$processResult.cleanedUp) { throw 'FAILED|Validation child process cleanup failed.' }
    Assert-StandardValidationCandidateUnchanged `
        -CandidateRoot $OriginalCandidateRoot `
        -ExpectedContentSha256 $ExpectedCandidateContentSha256 `
        -AdapterPath $AdapterPath `
        -ExpectedAdapterSha256 $ExpectedAdapterSha256
    $envelope = Assert-StandardValidationToolEnvelope `
        -Stdout ([string]$processResult.stdout) `
        -ProcessResult $processResult `
        -CandidateId $CandidateId `
        -Context "$StageId/$ToolId" `
        -SkillId $SkillId `
        -SkillInventorySha256 $SkillInventorySha256 `
        -ExpectedActiveSkills $ExpectedActiveSkills
    return [pscustomobject][ordered]@{ event = $event; envelope = $envelope }
}

function Assert-StandardValidationApprovalScalar {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value) -or [string]$Value -match '[\x00-\x1F\x7F]') {
        throw "BLOCKED|$Context '$Name' must be a non-empty scalar without control characters."
    }
    return [string]$Value
}

function Convert-StandardValidationStringArrayToCanonicalJson {
    param([Parameter(Mandatory = $true)][string[]] $Values)

    return (ConvertTo-Json -InputObject ([object[]]$Values) -Compress -Depth 10)
}

function Convert-StandardValidationApprovalTimestamp {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -is [string]) {
        return Assert-StandardValidationApprovalScalar -Value $Value -Name $Name -Context $Context
    }
    # Windows PowerShell 5.1 ConvertFrom-Json coerces ISO UTC strings to DateTime.
    # Preserve the canonical round-trip form only when that coercion retained UTC.
    if ($Value -is [DateTime] -and $Value.Kind -eq [DateTimeKind]::Utc) {
        return $Value.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    throw "BLOCKED|$Context '$Name' must be an ISO-8601 UTC timestamp string."
}

function Get-StandardValidationHumanApprovalPayload {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $ApprovalId,
        [Parameter(Mandatory = $true)][string] $Approver,
        [Parameter(Mandatory = $true)][string] $ApprovalTimestamp,
        [Parameter(Mandatory = $true)][string] $ReviewDisposition,
        [Parameter(Mandatory = $true)][string] $HostId,
        [Parameter(Mandatory = $true)][string] $ActorId
    )

    return "candidateId=$CandidateId`napprovalId=$ApprovalId`napprover=$Approver`napprovalTimestamp=$ApprovalTimestamp`nreviewDisposition=$ReviewDisposition`nhostId=$HostId`nactorId=$ActorId"
}

function Assert-StandardValidationHumanApprovalEvidence {
    param(
        [Parameter(Mandatory = $true)] $Evidence,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-StandardValidationExactPropertySet -Object $Evidence -Expected @(
        'schemaVersion', 'evidenceType', 'candidateId', 'status', 'approvalId', 'approver',
        'approvalTimestamp', 'reviewDisposition', 'attestation'
    ) -Context $Context
    if ((Get-StandardValidationRequiredProperty -Object $Evidence -Name 'schemaVersion' -Context $Context) -ne 1 -or
        [string](Get-StandardValidationRequiredProperty -Object $Evidence -Name 'evidenceType' -Context $Context) -cne 'human-approval' -or
        [string](Get-StandardValidationRequiredProperty -Object $Evidence -Name 'candidateId' -Context $Context) -cne $CandidateId -or
        [string](Get-StandardValidationRequiredProperty -Object $Evidence -Name 'status' -Context $Context) -cne 'approved') {
        throw "BLOCKED|$Context is not an approved evidence result bound to this candidate."
    }

    $approvalId = Assert-StandardValidationApprovalScalar -Value (Get-StandardValidationRequiredProperty -Object $Evidence -Name 'approvalId' -Context $Context) -Name 'approvalId' -Context $Context
    $approver = Assert-StandardValidationApprovalScalar -Value (Get-StandardValidationRequiredProperty -Object $Evidence -Name 'approver' -Context $Context) -Name 'approver' -Context $Context
    $approvalTimestamp = Convert-StandardValidationApprovalTimestamp -Value (Get-StandardValidationRequiredProperty -Object $Evidence -Name 'approvalTimestamp' -Context $Context) -Name 'approvalTimestamp' -Context $Context
    $reviewDisposition = Assert-StandardValidationApprovalScalar -Value (Get-StandardValidationRequiredProperty -Object $Evidence -Name 'reviewDisposition' -Context $Context) -Name 'reviewDisposition' -Context $Context
    if ($reviewDisposition -cne 'approved') { throw "BLOCKED|$Context reviewDisposition must be approved." }

    if ($approvalTimestamp -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?(Z|\+00:00)$') {
        throw "BLOCKED|$Context approvalTimestamp must be an ISO-8601 UTC timestamp."
    }
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($approvalTimestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedTimestamp) -or
        $parsedTimestamp.Offset -ne [TimeSpan]::Zero) {
        throw "BLOCKED|$Context approvalTimestamp is not a valid UTC timestamp."
    }
    if ($parsedTimestamp -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw "BLOCKED|$Context approvalTimestamp is in the future."
    }

    $attestation = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'attestation' -Context $Context
    Assert-StandardValidationExactPropertySet -Object $attestation -Expected @(
        'schemaVersion', 'attestationType', 'candidateId', 'approvalId', 'hostId', 'actorId',
        'issuedAt', 'reviewDisposition', 'signature'
    ) -Context "$Context attestation"
    if ((Get-StandardValidationRequiredProperty -Object $attestation -Name 'schemaVersion' -Context "$Context attestation") -ne 1 -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'attestationType' -Context "$Context attestation") -cne 'trusted-supervisor-human-approval-v1' -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'candidateId' -Context "$Context attestation") -cne $CandidateId -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'approvalId' -Context "$Context attestation") -cne $approvalId -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'reviewDisposition' -Context "$Context attestation") -cne 'approved') {
        throw "BLOCKED|$Context trusted supervisor attestation is not bound to the approved candidate."
    }
    $hostId = Assert-StandardValidationApprovalScalar -Value (Get-StandardValidationRequiredProperty -Object $attestation -Name 'hostId' -Context "$Context attestation") -Name 'hostId' -Context "$Context attestation"
    $actorId = Assert-StandardValidationApprovalScalar -Value (Get-StandardValidationRequiredProperty -Object $attestation -Name 'actorId' -Context "$Context attestation") -Name 'actorId' -Context "$Context attestation"
    $issuedAt = Convert-StandardValidationApprovalTimestamp -Value (Get-StandardValidationRequiredProperty -Object $attestation -Name 'issuedAt' -Context "$Context attestation") -Name 'issuedAt' -Context "$Context attestation"
    if ($issuedAt -cne $approvalTimestamp) { throw "BLOCKED|$Context attestation issuedAt does not match approvalTimestamp." }
    $signature = Assert-StandardValidationApprovalScalar -Value (Get-StandardValidationRequiredProperty -Object $attestation -Name 'signature' -Context "$Context attestation") -Name 'signature' -Context "$Context attestation"
    if ($signature -notmatch '^[A-Za-z0-9+/]+={0,2}$' -or ($signature.Length % 4) -ne 0) {
        throw "BLOCKED|$Context attestation signature is not valid base64."
    }

    $publicKeyPath = Get-StandardValidationTrustAnchorPath -KeyId 'humanApproval' -TrustAnchorRoot $TrustAnchorRoot
    Assert-StandardValidationOutsideRoot -Path $publicKeyPath -Root $CandidateRoot -Context "$Context trusted public key"
    Assert-StandardValidationOutsideRoot -Path $publicKeyPath -Root $ArtifactsRoot -Context "$Context trusted public key"
    if (-not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        throw "BLOCKED|$Context trusted supervisor human-approval public key is missing."
    }
    $publicKeyItem = Get-Item -Force -LiteralPath $publicKeyPath -ErrorAction Stop
    if (($publicKeyItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "BLOCKED|$Context trusted human-approval public key must not be a reparse point."
    }
    $publicKeyXml = Get-Content -Raw -Encoding UTF8 -LiteralPath $publicKeyPath
    if ([string]::IsNullOrWhiteSpace($publicKeyXml) -or
        $publicKeyXml -notmatch '(?is)^\s*<RSAKeyValue>\s*<Modulus>[^<]+</Modulus>\s*<Exponent>[^<]+</Exponent>\s*</RSAKeyValue>\s*$' -or
        $publicKeyXml -match '(?i)<D(?:\s|>)') {
        throw "BLOCKED|$Context trusted public key must be an RSA XML public key."
    }

    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        try { $rsa.FromXmlString($publicKeyXml) }
        catch { throw "BLOCKED|$Context trusted public key could not be parsed as RSA XML: $($_.Exception.Message)" }
        $parameters = $rsa.ExportParameters($false)
        if ($null -eq $parameters.Modulus -or $parameters.Modulus.Length -eq 0 -or
            $null -eq $parameters.Exponent -or $parameters.Exponent.Length -eq 0) {
            throw "BLOCKED|$Context trusted public key does not contain an RSA public key."
        }
        $signatureBytes = $null
        try { $signatureBytes = [Convert]::FromBase64String($signature) }
        catch { throw "BLOCKED|$Context attestation signature is not valid base64." }
        $payload = Get-StandardValidationHumanApprovalPayload `
            -CandidateId $CandidateId `
            -ApprovalId $approvalId `
            -Approver $approver `
            -ApprovalTimestamp $approvalTimestamp `
            -ReviewDisposition $reviewDisposition `
            -HostId $hostId `
            -ActorId $actorId
        $payloadBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload)
        if (-not $rsa.VerifyData($payloadBytes, 'SHA256', $signatureBytes)) {
            throw "BLOCKED|$Context trusted supervisor signature verification failed."
        }
    }
    finally { $rsa.Dispose() }
}

function Assert-StandardValidationLifecycleTimestamp {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $issuedAt = Convert-StandardValidationApprovalTimestamp -Value $Value -Name 'issuedAt' -Context $Context
    if ($issuedAt -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?(Z|\+00:00)$') {
        throw "BLOCKED|$Context issuedAt must be an ISO-8601 UTC timestamp."
    }
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($issuedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedTimestamp) -or
        $parsedTimestamp.Offset -ne [TimeSpan]::Zero) {
        throw "BLOCKED|$Context issuedAt is not a valid UTC timestamp."
    }
    if ($parsedTimestamp -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw "BLOCKED|$Context issuedAt is in the future."
    }
    return $issuedAt
}

function Assert-StandardValidationLifecycleEvidence {
    param(
        [Parameter(Mandatory = $true)] $Evidence,
        [Parameter(Mandatory = $true)][ValidateSet('publish-install', 'post-install')][string] $ExpectedType,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $expectedProperties = if ($ExpectedType -ceq 'publish-install') {
        @('schemaVersion', 'evidenceType', 'candidateId', 'status', 'authorization', 'releaseIdentity', 'attestation')
    }
    else {
        @('schemaVersion', 'evidenceType', 'candidateId', 'status', 'installedInventory', 'postInstallIntegrity', 'attestation')
    }
    Assert-StandardValidationExactPropertySet -Object $Evidence -Expected $expectedProperties -Context $Context

    $schemaVersion = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'schemaVersion' -Context $Context
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1 -or
        [string](Get-StandardValidationRequiredProperty -Object $Evidence -Name 'evidenceType' -Context $Context) -cne $ExpectedType -or
        [string](Get-StandardValidationRequiredProperty -Object $Evidence -Name 'candidateId' -Context $Context) -cne $CandidateId) {
        throw "BLOCKED|$Context is not bound to this candidate and evidence type."
    }

    $attestation = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'attestation' -Context $Context
    $attestationProperties = if ($ExpectedType -ceq 'publish-install') {
        @('schemaVersion', 'attestationType', 'candidateId', 'evidenceType', 'status', 'authorization', 'releaseIdentity', 'issuedAt', 'signature')
    }
    else {
        @('schemaVersion', 'attestationType', 'candidateId', 'evidenceType', 'status', 'installedInventory', 'postInstallIntegrity', 'issuedAt', 'signature')
    }
    Assert-StandardValidationExactPropertySet -Object $attestation -Expected $attestationProperties -Context "$Context attestation"

    $attestationSchemaVersion = Get-StandardValidationRequiredProperty -Object $attestation -Name 'schemaVersion' -Context "$Context attestation"
    $expectedAttestationType = "trusted-supervisor-$ExpectedType-v1"
    if (($attestationSchemaVersion -isnot [int] -and $attestationSchemaVersion -isnot [long]) -or [int64]$attestationSchemaVersion -ne 1 -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'attestationType' -Context "$Context attestation") -cne $expectedAttestationType -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'candidateId' -Context "$Context attestation") -cne $CandidateId -or
        [string](Get-StandardValidationRequiredProperty -Object $attestation -Name 'evidenceType' -Context "$Context attestation") -cne $ExpectedType) {
        throw "BLOCKED|$Context trusted supervisor attestation is not bound to this candidate and evidence type."
    }

    $issuedAt = Assert-StandardValidationLifecycleTimestamp `
        -Value (Get-StandardValidationRequiredProperty -Object $attestation -Name 'issuedAt' -Context "$Context attestation") `
        -Context "$Context attestation"
    $fields = @{
        candidateId = $CandidateId
        evidenceType = $ExpectedType
        issuedAt = $issuedAt
    }

    if ($ExpectedType -ceq 'publish-install') {
        $status = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'status' -Context $Context
        $authorization = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'authorization' -Context $Context
        if ($status -isnot [string] -or [string]$status -cne 'authorized' -or $authorization -isnot [bool] -or -not [bool]$authorization) {
            throw "BLOCKED|$Context must contain a typed authorized publish/install result."
        }
        $releaseIdentity = Assert-StandardValidationApprovalScalar `
            -Value (Get-StandardValidationRequiredProperty -Object $Evidence -Name 'releaseIdentity' -Context $Context) `
            -Name 'releaseIdentity' `
            -Context $Context
        $attestationStatus = Get-StandardValidationRequiredProperty -Object $attestation -Name 'status' -Context "$Context attestation"
        $attestationAuthorization = Get-StandardValidationRequiredProperty -Object $attestation -Name 'authorization' -Context "$Context attestation"
        $attestationReleaseIdentity = Assert-StandardValidationApprovalScalar `
            -Value (Get-StandardValidationRequiredProperty -Object $attestation -Name 'releaseIdentity' -Context "$Context attestation") `
            -Name 'releaseIdentity' `
            -Context "$Context attestation"
        if ($attestationStatus -isnot [string] -or [string]$attestationStatus -cne [string]$status -or
            $attestationAuthorization -isnot [bool] -or [bool]$attestationAuthorization -ne [bool]$authorization -or
            $attestationReleaseIdentity -cne $releaseIdentity) {
            throw "BLOCKED|$Context trusted supervisor attestation does not match the publish/install result."
        }
        $fields.authorization = [string]$authorization
        $fields.releaseIdentity = $releaseIdentity
        $fields.status = [string]$status
    }
    else {
        $status = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'status' -Context $Context
        $postInstallIntegrity = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'postInstallIntegrity' -Context $Context
        if ($status -isnot [string] -or [string]$status -cne 'passed' -or
            $postInstallIntegrity -isnot [bool] -or -not [bool]$postInstallIntegrity) {
            throw "BLOCKED|$Context must contain a typed passed post-install result."
        }
        $inventory = Get-StandardValidationRequiredProperty -Object $Evidence -Name 'installedInventory' -Context $Context
        if ($inventory -isnot [array] -or @($inventory).Count -eq 0) {
            throw "BLOCKED|$Context installedInventory must be a non-empty array."
        }
        $inventoryValues = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in @($inventory)) {
            $inventoryValue = Assert-StandardValidationApprovalScalar -Value $item -Name 'installedInventory item' -Context $Context
            [void]$inventoryValues.Add($inventoryValue)
        }
        $attestationStatus = Get-StandardValidationRequiredProperty -Object $attestation -Name 'status' -Context "$Context attestation"
        $attestationIntegrity = Get-StandardValidationRequiredProperty -Object $attestation -Name 'postInstallIntegrity' -Context "$Context attestation"
        $attestationInventory = Get-StandardValidationRequiredProperty -Object $attestation -Name 'installedInventory' -Context "$Context attestation"
        if ($attestationStatus -isnot [string] -or [string]$attestationStatus -cne [string]$status -or
            $attestationIntegrity -isnot [bool] -or [bool]$attestationIntegrity -ne [bool]$postInstallIntegrity -or
            $attestationInventory -isnot [array] -or @($attestationInventory).Count -ne $inventoryValues.Count) {
            throw "BLOCKED|$Context trusted supervisor attestation does not match the post-install result."
        }
        for ($index = 0; $index -lt $inventoryValues.Count; $index++) {
            $attestationInventoryValue = Assert-StandardValidationApprovalScalar `
                -Value @($attestationInventory)[$index] `
                -Name 'installedInventory item' `
                -Context "$Context attestation"
            if ($attestationInventoryValue -cne $inventoryValues[$index]) {
                throw "BLOCKED|$Context trusted supervisor attestation inventory does not match the post-install result."
            }
        }
        $fields.installedInventory = Convert-StandardValidationStringArrayToCanonicalJson -Values $inventoryValues.ToArray()
        $fields.postInstallIntegrity = [string]$postInstallIntegrity
        $fields.status = [string]$status
    }

    $trustedKeyPath = Get-StandardValidationTrustAnchorPath -KeyId 'supervisor' -TrustAnchorRoot $TrustAnchorRoot
    Assert-StandardValidationOutsideRoot -Path $trustedKeyPath -Root $CandidateRoot -Context "$Context trusted public key"
    Assert-StandardValidationOutsideRoot -Path $trustedKeyPath -Root $ArtifactsRoot -Context "$Context trusted public key"
    Assert-StandardValidationSignedReceipt `
        -Receipt $attestation `
        -ReceiptType "$ExpectedType-v1" `
        -Fields $fields `
        -TrustAnchorRoot $TrustAnchorRoot `
        -Context "$Context attestation"
}

function Assert-StandardValidationImportedEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedType,
        [Parameter(Mandatory = $true)][string] $CandidateId,
        [Parameter(Mandatory = $true)][string] $TrustAnchorRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $evidence = Get-StandardValidationJson -Path $Path -Context $Context
    if ($evidence -is [array]) { throw "BLOCKED|$Context must be a JSON object." }
    if ((Get-StandardValidationProperty -Object $evidence -Name 'schemaVersion') -ne 1 -or
        [string](Get-StandardValidationProperty -Object $evidence -Name 'evidenceType') -cne $ExpectedType -or
        [string](Get-StandardValidationProperty -Object $evidence -Name 'candidateId') -cne $CandidateId) {
        throw "BLOCKED|$Context is not bound to this candidate and evidence type."
    }
    $status = [string](Get-StandardValidationProperty -Object $evidence -Name 'status')
    if ($status -notin @('passed', 'approved', 'authorized')) { throw "BLOCKED|$Context is not a successful evidence result." }
    if ($ExpectedType -ceq 'semantic') {
        if ((Get-StandardValidationProperty -Object $evidence -Name 'consentGranted') -ne $true) {
            throw 'BLOCKED|Semantic evidence does not prove explicit consent.'
        }
        foreach ($name in @('provider', 'purpose', 'scope')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $evidence -Name $name))) {
                throw "BLOCKED|Semantic evidence is missing '$name'."
            }
        }
    }
    if ($ExpectedType -ceq 'human-approval') {
        try {
            Assert-StandardValidationHumanApprovalEvidence `
                -Evidence $evidence `
                -CandidateId $CandidateId `
                -TrustAnchorRoot $TrustAnchorRoot `
                -CandidateRoot $CandidateRoot `
                -ArtifactsRoot $ArtifactsRoot `
                -Context $Context
        }
        catch {
            $humanMessage = [string]$_.Exception.Message
            $humanSeparator = $humanMessage.IndexOf('|')
            if ($humanSeparator -gt 0 -and $humanMessage.Substring(0, $humanSeparator) -in @('BLOCKED', 'INVALID', 'FAILED')) {
                $humanMessage = $humanMessage.Substring($humanSeparator + 1)
            }
            throw "BLOCKED|$humanMessage"
        }
    }
    if ($ExpectedType -ceq 'ai-review') {
        [void](Assert-StandardValidationAiReviewEvidence -Evidence $evidence -CandidateId $CandidateId -Context $Context)
    }
    if ($ExpectedType -in @('publish-install', 'post-install')) {
        try {
            Assert-StandardValidationLifecycleEvidence `
                -Evidence $evidence `
                -ExpectedType $ExpectedType `
                -CandidateId $CandidateId `
                -TrustAnchorRoot $TrustAnchorRoot `
                -CandidateRoot $CandidateRoot `
                -ArtifactsRoot $ArtifactsRoot `
                -Context $Context
        }
        catch {
            $lifecycleMessage = [string]$_.Exception.Message
            $lifecycleSeparator = $lifecycleMessage.IndexOf('|')
            if ($lifecycleSeparator -gt 0 -and $lifecycleMessage.Substring(0, $lifecycleSeparator) -in @('BLOCKED', 'INVALID', 'FAILED')) {
                $lifecycleMessage = $lifecycleMessage.Substring($lifecycleSeparator + 1)
            }
            throw "BLOCKED|$lifecycleMessage"
        }
    }
    return ,$evidence
}

function Assert-StandardValidationContractFiles {
    param([Parameter(Mandatory = $true)][string] $RepositoryRoot)

    $contractPath = Join-Path $RepositoryRoot 'docs/standards/standard-validation-contract-v1.json'
    $contract = Get-StandardValidationJson -Path $contractPath -Context 'central validation contract'
    if ((Get-StandardValidationProperty -Object $contract -Name 'schemaVersion') -ne 1 -or
        [string](Get-StandardValidationProperty -Object $contract -Name 'contract') -cne 'standard-validation-contract-v1') {
        throw 'INVALID|Central validation contract identity is unsupported.'
    }
    $stages = Get-StandardValidationRequiredProperty -Object $contract -Name 'stages' -Context 'central validation contract'
    if ($stages -isnot [array] -or @($stages).Count -ne 10) { throw 'INVALID|Central validation contract must declare ten stages.' }
    for ($index = 0; $index -lt $script:StandardValidationStageDefinitions.Count; $index++) {
        if ([int]$stages[$index].order -ne [int]$script:StandardValidationStageDefinitions[$index].order -or
            [string]$stages[$index].id -cne [string]$script:StandardValidationStageDefinitions[$index].id) {
            throw 'INVALID|Central validation contract stage order is not canonical.'
        }
    }
    $policyPath = Join-Path $RepositoryRoot 'docs/standards/validation-security-gate.json'
    $policy = Get-StandardValidationJson -Path $policyPath -Context 'canonical validation security gate'
    $authorityGatePath = Join-Path $RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
    if (-not (Test-Path -LiteralPath $authorityGatePath -PathType Leaf)) {
        throw 'INVALID|Canonical authority gate is missing.'
    }
    try {
        . $authorityGatePath -DefineFunctionsOnly
        [void](Assert-AuthorityValidationSecurityGate -Policy $policy)
    }
    catch { throw "INVALID|Canonical validation security gate failed authority validation: $($_.Exception.Message)" }
    $policyIds = @($policy.stages | ForEach-Object { [string]$_.id })
    $contractIds = @($stages | ForEach-Object { [string]$_.id })
    if (($policyIds -join ',') -cne ($contractIds -join ',')) { throw 'INVALID|Validation contract and security policy stage orders diverge.' }
    $resolverPath = Join-Path $RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1'
    $toolchainPath = Join-Path $RepositoryRoot 'docs/standards/validation-toolchain.json'
    foreach ($authorityFile in @($resolverPath, $toolchainPath, $authorityGatePath, (Join-Path $RepositoryRoot 'scripts/Invoke-StandardValidation.ps1'))) {
        if (-not (Test-Path -LiteralPath $authorityFile -PathType Leaf)) {
            throw "INVALID|Central authority file is missing: $authorityFile"
        }
    }
    try {
        $LASTEXITCODE = 0
        $resolverJson = (& $resolverPath -ValidatePolicyOnly 2>&1 | Out-String).Trim()
        if ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) { throw "resolver exit code $LASTEXITCODE" }
        $resolverPolicy = $resolverJson | ConvertFrom-Json
    }
    catch { throw "INVALID|Central validation tool policy could not be verified: $($_.Exception.Message)" }
    if ([string]$resolverPolicy.policy -cne 'latest-stable-per-validation-run' -or
        [string]$resolverPolicy.sourceTrust.enforcement -cne 'exact-approved-source' -or
        [bool]$resolverPolicy.sourceTrust.failClosedOnMismatch -ne $true) {
        throw 'INVALID|Central resolver policy is not the approved latest-stable fail-closed policy.'
    }
    $authority = [ordered]@{
        repository = $script:StandardValidationAuthorityRepository
        runnerPath = 'scripts/Invoke-StandardValidation.ps1'
        runnerSha256 = Get-StandardValidationFileSha256 -Path (Join-Path $RepositoryRoot 'scripts/Invoke-StandardValidation.ps1') -Context 'central runner'
        contractPath = 'docs/standards/standard-validation-contract-v1.json'
        contractSha256 = Get-StandardValidationFileSha256 -Path $contractPath -Context 'central validation contract'
        policyPath = 'docs/standards/validation-security-gate.json'
        policySha256 = Get-StandardValidationFileSha256 -Path $policyPath -Context 'canonical validation security gate'
        authorityGatePath = 'scripts/Invoke-StandardAuthorityGate.ps1'
        authorityGateSha256 = Get-StandardValidationFileSha256 -Path $authorityGatePath -Context 'canonical authority gate'
        resolverPath = 'scripts/Resolve-StandardValidationTool.ps1'
        resolverSha256 = Get-StandardValidationFileSha256 -Path $resolverPath -Context 'central tool resolver'
        trustAnchors = Get-StandardValidationTrustAnchorEvidence
    }
    return [pscustomobject][ordered]@{ contract = $contract; contractPath = $contractPath; policy = $policy; policyPath = $policyPath; authority = $authority }
}

function Assert-StandardValidationAuthorityUnchanged {
    param([Parameter(Mandatory = $true)] $Authority)

    $checks = @(
        [pscustomobject]@{ path = $Authority.runnerPath; sha256 = $Authority.runnerSha256; context = 'central runner' }
        [pscustomobject]@{ path = $Authority.contractPath; sha256 = $Authority.contractSha256; context = 'central validation contract' }
        [pscustomobject]@{ path = $Authority.policyPath; sha256 = $Authority.policySha256; context = 'canonical validation security gate' }
        [pscustomobject]@{ path = $Authority.authorityGatePath; sha256 = $Authority.authorityGateSha256; context = 'canonical authority gate' }
        [pscustomobject]@{ path = $Authority.resolverPath; sha256 = $Authority.resolverSha256; context = 'central tool resolver' }
    )
    foreach ($check in $checks) {
        $path = Join-Path $script:StandardValidationRepositoryRoot ([string]$check.path)
        $actual = Get-StandardValidationFileSha256 -Path $path -Context "$($check.context) revalidation"
        if ($actual -cne [string]$check.sha256) {
            throw "FAILED|$($check.context) changed during validation."
        }
    }
    $binding = Get-StandardValidationProperty -Object $Authority -Name 'binding'
    if ($null -ne $binding -and [bool](Get-StandardValidationProperty -Object $binding -Name 'verified')) {
        $archivePath = [string](Get-StandardValidationProperty -Object $binding -Name 'archivePath')
        $evidencePath = [string](Get-StandardValidationProperty -Object $binding -Name 'snapshotEvidencePath')
        $archiveExpected = [string](Get-StandardValidationProperty -Object $binding -Name 'archiveSha256')
        $evidenceExpected = [string](Get-StandardValidationProperty -Object $binding -Name 'snapshotEvidenceSha256')
        if ((Get-StandardValidationFileSha256 -Path $archivePath -Context 'authority archive revalidation') -cne $archiveExpected) {
            throw 'FAILED|Authority archive changed during validation.'
        }
        if ((Get-StandardValidationFileSha256 -Path $evidencePath -Context 'authority snapshot evidence revalidation') -cne $evidenceExpected) {
            throw 'FAILED|Authority snapshot evidence changed during validation.'
        }
        foreach ($entry in @((Get-StandardValidationProperty -Object $binding -Name 'selectedFiles'))) {
            $selectedPath = Join-Path $script:StandardValidationRepositoryRoot ([string]$entry.path)
            if ((Get-StandardValidationFileSha256 -Path $selectedPath -Context 'authority selected file revalidation') -cne [string]$entry.sha256) {
                throw "FAILED|Authority selected file changed during validation: $($entry.path)"
            }
        }
    }
}

function New-StandardValidationCandidateEvidence {
    param(
        [Parameter(Mandatory = $true)][guid] $RunId,
        [Parameter(Mandatory = $true)][string] $State,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][bool] $ReleaseEligible,
        $Candidate,
        $Adapter,
        $Authority,
        [Parameter(Mandatory = $true)] $Stages,
        [string] $FailureState,
        [string] $FailureMessage,
        [string] $ArtifactRoot,
        [string] $LockPath
    )

        $result = [ordered]@{
        schemaVersion = 1
        evidence = 'standard-validation-evidence-v1'
        contract = 'standard-validation-contract-v1'
        runId = $RunId.ToString()
        state = $State
        exitCode = $ExitCode
        releaseEligible = $ReleaseEligible
        candidate = if ($null -eq $Candidate) { [ordered]@{ sourceRepository = 'https://invalid.invalid/invalid/invalid.git'; sourceRevision = ('0' * 40); baseRevision = ('0' * 40); eventName = 'invalid'; candidateId = ('0' * 64); contentSha256 = ('0' * 64); archiveSha256 = ('0' * 64); inventory = @([ordered]@{ path = 'unavailable'; sha256 = ('0' * 64); length = 0 }); activeSkills = @('invalid'); acquisition = [ordered]@{ status = 'unverified'; verified = $false; sourceRepository = 'unavailable'; sourceRevision = 'unavailable'; baseRevision = 'unavailable'; eventName = 'invalid'; archivePath = $null; archiveUrl = $null; archivePrefix = $null; archiveSha256 = ('0' * 64); contentSha256 = $null; evidencePath = $null; evidenceSha256 = ('0' * 64) } } } else { $Candidate }
        adapter = if ($null -eq $Adapter) { [ordered]@{ schemaVersion = 1; sha256 = ('0' * 64); mode = 'production'; canonicalValidatorPath = 'unavailable'; skillsRoot = 'unavailable'; activeSkills = @('invalid') } } else { $Adapter }
        authority = if ($null -eq $Authority) { [ordered]@{ repository = $script:StandardValidationAuthorityRepository; runnerPath = 'scripts/Invoke-StandardValidation.ps1'; runnerSha256 = ('0' * 64); contractPath = 'docs/standards/standard-validation-contract-v1.json'; contractSha256 = ('0' * 64); policyPath = 'docs/standards/validation-security-gate.json'; policySha256 = ('0' * 64); authorityGatePath = 'scripts/Invoke-StandardAuthorityGate.ps1'; authorityGateSha256 = ('0' * 64); resolverPath = 'scripts/Resolve-StandardValidationTool.ps1'; resolverSha256 = ('0' * 64); trustAnchors = @([ordered]@{ id = 'supervisor'; path = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'; sha256 = ('0' * 64) }, [ordered]@{ id = 'humanApproval'; path = 'docs/standards/trust-anchors/human-approval-public-key.xml'; sha256 = ('0' * 64) }); binding = [ordered]@{ status = 'unverified'; verified = $false; repository = $script:StandardValidationAuthorityRepository; revision = $null; archivePath = $null; archiveUrl = $null; archivePrefix = $null; archiveSha256 = ('0' * 64); snapshotEvidencePath = $null; snapshotEvidenceSha256 = ('0' * 64); snapshotInventorySha256 = ('0' * 64); selectedFiles = @() } } } else { $Authority }
        stages = $Stages
        artifacts = [ordered]@{
            root = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { 'unavailable' } else { $ArtifactRoot }
            lockPath = if ([string]::IsNullOrWhiteSpace($LockPath)) { 'unavailable' } else { $LockPath }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureState)) {
        $result.failure = [ordered]@{ state = $FailureState; message = if ([string]::IsNullOrWhiteSpace($FailureMessage)) { 'Validation did not pass.' } else { $FailureMessage } }
    }
    return [pscustomobject]$result
}

function Invoke-StandardValidationRun {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $AdapterPath,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [string] $OutputPath,
        [Parameter(Mandatory = $true)][string] $SourceRepository,
        [Parameter(Mandatory = $true)][string] $SourceRevision,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)][string] $EventName,
        [string] $CandidateArchivePath,
        [string] $CandidateAcquisitionEvidencePath,
        [string] $CandidateArchiveSha256,
        [string] $AuthorityRevision,
        [string] $AuthorityArchivePath,
        [string] $AuthoritySnapshotEvidencePath,
        [int] $TimeoutSeconds = 300,
        [string] $CancellationPath,
        [string] $TrustedToolRoot,
        [bool] $DevelopmentHarness = $false,
        [bool] $SemanticTriggered = $false,
        [bool] $SemanticConsent = $false,
        [string] $SemanticProvider,
        [string] $SemanticPurpose,
        [string] $SemanticScope,
        [string] $SemanticEvidencePath,
        [string] $AiReviewEvidencePath,
        [string] $HumanApprovalEvidencePath,
        [string] $PublishInstallEvidencePath,
        [string] $PostInstallEvidencePath,
        [bool] $CompleteLifecycle = $false
    )

    $script:StandardValidationAuthorityEvidence = $null
    $script:StandardValidationLastEvent = $null
    $runId = [guid]::NewGuid()
    $stages = New-StandardValidationStages
    $state = 'FAILED'
    $failureState = 'FAILED'
    $failureMessage = 'Validation did not complete.'
    $releaseEligible = $false
    $candidateEvidence = $null
    $adapterEvidence = $null
    $runRoot = $null
    $lockPath = $null
    $lockCreated = $false
    $finalWritten = $false
    $artifactRootFull = $null
    $trustedToolRootFull = $null
    $trustAnchorRootFull = $null
    $outputFull = $null
    $outputReservationStream = $null
    $outputReservationToken = $null
    $originalCandidateRoot = $null
    $adapterFull = $null
    $expectedCandidateContentSha256 = $null
    $expectedAdapterSha256 = $null
    $candidateInventory = $null
    $candidateAcquisition = $null
    $adapter = $null
    $adapterResult = $null
    $contractResult = $null
    $authorityEvidence = $null
    $requiresHumanReview = $false
    $analyzerSemanticRequired = $false
    $semanticRequiredSources = New-Object 'System.Collections.Generic.List[string]'
    $authorityBinding = $null

    try {
        if ($TimeoutSeconds -lt 1) { throw 'INVALID|TimeoutSeconds must be at least one second.' }
        Assert-StandardValidationSourceRepository -Value $SourceRepository
        Assert-StandardValidationRevision -Value $SourceRevision -Context 'SourceRevision'
        Assert-StandardValidationRevision -Value $BaseRevision -Context 'BaseRevision'
        if (-not [string]::IsNullOrWhiteSpace($CandidateArchiveSha256)) {
            Assert-StandardValidationSha256 -Value $CandidateArchiveSha256 -Context 'CandidateArchiveSha256'
        }
        if ([string]::IsNullOrWhiteSpace($TrustedToolRoot)) { $TrustedToolRoot = Split-Path -Parent $PSScriptRoot }
        $originalCandidateRoot = Get-StandardValidationFullPath -Path $CandidateRoot -Context 'CandidateRoot'
        $adapterFull = Get-StandardValidationFullPath -Path $AdapterPath -Context 'AdapterPath'
        $artifactRootFull = Get-StandardValidationFullPath -Path $ArtifactsRoot -Context 'ArtifactsRoot'
        $trustedToolRootFull = Get-StandardValidationFullPath -Path $TrustedToolRoot -Context 'TrustedToolRoot'
        $trustAnchorRootFull = if ($DevelopmentHarness) {
            $trustedToolRootFull
        }
        else {
            Get-StandardValidationFullPath -Path (Join-Path $script:StandardValidationRepositoryRoot 'docs/standards/trust-anchors') -Context 'immutable validation trust-anchor root'
        }
        if (-not (Test-Path -LiteralPath $originalCandidateRoot -PathType Container)) { throw 'INVALID|CandidateRoot is not a directory.' }
        if (-not (Test-Path -LiteralPath $adapterFull -PathType Leaf)) { throw 'INVALID|AdapterPath is not a file.' }
        if (-not (Test-Path -LiteralPath $trustedToolRootFull -PathType Container)) { throw 'INVALID|TrustedToolRoot is not a directory.' }
        Assert-StandardValidationDistinctRoots -First $originalCandidateRoot -Second $artifactRootFull -Context 'CandidateRoot and ArtifactsRoot'
        Assert-StandardValidationOutsideRoot -Path $trustedToolRootFull -Root $originalCandidateRoot -Context 'TrustedToolRoot'
        Assert-StandardValidationOutsideRoot -Path $trustedToolRootFull -Root $artifactRootFull -Context 'TrustedToolRoot'
        Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $originalCandidateRoot -Context 'AdapterPath'
        Assert-StandardValidationOutsideRoot -Path $adapterFull -Root $artifactRootFull -Context 'AdapterPath'
        Assert-StandardValidationNoReparsePoints -Root $adapterFull -Context 'adapter'
        Assert-StandardValidationNoReparsePoints -Root $trustedToolRootFull -Context 'TrustedToolRoot'
        Assert-StandardValidationOutsideRoot -Path $artifactRootFull -Root (Split-Path -Parent $PSScriptRoot) -Context 'ArtifactsRoot'
        [void](New-Item -ItemType Directory -Path $artifactRootFull -Force)
        Assert-StandardValidationNoReparsePoints -Root $artifactRootFull -Context 'ArtifactsRoot'
        if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $artifactRootFull 'standard-validation-evidence.json' }
        $outputFull = Get-StandardValidationFullPath -Path $OutputPath -Context 'OutputPath'
        if (-not (Test-StandardValidationPathWithin -Path $outputFull -Root $artifactRootFull -IncludeRoot)) {
            throw 'INVALID|OutputPath must be under ArtifactsRoot.'
        }
        if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
            throw 'INVALID|OutputPath already exists; evidence is create-only and cannot be overwritten.'
        }
        $outputReservation = New-StandardValidationOutputReservation -Path $outputFull
        $outputReservationStream = $outputReservation.stream
        $outputReservationToken = [string]$outputReservation.token
        if (-not $DevelopmentHarness) {
            foreach ($keyId in @('supervisor', 'humanApproval')) {
                [void](Get-StandardValidationTrustAnchorPath -KeyId $keyId -TrustAnchorRoot $trustAnchorRootFull)
            }
        }
        if ($DevelopmentHarness) {
            $authorityBinding = [ordered]@{
                status = 'unverified-development-harness'; verified = $false; repository = $script:StandardValidationAuthorityRepository; revision = $null
                archivePath = $null; archiveUrl = $null; archivePrefix = $null; archiveSha256 = ('0' * 64); snapshotEvidencePath = $null
                snapshotEvidenceSha256 = ('0' * 64); snapshotInventorySha256 = ('0' * 64); selectedFiles = @()
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($AuthorityRevision) -or [string]::IsNullOrWhiteSpace($AuthorityArchivePath) -or
                [string]::IsNullOrWhiteSpace($AuthoritySnapshotEvidencePath)) {
                throw 'INVALID|Production validation requires AuthorityRevision, AuthorityArchivePath, and AuthoritySnapshotEvidencePath.'
            }
            $authorityBinding = Assert-StandardValidationAuthoritySnapshot `
                -RepositoryRoot (Split-Path -Parent $PSScriptRoot) `
                -AuthorityRevision $AuthorityRevision `
                -AuthorityArchivePath $AuthorityArchivePath `
                -AuthoritySnapshotEvidencePath $AuthoritySnapshotEvidencePath `
                -TrustAnchorRoot $trustAnchorRootFull `
                -ArtifactsRoot $artifactRootFull `
                -StagingRoot (Join-Path $artifactRootFull 'acquisition/authority-archive') `
                -Context 'authority snapshot'
        }
        $contractResult = Assert-StandardValidationContractFiles -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
        $authorityEvidence = $contractResult.authority
        $authorityEvidence.binding = $authorityBinding
        $script:StandardValidationAuthorityEvidence = $authorityEvidence
        $adapter = Get-StandardValidationJson -Path $adapterFull -Context 'standard validation adapter'
        $adapterResult = Assert-StandardValidationAdapter `
            -Adapter $adapter `
            -CandidateRoot $originalCandidateRoot `
            -ArtifactsRoot $artifactRootFull `
            -TrustedToolRoot $trustedToolRootFull `
            -DevelopmentHarness $DevelopmentHarness
        try {
            . $contractResult.authority.authorityGatePath -DefineFunctionsOnly
            [void](Assert-AuthorityConsumerEntryPointContract -RepositoryRoot $originalCandidateRoot -CanonicalValidatorPath $adapterResult.canonicalValidatorPath -Policy $contractResult.policy)
        }
        catch {
            throw "BLOCKED|Consumer entry-point contract failed: $($_.Exception.Message)"
        }
        if ($DevelopmentHarness) {
            $candidateAcquisition = [ordered]@{
                status = 'unverified-development-harness'; verified = $false; sourceRepository = $SourceRepository; sourceRevision = $SourceRevision
                baseRevision = $BaseRevision; eventName = $EventName; archivePath = $null; archiveUrl = $null; archiveSha256 = if ($CandidateArchiveSha256) { $CandidateArchiveSha256 } else { ('0' * 64) }
                archivePrefix = $null; contentSha256 = $null; evidencePath = $null; evidenceSha256 = ('0' * 64)
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($CandidateArchivePath) -or [string]::IsNullOrWhiteSpace($CandidateAcquisitionEvidencePath) -or
                [string]::IsNullOrWhiteSpace($CandidateArchiveSha256)) {
                throw 'INVALID|Production validation requires CandidateArchivePath, CandidateAcquisitionEvidencePath, and CandidateArchiveSha256.'
            }
            $candidateAcquisition = Assert-StandardValidationCandidateAcquisition `
                -CandidateRoot $originalCandidateRoot `
                -CandidateArchivePath $CandidateArchivePath `
                -CandidateAcquisitionEvidencePath $CandidateAcquisitionEvidencePath `
                -TrustAnchorRoot $trustAnchorRootFull `
                -ArtifactsRoot $artifactRootFull `
                -StagingRoot (Join-Path $artifactRootFull 'acquisition/candidate-archive') `
                -ExpectedSourceRepository $SourceRepository `
                -ExpectedSourceRevision $SourceRevision `
                -ExpectedBaseRevision $BaseRevision `
                -ExpectedEventName $EventName `
                -CandidateArchiveSha256 $CandidateArchiveSha256 `
                -Context 'candidate acquisition'
        }
        $candidateInventory = Get-StandardValidationInventory -Root $originalCandidateRoot -Context 'candidate'
        $expectedCandidateContentSha256 = Get-StandardValidationInventorySha256 -Inventory $candidateInventory
        if (-not $DevelopmentHarness -and [string]$candidateAcquisition.contentSha256 -cne $expectedCandidateContentSha256) {
            throw 'BLOCKED|Candidate acquisition receipt content identity does not match the candidate root.'
        }
        $expectedAdapterSha256 = Get-StandardValidationFileSha256 -Path $adapterFull -Context 'adapter'
        $candidateId = Get-StandardValidationTextSha256 -Value (
            "$SourceRepository`n$SourceRevision`n$BaseRevision`n$EventName`n$expectedCandidateContentSha256`n$expectedAdapterSha256`n$CandidateArchiveSha256"
        )
        $candidateEvidence = [ordered]@{
            sourceRepository = $SourceRepository
            sourceRevision = $SourceRevision
            baseRevision = $BaseRevision
            eventName = $EventName
            candidateId = $candidateId
            contentSha256 = $expectedCandidateContentSha256
            archiveSha256 = [string]$candidateAcquisition.archiveSha256
            acquisition = $candidateAcquisition
            inventory = $candidateInventory
            activeSkills = @($adapterResult.skills.ids)
        }
        $adapterEvidence = [ordered]@{
            schemaVersion = 1
            sha256 = $expectedAdapterSha256
            mode = $adapterResult.mode
            canonicalValidatorPath = $adapterResult.canonicalValidatorPath
            skillsRoot = $adapterResult.skills.relative
            activeSkills = @($adapterResult.skills.ids)
        }
        $executionKey = Get-StandardValidationTextSha256 -Value "$SourceRepository`n$SourceRevision`n$BaseRevision`n$EventName`n$candidateId"
        $lockDirectory = Join-Path $artifactRootFull 'locks'
        [void](New-Item -ItemType Directory -Path $lockDirectory -Force)
        $lockPath = Join-Path $lockDirectory "$executionKey.lock"
        try {
            $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $lockBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(([ordered]@{ runId = $runId.ToString(); candidateId = $candidateId; eventName = $EventName } | ConvertTo-Json -Compress) + [Environment]::NewLine)
                $lockStream.Write($lockBytes, 0, $lockBytes.Length); $lockStream.Flush()
            }
            finally { $lockStream.Dispose() }
            $lockCreated = $true
        }
        catch [System.IO.IOException] { throw 'INVALID|A canonical execution already exists for this event and candidate.' }
        $runRoot = Join-Path (Join-Path $artifactRootFull 'runs') $executionKey
        [void](New-Item -ItemType Directory -Path $runRoot -Force)
        $snapshotRoot = Join-Path $runRoot 'candidate-snapshot'
        Copy-StandardValidationSnapshot -Source $originalCandidateRoot -Destination $snapshotRoot
        $snapshotInventory = Get-StandardValidationInventory -Root $snapshotRoot -Context 'candidate snapshot'
        if ((Get-StandardValidationInventorySha256 -Inventory $snapshotInventory) -cne $expectedCandidateContentSha256) {
            throw 'FAILED|Candidate snapshot identity does not match the source candidate.'
        }
        $activeSkillsText = (@($adapterResult.skills.ids | Sort-Object) -join ';')
        $snapshotSkillsRoot = Join-Path $snapshotRoot $adapterResult.skills.relative

        $stage = Get-StandardValidationStage -Stages $stages -Id 'controlled-acquisition'
        Start-StandardValidationStage -Stage $stage
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'integrity-verification'
        Start-StandardValidationStage -Stage $stage
        Assert-StandardValidationCandidateUnchanged -CandidateRoot $originalCandidateRoot -ExpectedContentSha256 $expectedCandidateContentSha256 -AdapterPath $adapterFull -ExpectedAdapterSha256 $expectedAdapterSha256
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'package-validation'
        Start-StandardValidationStage -Stage $stage
        $invocation = Invoke-StandardValidationCommandAndRecord `
            -CommandSpec $adapterResult.commands.packageAdapter `
            -RunRoot $runRoot `
            -StageId $stage.id `
            -ToolId 'package-adapter' `
            -CandidateId $candidateId `
            -ExpectedActiveSkills $adapterResult.skills.ids `
            -SnapshotRoot $snapshotRoot `
            -ExpectedSnapshotContentSha256 $expectedCandidateContentSha256 `
            -SkillsRoot $snapshotSkillsRoot `
            -ActiveSkillsText $activeSkillsText `
            -OriginalCandidateRoot $originalCandidateRoot `
            -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
            -AdapterPath $adapterFull `
            -ExpectedAdapterSha256 $expectedAdapterSha256 `
            -TimeoutSeconds $TimeoutSeconds `
            -CancellationPath $CancellationPath `
            -OutputReservationStream $outputReservationStream `
            -OutputReservationPath $outputFull `
            -OutputReservationToken $outputReservationToken
        $stage.events += $invocation.event
        $requiresHumanReview = [bool](Assert-StandardValidationFindings -Envelope $invocation.envelope -Context 'package adapter')
        if (Get-StandardValidationSemanticRequirement -Envelope $invocation.envelope -Context 'package adapter') {
            $analyzerSemanticRequired = $true
            [void]$semanticRequiredSources.Add('package-validation/package-adapter')
        }
        foreach ($skill in @($adapterResult.skills.records)) {
            foreach ($toolName in @('skillValidator', 'skillTools')) {
                $toolId = if ($toolName -ceq 'skillValidator') { 'skill-validator' } else { 'skill-tools' }
                $invocation = Invoke-StandardValidationCommandAndRecord `
                    -CommandSpec $adapterResult.commands[$toolName] `
                    -RunRoot $runRoot `
                    -StageId $stage.id `
                    -ToolId $toolId `
                    -CandidateId $candidateId `
                    -SkillId $skill.id `
                    -SkillInventorySha256 $skill.inventorySha256 `
                    -SnapshotRoot $snapshotRoot `
                    -ExpectedSnapshotContentSha256 $expectedCandidateContentSha256 `
                    -SkillsRoot $snapshotSkillsRoot `
                    -ActiveSkillsText $activeSkillsText `
                    -OriginalCandidateRoot $originalCandidateRoot `
                    -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
                    -AdapterPath $adapterFull `
                    -ExpectedAdapterSha256 $expectedAdapterSha256 `
                    -TimeoutSeconds $TimeoutSeconds `
                    -CancellationPath $CancellationPath `
                    -OutputReservationStream $outputReservationStream `
                    -OutputReservationPath $outputFull `
                    -OutputReservationToken $outputReservationToken
                $stage.events += $invocation.event
                if ([bool](Assert-StandardValidationFindings -Envelope $invocation.envelope -Context "$toolName/$($skill.id)")) { $requiresHumanReview = $true }
                if (Get-StandardValidationSemanticRequirement -Envelope $invocation.envelope -Context "$toolName/$($skill.id)") {
                    $analyzerSemanticRequired = $true
                    [void]$semanticRequiredSources.Add("package-validation/$toolId/$($skill.id)")
                }
            }
        }
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'skillspector-static'
        Start-StandardValidationStage -Stage $stage
        $invocation = Invoke-StandardValidationCommandAndRecord `
            -CommandSpec $adapterResult.commands.staticAnalyzer `
            -RunRoot $runRoot `
            -StageId $stage.id `
            -ToolId 'staticAnalyzer' `
            -CandidateId $candidateId `
            -ExpectedActiveSkills $adapterResult.skills.ids `
            -SnapshotRoot $snapshotRoot `
            -ExpectedSnapshotContentSha256 $expectedCandidateContentSha256 `
            -SkillsRoot $snapshotSkillsRoot `
            -ActiveSkillsText $activeSkillsText `
            -OriginalCandidateRoot $originalCandidateRoot `
            -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
            -AdapterPath $adapterFull `
            -ExpectedAdapterSha256 $expectedAdapterSha256 `
            -TimeoutSeconds $TimeoutSeconds `
            -CancellationPath $CancellationPath `
            -OutputReservationStream $outputReservationStream `
            -OutputReservationPath $outputFull `
            -OutputReservationToken $outputReservationToken
        $stage.events += $invocation.event
        if ([string](Get-StandardValidationProperty -Object $invocation.envelope -Name 'scannerIdentity') -ne 'development-fixture-static-analyzer' -and
            [string]::IsNullOrWhiteSpace([string](Get-StandardValidationProperty -Object $invocation.envelope -Name 'scannerIdentity'))) {
            throw 'FAILED|Static evidence is missing scanner identity.'
        }
        if ([string](Get-StandardValidationProperty -Object $invocation.envelope -Name 'analyzerCompleteness') -cne 'complete') {
            throw 'FAILED|Static analyzer coverage is incomplete.'
        }
        $staticSkills = Get-StandardValidationProperty -Object $invocation.envelope -Name 'activeSkills'
        if ($staticSkills -isnot [array] -or (@($staticSkills | Sort-Object) -join "`n") -cne (@($adapterResult.skills.ids | Sort-Object) -join "`n")) {
            throw 'FAILED|Static analyzer did not cover every active Skill.'
        }
        if ([bool](Assert-StandardValidationFindings -Envelope $invocation.envelope -Context 'Static analyzer')) { $requiresHumanReview = $true }
        if (Get-StandardValidationSemanticRequirement -Envelope $invocation.envelope -Context 'Static analyzer') {
            $analyzerSemanticRequired = $true
            [void]$semanticRequiredSources.Add('skillspector-static/staticAnalyzer')
        }
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'repository-tests'
        Start-StandardValidationStage -Stage $stage
        foreach ($test in @($adapterResult.repositoryTests)) {
            $invocation = Invoke-StandardValidationCommandAndRecord `
                -CommandSpec $test.command `
                -RunRoot $runRoot `
                -StageId $stage.id `
                -ToolId $test.id `
                -CandidateId $candidateId `
                -SnapshotRoot $snapshotRoot `
                -ExpectedSnapshotContentSha256 $expectedCandidateContentSha256 `
                -SkillsRoot $snapshotSkillsRoot `
                -ActiveSkillsText $activeSkillsText `
                -OriginalCandidateRoot $originalCandidateRoot `
                -ExpectedCandidateContentSha256 $expectedCandidateContentSha256 `
                -AdapterPath $adapterFull `
                -ExpectedAdapterSha256 $expectedAdapterSha256 `
                -TimeoutSeconds $TimeoutSeconds `
                -CancellationPath $CancellationPath `
                -OutputReservationStream $outputReservationStream `
                -OutputReservationPath $outputFull `
                -OutputReservationToken $outputReservationToken
            $stage.events += $invocation.event
        }
        Complete-StandardValidationStage -Stage $stage -Status passed
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        $stage = Get-StandardValidationStage -Stages $stages -Id 'conditional-semantic-scan'
        $effectiveSemanticTriggered = [bool]($SemanticTriggered -or $analyzerSemanticRequired)
        $stage.triggerDecision = [ordered]@{
            callerRequested = [bool]$SemanticTriggered
            analyzerRequired = [bool]$analyzerSemanticRequired
            analyzerSources = @($semanticRequiredSources.ToArray())
            effectiveTriggered = $effectiveSemanticTriggered
        }
        if (-not $effectiveSemanticTriggered) {
            Complete-StandardValidationStage -Stage $stage -Status 'not-applicable' -Reason 'Canonical analyzer envelopes did not require semantic analysis and the caller did not add a trigger.'
        }
        elseif (-not $SemanticConsent) {
            Start-StandardValidationStage -Stage $stage
            Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Explicit semantic provider, scope, purpose, and consent are required.'
            Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
            throw 'BLOCKED|Semantic scan was triggered without explicit consent.'
        }
        else {
            Start-StandardValidationStage -Stage $stage
            if ([string]::IsNullOrWhiteSpace($SemanticProvider) -or [string]::IsNullOrWhiteSpace($SemanticPurpose) -or [string]::IsNullOrWhiteSpace($SemanticScope)) {
                Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Semantic consent is missing provider, scope, or purpose.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                throw 'BLOCKED|Semantic consent metadata is incomplete.'
            }
            if ([string]::IsNullOrWhiteSpace($SemanticEvidencePath)) {
                Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Semantic consent has no candidate-bound evidence file.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                throw 'BLOCKED|Semantic consent requires candidate-bound semantic evidence.'
            }
            $semanticFullPath = Get-StandardValidationFullPath -Path $SemanticEvidencePath -Context 'semantic evidence'
            Assert-StandardValidationOutsideRoot -Path $semanticFullPath -Root $originalCandidateRoot -Context 'semantic evidence'
            Assert-StandardValidationOutsideRoot -Path $semanticFullPath -Root $artifactRootFull -Context 'semantic evidence'
            $semantic = Assert-StandardValidationImportedEvidence `
                -Path $semanticFullPath `
                -ExpectedType 'semantic' `
                -CandidateId $candidateId `
                -TrustAnchorRoot $trustAnchorRootFull `
                -CandidateRoot $originalCandidateRoot `
                -ArtifactsRoot $artifactRootFull `
                -Context 'semantic evidence'
            if ([string]$semantic.provider -cne $SemanticProvider -or [string]$semantic.purpose -cne $SemanticPurpose -or [string]$semantic.scope -cne $SemanticScope) {
                throw 'BLOCKED|Semantic evidence consent metadata does not match the invocation.'
            }
            $stage.events += [pscustomobject][ordered]@{ eventId = [guid]::NewGuid().ToString(); stageId = $stage.id; toolId = 'imported-semantic-evidence'; skillId = $null; candidateId = $candidateId; commandSha256 = Get-StandardValidationFileSha256 -Path $semanticFullPath -Context 'semantic evidence'; exitCode = 0; status = 'passed'; outputSha256 = Get-StandardValidationFileSha256 -Path $semanticFullPath -Context 'semantic evidence'; outputPath = $semanticFullPath; cleanedUp = $true }
            if ([bool](Assert-StandardValidationFindings -Envelope $semantic -Context 'semantic evidence')) { $requiresHumanReview = $true }
            Complete-StandardValidationStage -Stage $stage -Status passed
        }
        Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage

        foreach ($later in @(
            [pscustomobject]@{ id = 'ai-review'; type = 'ai-review'; path = $AiReviewEvidencePath },
            [pscustomobject]@{ id = 'human-approval'; type = 'human-approval'; path = $HumanApprovalEvidencePath },
            [pscustomobject]@{ id = 'publish-or-install'; type = 'publish-install'; path = $PublishInstallEvidencePath },
            [pscustomobject]@{ id = 'post-install-verification'; type = 'post-install'; path = $PostInstallEvidencePath }
        )) {
            $stage = Get-StandardValidationStage -Stages $stages -Id $later.id
            if (-not $CompleteLifecycle) {
                Complete-StandardValidationStage -Stage $stage -Status 'not-applicable' -Reason 'Validation-only run does not perform release lifecycle stages.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                continue
            }
            Start-StandardValidationStage -Stage $stage
            if ([string]::IsNullOrWhiteSpace([string]$later.path)) {
                Complete-StandardValidationStage -Stage $stage -Status blocked -Reason 'Required lifecycle evidence is missing.'
                Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
                throw "BLOCKED|$($later.id) requires structured candidate-bound evidence."
            }
            $laterEvidencePath = Get-StandardValidationFullPath -Path ([string]$later.path) -Context "$($later.id) evidence"
            Assert-StandardValidationOutsideRoot -Path $laterEvidencePath -Root $originalCandidateRoot -Context "$($later.id) evidence"
            Assert-StandardValidationOutsideRoot -Path $laterEvidencePath -Root $artifactRootFull -Context "$($later.id) evidence"
            $imported = Assert-StandardValidationImportedEvidence `
                -Path $laterEvidencePath `
                -ExpectedType ([string]$later.type) `
                -CandidateId $candidateId `
                -TrustAnchorRoot $trustAnchorRootFull `
                -CandidateRoot $originalCandidateRoot `
                -ArtifactsRoot $artifactRootFull `
                -Context "$($later.id) evidence"
            $stage.events += [pscustomobject][ordered]@{ eventId = [guid]::NewGuid().ToString(); stageId = $stage.id; toolId = "imported-$($later.type)"; skillId = $null; candidateId = $candidateId; commandSha256 = Get-StandardValidationFileSha256 -Path $laterEvidencePath -Context "$($later.id) evidence"; exitCode = 0; status = 'passed'; outputSha256 = Get-StandardValidationFileSha256 -Path $laterEvidencePath -Context "$($later.id) evidence"; outputPath = $laterEvidencePath; cleanedUp = $true }
            if ($later.type -ceq 'ai-review' -and
                [bool](Assert-StandardValidationAiReviewEvidence -Evidence $imported -CandidateId $candidateId -Context 'ai-review evidence')) {
                $requiresHumanReview = $true
            }
            Complete-StandardValidationStage -Stage $stage -Status passed
            Write-StandardValidationStageReceipt -RunRoot $runRoot -Stage $stage
        }
        if ($requiresHumanReview -and -not $CompleteLifecycle) {
            throw 'BLOCKED|A medium-severity finding requires human review before release.'
        }
        if ($CompleteLifecycle -and -not $DevelopmentHarness) { $releaseEligible = $true }
        Assert-StandardValidationAuthorityUnchanged -Authority $authorityEvidence
        $state = 'PASS'
        $failureState = $null
        $failureMessage = $null
    }
    catch {
        $rawMessage = [string]$_.Exception.Message
        $separator = $rawMessage.IndexOf('|')
        if ($separator -gt 0) {
            $candidateState = $rawMessage.Substring(0, $separator)
            if ($script:StandardValidationExitCodes.Contains($candidateState)) {
                $failureState = $candidateState
                $failureMessage = $rawMessage.Substring($separator + 1)
            }
            else { $failureState = 'FAILED'; $failureMessage = $rawMessage }
        }
        else { $failureState = 'FAILED'; $failureMessage = $rawMessage }
        $state = $failureState
        $releaseEligible = $false
        $failedStage = @($stages | Where-Object { $_.status -eq 'not-run' -and $null -ne $_.startedAt } | Select-Object -Last 1)
        if ($failedStage.Count -eq 1) {
            $status = if ($failureState -ceq 'BLOCKED') { 'blocked' } elseif ($failureState -ceq 'CANCELLED') { 'cancelled' } else { 'failed' }
            if ($null -ne $script:StandardValidationLastEvent -and
                @($failedStage[0].events | Where-Object { [string]$_.eventId -ceq [string]$script:StandardValidationLastEvent.eventId }).Count -eq 0) {
                $failedStage[0].events += $script:StandardValidationLastEvent
            }
            Complete-StandardValidationStage -Stage $failedStage[0] -Status $status -Reason $failureMessage
        }
        if ($failureState -ceq 'BLOCKED') {
            foreach ($remainingStage in @($stages | Where-Object { $_.status -eq 'not-run' })) {
                Complete-StandardValidationStage -Stage $remainingStage -Status 'not-applicable' -Reason 'A prior required consent, approval, or barrier was blocked.'
            }
        }
    }
    finally {
        $exitCode = [int]$script:StandardValidationExitCodes[$state]
        $finalEvidence = New-StandardValidationCandidateEvidence `
            -RunId $runId `
            -State $state `
            -ExitCode $exitCode `
            -ReleaseEligible $releaseEligible `
            -Candidate $candidateEvidence `
            -Adapter $adapterEvidence `
            -Authority $authorityEvidence `
            -Stages $stages `
            -FailureState $failureState `
            -FailureMessage $failureMessage `
            -ArtifactRoot $artifactRootFull `
            -LockPath $lockPath
        if ($null -ne $outputReservationStream -and -not $finalWritten) {
            try {
                Assert-StandardValidationOutputReservation `
                    -Path $outputFull `
                    -Stream $outputReservationStream `
                    -Token $outputReservationToken `
                    -Context 'Final evidence'
                Write-StandardValidationJsonReserved `
                    -Path $outputFull `
                    -Stream $outputReservationStream `
                    -Token $outputReservationToken `
                    -Value $finalEvidence
                $finalWritten = $true
            }
            catch {
                $state = 'FAILED'
                $failureState = 'FAILED'
                $failureMessage = "Final evidence reservation or write failed: $($_.Exception.Message)"
                $releaseEligible = $false
                $finalEvidence = New-StandardValidationCandidateEvidence `
                    -RunId $runId `
                    -State $state `
                    -ExitCode ([int]$script:StandardValidationExitCodes[$state]) `
                    -ReleaseEligible $false `
                    -Candidate $candidateEvidence `
                    -Adapter $adapterEvidence `
                    -Authority $authorityEvidence `
                    -Stages $stages `
                    -FailureState $failureState `
                    -FailureMessage $failureMessage `
                    -ArtifactRoot $artifactRootFull `
                    -LockPath $lockPath
                try {
                    $outputReservationStream.Dispose()
                    $outputReservationStream = $null
                    if ([System.IO.File]::Exists($outputFull)) {
                        [System.IO.File]::Delete($outputFull)
                    }
                    $replacementReservation = New-StandardValidationOutputReservation -Path $outputFull
                    $outputReservationStream = $replacementReservation.stream
                    $outputReservationToken = [string]$replacementReservation.token
                    Write-StandardValidationJsonReserved `
                        -Path $outputFull `
                        -Stream $outputReservationStream `
                        -Token $outputReservationToken `
                        -Value $finalEvidence
                    $finalWritten = $true
                }
                catch {
                    $finalWritten = $false
                }
            }
        }
        elseif ($null -ne $outputFull -and -not $finalWritten -and -not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
            # Failures that occur before the reservation can be established may
            # still emit create-only evidence, but never overwrite an existing
            # path owned by a previous execution.
            try {
                [void](Write-StandardValidationJsonCreate -Path $outputFull -Value $finalEvidence)
                $finalWritten = $true
            }
            catch {
                if ($state -eq 'PASS') {
                    $state = 'FAILED'
                    $failureState = 'FAILED'
                    $failureMessage = "Final evidence write failed: $($_.Exception.Message)"
                    $finalEvidence = New-StandardValidationCandidateEvidence `
                        -RunId $runId `
                        -State $state `
                        -ExitCode ([int]$script:StandardValidationExitCodes[$state]) `
                        -ReleaseEligible $false `
                        -Candidate $candidateEvidence `
                        -Adapter $adapterEvidence `
                        -Authority $authorityEvidence `
                        -Stages $stages `
                        -FailureState $failureState `
                        -FailureMessage $failureMessage `
                        -ArtifactRoot $artifactRootFull `
                        -LockPath $lockPath
                }
            }
        }
        if ($null -ne $outputReservationStream) {
            $outputReservationStream.Dispose()
            $outputReservationStream = $null
        }
    }
    return $finalEvidence
}

if ($DefineFunctionsOnly) { return }

$result = Invoke-StandardValidationRun `
    -CandidateRoot $CandidateRoot `
    -AdapterPath $AdapterPath `
    -ArtifactsRoot $ArtifactsRoot `
    -OutputPath $OutputPath `
    -SourceRepository $SourceRepository `
    -SourceRevision $SourceRevision `
    -BaseRevision $BaseRevision `
    -EventName $EventName `
    -CandidateArchivePath $CandidateArchivePath `
    -CandidateAcquisitionEvidencePath $CandidateAcquisitionEvidencePath `
    -CandidateArchiveSha256 $CandidateArchiveSha256 `
    -AuthorityRevision $AuthorityRevision `
    -AuthorityArchivePath $AuthorityArchivePath `
    -AuthoritySnapshotEvidencePath $AuthoritySnapshotEvidencePath `
    -TimeoutSeconds $TimeoutSeconds `
    -CancellationPath $CancellationPath `
    -TrustedToolRoot $TrustedToolRoot `
    -DevelopmentHarness ([bool]$DevelopmentHarness) `
    -SemanticTriggered ([bool]$SemanticTriggered) `
    -SemanticConsent ([bool]$SemanticConsent) `
    -SemanticProvider $SemanticProvider `
    -SemanticPurpose $SemanticPurpose `
    -SemanticScope $SemanticScope `
    -SemanticEvidencePath $SemanticEvidencePath `
    -AiReviewEvidencePath $AiReviewEvidencePath `
    -HumanApprovalEvidencePath $HumanApprovalEvidencePath `
    -PublishInstallEvidencePath $PublishInstallEvidencePath `
    -PostInstallEvidencePath $PostInstallEvidencePath `
    -CompleteLifecycle ([bool]$CompleteLifecycle)
$result | ConvertTo-Json -Depth 100
exit ([int]$result.exitCode)
