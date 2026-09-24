Set-StrictMode -Version 2.0

# SYP-220 Phase 1 local semantic bridge.
#
# This module is deliberately provider-agnostic.  Provider routes, consent,
# callbacks, and public verification keys are supplied by the caller.  It is
# a local contract/verification core, not a protected production supervisor,
# a trust-anchor store, or a signer service.

$script:StandardSemanticBridgeSchemaVersion = 2
$script:StandardSemanticBridgeArtifactClassification = 'local-semantic-bridge-v2'
$script:StandardSemanticBridgeAttestationType = 'local-semantic-bridge-v2'
$script:StandardSemanticBridgeAlgorithm = 'RSASSA-PKCS1-v1_5-SHA-256'
$script:StandardSemanticBridgeConsentExpiryGuardMessage = 'standard-semantic-bridge-consent-expired-before-callback-invocation'
$script:StandardSemanticBridgeConsentExpiryGuardDataKey = 'StandardSemanticBridge.InternalFailureKind'
$script:StandardSemanticBridgeConsentExpiryGuardFailureKind = 'ConsentExpiredBeforeCallbackInvocation'
$script:StandardSemanticBridgeChildReportedExpiryFailureKind = 'ChildReportedConsentExpiry'
$script:StandardSemanticBridgeCallbackCleanupFailureDataKey = 'CallbackCleanupError'
$script:StandardSemanticBridgeHex64 = '^[0-9a-f]{64}$'
$script:StandardSemanticBridgeGitObject = '^(?:[0-9a-f]{40}|[0-9a-f]{64})$'
$script:StandardSemanticBridgeCanonicalBase64 = '^[A-Za-z0-9+/]+={0,2}$'
$script:StandardSemanticBridgeCallbackStdoutQuotaCharacters = 16777216
$script:StandardSemanticBridgeCallbackStderrQuotaCharacters = 16384
# Module-private seam used only by the focused capability regression.  It is
# never exported and has no effect unless a test explicitly sets it in module
# scope for one invocation.
$script:StandardSemanticBridgeTestForceLinuxNamespaceUnavailable = $false

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $null -eq ('StandardSemanticBridgeProcessControlNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class StandardSemanticBridgeProcessControlNative
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

if ($null -eq ('StandardSemanticBridgeBoundedCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class StandardSemanticBridgeBoundedCaptureResult
{
    public string Text { get; private set; }
    public bool Exceeded { get; private set; }
    public int CharacterCount { get; private set; }

    public StandardSemanticBridgeBoundedCaptureResult(string text, bool exceeded, int characterCount)
    {
        Text = text;
        Exceeded = exceeded;
        CharacterCount = characterCount;
    }
}

public static class StandardSemanticBridgeBoundedCapture
{
    public static Task<StandardSemanticBridgeBoundedCaptureResult> Start(StreamReader reader, int quota)
    {
        if (reader == null) throw new ArgumentNullException("reader");
        if (quota < 1) throw new ArgumentOutOfRangeException("quota");
        return Task.Factory.StartNew(
            () => Read(reader, quota),
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    private static StandardSemanticBridgeBoundedCaptureResult Read(StreamReader reader, int quota)
    {
        var builder = new StringBuilder(Math.Min(quota, 4096));
        var buffer = new char[4096];
        var count = 0;
        while (true)
        {
            var read = reader.Read(buffer, 0, buffer.Length);
            if (read == 0) return new StandardSemanticBridgeBoundedCaptureResult(builder.ToString(), false, count);
            var remaining = quota - count;
            if (read > remaining)
            {
                if (remaining > 0) builder.Append(buffer, 0, remaining);
                return new StandardSemanticBridgeBoundedCaptureResult(builder.ToString(), true, quota);
            }
            builder.Append(buffer, 0, read);
            count += read;
        }
    }
}
'@
}

function Get-StandardSemanticBridgePropertyNames {
    param([Parameter(Mandatory = $true)] $Object)

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-StandardSemanticBridgeProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $null }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-StandardSemanticBridgePropertyNoEnumerate {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return }
        Write-Output -NoEnumerate $Object[$Name]
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { Write-Output -NoEnumerate $property.Value }
}

function Sort-StandardSemanticBridgeOrdinalStrings {
    param([AllowEmptyCollection()][string[]] $Values)
    $sorted = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $index = 0
        while ($index -lt $sorted.Count -and [string]::CompareOrdinal($sorted[$index], [string]$value) -le 0) { $index++ }
        $sorted.Insert($index, [string]$value)
    }
    return @($sorted.ToArray())
}

function Sort-StandardSemanticBridgeOrdinalObjects {
    param(
        [AllowEmptyCollection()][object[]] $Objects,
        [Parameter(Mandatory = $true)][scriptblock] $KeySelector
    )
    $sorted = New-Object System.Collections.Generic.List[object]
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($object in @($Objects)) {
        $key = [string](& $KeySelector $object)
        $index = 0
        while ($index -lt $keys.Count -and [string]::CompareOrdinal($keys[$index], $key) -le 0) { $index++ }
        $keys.Insert($index, $key)
        $sorted.Insert($index, $object)
    }
    return @($sorted.ToArray())
}

function Test-StandardSemanticBridgeHasProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-StandardSemanticBridgeExactProperties {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType] -or $Object -is [array]) {
        throw "$Context must be a structured object."
    }
    $actual = @(Get-StandardSemanticBridgePropertyNames -Object $Object)
    $actualSorted = @($actual | Sort-Object -CaseSensitive)
    $expectedSorted = @($Expected | Sort-Object -CaseSensitive)
    if (($actualSorted -join "`n") -cne ($expectedSorted -join "`n")) {
        throw "$Context has a non-canonical property set."
    }
}

function Test-StandardSemanticBridgeNumericSchemaVersion {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)][int] $Expected
    )

    if ($null -eq $Value) { return $false }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal
    )) {
        return $false
    }

    try {
        # JSON Schema's integer type includes mathematically integral JSON
        # numbers such as 2.0. Convert only recognized CLR numeric types so
        # strings and booleans cannot become valid through PowerShell casts.
        $numericValue = [Convert]::ToDecimal($Value, [Globalization.CultureInfo]::InvariantCulture)
        return $numericValue -eq [decimal]$Expected
    }
    catch { return $false }
}

function Assert-StandardSemanticBridgeNonEmptyScalar {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value) -or
        [string]$Value -match '[\x00-\x1f\x7f]') {
        throw "$Context must be a non-empty scalar string."
    }
    return [string]$Value
}

function Assert-StandardSemanticBridgeCanonicalBase64 {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $text = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Value -Context $Context
    if ($text -cnotmatch $script:StandardSemanticBridgeCanonicalBase64) {
        throw "$Context must match canonical base64 syntax."
    }
    try { $decoded = [Convert]::FromBase64String($text) }
    catch { throw "$Context is not valid base64." }
    if ([Convert]::ToBase64String($decoded) -cne $text) {
        throw "$Context must use canonical base64 encoding."
    }
    return $text
}

function Assert-StandardSemanticBridgeSha256 {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $text = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Value -Context $Context
    if ($text -cnotmatch $script:StandardSemanticBridgeHex64) { throw "$Context must be lowercase SHA-256 hex." }
    return $text
}

function Assert-StandardSemanticBridgeGitObject {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $text = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Value -Context $Context
    if ($text -cnotmatch $script:StandardSemanticBridgeGitObject) { throw "$Context must be a lowercase Git object id." }
    return $text
}

function Assert-StandardSemanticBridgeUri {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $text = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Value -Context $Context
    $uri = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "$Context must be an absolute credential-free HTTP(S) URI without query or fragment."
    }
    return $text
}

function ConvertTo-StandardSemanticBridgeCanonicalValue {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [single] -or $Value -is [double]) {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw 'canonical JSON does not permit NaN or Infinity.'
        }
        # Normalize through the invariant round-trip representation before
        # ConvertTo-Json.  The bridge contracts contain integer counts, but
        # this keeps generic digest callers from depending on a process
        # culture or a PowerShell numeric formatter.
        $roundTrip = $number.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        return [double]::Parse($roundTrip, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [decimal]) {
        $roundTrip = $Value.ToString('G29', [Globalization.CultureInfo]::InvariantCulture)
        return [decimal]::Parse($roundTrip, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [byte] -or
        $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or
        $Value -is [uint64]) {
        return $Value
    }
    if ($Value -is [Guid]) { return $Value.ToString() }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [byte[]]) { return [Convert]::ToBase64String($Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @(Sort-StandardSemanticBridgeOrdinalStrings -Values @($Value.Keys | ForEach-Object { [string]$_ }))) {
            $ordered[$key] = ConvertTo-StandardSemanticBridgeCanonicalValue -Value $Value[$key]
        }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-StandardSemanticBridgeCanonicalValue -Value $item)) }
        return ,([object[]]$items.ToArray())
    }
    if (@($Value.PSObject.Properties).Count -gt 0) {
        $ordered = [ordered]@{}
        foreach ($propertyName in @(Sort-StandardSemanticBridgeOrdinalStrings -Values @($Value.PSObject.Properties.Name))) {
            $ordered[$propertyName] = ConvertTo-StandardSemanticBridgeCanonicalValue -Value $Value.PSObject.Properties[$propertyName].Value
        }
        return [pscustomobject]$ordered
    }
    return $Value
}

function Get-StandardSemanticBridgeCanonicalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $Value)

    $canonical = ConvertTo-StandardSemanticBridgeCanonicalValue -Value $Value
    return (ConvertTo-Json -InputObject $canonical -Compress -Depth 100)
}

function Get-StandardSemanticBridgeSha256FromBytes {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-StandardSemanticBridgeSha256FromText {
    param([Parameter(Mandatory = $true)][string] $Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return Get-StandardSemanticBridgeSha256FromBytes -Bytes $utf8.GetBytes($Text)
}

function Test-StandardSemanticBridgeByteSequenceEqual {
    param([Parameter(Mandatory = $true)][byte[]] $Left, [Parameter(Mandatory = $true)][byte[]] $Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Get-StandardSemanticBridgeArtifactSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Artifact)
    $json = Get-StandardSemanticBridgeCanonicalJson -Value $Artifact
    return Get-StandardSemanticBridgeSha256FromText -Text $json
}

function ConvertTo-StandardSemanticBridgeUtcTimestamp {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $parsed = [DateTime]::MinValue
    if ($Value -is [DateTime]) { $parsed = $Value }
    elseif ($Value -is [string] -and [DateTime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { }
    else { throw "$Context must be an ISO-8601 timestamp." }
    if ($parsed.Kind -eq [DateTimeKind]::Unspecified) { throw "$Context must include an explicit UTC offset." }
    $utc = $parsed.ToUniversalTime()
    return $utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-StandardSemanticBridgeTimestamp {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $parsed = [DateTime]::MinValue
    $parsedDirectly = $Value -is [DateTime]
    if ($parsedDirectly) { $parsed = [DateTime]$Value }
    elseif (-not [DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw "$Context is not a valid UTC timestamp."
    }
    if (
        $parsed.Kind -eq [DateTimeKind]::Unspecified) { throw "$Context is not a valid UTC timestamp." }
    return $parsed.ToUniversalTime()
}

function Assert-StandardSemanticBridgeUuid {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $text = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Value -Context $Context
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($text, [ref]$guid)) { throw "$Context must be a UUID." }
    # Keep imported artifacts on the same canonical D-form used by the
    # constructors.  This also avoids accepting braces or a non-canonical
    # formatter that can hash differently across runtimes.
    if ($text -cne $guid.ToString('D')) { throw "$Context must be a canonical UUID." }
    return $guid.ToString('D')
}

function Assert-StandardSemanticBridgeAuthorizer {
    param(
        [Parameter(Mandatory = $true)] $Authorizer,
        [string] $Context = 'authorizer'
    )

    Assert-StandardSemanticBridgeExactProperties -Object $Authorizer -Expected @('subject', 'authorityScope', 'authenticationContext') -Context $Context
    return [pscustomobject][ordered]@{
        subject = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Authorizer 'subject') "$Context subject"
        authorityScope = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Authorizer 'authorityScope') "$Context authorityScope"
        authenticationContext = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Authorizer 'authenticationContext') "$Context authenticationContext"
    }
}

function Assert-StandardSemanticBridgeStringArray {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $AllowEmpty
    )
    if ($Value -isnot [array]) { throw "$Context must be an array." }
    if (-not $AllowEmpty -and @($Value).Count -eq 0) { throw "$Context must not be empty." }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Value)) {
        $text = Assert-StandardSemanticBridgeNonEmptyScalar -Value $entry -Context "$Context item"
        if (-not $seen.Add($text)) { throw "$Context contains a duplicate item." }
        [void]$result.Add($text)
    }
    return @($result.ToArray())
}

function Get-StandardSemanticBridgeAnalyzerEntries {
    param([Parameter(Mandatory = $true)] $Analyzers)
    if ($Analyzers -isnot [array] -or @($Analyzers).Count -eq 0) { throw 'analyzers must be a non-empty array.' }
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Analyzers)) {
        Assert-StandardSemanticBridgeExactProperties -Object $entry -Expected @('id', 'version', 'sourceSha256') -Context 'analyzer entry'
        $id = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $entry 'id') -Context 'analyzer id'
        $version = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $entry 'version') -Context 'analyzer version'
        $source = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $entry 'sourceSha256') -Context "analyzer '$id' sourceSha256"
        if (-not $ids.Add($id)) { throw "analyzer set contains a duplicate analyzer ID '$id'." }
        [void]$entries.Add([pscustomobject][ordered]@{ id = $id; version = $version; sourceSha256 = $source })
    }
    return @(Sort-StandardSemanticBridgeOrdinalObjects -Objects @($entries.ToArray()) -KeySelector { param($entry) '{0}@{1}' -f $entry.id, $entry.version })
}

function Get-StandardSemanticAnalyzerSetIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()] $Analyzers)

    $entries = @(Get-StandardSemanticBridgeAnalyzerEntries -Analyzers $Analyzers)
    $identities = @($entries | ForEach-Object { '{0}@{1}' -f $_.id, $_.version })
    $canonicalJson = Get-StandardSemanticBridgeCanonicalJson -Value $identities
    return 'semantic-analyzer-set-v1:{0}' -f (Get-StandardSemanticBridgeSha256FromText -Text $canonicalJson)
}

function New-StandardSemanticBridgeAnalyzerSet {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Analyzers)

    $entries = @(Get-StandardSemanticBridgeAnalyzerEntries -Analyzers $Analyzers)
    $identity = Get-StandardSemanticAnalyzerSetIdentity -Analyzers $entries
    return [pscustomobject][ordered]@{
        canonicalization = 'semantic-analyzer-set-v1'
        analyzers = @($entries)
        analyzerSetIdentity = $identity
    }
}

function Assert-StandardSemanticBridgeAnalyzerSet {
    param([Parameter(Mandatory = $true)] $AnalyzerSet, [string] $Context = 'analyzerSet')
    Assert-StandardSemanticBridgeExactProperties -Object $AnalyzerSet -Expected @('canonicalization', 'analyzers', 'analyzerSetIdentity') -Context $Context
    if ([string](Get-StandardSemanticBridgeProperty $AnalyzerSet 'canonicalization') -cne 'semantic-analyzer-set-v1') { throw "$Context has an unsupported canonicalization." }
    $rawAnalyzers = Get-StandardSemanticBridgePropertyNoEnumerate $AnalyzerSet 'analyzers'
    if ($rawAnalyzers -isnot [array]) { throw "$Context analyzers must be an array." }
    $entries = @(Get-StandardSemanticBridgeAnalyzerEntries -Analyzers $rawAnalyzers)
    $rawOrder = @($rawAnalyzers | ForEach-Object { '{0}@{1}' -f [string](Get-StandardSemanticBridgeProperty $_ 'id'), [string](Get-StandardSemanticBridgeProperty $_ 'version') }) -join "`n"
    $canonicalOrder = @($entries | ForEach-Object { '{0}@{1}' -f $_.id, $_.version }) -join "`n"
    if ($rawOrder -cne $canonicalOrder) { throw "$Context analyzers must be in exact ordinal id@version order." }
    $identity = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $AnalyzerSet 'analyzerSetIdentity') -Context "$Context identity"
    if ($identity -cne (Get-StandardSemanticAnalyzerSetIdentity -Analyzers $entries)) { throw "$Context identity is not self-consistent." }
    return [pscustomobject][ordered]@{ canonicalization = 'semantic-analyzer-set-v1'; analyzers = @($entries); analyzerSetIdentity = $identity }
}

function Assert-StandardSemanticBridgeSafePath {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $path = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Value -Context $Context
    if ($path.StartsWith('/') -or $path.StartsWith('\') -or $path -match '^[A-Za-z]:') { throw "$Context is not a safe relative path." }
    $parts = @($path.Replace('\', '/').Split('/'))
    if (@($parts | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) { throw "$Context is not a safe relative path." }
    return $path.Replace('\', '/')
}

function New-StandardSemanticBridgeProviderTextInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()] $TextItems)

    if ($TextItems -isnot [array] -or @($TextItems).Count -eq 0) { throw 'provider text inventory requires at least one text item.' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $items = New-Object System.Collections.Generic.List[object]
    $totalBytes = [int64]0
    foreach ($item in @($TextItems)) {
        $names = @(Get-StandardSemanticBridgePropertyNames -Object $item)
        if ($names -notcontains 'path' -or $names -notcontains 'contentKind') { throw 'provider text item is missing path or contentKind.' }
        $path = Assert-StandardSemanticBridgeSafePath -Value (Get-StandardSemanticBridgeProperty $item 'path') -Context 'provider text item path'
        $kind = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $item 'contentKind') -Context 'provider text item contentKind'
        if (-not $seen.Add($path)) { throw 'provider text inventory contains a duplicate path.' }
        $hasText = Test-StandardSemanticBridgeHasProperty -Object $item -Name 'text'
        $hasBytes = Test-StandardSemanticBridgeHasProperty -Object $item -Name 'bytes'
        if (($hasText -and $hasBytes) -or (-not $hasText -and -not $hasBytes)) { throw 'provider text item must contain exactly one text or bytes value.' }
        $bytes = $null
        if ($hasText) {
            $text = Get-StandardSemanticBridgeProperty $item 'text'
            if ($text -isnot [string]) { throw 'provider text item text must be a string.' }
            $bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes([string]$text)
        }
        else {
            $rawBytes = Get-StandardSemanticBridgePropertyNoEnumerate $item 'bytes'
            if ($rawBytes -isnot [byte[]]) { throw 'provider text item bytes must be a byte array.' }
            $bytes = [byte[]]$rawBytes
        }
        if ($bytes.Length -eq 0) { throw 'provider text item must contain at least one byte.' }
        $sha = Get-StandardSemanticBridgeSha256FromBytes -Bytes $bytes
        [void]$items.Add([pscustomobject][ordered]@{ path = $path; contentKind = $kind; byteCount = [int64]$bytes.Length; sha256 = $sha })
        $totalBytes += [int64]$bytes.Length
    }
    $sortedItems = @(Sort-StandardSemanticBridgeOrdinalObjects -Objects @($items.ToArray()) -KeySelector { param($item) [string]$item.path })
    $inventoryShape = [pscustomobject][ordered]@{ items = $sortedItems }
    $inventoryDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact $inventoryShape
    return [pscustomobject][ordered]@{
        items = $sortedItems
        sha256 = $inventoryDigest
        fileCount = [int]$sortedItems.Count
        byteCount = [int64]$totalBytes
    }
}

function Assert-StandardSemanticBridgeProviderTextInventory {
    param([Parameter(Mandatory = $true)] $Inventory, [string] $Context = 'providerTextInventory')
    Assert-StandardSemanticBridgeExactProperties -Object $Inventory -Expected @('items', 'sha256', 'fileCount', 'byteCount') -Context $Context
    $sha = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $Inventory 'sha256') -Context "$Context sha256"
    $rawItemsValue = Get-StandardSemanticBridgePropertyNoEnumerate $Inventory 'items'
    if ($rawItemsValue -isnot [array]) { throw "$Context items must be an array." }
    $itemsValue = @($rawItemsValue)
    if (@($itemsValue).Count -eq 0) { throw "$Context items must be a non-empty array." }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $items = New-Object System.Collections.Generic.List[object]
    [int64]$totalBytes = 0
    foreach ($item in @($itemsValue)) {
        Assert-StandardSemanticBridgeExactProperties -Object $item -Expected @('path', 'contentKind', 'byteCount', 'sha256') -Context "$Context item"
        $path = Assert-StandardSemanticBridgeSafePath -Value (Get-StandardSemanticBridgeProperty $item 'path') -Context "$Context item path"
        $kind = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $item 'contentKind') -Context "$Context item contentKind"
        if (-not $seen.Add($path)) { throw "$Context contains a duplicate path." }
        $byteCountValue = Get-StandardSemanticBridgeProperty $item 'byteCount'
        if ($byteCountValue -isnot [int] -and $byteCountValue -isnot [long] -and $byteCountValue -isnot [int64] -or [int64]$byteCountValue -le 0) { throw "$Context item byteCount is invalid." }
        $itemSha = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $item 'sha256') -Context "$Context item sha256"
        [void]$items.Add([pscustomobject][ordered]@{ path = $path; contentKind = $kind; byteCount = [int64]$byteCountValue; sha256 = $itemSha })
        $totalBytes += [int64]$byteCountValue
    }
    $sorted = @(Sort-StandardSemanticBridgeOrdinalObjects -Objects @($items.ToArray()) -KeySelector { param($item) [string]$item.path })
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ([string]$sorted[$i].path -cne [string]@($itemsValue)[$i].path) {
            # Inventory order is part of the strict contract.  Do not silently normalize an artifact.
            throw "$Context items must be in ordinal path order."
        }
    }
    if ([int]$Inventory.fileCount -ne $sorted.Count -or [int64]$Inventory.byteCount -ne $totalBytes) { throw "$Context count does not match its items." }
    $expectedSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject][ordered]@{ items = $sorted })
    if ($sha -cne $expectedSha) { throw "$Context sha256 is not self-consistent." }
    return [pscustomobject][ordered]@{ items = $sorted; sha256 = $sha; fileCount = [int]$sorted.Count; byteCount = [int64]$totalBytes }
}

function Assert-StandardSemanticBridgeBindings {
    param([Parameter(Mandatory = $true)] $Bindings, [string] $Context = 'bindings')
    Assert-StandardSemanticBridgeExactProperties -Object $Bindings -Expected @('candidate', 'authority', 'tool', 'launch') -Context $Context
    $candidate = Get-StandardSemanticBridgeProperty $Bindings 'candidate'
    Assert-StandardSemanticBridgeExactProperties -Object $candidate -Expected @('candidateId', 'sourceRepository', 'sourceRevision', 'baseRevision', 'sourceTree', 'inputInventorySha256') -Context "$Context candidate"
    $candidateId = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $candidate 'candidateId') -Context "$Context candidateId"
    $sourceRepository = Assert-StandardSemanticBridgeUri -Value (Get-StandardSemanticBridgeProperty $candidate 'sourceRepository') -Context "$Context sourceRepository"
    $sourceRevision = Assert-StandardSemanticBridgeGitObject -Value (Get-StandardSemanticBridgeProperty $candidate 'sourceRevision') -Context "$Context sourceRevision"
    $baseRevision = Assert-StandardSemanticBridgeGitObject -Value (Get-StandardSemanticBridgeProperty $candidate 'baseRevision') -Context "$Context baseRevision"
    $sourceTree = Assert-StandardSemanticBridgeGitObject -Value (Get-StandardSemanticBridgeProperty $candidate 'sourceTree') -Context "$Context sourceTree"
    $inputInventorySha256 = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $candidate 'inputInventorySha256') -Context "$Context inputInventorySha256"
    $authority = Get-StandardSemanticBridgeProperty $Bindings 'authority'
    Assert-StandardSemanticBridgeExactProperties -Object $authority -Expected @('repository', 'revision', 'tree', 'snapshotInventorySha256') -Context "$Context authority"
    $authorityRepository = Assert-StandardSemanticBridgeUri -Value (Get-StandardSemanticBridgeProperty $authority 'repository') -Context "$Context authority.repository"
    $authorityRevision = Assert-StandardSemanticBridgeGitObject -Value (Get-StandardSemanticBridgeProperty $authority 'revision') -Context "$Context authority.revision"
    $authorityTree = Assert-StandardSemanticBridgeGitObject -Value (Get-StandardSemanticBridgeProperty $authority 'tree') -Context "$Context authority.tree"
    $snapshotInventorySha256 = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $authority 'snapshotInventorySha256') -Context "$Context authority.snapshotInventorySha256"
    $tool = Get-StandardSemanticBridgeProperty $Bindings 'tool'
    Assert-StandardSemanticBridgeExactProperties -Object $tool -Expected @('toolId', 'version', 'packageSha256', 'resolverReceiptSha256') -Context "$Context tool"
    $toolId = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $tool 'toolId') -Context "$Context toolId"
    $toolVersion = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $tool 'version') -Context "$Context tool version"
    $packageSha256 = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $tool 'packageSha256') -Context "$Context tool packageSha256"
    $resolverReceiptSha256 = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $tool 'resolverReceiptSha256') -Context "$Context tool resolverReceiptSha256"
    $launch = Get-StandardSemanticBridgeProperty $Bindings 'launch'
    Assert-StandardSemanticBridgeExactProperties -Object $launch -Expected @('resolutionRunId', 'launchReceiptSha256', 'consumptionSha256') -Context "$Context launch"
    $runId = Assert-StandardSemanticBridgeNonEmptyScalar -Value (Get-StandardSemanticBridgeProperty $launch 'resolutionRunId') -Context "$Context launch resolutionRunId"
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($runId, [ref]$guid)) { throw "$Context launch resolutionRunId must be a UUID." }
    $launchReceiptSha256 = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $launch 'launchReceiptSha256') -Context "$Context launchReceiptSha256"
    $consumptionSha256 = Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $launch 'consumptionSha256') -Context "$Context consumptionSha256"
    return [pscustomobject][ordered]@{
        candidate = [pscustomobject][ordered]@{ candidateId = $candidateId; sourceRepository = $sourceRepository; sourceRevision = $sourceRevision; baseRevision = $baseRevision; sourceTree = $sourceTree; inputInventorySha256 = $inputInventorySha256 }
        authority = [pscustomobject][ordered]@{ repository = $authorityRepository; revision = $authorityRevision; tree = $authorityTree; snapshotInventorySha256 = $snapshotInventorySha256 }
        tool = [pscustomobject][ordered]@{ toolId = $toolId; version = $toolVersion; packageSha256 = $packageSha256; resolverReceiptSha256 = $resolverReceiptSha256 }
        launch = [pscustomobject][ordered]@{ resolutionRunId = $guid.ToString(); launchReceiptSha256 = $launchReceiptSha256; consumptionSha256 = $consumptionSha256 }
    }
}

function Assert-StandardSemanticBridgeProviderRoute {
    param([Parameter(Mandatory = $true)] $ProviderRoute, [string] $Context = 'providerRoute')
    Assert-StandardSemanticBridgeExactProperties -Object $ProviderRoute -Expected @('provider', 'adapter', 'accountOrTenant', 'model', 'endpoint', 'dataRegion', 'retentionPolicy', 'trainingPolicy') -Context $Context
    return [pscustomobject][ordered]@{
        provider = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'provider') "$Context provider"
        adapter = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'adapter') "$Context adapter"
        accountOrTenant = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'accountOrTenant') "$Context accountOrTenant"
        model = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'model') "$Context model"
        endpoint = Assert-StandardSemanticBridgeUri (Get-StandardSemanticBridgeProperty $ProviderRoute 'endpoint') "$Context endpoint"
        dataRegion = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'dataRegion') "$Context dataRegion"
        retentionPolicy = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'retentionPolicy') "$Context retentionPolicy"
        trainingPolicy = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $ProviderRoute 'trainingPolicy') "$Context trainingPolicy"
    }
}

function Assert-StandardSemanticBridgeScope {
    param([Parameter(Mandatory = $true)] $Scope, [string] $Context = 'scope')
    Assert-StandardSemanticBridgeExactProperties -Object $Scope -Expected @('description', 'paths', 'contentKinds') -Context $Context
    $description = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Scope 'description') "$Context description"
    $rawPaths = Get-StandardSemanticBridgePropertyNoEnumerate $Scope 'paths'
    $rawContentKinds = Get-StandardSemanticBridgePropertyNoEnumerate $Scope 'contentKinds'
    if ($rawPaths -isnot [array] -or $rawContentKinds -isnot [array]) { throw "$Context paths and contentKinds must be arrays." }
    $paths = Assert-StandardSemanticBridgeStringArray -Value $rawPaths -Context "$Context paths"
    $contentKinds = Assert-StandardSemanticBridgeStringArray -Value $rawContentKinds -Context "$Context contentKinds"
    foreach ($path in $paths) { [void](Assert-StandardSemanticBridgeSafePath -Value $path -Context "$Context path") }
    return [pscustomobject][ordered]@{ description = $description; paths = @(Sort-StandardSemanticBridgeOrdinalStrings -Values $paths); contentKinds = @(Sort-StandardSemanticBridgeOrdinalStrings -Values $contentKinds) }
}

function Assert-StandardSemanticBridgeScopeCoversInventory {
    param(
        [Parameter(Mandatory = $true)] $Scope,
        [Parameter(Mandatory = $true)] $Inventory,
        [string] $Context = 'scope'
    )

    $normalizedScope = Assert-StandardSemanticBridgeScope -Scope $Scope -Context $Context
    $normalizedInventory = Assert-StandardSemanticBridgeProviderTextInventory -Inventory $Inventory -Context "$Context providerTextInventory"
    $scopePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $scopeKinds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in @($normalizedScope.paths)) { [void]$scopePaths.Add([string]$path) }
    foreach ($kind in @($normalizedScope.contentKinds)) { [void]$scopeKinds.Add([string]$kind) }
    foreach ($item in @($normalizedInventory.items)) {
        if (-not $scopePaths.Contains([string]$item.path)) { throw "$Context does not cover provider inventory path '$($item.path)' exactly." }
        if (-not $scopeKinds.Contains([string]$item.contentKind)) { throw "$Context does not cover provider inventory contentKind '$($item.contentKind)' exactly." }
    }
    return $true
}

function New-StandardSemanticBridgeConsentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Bindings,
        [Parameter(Mandatory = $true)] $ProviderRoute,
        [Parameter(Mandatory = $true)][string] $Purpose,
        [Parameter(Mandatory = $true)] $Scope,
        [Parameter(Mandatory = $true)] $ProviderTextInventory,
        [Parameter(Mandatory = $true)] $AnalyzerSet,
        [string] $RequestId = ([Guid]::NewGuid().ToString()),
        [DateTime] $RequestedAt = [DateTime]::UtcNow,
        [DateTime] $ExpiresAt = [DateTime]::UtcNow.AddHours(1)
    )

    $normalizedBindings = Assert-StandardSemanticBridgeBindings -Bindings $Bindings
    $normalizedRoute = Assert-StandardSemanticBridgeProviderRoute -ProviderRoute $ProviderRoute
    $normalizedScope = Assert-StandardSemanticBridgeScope -Scope $Scope
    $normalizedInventory = Assert-StandardSemanticBridgeProviderTextInventory -Inventory $ProviderTextInventory
    $normalizedAnalyzers = Assert-StandardSemanticBridgeAnalyzerSet -AnalyzerSet $AnalyzerSet
    $requestGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($RequestId, [ref]$requestGuid)) { throw 'requestId must be a UUID.' }
    $requested = ConvertTo-StandardSemanticBridgeUtcTimestamp -Value $RequestedAt -Context 'requestedAt'
    $expires = ConvertTo-StandardSemanticBridgeUtcTimestamp -Value $ExpiresAt -Context 'expiresAt'
    $requestedDate = Get-StandardSemanticBridgeTimestamp -Value $requested -Context 'requestedAt'
    $expiresDate = Get-StandardSemanticBridgeTimestamp -Value $expires -Context 'expiresAt'
    if ($expiresDate -le $requestedDate) { throw 'expiresAt must be later than requestedAt.' }
    $purposeText = Assert-StandardSemanticBridgeNonEmptyScalar -Value $Purpose -Context 'purpose'
    $request = [pscustomobject][ordered]@{
        schemaVersion = $script:StandardSemanticBridgeSchemaVersion
        artifactType = 'semantic-consent-request-v2'
        artifactClassification = $script:StandardSemanticBridgeArtifactClassification
        requestId = $requestGuid.ToString()
        requestedAt = $requested
        expiresAt = $expires
        bindings = $normalizedBindings
        providerRoute = $normalizedRoute
        purpose = $purposeText
        scope = $normalizedScope
        providerTextInventory = $normalizedInventory
        analyzerSet = $normalizedAnalyzers
        consentPayloadSha256 = ('0' * 64)
    }
    $payload = [ordered]@{}
    foreach ($property in @($request.PSObject.Properties | Where-Object { $_.Name -ne 'consentPayloadSha256' })) { $payload[$property.Name] = $property.Value }
    $request.consentPayloadSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$payload)
    return $request
}

function New-StandardSemanticBridgeConsentDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] $Authorizer,
        [string] $DecisionId = ([Guid]::NewGuid().ToString()),
        [DateTime] $AuthorizedAt = [DateTime]::UtcNow
    )

    Assert-StandardSemanticBridgeExactProperties -Object $Request -Expected @('schemaVersion', 'artifactType', 'artifactClassification', 'requestId', 'requestedAt', 'expiresAt', 'bindings', 'providerRoute', 'purpose', 'scope', 'providerTextInventory', 'analyzerSet', 'consentPayloadSha256') -Context 'consent request'
    if (-not (Test-StandardSemanticBridgeNumericSchemaVersion -Value $Request.schemaVersion -Expected $script:StandardSemanticBridgeSchemaVersion) -or [string]$Request.artifactType -cne 'semantic-consent-request-v2' -or [string]$Request.artifactClassification -cne $script:StandardSemanticBridgeArtifactClassification) { throw 'consent request is not a v2 local bridge artifact.' }
    $payload = [ordered]@{}
    foreach ($property in @($Request.PSObject.Properties | Where-Object { $_.Name -ne 'consentPayloadSha256' })) { $payload[$property.Name] = $property.Value }
    if ([string]$Request.consentPayloadSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$payload))) { throw 'consent request payload digest is invalid.' }
    $requestNormalized = New-StandardSemanticBridgeConsentRequest -Bindings $Request.bindings -ProviderRoute $Request.providerRoute -Purpose ([string]$Request.purpose) -Scope $Request.scope -ProviderTextInventory $Request.providerTextInventory -AnalyzerSet $Request.analyzerSet -RequestId ([string]$Request.requestId) -RequestedAt (Get-StandardSemanticBridgeTimestamp $Request.requestedAt 'request requestedAt') -ExpiresAt (Get-StandardSemanticBridgeTimestamp $Request.expiresAt 'request expiresAt')
    if ((Get-StandardSemanticBridgeCanonicalJson $requestNormalized) -cne (Get-StandardSemanticBridgeCanonicalJson $Request)) { throw 'consent request is not self-consistent.' }
    $normalizedAuthorizer = Assert-StandardSemanticBridgeAuthorizer -Authorizer $Authorizer
    $decisionGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($DecisionId, [ref]$decisionGuid)) { throw 'decisionId must be a UUID.' }
    $authorized = ConvertTo-StandardSemanticBridgeUtcTimestamp -Value $AuthorizedAt -Context 'authorizedAt'
    $authorizedDate = Get-StandardSemanticBridgeTimestamp -Value $authorized -Context 'authorizedAt'
    $requestDate = Get-StandardSemanticBridgeTimestamp -Value $Request.requestedAt -Context 'request requestedAt'
    $expiryDate = Get-StandardSemanticBridgeTimestamp -Value $Request.expiresAt -Context 'request expiresAt'
    if ($authorizedDate -lt $requestDate -or $authorizedDate -ge $expiryDate) { throw 'authorizedAt must be within the requested consent validity window.' }
    $decision = [pscustomobject][ordered]@{
        schemaVersion = $script:StandardSemanticBridgeSchemaVersion
        artifactType = 'semantic-consent-decision-v2'
        artifactClassification = $script:StandardSemanticBridgeArtifactClassification
        decisionId = $decisionGuid.ToString()
        requestId = [string]$Request.requestId
        consentRequestSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $Request
        bindings = $Request.bindings
        providerRoute = $Request.providerRoute
        purpose = [string]$Request.purpose
        scope = $Request.scope
        providerTextInventory = $Request.providerTextInventory
        analyzerSet = $Request.analyzerSet
        authorizer = $normalizedAuthorizer
        authorizedAt = $authorized
        expiresAt = [string]$Request.expiresAt
        consentGranted = $true
        consentDecisionPayloadSha256 = ('0' * 64)
    }
    $decisionPayload = [ordered]@{}
    foreach ($property in @($decision.PSObject.Properties | Where-Object { $_.Name -ne 'consentDecisionPayloadSha256' })) { $decisionPayload[$property.Name] = $property.Value }
    $decision.consentDecisionPayloadSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$decisionPayload)
    return $decision
}

function Test-StandardSemanticBridgeConsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $ConsentRequest,
        [Parameter(Mandatory = $true)] $ConsentDecision,
        [Parameter(Mandatory = $true)] $CurrentBindings,
        [Parameter(Mandatory = $true)] $CurrentProviderRoute,
        [Parameter(Mandatory = $true)][string] $CurrentPurpose,
        [Parameter(Mandatory = $true)] $CurrentScope,
        [Parameter(Mandatory = $true)] $CurrentProviderTextInventory,
        [Parameter(Mandatory = $true)] $CurrentAnalyzerSet,
        [DateTime] $Now = [DateTime]::UtcNow
    )

    try {
        Assert-StandardSemanticBridgeExactProperties -Object $ConsentRequest -Expected @('schemaVersion', 'artifactType', 'artifactClassification', 'requestId', 'requestedAt', 'expiresAt', 'bindings', 'providerRoute', 'purpose', 'scope', 'providerTextInventory', 'analyzerSet', 'consentPayloadSha256') -Context 'consent request'
        Assert-StandardSemanticBridgeExactProperties -Object $ConsentDecision -Expected @('schemaVersion', 'artifactType', 'artifactClassification', 'decisionId', 'requestId', 'consentRequestSha256', 'bindings', 'providerRoute', 'purpose', 'scope', 'providerTextInventory', 'analyzerSet', 'authorizer', 'authorizedAt', 'expiresAt', 'consentGranted', 'consentDecisionPayloadSha256') -Context 'consent decision'
        if (-not (Test-StandardSemanticBridgeNumericSchemaVersion -Value $ConsentRequest.schemaVersion -Expected $script:StandardSemanticBridgeSchemaVersion) -or [string]$ConsentRequest.artifactType -cne 'semantic-consent-request-v2' -or [string]$ConsentRequest.artifactClassification -cne $script:StandardSemanticBridgeArtifactClassification) { throw 'consent request schema mismatch.' }
        if (-not (Test-StandardSemanticBridgeNumericSchemaVersion -Value $ConsentDecision.schemaVersion -Expected $script:StandardSemanticBridgeSchemaVersion) -or [string]$ConsentDecision.artifactType -cne 'semantic-consent-decision-v2' -or [string]$ConsentDecision.artifactClassification -cne $script:StandardSemanticBridgeArtifactClassification) { throw 'consent decision schema mismatch.' }
        $requestId = Assert-StandardSemanticBridgeUuid -Value (Get-StandardSemanticBridgeProperty $ConsentRequest 'requestId') -Context 'consent request requestId'
        $decisionId = Assert-StandardSemanticBridgeUuid -Value (Get-StandardSemanticBridgeProperty $ConsentDecision 'decisionId') -Context 'consent decision decisionId'
        $decisionRequestId = Assert-StandardSemanticBridgeUuid -Value (Get-StandardSemanticBridgeProperty $ConsentDecision 'requestId') -Context 'consent decision requestId'
        if ($decisionRequestId -cne $requestId) { throw 'consent request and decision IDs do not match.' }
        [void](Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $ConsentRequest 'consentPayloadSha256') -Context 'consent request payload digest')
        [void](Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $ConsentDecision 'consentRequestSha256') -Context 'consent decision request digest')
        [void](Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $ConsentDecision 'consentDecisionPayloadSha256') -Context 'consent decision payload digest')
        $requestDigestPayload = [ordered]@{}
        foreach ($property in @($ConsentRequest.PSObject.Properties | Where-Object { $_.Name -ne 'consentPayloadSha256' })) { $requestDigestPayload[$property.Name] = $property.Value }
        if ([string]$ConsentRequest.consentPayloadSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$requestDigestPayload))) { throw 'consent request payload digest mismatch.' }
        $decisionDigestPayload = [ordered]@{}
        foreach ($property in @($ConsentDecision.PSObject.Properties | Where-Object { $_.Name -ne 'consentDecisionPayloadSha256' })) { $decisionDigestPayload[$property.Name] = $property.Value }
        if ([string]$ConsentDecision.consentDecisionPayloadSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact ([pscustomobject]$decisionDigestPayload))) { throw 'consent decision payload digest mismatch.' }
        if ([string]$ConsentDecision.consentRequestSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact $ConsentRequest)) { throw 'consent request artifact digest mismatch.' }
        if ($ConsentDecision.consentGranted -isnot [bool] -or -not [bool]$ConsentDecision.consentGranted) { throw 'consent was not explicitly granted.' }
        $requestRequestedAt = Get-StandardSemanticBridgeTimestamp -Value $ConsentRequest.requestedAt -Context 'consent request requestedAt'
        $requestExpiry = Get-StandardSemanticBridgeTimestamp -Value $ConsentRequest.expiresAt -Context 'consent request expiresAt'
        $decisionExpiry = Get-StandardSemanticBridgeTimestamp -Value $ConsentDecision.expiresAt -Context 'consent decision expiresAt'
        $authorizedAt = Get-StandardSemanticBridgeTimestamp -Value $ConsentDecision.authorizedAt -Context 'consent authorizedAt'
        if ($requestExpiry -le $requestRequestedAt) { throw 'consent request expiresAt must be later than requestedAt.' }
        if ($authorizedAt -lt $requestRequestedAt -or $authorizedAt -ge $requestExpiry) { throw 'consent authorizedAt must be within the requested consent validity window.' }
        $normalizedAuthorizer = Assert-StandardSemanticBridgeAuthorizer -Authorizer $ConsentDecision.authorizer -Context 'consent decision authorizer'
        $requestNormalized = New-StandardSemanticBridgeConsentRequest `
            -Bindings $ConsentRequest.bindings `
            -ProviderRoute $ConsentRequest.providerRoute `
            -Purpose ([string]$ConsentRequest.purpose) `
            -Scope $ConsentRequest.scope `
            -ProviderTextInventory $ConsentRequest.providerTextInventory `
            -AnalyzerSet $ConsentRequest.analyzerSet `
            -RequestId $requestId `
            -RequestedAt $requestRequestedAt `
            -ExpiresAt $requestExpiry
        if ((Get-StandardSemanticBridgeCanonicalJson $requestNormalized) -cne (Get-StandardSemanticBridgeCanonicalJson $ConsentRequest)) { throw 'consent request is not self-consistent.' }
        $decisionNormalized = New-StandardSemanticBridgeConsentDecision `
            -Request $requestNormalized `
            -Authorizer $normalizedAuthorizer `
            -DecisionId $decisionId `
            -AuthorizedAt $authorizedAt
        if ((Get-StandardSemanticBridgeCanonicalJson $decisionNormalized) -cne (Get-StandardSemanticBridgeCanonicalJson $ConsentDecision)) { throw 'consent decision is not self-consistent.' }
        $nowUtc = $Now.ToUniversalTime()
        if ($decisionExpiry -ne $requestExpiry -or $nowUtc -lt $authorizedAt -or $nowUtc -ge $decisionExpiry) { throw 'consent is missing, not yet active, or expired.' }
        $normalizedBindings = Assert-StandardSemanticBridgeBindings -Bindings $CurrentBindings
        $normalizedRoute = Assert-StandardSemanticBridgeProviderRoute -ProviderRoute $CurrentProviderRoute
        $normalizedScope = Assert-StandardSemanticBridgeScope -Scope $CurrentScope
        $normalizedInventory = Assert-StandardSemanticBridgeProviderTextInventory -Inventory $CurrentProviderTextInventory
        $normalizedAnalyzerSet = Assert-StandardSemanticBridgeAnalyzerSet -AnalyzerSet $CurrentAnalyzerSet
        [void](Assert-StandardSemanticBridgeScopeCoversInventory -Scope $normalizedScope -Inventory $normalizedInventory -Context 'current scope')
        $currentPurpose = Assert-StandardSemanticBridgeNonEmptyScalar -Value $CurrentPurpose -Context 'current purpose'
        foreach ($pair in @(
            @{ A = $ConsentRequest.bindings; B = $normalizedBindings; Name = 'candidate/source/authority/tool/launch bindings' },
            @{ A = $ConsentRequest.providerRoute; B = $normalizedRoute; Name = 'provider route' },
            @{ A = $ConsentRequest.scope; B = $normalizedScope; Name = 'scope' },
            @{ A = $ConsentRequest.providerTextInventory; B = $normalizedInventory; Name = 'provider text inventory' },
            @{ A = $ConsentRequest.analyzerSet; B = $normalizedAnalyzerSet; Name = 'analyzer set' }
        )) {
            if ((Get-StandardSemanticBridgeCanonicalJson $pair.A) -cne (Get-StandardSemanticBridgeCanonicalJson $pair.B)) { throw "consent $($pair.Name) drifted." }
        }
        if ([string]$ConsentRequest.purpose -cne $currentPurpose) { throw 'consent purpose drifted.' }
        foreach ($name in @('bindings', 'providerRoute', 'purpose', 'scope', 'providerTextInventory', 'analyzerSet')) {
            if ((Get-StandardSemanticBridgeCanonicalJson (Get-StandardSemanticBridgeProperty $ConsentDecision $name)) -cne (Get-StandardSemanticBridgeCanonicalJson (Get-StandardSemanticBridgeProperty $ConsentRequest $name))) { throw "consent decision $name drifted from request." }
        }
        return [pscustomobject][ordered]@{ valid = $true; reason = $null; consentRequestSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $ConsentRequest; consentArtifactSha256 = Get-StandardSemanticBridgeArtifactSha256 -Artifact $ConsentDecision }
    }
    catch {
        return [pscustomobject][ordered]@{ valid = $false; reason = [string]$_.Exception.Message; consentRequestSha256 = $null; consentArtifactSha256 = $null }
    }
}

function Assert-StandardSemanticBridgeConsent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [hashtable] $Parameters)
    $result = Test-StandardSemanticBridgeConsent @Parameters
    if (-not [bool]$result.valid) { throw "semantic consent rejected: $($result.reason)" }
    return $result
}

function Get-StandardSemanticBridgeWorkItemKey {
    param(
        [Parameter(Mandatory = $true)] $Bindings,
        [Parameter(Mandatory = $true)] $ProviderRoute,
        [Parameter(Mandatory = $true)] $AnalyzerSet,
        [Parameter(Mandatory = $true)] $Item
    )
    $shape = [pscustomobject][ordered]@{ bindings = $Bindings; providerRoute = $ProviderRoute; analyzerSet = $AnalyzerSet; item = $Item }
    return 'semantic-work-item-v2:{0}' -f (Get-StandardSemanticBridgeArtifactSha256 -Artifact $shape)
}

function Test-StandardSemanticBridgeCanonicalSeverity {
    param([AllowNull()] $Severity)

    if ($Severity -isnot [string]) { return $false }
    foreach ($allowedSeverity in @('critical', 'high', 'medium', 'low', 'informational')) {
        if ([string]::Equals([string]$Severity, $allowedSeverity, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Assert-StandardSemanticBridgeFinding {
    param([Parameter(Mandatory = $true)] $Finding, [string] $Context = 'finding')
    Assert-StandardSemanticBridgeExactProperties -Object $Finding -Expected @('severity', 'fingerprint', 'ruleId', 'message', 'path', 'analyzerId') -Context $Context
    $severityValue = Get-StandardSemanticBridgeProperty $Finding 'severity'
    if (-not (Test-StandardSemanticBridgeCanonicalSeverity -Severity $severityValue)) { throw "$Context severity is unsupported." }
    $severity = [string]$severityValue
    $fingerprint = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Finding 'fingerprint') "$Context fingerprint"
    $ruleId = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Finding 'ruleId') "$Context ruleId"
    $message = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Finding 'message') "$Context message"
    $path = Assert-StandardSemanticBridgeSafePath (Get-StandardSemanticBridgeProperty $Finding 'path') "$Context path"
    $analyzerId = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $Finding 'analyzerId') "$Context analyzerId"
    return [pscustomobject][ordered]@{ severity = $severity; fingerprint = $fingerprint; ruleId = $ruleId; message = $message; path = $path; analyzerId = $analyzerId }
}

function Get-StandardSemanticBridgeCanonicalFindings {
    param([Parameter(Mandatory = $true)] $Findings)
    if ($Findings -isnot [array]) { throw 'provider findings must be an array.' }
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($finding in @($Findings)) { [void]$normalized.Add((Assert-StandardSemanticBridgeFinding -Finding $finding -Context 'provider finding')) }
    return @(Sort-StandardSemanticBridgeOrdinalObjects -Objects @($normalized.ToArray()) -KeySelector { param($finding) [string]$finding.analyzerId + [char]0 + [string]$finding.ruleId + [char]0 + [string]$finding.fingerprint + [char]0 + [string]$finding.path + [char]0 + [string]$finding.severity + [char]0 + [string]$finding.message })
}

function Get-StandardSemanticBridgeLedgerDigest {
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] $Entries)
    $sorted = @(Sort-StandardSemanticBridgeOrdinalObjects -Objects $Entries -KeySelector { param($entry) [string]$entry.idempotencyKey })
    return Get-StandardSemanticBridgeArtifactSha256 -Artifact @($sorted)
}

function ConvertFrom-StandardSemanticBridgeIsolatedValue {
    param([AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType] -or $Value -is [byte[]]) {
        return $Value
    }
    if ($Value -is [System.Collections.IList]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            [void]$items.Add((ConvertFrom-StandardSemanticBridgeIsolatedValue -Value $item))
        }
        Write-Output -NoEnumerate ([object[]]$items.ToArray())
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $dictionary = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $dictionary[[string]$key] = ConvertFrom-StandardSemanticBridgeIsolatedValue -Value $Value[$key]
        }
        return $dictionary
    }
    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })
    if ($properties.Count -gt 0) {
        $normalized = [ordered]@{}
        foreach ($property in $properties) {
            $normalized[[string]$property.Name] = ConvertFrom-StandardSemanticBridgeIsolatedValue -Value $property.Value
        }
        return [pscustomobject]$normalized
    }
    return $Value
}

function Test-StandardSemanticBridgeLinuxHost {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix -and
        [IO.Directory]::Exists('/proc') -and [IO.File]::Exists('/proc/self/ns/pid'))
}

function Get-StandardSemanticBridgeLinuxNamespaceIdentity {
    param([Parameter(Mandatory = $true)][int] $ProcessId)

    if (-not (Test-StandardSemanticBridgeLinuxHost)) { throw 'Linux PID namespace support is unavailable.' }
    $namespaceItem = Get-Item -LiteralPath ("/proc/{0}/ns/pid" -f $ProcessId) -ErrorAction Stop
    $target = [string]$namespaceItem.Target
    if ([string]::IsNullOrWhiteSpace($target)) { $target = [string]$namespaceItem.LinkTarget }
    if ([string]::IsNullOrWhiteSpace($target)) { throw "Could not identify PID namespace for process $ProcessId." }
    return $target
}

function Get-StandardSemanticBridgeLinuxProcessStat {
    param([Parameter(Mandatory = $true)][int] $ProcessId)

    if (-not (Test-StandardSemanticBridgeLinuxHost)) { throw 'Linux process inspection is unavailable.' }
    if ($ProcessId -le 0) { throw 'Linux process identity must use a positive PID.' }
    $processDirectory = "/proc/{0}" -f $ProcessId
    $statPath = Join-Path $processDirectory 'stat'
    if (-not [IO.Directory]::Exists($processDirectory)) { return $null }
    try { $stat = [IO.File]::ReadAllText($statPath) }
    catch {
        if ([IO.Directory]::Exists($processDirectory)) { throw "Could not read required process state ${statPath}: $($_.Exception.Message)" }
        return $null
    }
    $closeParen = $stat.LastIndexOf(')')
    if ($closeParen -lt 0 -or $closeParen + 2 -ge $stat.Length) { throw "Could not parse required process state $statPath." }
    $fields = $stat.Substring($closeParen + 2).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($fields.Count -le 19) { throw "Process state ${statPath} is incomplete." }
    $parentId = 0
    $startTime = 0L
    if (-not [int]::TryParse($fields[1], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parentId) -or
        -not [long]::TryParse($fields[19], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$startTime) -or
        $startTime -le 0) {
        throw "Could not parse required process identity ${statPath}."
    }
    $state = [string]$fields[0]
    if ([string]::IsNullOrWhiteSpace($state)) { throw "Could not parse required process state $statPath." }
    return [pscustomobject][ordered]@{
        ProcessId = $ProcessId
        ParentProcessId = $parentId
        StartTime = $startTime
        State = $state.Substring(0, 1)
    }
}

function Find-StandardSemanticBridgeLinuxNamespaceChildProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $WrapperProcessId,
        [Parameter(Mandatory = $true)][string] $NamespaceIdentity
    )

    $wrapperDirectory = "/proc/{0}" -f $WrapperProcessId
    $childrenPath = Join-Path (Join-Path (Join-Path $wrapperDirectory 'task') ([string]$WrapperProcessId)) 'children'
    if (-not [IO.Directory]::Exists($wrapperDirectory)) { return $null }
    try { $childrenText = [IO.File]::ReadAllText($childrenPath) }
    catch {
        if ([IO.Directory]::Exists($wrapperDirectory)) { throw "Could not read callback wrapper children ${childrenPath}: $($_.Exception.Message)" }
        return $null
    }
    foreach ($token in @($childrenText -split '\s+')) {
        $childProcessId = 0
        if (-not [int]::TryParse([string]$token, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$childProcessId) -or $childProcessId -le 0) { continue }
        $item = Get-StandardSemanticBridgeLinuxProcessStat -ProcessId $childProcessId
        if ($null -eq $item -or [int]$item.ParentProcessId -ne $WrapperProcessId) { continue }
        try {
            if ((Get-StandardSemanticBridgeLinuxNamespaceIdentity -ProcessId ([int]$item.ProcessId)) -cne $NamespaceIdentity) { continue }
            $status = [IO.File]::ReadAllText(("/proc/{0}/status" -f [int]$item.ProcessId))
            $nspidMatch = [regex]::Match($status, '(?m)^NSpid:\s+(.+)$')
            if (-not $nspidMatch.Success) { throw "Could not verify NSpid for process $($item.ProcessId)." }
            $nspids = @($nspidMatch.Groups[1].Value.Trim() -split '\s+')
            if ($nspids.Count -eq 0 -or [int]$nspids[$nspids.Count - 1] -ne 1) { continue }
            return $item
        }
        catch {
            if ([IO.Directory]::Exists(("/proc/{0}" -f [int]$item.ProcessId))) { throw }
        }
    }
    return $null
}

function Find-StandardSemanticBridgeLinuxNamespaceInitChildProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $WrapperProcessId,
        [Parameter(Mandatory = $true)][string] $ParentNamespaceIdentity
    )

    $wrapperDirectory = "/proc/{0}" -f $WrapperProcessId
    $childrenPath = Join-Path (Join-Path (Join-Path $wrapperDirectory 'task') ([string]$WrapperProcessId)) 'children'
    if (-not [IO.Directory]::Exists($wrapperDirectory)) { return $null }
    try { $childrenText = [IO.File]::ReadAllText($childrenPath) }
    catch {
        if ([IO.Directory]::Exists($wrapperDirectory)) { throw "Could not read callback wrapper children ${childrenPath}: $($_.Exception.Message)" }
        return $null
    }
    foreach ($token in @($childrenText -split '\s+')) {
        $childProcessId = 0
        if (-not [int]::TryParse([string]$token, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$childProcessId) -or $childProcessId -le 0) { continue }
        $item = Get-StandardSemanticBridgeLinuxProcessStat -ProcessId $childProcessId
        if ($null -eq $item -or [int]$item.ParentProcessId -ne $WrapperProcessId) { continue }
        try {
            $namespaceIdentity = Get-StandardSemanticBridgeLinuxNamespaceIdentity -ProcessId ([int]$item.ProcessId)
            if ([string]::Equals($namespaceIdentity, $ParentNamespaceIdentity, [StringComparison]::Ordinal)) { continue }
            $status = [IO.File]::ReadAllText(("/proc/{0}/status" -f [int]$item.ProcessId))
            $nspidMatch = [regex]::Match($status, '(?m)^NSpid:\s+(.+)$')
            if (-not $nspidMatch.Success) { throw "Could not verify NSpid for process $($item.ProcessId)." }
            $nspids = @($nspidMatch.Groups[1].Value.Trim() -split '\s+')
            if ($nspids.Count -eq 0 -or [int]$nspids[$nspids.Count - 1] -ne 1) { continue }
            return [pscustomobject][ordered]@{
                ProcessId = [int]$item.ProcessId
                StartTime = [long]$item.StartTime
                State = [string]$item.State
                NamespaceIdentity = $namespaceIdentity
            }
        }
        catch {
            if ([IO.Directory]::Exists(("/proc/{0}" -f [int]$item.ProcessId))) { throw }
        }
    }
    return $null
}

function Get-StandardSemanticBridgeLinuxNamespaceInitState {
    param(
        [Parameter(Mandatory = $true)][int] $InitProcessId,
        [Parameter(Mandatory = $true)][long] $InitStartTime
    )

    $item = Get-StandardSemanticBridgeLinuxProcessStat -ProcessId $InitProcessId
    if ($null -eq $item) {
        return [pscustomobject][ordered]@{ State = 'Absent'; ProcessId = $InitProcessId; StartTime = $InitStartTime }
    }
    if ([long]$item.StartTime -ne $InitStartTime) {
        return [pscustomobject][ordered]@{ State = 'Reused'; ProcessId = $InitProcessId; StartTime = [long]$item.StartTime }
    }
    if ([string]$item.State -in @('Z', 'X', 'x')) {
        return [pscustomobject][ordered]@{ State = 'Exited'; ProcessId = $InitProcessId; StartTime = $InitStartTime }
    }
    return [pscustomobject][ordered]@{ State = 'Running'; ProcessId = $InitProcessId; StartTime = $InitStartTime; LinuxState = [string]$item.State }
}

function Stop-StandardSemanticBridgeOwnedCallbackProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][bool] $JobAssigned,
        [Parameter(Mandatory = $true)][IntPtr] $JobHandle,
        [bool] $UnixPidNamespaceActive = $false
    )

    if ($JobAssigned) {
        if (-not [StandardSemanticBridgeProcessControlNative]::TryTerminateJobObject($JobHandle, 1)) {
            throw 'TerminateJobObject returned false.'
        }
        return
    }
    if ($UnixPidNamespaceActive) {
        # Invoke Kill directly on the retained Diagnostics.Process wrapper
        # reference; a prior HasExited/PID query would create a check-then-kill
        # window.  The wrapper is the only Unix process reference used here,
        # and unshare --kill-child=SIGKILL is the namespace cleanup contract.
        # The retained namespace-init identity is checked after termination;
        # never signal a raw PID or the wrapper's process group as a boundary.
        try { $Process.Kill() } catch { if (-not $Process.HasExited) { throw } }
        return
    }
    try { $Process.Kill() } catch { if (-not $Process.HasExited) { throw } }
}

function Wait-StandardSemanticBridgeOwnedCallbackProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][int] $TimeoutMilliseconds,
        [bool] $UnixPidNamespaceActive = $false,
        [int] $UnixPidNamespaceInitProcessId = -1,
        [long] $UnixPidNamespaceInitStartTime = -1,
        [ref] $FailureReason = [ref]$null
    )

    if ($UnixPidNamespaceActive) {
        if (-not $Process.HasExited -and -not $Process.WaitForExit($TimeoutMilliseconds)) {
            $FailureReason.Value = 'owned Linux PID namespace wrapper did not exit before cleanup deadline.'
            return $false
        }
        [void]$Process.WaitForExit(0)
        if ($UnixPidNamespaceInitProcessId -le 0 -or $UnixPidNamespaceInitStartTime -le 0) {
            $FailureReason.Value = 'Verified Linux PID namespace init identity was unavailable during cleanup.'
            return $false
        }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $stableExitStartedAt = $null
        $lastStateError = $null
        $lastState = $null
        try {
            do {
                try {
                    $initState = Get-StandardSemanticBridgeLinuxNamespaceInitState `
                        -InitProcessId $UnixPidNamespaceInitProcessId `
                        -InitStartTime $UnixPidNamespaceInitStartTime
                    $lastStateError = $null
                    $lastState = [string]$initState.State
                }
                catch {
                    # The retained PID is the only process identity observed
                    # after launch.  A transient /proc read race is retried,
                    # while a persistent read failure remains fail closed.
                    $lastStateError = [string]$_.Exception.Message
                    $lastState = $null
                    $stableExitStartedAt = $null
                }
                if ($null -eq $lastStateError -and $lastState -in @('Absent', 'Exited')) {
                    if ($null -eq $stableExitStartedAt) { $stableExitStartedAt = $deadline.ElapsedMilliseconds }
                    elseif (($deadline.ElapsedMilliseconds - $stableExitStartedAt) -ge 250) { return $true }
                }
                elseif ($null -eq $lastStateError -and $lastState -eq 'Reused') {
                    $FailureReason.Value = 'Verified Linux PID namespace init PID was reused before cleanup completed.'
                    return $false
                }
                elseif ($null -eq $lastStateError) {
                    $stableExitStartedAt = $null
                }
                if ($deadline.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                    if ($null -ne $lastStateError) {
                        $FailureReason.Value = "Retained Linux PID namespace init state could not be verified: $lastStateError"
                    }
                    else {
                        $FailureReason.Value = "Retained Linux PID namespace init remained in state '$lastState'."
                    }
                    return $false
                }
                Start-Sleep -Milliseconds 25
            } while ($true)
        }
        finally { $deadline.Stop() }
    }
    if (-not $Process.HasExited) { return $Process.WaitForExit($TimeoutMilliseconds) }
    return $true
}

function Get-StandardSemanticBridgeChildEnvironment {
    # ProcessStartInfo inherits the caller environment by default.  Callback
    # input and context cross the boundary through explicit stdin payloads, so
    # no bridge-specific environment variables are needed.  Keep only the
    # small OS/runtime surface required to start the current PowerShell host
    # consistently on Windows PowerShell 5.1, PowerShell 7, and Unix.
    $safeInheritedNames = @('TEMP', 'TMP')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # Keep the same vetted Windows/.NET startup surface used by the
        # bounded Pester and authority runners.  These values describe the
        # host/runtime and user profile locations only; callback/provider
        # configuration and credential namespaces remain excluded.
        $safeInheritedNames += @(
            'Path', 'PATHEXT', 'COMSPEC', 'SystemRoot', 'WINDIR', 'OS',
            'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER',
            'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMW6432',
            'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)', 'COMMONPROGRAMW6432',
            'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA'
        )
        # Deliberately omit PSExecutionPolicyPreference.  It is a launcher
        # policy override rather than a callback runtime dependency, so it
        # should not cross this boundary into callback descendants.
    }
    else {
        $safeInheritedNames += @(
            'PATH', 'TMPDIR', 'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE',
            'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER',
            'DOTNET_ROOT', 'DOTNET_ROOT_X64', 'XDG_RUNTIME_DIR'
        )
    }
    $childEnvironment = [ordered]@{}
    foreach ($name in $safeInheritedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -ne $value) { $childEnvironment[$name] = [string]$value }
    }
    return $childEnvironment
}

function New-StandardSemanticBridgePrivateDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Unix) { throw 'Private Unix directory creation is unavailable on this host.' }
    $unixModeType = [Type]::GetType('System.IO.UnixFileMode, System.Private.CoreLib')
    if ($null -eq $unixModeType) { throw 'The runtime does not expose UnixFileMode.' }
    $createMethods = @([IO.Directory].GetMethods() | Where-Object {
            $_.Name -ceq 'CreateDirectory' -and $_.IsStatic -and $_.GetParameters().Count -eq 2 -and
            $_.GetParameters()[0].ParameterType -eq [string] -and $_.GetParameters()[1].ParameterType -eq $unixModeType
        })
    if ($createMethods.Count -ne 1) { throw 'The runtime does not expose atomic private directory creation.' }
    $privateMode = [Enum]::ToObject($unixModeType, 448)
    [void]$createMethods[0].Invoke($null, [object[]]@($Path, $privateMode))
    $directoryInfo = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $directoryInfo.PSIsContainer -or (($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'PID namespace handshake directory is not a private regular directory.'
    }
    $getModeMethods = @([IO.File].GetMethods() | Where-Object {
            $_.Name -ceq 'GetUnixFileMode' -and $_.IsStatic -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType -eq [string]
        })
    if ($getModeMethods.Count -ne 1) { throw 'The runtime does not expose UnixFileMode verification.' }
    $actualMode = [int]$getModeMethods[0].Invoke($null, [object[]]@($Path))
    if (($actualMode -band 511) -ne 448) { throw "PID namespace handshake directory mode is not 0700 (actual $actualMode)." }
    $statPath = @('/usr/bin/stat', '/bin/stat') | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
    $idPath = @('/usr/bin/id', '/bin/id') | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$statPath) -or [string]::IsNullOrWhiteSpace([string]$idPath)) { throw 'Trusted owner verification tools are unavailable.' }
    $ownerOutput = @(& $statPath -c '%u' -- $Path 2>&1)
    $ownerExit = $LASTEXITCODE
    $uidOutput = @(& $idPath -u 2>&1)
    $uidExit = $LASTEXITCODE
    if ($ownerExit -ne 0 -or $uidExit -ne 0 -or $ownerOutput.Count -ne 1 -or $uidOutput.Count -ne 1 -or
        [string]$ownerOutput[0] -notmatch '^\d+$' -or [string]$uidOutput[0] -notmatch '^\d+$' -or
        [string]$ownerOutput[0] -cne [string]$uidOutput[0]) {
        throw 'PID namespace handshake directory owner verification failed.'
    }
}

function New-StandardSemanticBridgeConsentExpiryGuardException {
    param([Parameter(Mandatory = $true)][string] $Context)

    $exception = [InvalidOperationException]::new($script:StandardSemanticBridgeConsentExpiryGuardMessage)
    $exception.Data[$script:StandardSemanticBridgeConsentExpiryGuardDataKey] = $script:StandardSemanticBridgeConsentExpiryGuardFailureKind
    return $exception
}

function Test-StandardSemanticBridgeConsentExpiryGuardException {
    param([AllowNull()][Exception] $Exception)

    if ($null -eq $Exception) { return $false }
    $dataKey = $script:StandardSemanticBridgeConsentExpiryGuardDataKey
    if (-not $Exception.Data.Contains($dataKey)) { return $false }
    return [string]::Equals(
        [string]$Exception.Data[$dataKey],
        $script:StandardSemanticBridgeConsentExpiryGuardFailureKind,
        [StringComparison]::Ordinal
    )
}

function New-StandardSemanticBridgeChildReportedExpiryException {
    param(
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $Message
    )

    $exception = [InvalidOperationException]::new("$Context returned an untrusted child-reported consent-expiry failure: $Message")
    $exception.Data[$script:StandardSemanticBridgeConsentExpiryGuardDataKey] = $script:StandardSemanticBridgeChildReportedExpiryFailureKind
    return $exception
}

function Test-StandardSemanticBridgeChildReportedExpiryException {
    param([AllowNull()][Exception] $Exception)

    if ($null -eq $Exception) { return $false }
    $dataKey = $script:StandardSemanticBridgeConsentExpiryGuardDataKey
    if (-not $Exception.Data.Contains($dataKey)) { return $false }
    return [string]::Equals(
        [string]$Exception.Data[$dataKey],
        $script:StandardSemanticBridgeChildReportedExpiryFailureKind,
        [StringComparison]::Ordinal
    )
}

function Test-StandardSemanticBridgeCallbackCleanupFailureException {
    param([AllowNull()][Exception] $Exception)

    if ($null -eq $Exception) { return $false }
    $dataKey = $script:StandardSemanticBridgeCallbackCleanupFailureDataKey
    if (-not $Exception.Data.Contains($dataKey)) { return $false }
    return -not [string]::IsNullOrWhiteSpace([string]$Exception.Data[$dataKey])
}

function Invoke-StandardSemanticBridgeCallbackWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Callback,
        [AllowNull()] $Argument,
        [AllowNull()] $CallbackContext,
        [Parameter(Mandatory = $true)][int] $TimeoutMilliseconds,
        [AllowNull()] $ConsentExpiresAt = $null,
        [string] $Context = 'callback'
    )

    if ($TimeoutMilliseconds -le 0) { throw [TimeoutException]::new("$Context deadline was exceeded before invocation.") }
    $consentExpiresAtUtc = $null
    if ($null -ne $ConsentExpiresAt) {
        $consentExpiresAtUtc = Get-StandardSemanticBridgeTimestamp -Value $ConsentExpiresAt -Context "$Context consent expiry"
    }
    $hostExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([string]::IsNullOrWhiteSpace($hostExecutable) -or -not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
        throw [InvalidOperationException]::new("$Context could not resolve an isolated PowerShell host.")
    }
    $isUnixHost = ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix)
    $isLinuxHost = Test-StandardSemanticBridgeLinuxHost
    if ($isUnixHost -and -not $isLinuxHost) {
        throw [InvalidOperationException]::new("$Context cannot establish a trusted Linux PID namespace boundary on this host.")
    }
    if ($isLinuxHost -and $script:StandardSemanticBridgeTestForceLinuxNamespaceUnavailable) {
        throw [InvalidOperationException]::new("$Context cannot establish a trusted Linux PID namespace boundary because the capability probe was forced unavailable.")
    }

    # The callback runs in a separate process because PowerShell.Stop() is a
    # cooperative boundary: it can wait indefinitely for a callback blocked in
    # native or non-cooperative .NET code.  Only serialized request/context data
    # crosses this boundary.  The bootstrap emits one CLIXML envelope on stdout.
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
try {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
        $handshakePath = [Environment]::GetEnvironmentVariable('STANDARD_SEMANTIC_BRIDGE_PID_NAMESPACE_HANDSHAKE')
        if ([string]::IsNullOrWhiteSpace($handshakePath)) {
            throw 'Unix callback host did not receive its private PID namespace handshake path.'
        }
        $expectedParentNamespaceTarget = [Environment]::GetEnvironmentVariable('STANDARD_SEMANTIC_BRIDGE_PARENT_PID_NAMESPACE')
        if ([string]::IsNullOrWhiteSpace($expectedParentNamespaceTarget)) {
            throw 'Unix callback host did not receive the expected parent PID namespace identity.'
        }
        $namespaceItem = Get-Item -LiteralPath '/proc/self/ns/pid' -ErrorAction Stop
        $namespaceTarget = [string]$namespaceItem.Target
        if ([string]::IsNullOrWhiteSpace($namespaceTarget)) { $namespaceTarget = [string]$namespaceItem.LinkTarget }
        if ([string]::IsNullOrWhiteSpace($namespaceTarget)) {
            throw 'Unix callback host could not identify its PID namespace.'
        }
        if ([string]::Equals($namespaceTarget.Trim(), $expectedParentNamespaceTarget.Trim(), [StringComparison]::Ordinal)) {
            throw 'Unix callback host is still in the parent PID namespace.'
        }

        # This bootstrap runs only after setpriv has dropped every capability.
        # Fail before the parent releases the callback payload if that boundary
        # did not survive execve or if the expected private mount view is absent.
        $statusText = [IO.File]::ReadAllText('/proc/self/status')
        $statusValues = @{}
        foreach ($statusLine in @($statusText -split "`n")) {
            $statusMatch = [regex]::Match([string]$statusLine, '^([^:]+):\s*(.*?)\s*$')
            if ($statusMatch.Success) { $statusValues[$statusMatch.Groups[1].Value] = $statusMatch.Groups[2].Value }
        }
        foreach ($capabilityName in @('CapEff', 'CapPrm', 'CapBnd')) {
            if (-not $statusValues.ContainsKey($capabilityName) -or [string]$statusValues[$capabilityName] -notmatch '^0+$') {
                throw "Unix callback host retained $capabilityName after capability drop."
            }
        }
        if (-not $statusValues.ContainsKey('NoNewPrivs') -or [string]$statusValues.NoNewPrivs -cne '1') {
            throw 'Unix callback host did not retain the no_new_privs boundary.'
        }
        if (-not $statusValues.ContainsKey('Pid') -or [string]$statusValues.Pid -cne '1' -or
            -not $statusValues.ContainsKey('NSpid') -or @(([string]$statusValues.NSpid -split '\s+') | Where-Object { $_ -match '\S' }).Count -ne 1 -or
            [string](@(([string]$statusValues.NSpid -split '\s+') | Where-Object { $_ -match '\S' })[0]) -cne '1') {
            throw 'Unix callback host does not have the private procfs PID 1 view.'
        }

        $mountInfoLines = @([IO.File]::ReadAllLines('/proc/self/mountinfo'))
        if ($mountInfoLines.Count -eq 0) { throw 'Unix callback host mountinfo is empty.' }
        $mountRows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($mountInfoLine in $mountInfoLines) {
            $separatorIndex = ([string]$mountInfoLine).IndexOf(' - ', [StringComparison]::Ordinal)
            if ($separatorIndex -le 0) { throw 'Unix callback host mountinfo contains a malformed record.' }
            $leftFields = @(([string]$mountInfoLine).Substring(0, $separatorIndex).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
            $rightFields = @(([string]$mountInfoLine).Substring($separatorIndex + 3).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
            $mountId = 0L
            $parentMountId = 0L
            if ($leftFields.Count -lt 6 -or $rightFields.Count -lt 3 -or
                -not [long]::TryParse([string]$leftFields[0], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$mountId) -or
                -not [long]::TryParse([string]$leftFields[1], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parentMountId) -or
                $mountId -le 0 -or $parentMountId -le 0) {
                throw 'Unix callback host mountinfo contains an incomplete record.'
            }
            [void]$mountRows.Add([pscustomobject][ordered]@{
                    MountId = $mountId
                    ParentMountId = $parentMountId
                    MountPoint = [string]$leftFields[4]
                    FileSystemType = [string]$rightFields[0]
                })
        }
        $procMountRows = @($mountRows | Where-Object { [string]$_.FileSystemType -ceq 'proc' })
        if ($procMountRows.Count -eq 0 -or @($procMountRows | Where-Object { [string]$_.MountPoint -cne '/proc' }).Count -gt 0) {
            throw 'Unix callback host has an inherited procfs alias outside canonical /proc.'
        }
        $procMountStack = @($mountRows | Where-Object { [string]$_.MountPoint -ceq '/proc' })
        if ($procMountStack.Count -eq 0) { throw 'Unix callback host has no canonical /proc mount stack.' }
        $parentMountIdsAtProc = @($procMountStack | ForEach-Object { [long]$_.ParentMountId })
        $topProcMounts = @($procMountStack | Where-Object { $parentMountIdsAtProc -notcontains [long]$_.MountId })
        if ($topProcMounts.Count -ne 1 -or [string]$topProcMounts[0].FileSystemType -cne 'proc') {
            throw 'Unix callback host canonical /proc top mount is not one verified procfs instance.'
        }
        $handshakeTemporaryPath = "$handshakePath.tmp"
        [IO.File]::WriteAllText($handshakeTemporaryPath, "$PID`n$namespaceTarget")
        if ([IO.File]::Exists($handshakePath)) { [IO.File]::Delete($handshakePath) }
        [IO.File]::Move($handshakeTemporaryPath, $handshakePath)
    }
    $payloadXml = [Console]::In.ReadToEnd()
    $payload = [Management.Automation.PSSerializer]::Deserialize($payloadXml)
    $argument = [Management.Automation.PSSerializer]::Deserialize([string]$payload.argumentXml)
    $callbackContext = [Management.Automation.PSSerializer]::Deserialize([string]$payload.contextXml)
    $callback = [scriptblock]::Create([string]$payload.callbackText)
    $consentExpiryText = [string]$payload.consentExpiresAtUtc
    $consentExpired = $false
    if (-not [string]::IsNullOrWhiteSpace($consentExpiryText)) {
        $consentExpiry = [DateTime]::Parse(
            $consentExpiryText,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        if ([DateTime]::UtcNow -ge $consentExpiry) {
            $consentExpired = $true
        }
    }
    if ($consentExpired) {
        $envelope = [pscustomobject][ordered]@{
            succeeded = $false
            failureKind = 'consent-expired-before-callback-invocation'
            output = @()
            error = 'standard-semantic-bridge-consent-expired-before-callback-invocation'
        }
    }
    else {
        try {
            $output = @(& $callback $argument $callbackContext)
            $envelope = [pscustomobject][ordered]@{
                succeeded = $true
                failureKind = $null
                output = @($output)
                error = $null
            }
        }
        catch {
            $envelope = [pscustomobject][ordered]@{
                succeeded = $false
                failureKind = 'callback-failure'
                output = @()
                error = [string]$_.Exception.Message
            }
        }
    }
}
catch {
    $envelope = [pscustomobject][ordered]@{
        succeeded = $false
        failureKind = 'bootstrap-failure'
        output = @()
        error = [string]$_.Exception.Message
    }
}
[Console]::Out.Write([Management.Automation.PSSerializer]::Serialize($envelope, 100))
'@
    $encodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $payload = [pscustomobject][ordered]@{
        callbackText = $Callback.ToString()
        argumentXml = [Management.Automation.PSSerializer]::Serialize($Argument, 100)
        contextXml = [Management.Automation.PSSerializer]::Serialize($CallbackContext, 100)
        consentExpiresAtUtc = if ($null -eq $consentExpiresAtUtc) { $null } else { $consentExpiresAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    }
    $payloadXml = [Management.Automation.PSSerializer]::Serialize($payload, 100)
    $launchFileName = $hostExecutable
    $launchArguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedBootstrap"
    $namespaceLaunchRequested = $false
    $parentPidNamespaceIdentity = $null
    $setprivPath = $null
    $pidNamespaceHandshakeDirectory = $null
    $pidNamespaceHandshakePath = $null
    $pidNamespaceHandshakeTemporaryPath = $null
    if ($isLinuxHost) {
        $parentPidNamespaceIdentity = Get-StandardSemanticBridgeLinuxNamespaceIdentity -ProcessId $PID
        foreach ($candidateSetprivPath in @('/usr/bin/setpriv', '/bin/setpriv')) {
            $candidateInfo = $null
            try { $candidateInfo = Get-Item -LiteralPath $candidateSetprivPath -Force -ErrorAction Stop } catch { }
            if ($null -ne $candidateInfo -and -not $candidateInfo.PSIsContainer -and (($candidateInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                $setprivPath = $candidateSetprivPath
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$setprivPath)) {
            throw [InvalidOperationException]::new("$Context cannot establish a trusted Linux callback boundary because no absolute setpriv executable is available.")
        }
        foreach ($candidateUnsharePath in @('/usr/bin/unshare', '/bin/unshare')) {
            $candidateInfo = $null
            try { $candidateInfo = Get-Item -LiteralPath $candidateUnsharePath -Force -ErrorAction Stop } catch { }
            if ($null -ne $candidateInfo -and -not $candidateInfo.PSIsContainer -and (($candidateInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                $launchFileName = $candidateUnsharePath
                $quotedHostExecutable = '"' + $hostExecutable.Replace('"', '\"') + '"'
                $quotedSetprivPath = '"' + $setprivPath.Replace('"', '\"') + '"'
                $launchArguments = "--user --map-root-user --pid --fork --kill-child=SIGKILL --mount-proc -- $quotedSetprivPath --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- $quotedHostExecutable -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedBootstrap"
                $namespaceLaunchRequested = $true
                break
            }
        }
        if (-not $namespaceLaunchRequested) {
            throw [InvalidOperationException]::new("$Context cannot establish a trusted Linux PID namespace because no absolute unshare executable is available.")
        }
        $pidNamespaceHandshakeDirectory = Join-Path ([IO.Path]::GetTempPath()) ("standard-semantic-bridge-pidns-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $pidNamespaceHandshakePath = Join-Path $pidNamespaceHandshakeDirectory 'ready.txt'
        $pidNamespaceHandshakeTemporaryPath = "$pidNamespaceHandshakePath.tmp"
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $launchFileName
    $startInfo.Arguments = $launchArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Windows PowerShell 5.1 exposes EnvironmentVariables through a private
    # StringDictionary whose getter first enumerates the inherited block.  A
    # hosted runner can contain case variants such as PATH/Path, which makes
    # that getter fail before the allowlist can be applied.  Initialize the
    # actual backing field when it exists; PowerShell 7 uses the public
    # Environment dictionary instead.
    $environmentVariablesField = $startInfo.GetType().GetField('environmentVariables', [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic)
    if ($null -ne $environmentVariablesField) {
        $environment = New-Object 'System.Collections.Specialized.StringDictionary'
        $environmentVariablesField.SetValue($startInfo, $environment)
    }
    else {
        $environmentProperty = $startInfo.GetType().GetProperty('Environment')
        $environment = if ($null -eq $environmentProperty) { $null } else { $environmentProperty.GetValue($startInfo, $null) }
    }
    if ($null -eq $environment) {
        throw [InvalidOperationException]::new("$Context could not access its child environment dictionary.")
    }
    $environment.Clear()
    foreach ($entry in (Get-StandardSemanticBridgeChildEnvironment).GetEnumerator()) {
        $environment[[string]$entry.Key] = [string]$entry.Value
    }
    if ($namespaceLaunchRequested) {
        $environment['STANDARD_SEMANTIC_BRIDGE_PID_NAMESPACE_HANDSHAKE'] = [string]$pidNamespaceHandshakePath
        $environment['STANDARD_SEMANTIC_BRIDGE_PARENT_PID_NAMESPACE'] = [string]$parentPidNamespaceIdentity
    }
    $process = $null
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $jobHandle = [IntPtr]::Zero
    $jobAssigned = $false
    $unixPidNamespaceActive = $false
    $unixPidNamespaceIdentity = $null
    $unixPidNamespaceInitProcessId = -1
    $unixPidNamespaceInitStartTime = -1L
    $callbackProcessTerminationRequested = $false
    $primaryException = $null
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($namespaceLaunchRequested) { [void](New-StandardSemanticBridgePrivateDirectory -Path $pidNamespaceHandshakeDirectory) }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $jobHandle = [StandardSemanticBridgeProcessControlNative]::CreateKillOnCloseJob()
        }
        if (-not $process.Start()) { throw [InvalidOperationException]::new("$Context process did not start.") }
        $started = $true
        # The child blocks on stdin until the payload is closed.  Assigning it
        # before releasing that payload makes the Windows Job Object the
        # authoritative owner of every callback descendant, including on
        # Windows PowerShell 5.1 where Process.Kill(bool) is unavailable.
        if ($jobHandle -ne [IntPtr]::Zero) {
            if (-not [StandardSemanticBridgeProcessControlNative]::TryAssignProcessToJobObject($jobHandle, $process.Handle)) {
                try { $process.Kill() } catch { }
                throw [InvalidOperationException]::new("$Context process could not be assigned to its Windows Job Object.")
            }
            $jobAssigned = $true
        }
        # Drain both redirected pipes as soon as the child starts.  The Linux
        # bootstrap may report a pre-READY failure and exit before callback
        # input is released; keeping these bounded readers active lets the
        # parent retain that diagnostic without risking a full pipe deadlock.
        $stdoutTask = [StandardSemanticBridgeBoundedCapture]::Start(
            $process.StandardOutput,
            $script:StandardSemanticBridgeCallbackStdoutQuotaCharacters
        )
        $stderrTask = [StandardSemanticBridgeBoundedCapture]::Start(
            $process.StandardError,
            $script:StandardSemanticBridgeCallbackStderrQuotaCharacters
        )
        if ($isUnixHost) {
            # The unshare wrapper is the only process handle we own.  The
            # child writes its namespace-local PID (which may be 1) and its
            # namespace link target before reading stdin.  Resolve the actual
            # host PID only by finding the wrapper's direct child with that
            # namespace identity; never inspect /proc/1 as a host PID.
            $namespaceReady = $false
            $namespaceLauncherExitedBeforeReady = $false
            $namespaceDeadlineExpired = $false
            $lastHandshakeDiagnostic = 'the child bootstrap has not published its READY record.'
            $remainingAtHandshakeStart = [int]([Math]::Max(0, $TimeoutMilliseconds - [int][Math]::Min([int]::MaxValue, $deadline.ElapsedMilliseconds)))
            $namespaceHandshakeBudgetMilliseconds = [int]([Math]::Min(5000, $remainingAtHandshakeStart))
            $namespaceHandshakeDeadline = [Diagnostics.Stopwatch]::StartNew()
            try {
                $parentNamespaceIdentity = Get-StandardSemanticBridgeLinuxNamespaceIdentity -ProcessId $PID
                while (-not $namespaceReady -and -not $namespaceLauncherExitedBeforeReady) {
                    $remainingInvocationMilliseconds = $TimeoutMilliseconds - [int][Math]::Min([int]::MaxValue, $deadline.ElapsedMilliseconds)
                    if ($remainingInvocationMilliseconds -le 0) {
                        $namespaceDeadlineExpired = $true
                        break
                    }
                    if ($namespaceHandshakeDeadline.ElapsedMilliseconds -ge $namespaceHandshakeBudgetMilliseconds) { break }

                    if (Test-Path -LiteralPath $pidNamespaceHandshakePath -PathType Leaf) {
                        try {
                            $handshakeLines = @([IO.File]::ReadAllLines($pidNamespaceHandshakePath))
                            $namespacePid = 0
                            if ($handshakeLines.Count -lt 2 -or
                                -not [int]::TryParse([string]$handshakeLines[0], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$namespacePid) -or
                                $namespacePid -ne 1 -or
                                [string]::IsNullOrWhiteSpace([string]$handshakeLines[1]) -or
                                [string]$handshakeLines[1].Trim() -ceq $parentNamespaceIdentity) {
                                $lastHandshakeDiagnostic = 'the READY record was malformed or did not identify PID 1 in a distinct namespace.'
                            }
                            else {
                                $candidateNamespaceIdentity = [string]$handshakeLines[1].Trim()
                                $namespaceChildIdentity = Find-StandardSemanticBridgeLinuxNamespaceChildProcessIdentity `
                                    -WrapperProcessId $process.Id `
                                    -NamespaceIdentity $candidateNamespaceIdentity
                                if ($null -ne $namespaceChildIdentity -and
                                    [int]$namespaceChildIdentity.ProcessId -gt 0 -and
                                    [long]$namespaceChildIdentity.StartTime -gt 0 -and
                                    [string]$namespaceChildIdentity.State -notin @('Z', 'X', 'x') -and
                                    -not $process.HasExited) {
                                    $unixPidNamespaceIdentity = $candidateNamespaceIdentity
                                    $unixPidNamespaceInitProcessId = [int]$namespaceChildIdentity.ProcessId
                                    $unixPidNamespaceInitStartTime = [long]$namespaceChildIdentity.StartTime
                                    $unixPidNamespaceActive = $true
                                    $namespaceReady = $true
                                    break
                                }
                                $lastHandshakeDiagnostic = 'the READY record was valid, but no live matching direct PID-namespace init child was found.'
                            }
                        }
                        catch { $lastHandshakeDiagnostic = "reading or validating the READY record failed: $($_.Exception.Message)" }
                    }

                    # Retain a kernel-verified PID-namespace init identity even
                    # while the bootstrap is still validating procfs.  If the
                    # invocation expires before READY, cleanup can then verify
                    # the namespace became empty after killing its wrapper.
                    if (-not $unixPidNamespaceActive) {
                        try {
                            $observedNamespaceChild = Find-StandardSemanticBridgeLinuxNamespaceInitChildProcessIdentity `
                                -WrapperProcessId $process.Id `
                                -ParentNamespaceIdentity $parentNamespaceIdentity
                            if ($null -ne $observedNamespaceChild -and
                                [int]$observedNamespaceChild.ProcessId -gt 0 -and
                                [long]$observedNamespaceChild.StartTime -gt 0) {
                                $unixPidNamespaceIdentity = [string]$observedNamespaceChild.NamespaceIdentity
                                $unixPidNamespaceInitProcessId = [int]$observedNamespaceChild.ProcessId
                                $unixPidNamespaceInitStartTime = [long]$observedNamespaceChild.StartTime
                                $unixPidNamespaceActive = $true
                                $lastHandshakeDiagnostic = 'the namespace init identity is live; the bootstrap has not yet published READY.'
                            }
                        }
                        catch { $lastHandshakeDiagnostic = "finding the live namespace init child failed: $($_.Exception.Message)" }
                    }

                    foreach ($captureSpec in @(
                        [pscustomobject]@{ Name = 'stdout'; Task = $stdoutTask },
                        [pscustomobject]@{ Name = 'stderr'; Task = $stderrTask }
                    )) {
                        if (-not $captureSpec.Task.IsCompleted) { continue }
                        if ($captureSpec.Task.IsFaulted) {
                            $captureError = [string]$captureSpec.Task.Exception.GetBaseException().Message
                            $lastHandshakeDiagnostic = "$($captureSpec.Name) capture failed: $captureError"
                            continue
                        }
                        $captureResult = $captureSpec.Task.GetAwaiter().GetResult()
                        if ([bool]$captureResult.Exceeded) {
                            throw [InvalidOperationException]::new("$Context exceeded its isolated $($captureSpec.Name) quota before the Linux PID namespace handshake completed.")
                        }
                    }

                    if ($process.HasExited) {
                        $namespaceLauncherExitedBeforeReady = $true
                        break
                    }
                    $remainingHandshakeMilliseconds = $namespaceHandshakeBudgetMilliseconds - [int][Math]::Min([int]::MaxValue, $namespaceHandshakeDeadline.ElapsedMilliseconds)
                    $sleepMilliseconds = [int]([Math]::Min(10, [Math]::Min($remainingInvocationMilliseconds, $remainingHandshakeMilliseconds)))
                    if ($sleepMilliseconds -gt 0) { Start-Sleep -Milliseconds $sleepMilliseconds }
                }
                if (-not $namespaceReady -and -not $namespaceLauncherExitedBeforeReady -and
                    ($TimeoutMilliseconds - [int][Math]::Min([int]::MaxValue, $deadline.ElapsedMilliseconds)) -le 0) {
                    $namespaceDeadlineExpired = $true
                }
            }
            finally { $namespaceHandshakeDeadline.Stop() }
            if (-not $namespaceReady) {
                if ($namespaceLauncherExitedBeforeReady -or $process.HasExited) {
                    [void]$process.WaitForExit(0)
                    try { [void]$stdoutTask.Wait(1000) } catch { }
                    try { [void]$stderrTask.Wait(1000) } catch { }
                    $startupDiagnostics = New-Object 'System.Collections.Generic.List[string]'
                    [void]$startupDiagnostics.Add(("launcher exit code {0}" -f [int]$process.ExitCode))
                    $bootstrapError = $null
                    if ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted -and -not $stdoutTask.IsCanceled) {
                        $startupStdoutResult = $stdoutTask.GetAwaiter().GetResult()
                        $startupStdout = [string]$startupStdoutResult.Text
                        if (-not [string]::IsNullOrWhiteSpace($startupStdout)) {
                            try {
                                $startupEnvelope = [Management.Automation.PSSerializer]::Deserialize($startupStdout)
                                if ($null -ne $startupEnvelope -and
                                    $null -ne $startupEnvelope.PSObject.Properties['failureKind'] -and
                                    [string]$startupEnvelope.failureKind -ceq 'bootstrap-failure') {
                                    $bootstrapError = [string]$startupEnvelope.error
                                }
                                else { $bootstrapError = 'child exited without a bootstrap failure envelope.' }
                            }
                            catch { $bootstrapError = 'child emitted an unreadable bootstrap envelope.' }
                        }
                    }
                    elseif ($stdoutTask.IsFaulted) {
                        $bootstrapError = "stdout capture failed: $($stdoutTask.Exception.GetBaseException().Message)"
                    }
                    else { $bootstrapError = 'stdout capture did not complete before the diagnostic bound.' }
                    if (-not [string]::IsNullOrWhiteSpace($bootstrapError)) {
                        $boundedBootstrapError = $bootstrapError.Trim()
                        if ($boundedBootstrapError.Length -gt 512) { $boundedBootstrapError = $boundedBootstrapError.Substring(0, 512) }
                        [void]$startupDiagnostics.Add("bootstrap: $boundedBootstrapError")
                    }
                    if ($stderrTask.IsCompleted -and -not $stderrTask.IsFaulted -and -not $stderrTask.IsCanceled) {
                        $startupStderrResult = $stderrTask.GetAwaiter().GetResult()
                        $startupStderr = ([string]$startupStderrResult.Text).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($startupStderr)) {
                            if ($startupStderr.Length -gt 512) { $startupStderr = $startupStderr.Substring(0, 512) }
                            [void]$startupDiagnostics.Add("stderr: $startupStderr")
                        }
                    }
                    elseif ($stderrTask.IsFaulted) {
                        [void]$startupDiagnostics.Add("stderr capture failed: $($stderrTask.Exception.GetBaseException().Message)")
                    }
                    [void]$startupDiagnostics.Add("last handshake: $lastHandshakeDiagnostic")
                    throw [InvalidOperationException]::new("$Context Linux PID namespace launcher exited before READY ($($startupDiagnostics -join '; ')).")
                }
                if ($namespaceDeadlineExpired) {
                    throw [TimeoutException]::new("$Context deadline was exceeded during the Linux PID namespace handshake. Last handshake diagnostic: $lastHandshakeDiagnostic")
                }
                throw [InvalidOperationException]::new("$Context could not prove a live private Linux PID namespace within the bounded startup window. Last handshake diagnostic: $lastHandshakeDiagnostic")
            }
        }
        if ($null -ne $consentExpiresAtUtc -and [DateTime]::UtcNow -ge $consentExpiresAtUtc) {
            throw (New-StandardSemanticBridgeConsentExpiryGuardException -Context $Context)
        }
        $remainingBeforePayloadMilliseconds = $TimeoutMilliseconds - [int][Math]::Min([int]::MaxValue, $deadline.ElapsedMilliseconds)
        if ($remainingBeforePayloadMilliseconds -le 0) {
            throw [TimeoutException]::new("$Context deadline was exceeded before callback input was released.")
        }
        $process.StandardInput.Write($payloadXml)
        $process.StandardInput.Close()

        $quotaStream = $null
        while ($true) {
            foreach ($captureSpec in @(
                [pscustomobject]@{ Name = 'stdout'; Task = $stdoutTask },
                [pscustomobject]@{ Name = 'stderr'; Task = $stderrTask }
            )) {
                if (-not $captureSpec.Task.IsCompleted) { continue }
                if ($captureSpec.Task.IsFaulted) {
                    $captureError = [string]$captureSpec.Task.Exception.GetBaseException().Message
                    throw [InvalidOperationException]::new("$Context isolated $($captureSpec.Name) capture failed: $captureError")
                }
                $captureResult = $captureSpec.Task.GetAwaiter().GetResult()
                if ([bool]$captureResult.Exceeded) {
                    $quotaStream = [string]$captureSpec.Name
                    break
                }
            }
            if ($null -ne $quotaStream) {
                try {
                    Stop-StandardSemanticBridgeOwnedCallbackProcess `
                        -Process $process `
                        -JobAssigned $jobAssigned `
                        -JobHandle $jobHandle `
                        -UnixPidNamespaceActive $unixPidNamespaceActive
                    $callbackProcessTerminationRequested = $true
                }
                catch {
                    throw [InvalidOperationException]::new("$Context exceeded its isolated $quotaStream quota and its process tree could not be terminated.")
                }
                if (-not (Wait-StandardSemanticBridgeOwnedCallbackProcess -Process $process  -TimeoutMilliseconds 5000 -UnixPidNamespaceActive $unixPidNamespaceActive -UnixPidNamespaceInitProcessId $unixPidNamespaceInitProcessId -UnixPidNamespaceInitStartTime $unixPidNamespaceInitStartTime)) {
                    throw [InvalidOperationException]::new("$Context exceeded its isolated $quotaStream quota and its process did not terminate.")
                }
                throw [InvalidOperationException]::new("$Context exceeded its isolated $quotaStream quota.")
            }

            if ($process.HasExited -and -not $callbackProcessTerminationRequested) {
                # A callback child may inherit one of the host's output handles.
                # Terminate the owned boundary as soon as the host exits so the
                # bounded capture tasks cannot wait for a late descendant side
                # effect before cleanup runs.
                try {
                    Stop-StandardSemanticBridgeOwnedCallbackProcess `
                        -Process $process `
                        -JobAssigned $jobAssigned `
                        -JobHandle $jobHandle `
                        -UnixPidNamespaceActive $unixPidNamespaceActive
                    $callbackProcessTerminationRequested = $true
                    if ($unixPidNamespaceActive) {
                        $waitFailure = $null
                        if (-not (Wait-StandardSemanticBridgeOwnedCallbackProcess -Process $process  -TimeoutMilliseconds 5000 -UnixPidNamespaceActive $unixPidNamespaceActive -UnixPidNamespaceInitProcessId $unixPidNamespaceInitProcessId -UnixPidNamespaceInitStartTime $unixPidNamespaceInitStartTime -FailureReason ([ref]$waitFailure))) {
                            $detail = if ([string]::IsNullOrWhiteSpace([string]$waitFailure)) { 'no cleanup diagnostic was available' } else { [string]$waitFailure }
                            throw [InvalidOperationException]::new("$Context callback host exited but its PID namespace did not become empty: $detail")
                        }
                    }
                }
                catch {
                    $detail = [string]$_.Exception.Message
                    throw [InvalidOperationException]::new("$Context callback host exited but its owned process boundary could not be terminated: $detail", $_.Exception)
                }
            }
            $remaining = $TimeoutMilliseconds - [int][Math]::Min([int]::MaxValue, $deadline.ElapsedMilliseconds)
            if ($remaining -le 0) {
                try {
                    Stop-StandardSemanticBridgeOwnedCallbackProcess `
                        -Process $process `
                        -JobAssigned $jobAssigned `
                        -JobHandle $jobHandle `
                        -UnixPidNamespaceActive $unixPidNamespaceActive
                    $callbackProcessTerminationRequested = $true
                }
                catch {
                    throw [TimeoutException]::new("$Context deadline was exceeded and its isolated process tree could not be terminated.")
                }
                if (-not (Wait-StandardSemanticBridgeOwnedCallbackProcess -Process $process  -TimeoutMilliseconds 5000 -UnixPidNamespaceActive $unixPidNamespaceActive -UnixPidNamespaceInitProcessId $unixPidNamespaceInitProcessId -UnixPidNamespaceInitStartTime $unixPidNamespaceInitStartTime)) {
                    throw [TimeoutException]::new("$Context deadline was exceeded and its isolated process did not terminate.")
                }
                throw [TimeoutException]::new("$Context deadline was exceeded.")
            }
            if ($process.HasExited -and $stdoutTask.IsCompleted -and $stderrTask.IsCompleted) { break }
            if ($process.HasExited) { Start-Sleep -Milliseconds ([Math]::Min(50, $remaining)) }
            else { [void]$process.WaitForExit([Math]::Min(50, $remaining)) }
        }

        $stdoutResult = $stdoutTask.GetAwaiter().GetResult()
        $stderrResult = $stderrTask.GetAwaiter().GetResult()
        $stdout = [string]$stdoutResult.Text
        $stderr = [string]$stderrResult.Text
        if ([bool]$stdoutResult.Exceeded -or [bool]$stderrResult.Exceeded) {
            $quotaStream = if ([bool]$stdoutResult.Exceeded) { 'stdout' } else { 'stderr' }
            try {
                Stop-StandardSemanticBridgeOwnedCallbackProcess `
                    -Process $process `
                    -JobAssigned $jobAssigned `
                    -JobHandle $jobHandle `
                    -UnixPidNamespaceActive $unixPidNamespaceActive
                $callbackProcessTerminationRequested = $true
            }
            catch { }
            [void](Wait-StandardSemanticBridgeOwnedCallbackProcess -Process $process  -TimeoutMilliseconds 5000 -UnixPidNamespaceActive $unixPidNamespaceActive -UnixPidNamespaceInitProcessId $unixPidNamespaceInitProcessId -UnixPidNamespaceInitStartTime $unixPidNamespaceInitStartTime)
            throw [InvalidOperationException]::new("$Context exceeded its isolated $quotaStream quota.")
        }
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
            $diagnostic = if ([string]::IsNullOrWhiteSpace($stderr)) { 'isolated callback returned no result.' } else { $stderr.Trim() }
            throw [InvalidOperationException]::new("$Context failed in its isolated process: $diagnostic")
        }
        try { $envelope = [Management.Automation.PSSerializer]::Deserialize($stdout) }
        catch { throw [InvalidOperationException]::new("$Context returned an invalid isolated result envelope.") }
        if ($null -eq $envelope -or -not [bool]$envelope.succeeded) {
            $message = if ($null -eq $envelope -or [string]::IsNullOrWhiteSpace([string]$envelope.error)) { 'callback failed without a diagnostic.' } else { [string]$envelope.error }
            $failureKind = if ($null -eq $envelope -or $null -eq $envelope.PSObject.Properties['failureKind']) { '' } else { [string]$envelope.failureKind }
            if ($failureKind -ceq 'consent-expired-before-callback-invocation') {
                throw (New-StandardSemanticBridgeChildReportedExpiryException -Context $Context -Message $message)
            }
            throw [InvalidOperationException]::new("$Context failed: $message")
        }
        $normalizedOutput = ConvertFrom-StandardSemanticBridgeIsolatedValue -Value $envelope.output
        return @($normalizedOutput)
    }
    catch {
        $primaryException = $_.Exception
        throw
    }
    finally {
        $deadline.Stop()
        $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
        if ($started) {
            try {
                if ($unixPidNamespaceActive) {
                    Stop-StandardSemanticBridgeOwnedCallbackProcess `
                        -Process $process `
                        -JobAssigned $false `
                        -JobHandle ([IntPtr]::Zero) `
                        -UnixPidNamespaceActive $true
                    if (-not (Wait-StandardSemanticBridgeOwnedCallbackProcess -Process $process  -TimeoutMilliseconds 5000 -UnixPidNamespaceActive $true -UnixPidNamespaceInitProcessId $unixPidNamespaceInitProcessId -UnixPidNamespaceInitStartTime $unixPidNamespaceInitStartTime)) {
                        $cleanupErrors.Add('Linux callback PID namespace did not become empty during callback cleanup.')
                    }
                }
                elseif ($jobAssigned -and -not $callbackProcessTerminationRequested) {
                    $callbackProcessTerminationRequested = $true
                    if (-not [StandardSemanticBridgeProcessControlNative]::TryTerminateJobObject($jobHandle, 1)) {
                        $cleanupErrors.Add('TerminateJobObject returned false during callback cleanup.')
                    }
                    if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
                        $cleanupErrors.Add('Callback host did not terminate during cleanup.')
                    }
                }
                elseif ($isUnixHost -and -not $process.HasExited) {
                    # The handshake failed before stdin was released, so no
                    # callback code could run.  Kill only the unshare wrapper;
                    # a missing namespace identity is itself a cleanup error.
                    try { $process.Kill() } catch { if (-not $process.HasExited) { throw } }
                    if (-not $process.WaitForExit(5000)) { $cleanupErrors.Add('Linux PID namespace wrapper did not terminate after failed handshake.') }
                }
                elseif (-not $jobAssigned -and -not $process.HasExited) {
                    $killTreeMethod = @($process.GetType().GetMethods() | Where-Object {
                            $_.Name -ceq 'Kill' -and $_.GetParameters().Count -eq 1 -and
                            $_.GetParameters()[0].ParameterType -eq [bool]
                        } | Select-Object -First 1)
                    if ($killTreeMethod.Count -eq 1) { [void]$killTreeMethod[0].Invoke($process, [object[]]@($true)) }
                    else { $process.Kill() }
                    if (-not $process.WaitForExit(5000)) { $cleanupErrors.Add('Callback host did not terminate during cleanup.') }
                }
            }
            catch { $cleanupErrors.Add("Callback process cleanup failed: $($_.Exception.Message)") }
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            try {
                if (-not [StandardSemanticBridgeProcessControlNative]::TryCloseHandle($jobHandle)) {
                    $cleanupErrors.Add('Windows Job Object handle did not close during callback cleanup.')
                }
            }
            catch { $cleanupErrors.Add("Windows Job Object cleanup failed: $($_.Exception.Message)") }
        }
        if ($null -ne $process) {
            try { $process.Dispose() }
            catch { $cleanupErrors.Add("Callback process handle disposal failed: $($_.Exception.Message)") }
        }
        foreach ($cleanupPath in @($pidNamespaceHandshakePath, $pidNamespaceHandshakeTemporaryPath)) {
            if ([string]::IsNullOrWhiteSpace([string]$cleanupPath)) { continue }
            try { if ([IO.File]::Exists([string]$cleanupPath)) { [IO.File]::Delete([string]$cleanupPath) } }
            catch { $cleanupErrors.Add("PID namespace handshake cleanup failed: $($_.Exception.Message)") }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pidNamespaceHandshakeDirectory)) {
            try {
                if ([IO.Directory]::Exists([string]$pidNamespaceHandshakeDirectory)) {
                    $directoryInfo = Get-Item -LiteralPath $pidNamespaceHandshakeDirectory -Force -ErrorAction Stop
                    if (-not $directoryInfo.PSIsContainer -or (($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                        throw 'PID namespace handshake directory changed into a non-private path.'
                    }
                    [IO.Directory]::Delete($pidNamespaceHandshakeDirectory, $false)
                }
            }
            catch { $cleanupErrors.Add("PID namespace handshake directory cleanup failed: $($_.Exception.Message)") }
        }
        if ($cleanupErrors.Count -gt 0) {
            $cleanupMessage = $cleanupErrors -join ' '
            if ($null -ne $primaryException) {
                # Preserve the primary failure marker as well as the cleanup
                # marker.  Callers prioritize cleanup while retaining expiry
                # and callback-invocation facts for accurate status/counting.
                $primaryException.Data[$script:StandardSemanticBridgeCallbackCleanupFailureDataKey] = $cleanupMessage
            }
            else {
                $cleanupException = [InvalidOperationException]::new("$Context cleanup failed: $cleanupMessage")
                $cleanupException.Data[$script:StandardSemanticBridgeCallbackCleanupFailureDataKey] = $cleanupMessage
                throw $cleanupException
            }
        }
    }
}

function Get-StandardSemanticBridgeCallbackTimeoutMilliseconds {
    param([Parameter(Mandatory = $true)][int] $TimeoutSeconds)

    $milliseconds = [double]$TimeoutSeconds * 1000.0
    if ($milliseconds -ge [int]::MaxValue) { return [int]::MaxValue }
    return [int][Math]::Ceiling($milliseconds)
}

function Assert-StandardSemanticBridgeExecutionLedger {
    param(
        [Parameter(Mandatory = $true)] $Execution,
        [Parameter(Mandatory = $true)] $Inventory,
        [Parameter(Mandatory = $true)] $Bindings,
        [Parameter(Mandatory = $true)] $ProviderRoute,
        [Parameter(Mandatory = $true)] $AnalyzerSet,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()] $Findings
    )

    Assert-StandardSemanticBridgeExactProperties -Object $Execution -Expected @('plannedWorkItemCount', 'successfulProviderCallCount', 'providerCalls', 'providerCallLedgerSha256', 'rawGraphLedgerSha256', 'rawFindingsLedgerSha256', 'findingsSha256') -Context 'evidence execution'
    $normalizedInventory = Assert-StandardSemanticBridgeProviderTextInventory -Inventory $Inventory -Context 'evidence execution inventory'
    $normalizedBindings = Assert-StandardSemanticBridgeBindings -Bindings $Bindings -Context 'evidence execution bindings'
    $normalizedRoute = Assert-StandardSemanticBridgeProviderRoute -ProviderRoute $ProviderRoute -Context 'evidence execution route'
    $normalizedAnalyzers = Assert-StandardSemanticBridgeAnalyzerSet -AnalyzerSet $AnalyzerSet -Context 'evidence execution analyzerSet'
    $expectedAnalyzerIds = @($normalizedAnalyzers.analyzers | ForEach-Object { [string]$_.id })
    $expectedAnalyzerIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($analyzerId in $expectedAnalyzerIds) { [void]$expectedAnalyzerIdSet.Add([string]$analyzerId) }
    foreach ($finding in @($Findings)) {
        if (-not $expectedAnalyzerIdSet.Contains([string]$finding.analyzerId)) { throw 'evidence finding analyzer is not declared in the analyzer set.' }
    }
    $plannedValue = Get-StandardSemanticBridgeProperty $Execution 'plannedWorkItemCount'
    $successfulValue = Get-StandardSemanticBridgeProperty $Execution 'successfulProviderCallCount'
    if (($plannedValue -isnot [int] -and $plannedValue -isnot [long] -and $plannedValue -isnot [int64]) -or
        ($successfulValue -isnot [int] -and $successfulValue -isnot [long] -and $successfulValue -isnot [int64])) { throw 'evidence execution counts must be integers.' }
    [int]$plannedCount = $plannedValue
    [int]$successfulCount = $successfulValue
    if ($plannedCount -ne [int]$normalizedInventory.fileCount -or $plannedCount -le 0 -or $successfulCount -ne $plannedCount) { throw 'evidence execution is not bound to the provider inventory count.' }
    $rawProviderCalls = Get-StandardSemanticBridgePropertyNoEnumerate $Execution 'providerCalls'
    if ($rawProviderCalls -isnot [array]) { throw 'evidence execution providerCalls must be an array.' }
    $providerCalls = @($rawProviderCalls)
    if ($providerCalls.Count -ne $plannedCount) { throw 'evidence execution providerCalls do not cover every planned work item.' }
    $seenIndexes = New-Object 'System.Collections.Generic.HashSet[int]'
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $normalizedRecords = New-Object System.Collections.Generic.List[object]
    $rawGraphRecords = New-Object System.Collections.Generic.List[object]
    $rawFindingRecords = New-Object System.Collections.Generic.List[object]
    foreach ($record in $providerCalls) {
        Assert-StandardSemanticBridgeExactProperties -Object $record -Expected @('workItemId', 'index', 'idempotencyKey', 'path', 'contentKind', 'textSha256', 'byteCount', 'analyzerSetIdentity', 'plannedAnalyzerIds', 'analyzerCoverage', 'requestSha256', 'responseSha256', 'findingsSha256', 'status') -Context 'evidence execution provider call'
        if ([string]$record.status -cne 'succeeded') { throw 'evidence execution contains a non-success provider call.' }
        $indexValue = Get-StandardSemanticBridgeProperty $record 'index'
        if ($indexValue -isnot [int] -and $indexValue -isnot [long] -and $indexValue -isnot [int64]) { throw 'evidence execution index must be an integer.' }
        $index = [int]$indexValue
        if ($index -lt 0 -or $index -ge $plannedCount -or -not $seenIndexes.Add($index)) { throw 'evidence execution contains a duplicate or out-of-range work item index.' }
        $workItemId = Assert-StandardSemanticBridgeNonEmptyScalar $record.workItemId 'evidence execution workItemId'
        if ($workItemId -cne ('semantic-work-item-{0:D4}' -f $index)) { throw 'evidence execution workItemId is not bound to its index.' }
        $path = Assert-StandardSemanticBridgeSafePath $record.path 'evidence execution path'
        if (-not $seenPaths.Add($path)) { throw 'evidence execution repeats an inventory path.' }
        $kind = Assert-StandardSemanticBridgeNonEmptyScalar $record.contentKind 'evidence execution contentKind'
        $byteCountValue = Get-StandardSemanticBridgeProperty $record 'byteCount'
        if (($byteCountValue -isnot [int] -and $byteCountValue -isnot [long] -and $byteCountValue -isnot [int64]) -or [int64]$byteCountValue -le 0) { throw 'evidence execution byteCount is invalid.' }
        $item = $normalizedInventory.items[$index]
        if ($null -eq $item -or [string]$item.path -cne $path -or [string]$item.contentKind -cne $kind -or [int64]$item.byteCount -ne [int64]$byteCountValue -or [string]$item.sha256 -cne [string]$record.textSha256) { throw 'evidence execution provider call is not bound to its indexed inventory item.' }
        [void](Assert-StandardSemanticBridgeSha256 $record.textSha256 'evidence execution textSha256')
        [void](Assert-StandardSemanticBridgeSha256 $record.requestSha256 'evidence execution requestSha256')
        [void](Assert-StandardSemanticBridgeSha256 $record.responseSha256 'evidence execution responseSha256')
        [void](Assert-StandardSemanticBridgeSha256 $record.findingsSha256 'evidence execution findingsSha256')
        $recordKey = Assert-StandardSemanticBridgeNonEmptyScalar $record.idempotencyKey 'evidence execution idempotencyKey'
        if (-not $seenKeys.Add($recordKey)) { throw 'evidence execution repeats an idempotency key.' }
        if ([string]$record.analyzerSetIdentity -cne [string]$normalizedAnalyzers.analyzerSetIdentity) { throw 'evidence execution analyzer set identity drifted.' }
        if ($record.plannedAnalyzerIds -isnot [array] -or $record.analyzerCoverage -isnot [array]) { throw 'evidence execution analyzer arrays are invalid.' }
        $plannedIds = Assert-StandardSemanticBridgeStringArray -Value $record.plannedAnalyzerIds -Context 'evidence execution plannedAnalyzerIds'
        $coverage = Assert-StandardSemanticBridgeStringArray -Value $record.analyzerCoverage -Context 'evidence execution analyzerCoverage'
        if ((@(Sort-StandardSemanticBridgeOrdinalStrings -Values $plannedIds) -join "`n") -cne (@(Sort-StandardSemanticBridgeOrdinalStrings -Values $expectedAnalyzerIds) -join "`n") -or
            (@(Sort-StandardSemanticBridgeOrdinalStrings -Values $coverage) -join "`n") -cne (@(Sort-StandardSemanticBridgeOrdinalStrings -Values $expectedAnalyzerIds) -join "`n")) { throw 'evidence execution analyzer coverage is not complete for every work item.' }
        $idempotencyItem = [pscustomobject][ordered]@{ path = $path; contentKind = $kind; textSha256 = [string]$record.textSha256; byteCount = [int64]$byteCountValue }
        $expectedKey = Get-StandardSemanticBridgeWorkItemKey -Bindings $normalizedBindings -ProviderRoute $normalizedRoute -AnalyzerSet $normalizedAnalyzers -Item $idempotencyItem
        if ($recordKey -cne $expectedKey) { throw 'evidence execution idempotency key is not self-consistent.' }
        $requestShape = [pscustomobject][ordered]@{ workItemId = $workItemId; idempotencyKey = $recordKey; providerRoute = $normalizedRoute; path = $path; contentKind = $kind; textSha256 = [string]$record.textSha256; byteCount = [int64]$byteCountValue }
        if ([string]$record.requestSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact $requestShape)) { throw 'evidence execution request ledger digest is invalid.' }
        $findingsForPath = @($Findings | Where-Object { [string]$_.path -ceq $path })
        $rebuiltResponse = [pscustomobject][ordered]@{ findings = @(Get-StandardSemanticBridgeCanonicalFindings -Findings $findingsForPath); analyzerCoverage = @(Sort-StandardSemanticBridgeOrdinalStrings -Values $coverage) }
        $expectedFindingsSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact @($rebuiltResponse.findings)
        if ([string]$record.findingsSha256 -cne $expectedFindingsSha) { throw 'evidence execution findings ledger digest is invalid.' }
        if ([string]$record.responseSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact $rebuiltResponse)) { throw 'evidence execution response ledger digest is invalid.' }
        $normalizedRecord = [pscustomobject][ordered]@{
            workItemId = $workItemId
            index = $index
            idempotencyKey = $recordKey
            path = $path
            contentKind = $kind
            textSha256 = [string]$record.textSha256
            byteCount = [int64]$byteCountValue
            analyzerSetIdentity = [string]$record.analyzerSetIdentity
            plannedAnalyzerIds = @($plannedIds)
            analyzerCoverage = @($coverage)
            requestSha256 = [string]$record.requestSha256
            responseSha256 = [string]$record.responseSha256
            findingsSha256 = [string]$record.findingsSha256
            status = 'succeeded'
        }
        [void]$normalizedRecords.Add($normalizedRecord)
        [void]$rawGraphRecords.Add([pscustomobject][ordered]@{ idempotencyKey = $recordKey; graphSha256 = [string]$record.responseSha256 })
        [void]$rawFindingRecords.Add([pscustomobject][ordered]@{ idempotencyKey = $recordKey; findingsSha256 = [string]$record.findingsSha256 })
    }
    if ($seenIndexes.Count -ne $plannedCount -or $seenPaths.Count -ne $plannedCount) { throw 'evidence execution omitted a planned work item.' }
    if ([string]$Execution.providerCallLedgerSha256 -cne (Get-StandardSemanticBridgeLedgerDigest -Entries @($normalizedRecords.ToArray()))) { throw 'evidence provider call ledger digest is not recomputable.' }
    if ([string]$Execution.rawGraphLedgerSha256 -cne (Get-StandardSemanticBridgeLedgerDigest -Entries @($rawGraphRecords.ToArray()))) { throw 'evidence raw graph ledger digest is not recomputable.' }
    if ([string]$Execution.rawFindingsLedgerSha256 -cne (Get-StandardSemanticBridgeLedgerDigest -Entries @($rawFindingRecords.ToArray()))) { throw 'evidence raw findings ledger digest is not recomputable.' }
    return $true
}

function Invoke-StandardSemanticBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $ConsentRequest,
        [Parameter(Mandatory = $true)] $ConsentDecision,
        [Parameter(Mandatory = $true)] $Bindings,
        [Parameter(Mandatory = $true)] $ProviderRoute,
        [Parameter(Mandatory = $true)][string] $Purpose,
        [Parameter(Mandatory = $true)] $Scope,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()] $TextItems,
        [Parameter(Mandatory = $true)] $Analyzers,
        [Parameter(Mandatory = $true)][scriptblock] $ProviderCallback,
        [Parameter(Mandatory = $true)][scriptblock] $SignerCallback,
        [Parameter(Mandatory = $true)][System.Security.Cryptography.RSA] $ExpectedSignerPublicKey,
        [Parameter(Mandatory = $true)][string] $ExpectedSignerKeyId,
        [AllowNull()] $ProviderCallbackContext = $null,
        [AllowNull()] $SignerCallbackContext = $null,
        [hashtable] $IdempotencyLedger = @{},
        [int] $TimeoutSeconds = 30,
        [DateTime] $Now = [DateTime]::UtcNow
    )

    # Provider and signer callbacks execute in isolated PowerShell processes.
    # They receive (request, callbackContext), must not depend on caller closure
    # state, and their optional contexts must be CLIXML-serializable.  Secrets
    # supplied through a context travel only through the redirected stdin pipe.
    $providerCalls = 0
    $successfulCalls = 0
    $inventory = $null
    $analyzerSet = $null
    try {
        if ($null -eq $ExpectedSignerPublicKey) { throw 'a trusted expected signer public key is required.' }
        $expectedSignerKeyId = Assert-StandardSemanticBridgeNonEmptyScalar -Value $ExpectedSignerKeyId -Context 'trusted expected signer keyId'
        if ($TimeoutSeconds -le 0) { throw 'timeout must be positive.' }
        $inventory = New-StandardSemanticBridgeProviderTextInventory -TextItems $TextItems
        $analyzerSet = New-StandardSemanticBridgeAnalyzerSet -Analyzers $Analyzers
        $consentParameters = @{
            ConsentRequest = $ConsentRequest; ConsentDecision = $ConsentDecision; CurrentBindings = $Bindings; CurrentProviderRoute = $ProviderRoute
            CurrentPurpose = $Purpose; CurrentScope = $Scope; CurrentProviderTextInventory = $inventory; CurrentAnalyzerSet = $analyzerSet; Now = $Now
        }
        $consentResult = Test-StandardSemanticBridgeConsent @consentParameters
        if (-not [bool]$consentResult.valid) {
            return [pscustomobject][ordered]@{ status = 'BLOCKED'; reason = [string]$consentResult.reason; providerCallCount = 0; successfulProviderCallCount = 0; providerCalls = @(); idempotencyLedger = $IdempotencyLedger; evidence = $null; evidenceBytes = $null }
        }
        $normalizedBindings = Assert-StandardSemanticBridgeBindings -Bindings $Bindings
        $normalizedRoute = Assert-StandardSemanticBridgeProviderRoute -ProviderRoute $ProviderRoute
        $normalizedScope = Assert-StandardSemanticBridgeScope -Scope $Scope
        $normalizedAnalyzers = Assert-StandardSemanticBridgeAnalyzerSet -AnalyzerSet $analyzerSet
        $bindingsDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedBindings
        $routeDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedRoute
        $scopeDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedScope
        $inventoryDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact $inventory
        $analyzerDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedAnalyzers
        $expectedAnalyzerIds = @($normalizedAnalyzers.analyzers | ForEach-Object { [string]$_.id })
        $expectedAnalyzerIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($analyzerId in $expectedAnalyzerIds) { [void]$expectedAnalyzerIdSet.Add([string]$analyzerId) }
        $allFindings = New-Object System.Collections.Generic.List[object]
        $coverage = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $successfulRecords = New-Object System.Collections.Generic.List[object]
        $rawGraphRecords = New-Object System.Collections.Generic.List[object]
        $rawFindingRecords = New-Object System.Collections.Generic.List[object]
        $failureRecords = New-Object System.Collections.Generic.List[object]
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $sourceTextItemsByCanonicalPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($sourceTextItem in @($TextItems)) {
            $sourcePath = Assert-StandardSemanticBridgeSafePath `
                -Value (Get-StandardSemanticBridgeProperty $sourceTextItem 'path') `
                -Context 'provider text item path'
            if ($sourceTextItemsByCanonicalPath.ContainsKey($sourcePath)) {
                throw 'provider text inventory contains a duplicate normalized source path.'
            }
            $sourceTextItemsByCanonicalPath.Add($sourcePath, $sourceTextItem)
        }
        if ($sourceTextItemsByCanonicalPath.Count -ne @($inventory.items).Count) {
            throw 'provider text inventory changed before egress.'
        }
        $workIndex = 0
        # Inventory order is the work-plan order. Resolve each row through a
        # single ordinal canonical-path map so safe source aliases such as
        # Windows separators match the normalized inventory identity.
        foreach ($inventoryItem in @($inventory.items)) {
            $path = Assert-StandardSemanticBridgeSafePath -Value $inventoryItem.path -Context 'text item path'
            if (-not $sourceTextItemsByCanonicalPath.ContainsKey($path)) { throw 'provider text inventory changed before egress.' }
            $textItem = $sourceTextItemsByCanonicalPath[$path]
            $kind = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $textItem 'contentKind') 'text item contentKind'
            $hasText = Test-StandardSemanticBridgeHasProperty -Object $textItem -Name 'text'
            $itemBytes = $null
            $text = $null
            if ($hasText) {
                $text = [string](Get-StandardSemanticBridgeProperty $textItem 'text')
                $itemBytes = $strictUtf8.GetBytes($text)
            }
            else {
                $itemBytes = [byte[]](Get-StandardSemanticBridgeProperty $textItem 'bytes')
                try {
                    $text = $strictUtf8.GetString($itemBytes)
                    $roundTripBytes = $strictUtf8.GetBytes($text)
                    if ($roundTripBytes.Length -ne $itemBytes.Length) { throw 'strict UTF-8 round-trip changed the byte count.' }
                    for ($byteIndex = 0; $byteIndex -lt $itemBytes.Length; $byteIndex++) {
                        if ($roundTripBytes[$byteIndex] -ne $itemBytes[$byteIndex]) { throw 'strict UTF-8 round-trip changed the bytes.' }
                    }
                }
                catch {
                    throw "provider text bytes are not valid strict UTF-8: $($_.Exception.Message)"
                }
            }
            $itemSha = Get-StandardSemanticBridgeSha256FromBytes -Bytes $itemBytes
            if ([string]$inventoryItem.contentKind -cne $kind -or [string]$inventoryItem.sha256 -cne $itemSha -or [int64]$inventoryItem.byteCount -ne [int64]$itemBytes.Length) { throw 'provider text inventory changed before egress.' }
            $workItem = [pscustomobject][ordered]@{ index = [int]$workIndex; path = $path; contentKind = $kind; textSha256 = $itemSha; byteCount = [int64]$itemBytes.Length }
            $idempotencyItem = [pscustomobject][ordered]@{ path = $path; contentKind = $kind; textSha256 = $itemSha; byteCount = [int64]$itemBytes.Length }
            $idempotencyKey = Get-StandardSemanticBridgeWorkItemKey -Bindings $normalizedBindings -ProviderRoute $normalizedRoute -AnalyzerSet $normalizedAnalyzers -Item $idempotencyItem
            $requestForDigest = [pscustomobject][ordered]@{ workItemId = 'semantic-work-item-{0:D4}' -f $workIndex; idempotencyKey = $idempotencyKey; providerRoute = $normalizedRoute; path = $path; contentKind = $kind; textSha256 = $itemSha; byteCount = [int64]$itemBytes.Length }
            $requestSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact $requestForDigest
            if ($IdempotencyLedger.ContainsKey($idempotencyKey) -and [string]$IdempotencyLedger[$idempotencyKey].status -eq 'succeeded') {
                # The ledger intentionally contains no response bytes.  A retry that
                # skips a prior success is therefore never allowed to manufacture PASS.
                [void]$failureRecords.Add([pscustomobject][ordered]@{ workItemId = $requestForDigest.workItemId; idempotencyKey = $idempotencyKey; path = $path; errorCode = 'prior-success-response-unavailable' })
                $workIndex++
                continue
            }
            $request = [pscustomobject][ordered]@{ workItemId = $requestForDigest.workItemId; idempotencyKey = $idempotencyKey; providerRoute = $normalizedRoute; path = $path; contentKind = $kind; analyzerSet = $normalizedAnalyzers; text = $text; bytes = $null }
            $callbackTimeoutMilliseconds = Get-StandardSemanticBridgeCallbackTimeoutMilliseconds -TimeoutSeconds $TimeoutSeconds
            $providerConsentParameters = $consentParameters.Clone()
            $providerConsentParameters.Now = [DateTime]::UtcNow
            $providerConsentResult = Test-StandardSemanticBridgeConsent @providerConsentParameters
            if (-not [bool]$providerConsentResult.valid) {
                return [pscustomobject][ordered]@{
                    status = 'BLOCKED'
                    reason = [string]$providerConsentResult.reason
                    providerCallCount = $providerCalls
                    successfulProviderCallCount = $successfulCalls
                    providerCalls = @($successfulRecords.ToArray())
                    failures = @($failureRecords.ToArray())
                    idempotencyLedger = $IdempotencyLedger
                    evidence = $null
                    evidenceBytes = $null
                }
            }
            $providerCalls++
            try {
                $responseItems = @(Invoke-StandardSemanticBridgeCallbackWithTimeout -Callback $ProviderCallback -Argument $request -CallbackContext $ProviderCallbackContext -TimeoutMilliseconds $callbackTimeoutMilliseconds -ConsentExpiresAt $ConsentDecision.expiresAt -Context 'provider callback')
                if ((Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedBindings) -cne $bindingsDigest -or
                    (Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedRoute) -cne $routeDigest -or
                    (Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedScope) -cne $scopeDigest -or
                    (Get-StandardSemanticBridgeArtifactSha256 -Artifact $inventory) -cne $inventoryDigest -or
                    (Get-StandardSemanticBridgeArtifactSha256 -Artifact $normalizedAnalyzers) -cne $analyzerDigest) {
                    throw 'provider-input-mutated-during-callback'
                }
                if ($responseItems.Count -ne 1 -or $null -eq $responseItems[0]) { throw 'provider-response-shape' }
                $response = $responseItems[0]
                Assert-StandardSemanticBridgeExactProperties -Object $response -Expected @('findings', 'analyzerCoverage') -Context 'provider response'
                $rawResponseFindings = Get-StandardSemanticBridgePropertyNoEnumerate $response 'findings'
                $rawResponseCoverage = Get-StandardSemanticBridgePropertyNoEnumerate $response 'analyzerCoverage'
                if ($rawResponseFindings -isnot [array] -or $rawResponseCoverage -isnot [array]) { throw 'provider-response-arrays-invalid' }
                $responseFindings = @(Get-StandardSemanticBridgeCanonicalFindings -Findings $rawResponseFindings)
                $responseCoverage = Assert-StandardSemanticBridgeStringArray -Value $rawResponseCoverage -Context 'provider analyzerCoverage'
                $canonicalCoverage = @(Sort-StandardSemanticBridgeOrdinalStrings -Values $responseCoverage)
                if (($canonicalCoverage -join "`n") -cne (@(Sort-StandardSemanticBridgeOrdinalStrings -Values $expectedAnalyzerIds) -join "`n")) {
                    throw 'provider-response-analyzer-coverage-incomplete-for-work-item'
                }
                foreach ($finding in @($responseFindings)) {
                    if (-not $expectedAnalyzerIdSet.Contains([string]$finding.analyzerId)) { throw 'provider-response-finding-analyzer-invalid' }
                    if ([string]$finding.path -cne $path -or [string]$finding.path -notin @($inventory.items | ForEach-Object { [string]$_.path })) { throw 'provider-response-finding-path-not-bound-to-work-item' }
                    [void]$allFindings.Add($finding)
                }
                foreach ($coverageId in @($canonicalCoverage)) { [void]$coverage.Add($coverageId) }
                $responseNormalized = [pscustomobject][ordered]@{ findings = @($responseFindings); analyzerCoverage = @($canonicalCoverage) }
                $responseSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact $responseNormalized
                $findingSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact @($responseFindings)
                $record = [pscustomobject][ordered]@{
                    workItemId = $request.workItemId
                    index = [int]$workIndex
                    idempotencyKey = $idempotencyKey
                    path = $path
                    contentKind = $kind
                    textSha256 = $itemSha
                    byteCount = [int64]$itemBytes.Length
                    analyzerSetIdentity = [string]$normalizedAnalyzers.analyzerSetIdentity
                    plannedAnalyzerIds = @($expectedAnalyzerIds)
                    analyzerCoverage = @($canonicalCoverage)
                    requestSha256 = $requestSha
                    responseSha256 = $responseSha
                    findingsSha256 = $findingSha
                    status = 'succeeded'
                }
                $IdempotencyLedger[$idempotencyKey] = $record
                [void]$successfulRecords.Add($record)
                [void]$rawGraphRecords.Add([pscustomobject][ordered]@{ idempotencyKey = $idempotencyKey; graphSha256 = $responseSha })
                [void]$rawFindingRecords.Add([pscustomobject][ordered]@{ idempotencyKey = $idempotencyKey; findingsSha256 = $findingSha })
                $successfulCalls++
            }
            catch {
                if (Test-StandardSemanticBridgeCallbackCleanupFailureException -Exception $_.Exception) {
                    if (Test-StandardSemanticBridgeConsentExpiryGuardException -Exception $_.Exception) { $providerCalls-- }
                    $cleanupMessage = [string]$_.Exception.Data[$script:StandardSemanticBridgeCallbackCleanupFailureDataKey]
                    $IdempotencyLedger[$idempotencyKey] = [pscustomobject][ordered]@{ idempotencyKey = $idempotencyKey; requestSha256 = $requestSha; status = 'failed'; errorCode = 'callback-cleanup-failure' }
                    [void]$failureRecords.Add([pscustomobject][ordered]@{ workItemId = $request.workItemId; idempotencyKey = $idempotencyKey; path = $path; errorCode = 'callback-cleanup-failure' })
                    return [pscustomobject][ordered]@{
                        status = 'FAILED'
                        reason = "provider callback cleanup failed: $cleanupMessage"
                        providerCallCount = $providerCalls
                        successfulProviderCallCount = $successfulCalls
                        providerCalls = @($successfulRecords.ToArray())
                        failures = @($failureRecords.ToArray())
                        idempotencyLedger = $IdempotencyLedger
                        evidence = $null
                        evidenceBytes = $null
                    }
                }
                if (Test-StandardSemanticBridgeConsentExpiryGuardException -Exception $_.Exception) {
                    $providerCalls--
                    return [pscustomobject][ordered]@{
                        status = 'BLOCKED'
                        reason = 'consent expired before the provider callback received its request.'
                        providerCallCount = $providerCalls
                        successfulProviderCallCount = $successfulCalls
                        providerCalls = @($successfulRecords.ToArray())
                        failures = @($failureRecords.ToArray())
                        idempotencyLedger = $IdempotencyLedger
                        evidence = $null
                        evidenceBytes = $null
                    }
                }
                if (Test-StandardSemanticBridgeChildReportedExpiryException -Exception $_.Exception) {
                    $childExpiryMessage = [string]$_.Exception.Message
                    $IdempotencyLedger[$idempotencyKey] = [pscustomobject][ordered]@{ idempotencyKey = $idempotencyKey; requestSha256 = $requestSha; status = 'failed'; errorCode = 'untrusted-child-consent-expiry' }
                    [void]$failureRecords.Add([pscustomobject][ordered]@{ workItemId = $request.workItemId; idempotencyKey = $idempotencyKey; path = $path; errorCode = 'untrusted-child-consent-expiry' })
                    return [pscustomobject][ordered]@{
                        status = 'FAILED'
                        reason = $childExpiryMessage
                        providerCallCount = $providerCalls
                        successfulProviderCallCount = $successfulCalls
                        providerCalls = @($successfulRecords.ToArray())
                        failures = @($failureRecords.ToArray())
                        idempotencyLedger = $IdempotencyLedger
                        evidence = $null
                        evidenceBytes = $null
                    }
                }
                $errorCode = if ($_.Exception -is [TimeoutException] -or $_.Exception.Message -match '(?i)timeout') { 'timeout' } elseif ($_.Exception.Message -eq 'provider-response-findings-missing') { 'incomplete-findings' } else { 'provider-failure' }
                $IdempotencyLedger[$idempotencyKey] = [pscustomobject][ordered]@{ idempotencyKey = $idempotencyKey; requestSha256 = $requestSha; status = 'failed'; errorCode = $errorCode }
                [void]$failureRecords.Add([pscustomobject][ordered]@{ workItemId = $request.workItemId; idempotencyKey = $idempotencyKey; path = $path; errorCode = $errorCode })
            }
            $workIndex++
        }
        if ($failureRecords.Count -gt 0 -or $successfulCalls -ne [int]$inventory.fileCount) {
            return [pscustomobject][ordered]@{ status = 'FAILED'; reason = if ($failureRecords.Count -gt 0) { 'provider execution was incomplete or a retry lacked prior response bytes.' } else { 'provider execution was incomplete.' }; providerCallCount = $providerCalls; successfulProviderCallCount = $successfulCalls; providerCalls = @($successfulRecords.ToArray()); failures = @($failureRecords.ToArray()); idempotencyLedger = $IdempotencyLedger; evidence = $null; evidenceBytes = $null }
        }
        $missingAnalyzers = @($expectedAnalyzerIds | Where-Object { -not $coverage.Contains($_) })
        if ($missingAnalyzers.Count -gt 0) {
            return [pscustomobject][ordered]@{ status = 'FAILED'; reason = 'analyzer coverage is incomplete.'; providerCallCount = $providerCalls; successfulProviderCallCount = $successfulCalls; providerCalls = @($successfulRecords.ToArray()); failures = @([pscustomobject][ordered]@{ errorCode = 'incomplete-analyzer-coverage' }); idempotencyLedger = $IdempotencyLedger; evidence = $null; evidenceBytes = $null }
        }
        $canonicalFindings = @(Get-StandardSemanticBridgeCanonicalFindings -Findings @($allFindings.ToArray()))
        $findingsDigest = Get-StandardSemanticBridgeArtifactSha256 -Artifact @($canonicalFindings)
        $analyzerCoverage = @(Sort-StandardSemanticBridgeOrdinalStrings -Values @($coverage))
        $generatedAtNow = [DateTime]::UtcNow
        $generatedAtConsentParameters = $consentParameters.Clone()
        $generatedAtConsentParameters.Now = $generatedAtNow
        $generatedAtConsentResult = Test-StandardSemanticBridgeConsent @generatedAtConsentParameters
        if (-not [bool]$generatedAtConsentResult.valid) {
            return [pscustomobject][ordered]@{
                status = 'BLOCKED'
                reason = [string]$generatedAtConsentResult.reason
                providerCallCount = $providerCalls
                successfulProviderCallCount = $successfulCalls
                providerCalls = @($successfulRecords.ToArray())
                failures = @($failureRecords.ToArray())
                idempotencyLedger = $IdempotencyLedger
                evidence = $null
                evidenceBytes = $null
            }
        }
        $generatedAt = ConvertTo-StandardSemanticBridgeUtcTimestamp -Value $generatedAtNow -Context 'generatedAt'
        $evidenceUnsigned = [pscustomobject][ordered]@{
            schemaVersion = $script:StandardSemanticBridgeSchemaVersion
            artifactType = 'semantic-evidence-v2'
            artifactClassification = $script:StandardSemanticBridgeArtifactClassification
            evidenceId = ([Guid]::NewGuid()).ToString()
            generatedAt = $generatedAt
            status = 'passed'
            decision = 'PASS'
            bindings = $normalizedBindings
            providerRoute = $normalizedRoute
            purpose = [string]$Purpose
            scope = $normalizedScope
            providerTextInventory = $inventory
            analyzerSet = $normalizedAnalyzers
            analyzerCoverage = $analyzerCoverage
            analyzerCompleteness = 'complete'
            consent = [pscustomobject][ordered]@{ consentRequestSha256 = $consentResult.consentRequestSha256; consentArtifactSha256 = $consentResult.consentArtifactSha256; authorizer = $ConsentDecision.authorizer; authorizedAt = [string]$ConsentDecision.authorizedAt; expiresAt = [string]$ConsentDecision.expiresAt; consentGranted = $true }
            execution = $null
            findings = @($canonicalFindings)
        }
        $providerCallLedgerSha = Get-StandardSemanticBridgeLedgerDigest -Entries @($successfulRecords.ToArray())
        $rawGraphLedgerSha = Get-StandardSemanticBridgeLedgerDigest -Entries @($rawGraphRecords.ToArray())
        $rawFindingsLedgerSha = Get-StandardSemanticBridgeLedgerDigest -Entries @($rawFindingRecords.ToArray())
        $evidenceUnsigned.execution = [pscustomobject][ordered]@{
            plannedWorkItemCount = [int]$inventory.fileCount
            successfulProviderCallCount = [int]$successfulCalls
            providerCalls = @($successfulRecords.ToArray())
            providerCallLedgerSha256 = $providerCallLedgerSha
            rawGraphLedgerSha256 = $rawGraphLedgerSha
            rawFindingsLedgerSha256 = $rawFindingsLedgerSha
            findingsSha256 = $findingsDigest
        }
        $unsignedPayloadSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact $evidenceUnsigned
        $unsignedJson = Get-StandardSemanticBridgeCanonicalJson -Value $evidenceUnsigned
        $unsignedBytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($unsignedJson)
        $signerRequest = [pscustomobject][ordered]@{ artifactType = 'semantic-evidence-v2'; algorithm = $script:StandardSemanticBridgeAlgorithm; payloadSha256 = $unsignedPayloadSha; payloadBytes = $unsignedBytes }
        $callbackTimeoutMilliseconds = Get-StandardSemanticBridgeCallbackTimeoutMilliseconds -TimeoutSeconds $TimeoutSeconds
        $signerConsentParameters = $consentParameters.Clone()
        $signerConsentParameters.Now = [DateTime]::UtcNow
        $signerConsentResult = Test-StandardSemanticBridgeConsent @signerConsentParameters
        if (-not [bool]$signerConsentResult.valid) {
            return [pscustomobject][ordered]@{
                status = 'BLOCKED'
                reason = [string]$signerConsentResult.reason
                providerCallCount = $providerCalls
                successfulProviderCallCount = $successfulCalls
                providerCalls = @($successfulRecords.ToArray())
                failures = @($failureRecords.ToArray())
                idempotencyLedger = $IdempotencyLedger
                evidence = $null
                evidenceBytes = $null
            }
        }
        $signatureItems = @(Invoke-StandardSemanticBridgeCallbackWithTimeout -Callback $SignerCallback -Argument $signerRequest -CallbackContext $SignerCallbackContext -TimeoutMilliseconds $callbackTimeoutMilliseconds -ConsentExpiresAt $ConsentDecision.expiresAt -Context 'signer callback')
        $afterSignerConsentParameters = $consentParameters.Clone()
        $afterSignerConsentParameters.Now = [DateTime]::UtcNow
        $afterSignerConsentResult = Test-StandardSemanticBridgeConsent @afterSignerConsentParameters
        if (-not [bool]$afterSignerConsentResult.valid) {
            return [pscustomobject][ordered]@{
                status = 'BLOCKED'
                reason = [string]$afterSignerConsentResult.reason
                providerCallCount = $providerCalls
                successfulProviderCallCount = $successfulCalls
                providerCalls = @($successfulRecords.ToArray())
                failures = @($failureRecords.ToArray())
                idempotencyLedger = $IdempotencyLedger
                evidence = $null
                evidenceBytes = $null
            }
        }
        if ($signatureItems.Count -ne 1 -or $null -eq $signatureItems[0]) { throw 'signer response shape is invalid.' }
        $signature = $signatureItems[0]
        Assert-StandardSemanticBridgeExactProperties -Object $signature -Expected @('keyId', 'algorithm', 'signature') -Context 'signer response'
        $keyId = Assert-StandardSemanticBridgeNonEmptyScalar (Get-StandardSemanticBridgeProperty $signature 'keyId') 'signer keyId'
        if (-not [string]::Equals($keyId, $expectedSignerKeyId, [StringComparison]::Ordinal)) { throw 'signer keyId does not match the trusted expected identity.' }
        if ([string](Get-StandardSemanticBridgeProperty $signature 'algorithm') -cne $script:StandardSemanticBridgeAlgorithm) { throw 'signer algorithm is unsupported.' }
        $signatureText = Assert-StandardSemanticBridgeCanonicalBase64 (Get-StandardSemanticBridgeProperty $signature 'signature') 'signer signature'
        $signatureBytes = [Convert]::FromBase64String($signatureText)
        if (-not $ExpectedSignerPublicKey.VerifyData($unsignedBytes, $signatureBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
            throw 'signer signature verification failed.'
        }
        $evidence = [pscustomobject][ordered]@{}
        foreach ($property in @($evidenceUnsigned.PSObject.Properties)) { $evidence | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value }
        $evidence | Add-Member -MemberType NoteProperty -Name 'attestation' -Value ([pscustomobject][ordered]@{ attestationType = $script:StandardSemanticBridgeAttestationType; keyId = $keyId; algorithm = $script:StandardSemanticBridgeAlgorithm; signedPayloadSha256 = $unsignedPayloadSha; issuedAt = $generatedAt; signature = $signatureText })
        $evidenceJson = Get-StandardSemanticBridgeCanonicalJson -Value $evidence
        $evidenceBytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($evidenceJson)
        $evidenceSha = Get-StandardSemanticBridgeSha256FromBytes -Bytes $evidenceBytes
        $finalConsentParameters = $consentParameters.Clone()
        $finalConsentParameters.Now = [DateTime]::UtcNow
        $finalConsentResult = Test-StandardSemanticBridgeConsent @finalConsentParameters
        if (-not [bool]$finalConsentResult.valid) {
            return [pscustomobject][ordered]@{
                status = 'BLOCKED'
                reason = [string]$finalConsentResult.reason
                providerCallCount = $providerCalls
                successfulProviderCallCount = $successfulCalls
                providerCalls = @($successfulRecords.ToArray())
                failures = @($failureRecords.ToArray())
                idempotencyLedger = $IdempotencyLedger
                evidence = $null
                evidenceBytes = $null
            }
        }
        return [pscustomobject][ordered]@{ status = 'PASS'; reason = $null; providerCallCount = $providerCalls; successfulProviderCallCount = $successfulCalls; providerCalls = @($successfulRecords.ToArray()); failures = @(); idempotencyLedger = $IdempotencyLedger; evidence = $evidence; evidenceBytes = [byte[]]$evidenceBytes; evidenceSha256 = $evidenceSha }
    }
    catch {
        if (Test-StandardSemanticBridgeCallbackCleanupFailureException -Exception $_.Exception) {
            $cleanupMessage = [string]$_.Exception.Data[$script:StandardSemanticBridgeCallbackCleanupFailureDataKey]
            $primaryMessage = [string]$_.Exception.Message
            $reason = "signer callback cleanup failed: $cleanupMessage"
            if (-not [string]::IsNullOrWhiteSpace($primaryMessage) -and
                $primaryMessage.IndexOf($script:StandardSemanticBridgeConsentExpiryGuardMessage, [StringComparison]::Ordinal) -lt 0) {
                $reason += " Primary callback failure: $primaryMessage"
            }
            return [pscustomobject][ordered]@{ status = 'FAILED'; reason = $reason; providerCallCount = $providerCalls; successfulProviderCallCount = $successfulCalls; providerCalls = @($successfulRecords.ToArray()); failures = @([pscustomobject][ordered]@{ errorCode = 'callback-cleanup-failure' }); idempotencyLedger = $IdempotencyLedger; evidence = $null; evidenceBytes = $null }
        }
        if (Test-StandardSemanticBridgeConsentExpiryGuardException -Exception $_.Exception) {
            return [pscustomobject][ordered]@{
                status = 'BLOCKED'
                reason = 'consent expired before the signer callback received its request.'
                providerCallCount = $providerCalls
                successfulProviderCallCount = $successfulCalls
                providerCalls = @($successfulRecords.ToArray())
                failures = @($failureRecords.ToArray())
                idempotencyLedger = $IdempotencyLedger
                evidence = $null
                evidenceBytes = $null
            }
        }
        return [pscustomobject][ordered]@{ status = 'FAILED'; reason = [string]$_.Exception.Message; providerCallCount = $providerCalls; successfulProviderCallCount = $successfulCalls; providerCalls = @(); failures = @([pscustomobject][ordered]@{ errorCode = 'bridge-failure' }); idempotencyLedger = $IdempotencyLedger; evidence = $null; evidenceBytes = $null }
    }
}

function Test-StandardSemanticBridgeEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]] $EvidenceBytes,
        [Parameter(Mandatory = $true)] $ConsentRequest,
        [Parameter(Mandatory = $true)] $ConsentDecision,
        [Parameter(Mandatory = $true)] [System.Security.Cryptography.RSA] $PublicKey,
        [Parameter(Mandatory = $true)][string] $ExpectedKeyId,
        [Parameter(Mandatory = $true)] $ExpectedBindings,
        [Parameter(Mandatory = $true)] $ExpectedProviderRoute,
        [Parameter(Mandatory = $true)][string] $ExpectedPurpose,
        [Parameter(Mandatory = $true)] $ExpectedScope,
        [Parameter(Mandatory = $true)] $ExpectedProviderTextInventory,
        [DateTime] $Now = [DateTime]::UtcNow,
        [hashtable] $ReplayLedger = $null
    )

    try {
        if ($EvidenceBytes.Length -eq 0) { throw 'evidence bytes are empty.' }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $json = $utf8.GetString($EvidenceBytes)
        $evidence = ConvertFrom-Json -InputObject $json
        $canonicalEvidenceBytes = $utf8.GetBytes((Get-StandardSemanticBridgeCanonicalJson -Value $evidence))
        if (-not (Test-StandardSemanticBridgeByteSequenceEqual -Left $EvidenceBytes -Right $canonicalEvidenceBytes)) { throw 'evidence bytes are not canonical UTF-8 JSON.' }
        Assert-StandardSemanticBridgeExactProperties -Object $evidence -Expected @('schemaVersion', 'artifactType', 'artifactClassification', 'evidenceId', 'generatedAt', 'status', 'decision', 'bindings', 'providerRoute', 'purpose', 'scope', 'providerTextInventory', 'analyzerSet', 'analyzerCoverage', 'analyzerCompleteness', 'consent', 'execution', 'findings', 'attestation') -Context 'evidence'
        if (-not (Test-StandardSemanticBridgeNumericSchemaVersion -Value $evidence.schemaVersion -Expected $script:StandardSemanticBridgeSchemaVersion) -or [string]$evidence.artifactType -cne 'semantic-evidence-v2' -or [string]$evidence.artifactClassification -cne $script:StandardSemanticBridgeArtifactClassification -or [string]$evidence.status -cne 'passed' -or [string]$evidence.decision -cne 'PASS') { throw 'evidence is not a valid v2 PASS artifact.' }
        $evidenceId = Assert-StandardSemanticBridgeUuid -Value $evidence.evidenceId -Context 'evidenceId'
        $normalizedInventory = Assert-StandardSemanticBridgeProviderTextInventory -Inventory $ExpectedProviderTextInventory
        $normalizedBindings = Assert-StandardSemanticBridgeBindings -Bindings $ExpectedBindings
        $normalizedRoute = Assert-StandardSemanticBridgeProviderRoute -ProviderRoute $ExpectedProviderRoute
        $normalizedScope = Assert-StandardSemanticBridgeScope -Scope $ExpectedScope
        $normalizedDecisionAnalyzerSet = Assert-StandardSemanticBridgeAnalyzerSet -AnalyzerSet $ConsentDecision.analyzerSet
        $normalizedDecision = Test-StandardSemanticBridgeConsent -ConsentRequest $ConsentRequest -ConsentDecision $ConsentDecision -CurrentBindings $normalizedBindings -CurrentProviderRoute $normalizedRoute -CurrentPurpose $ExpectedPurpose -CurrentScope $normalizedScope -CurrentProviderTextInventory $normalizedInventory -CurrentAnalyzerSet $normalizedDecisionAnalyzerSet -Now $Now
        if (-not [bool]$normalizedDecision.valid) { throw "consent rejected: $($normalizedDecision.reason)" }
        foreach ($name in @('bindings', 'providerRoute', 'scope', 'providerTextInventory', 'analyzerSet')) {
            if ((Get-StandardSemanticBridgeCanonicalJson (Get-StandardSemanticBridgeProperty $evidence $name)) -cne (Get-StandardSemanticBridgeCanonicalJson (Get-StandardSemanticBridgeProperty $ConsentDecision $name))) { throw "evidence $name is not consent-bound." }
        }
        if ([string]$evidence.purpose -cne [string]$ExpectedPurpose) { throw 'evidence purpose is not consent-bound.' }
        Assert-StandardSemanticBridgeExactProperties -Object $evidence.consent -Expected @('consentRequestSha256', 'consentArtifactSha256', 'authorizer', 'authorizedAt', 'expiresAt', 'consentGranted') -Context 'evidence consent'
        if ([string]$evidence.consent.consentRequestSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact $ConsentRequest) -or [string]$evidence.consent.consentArtifactSha256 -cne (Get-StandardSemanticBridgeArtifactSha256 -Artifact $ConsentDecision)) { throw 'evidence consent artifact digest is invalid.' }
        if ($evidence.consent.consentGranted -isnot [bool] -or -not [bool]$evidence.consent.consentGranted) { throw 'evidence consent is not granted.' }
        if ((Get-StandardSemanticBridgeCanonicalJson $evidence.consent.authorizer) -cne (Get-StandardSemanticBridgeCanonicalJson $ConsentDecision.authorizer) -or
            (Get-StandardSemanticBridgeTimestamp $evidence.consent.authorizedAt 'evidence consent authorizedAt') -ne (Get-StandardSemanticBridgeTimestamp $ConsentDecision.authorizedAt 'consent authorizedAt') -or
            (Get-StandardSemanticBridgeTimestamp $evidence.consent.expiresAt 'evidence consent expiresAt') -ne (Get-StandardSemanticBridgeTimestamp $ConsentDecision.expiresAt 'consent expiresAt')) {
            throw 'evidence consent metadata is not decision-bound.'
        }
        $generatedAt = Get-StandardSemanticBridgeTimestamp -Value $evidence.generatedAt -Context 'evidence generatedAt'
        $nowUtc = $Now.ToUniversalTime()
        $expiry = Get-StandardSemanticBridgeTimestamp -Value $ConsentDecision.expiresAt -Context 'consent expiry'
        if ($generatedAt -lt (Get-StandardSemanticBridgeTimestamp $ConsentDecision.authorizedAt 'consent authorizedAt') -or $generatedAt -ge $expiry -or $generatedAt -gt $nowUtc) { throw 'evidence is outside the consent validity window.' }
        $expectedAnalyzerSet = Assert-StandardSemanticBridgeAnalyzerSet -AnalyzerSet $evidence.analyzerSet
        $expectedAnalyzerIds = @($expectedAnalyzerSet.analyzers | ForEach-Object { [string]$_.id })
        if ($evidence.analyzerCoverage -isnot [array]) { throw 'evidence analyzerCoverage must be an array.' }
        $coverage = Assert-StandardSemanticBridgeStringArray -Value $evidence.analyzerCoverage -Context 'evidence analyzerCoverage'
        $coverageCanonical = (@(Sort-StandardSemanticBridgeOrdinalStrings -Values $coverage) -join "`n")
        $expectedCoverageCanonical = (@(Sort-StandardSemanticBridgeOrdinalStrings -Values $expectedAnalyzerIds) -join "`n")
        if ($coverageCanonical -cne $expectedCoverageCanonical) { throw 'evidence analyzer coverage is incomplete or unexpected.' }
        if ([string]$evidence.analyzerCompleteness -cne 'complete') { throw 'evidence analyzer completeness is not complete.' }
        if ($evidence.findings -isnot [array]) { throw 'evidence findings must be an array.' }
        $findings = @(Get-StandardSemanticBridgeCanonicalFindings -Findings $evidence.findings)
        foreach ($finding in $findings) {
            if (@($normalizedInventory.items | Where-Object { [string]$_.path -ceq [string]$finding.path }).Count -ne 1) { throw 'evidence finding path is not bound to provider inventory.' }
        }
        $findingsSha = Get-StandardSemanticBridgeArtifactSha256 -Artifact @($findings)
        [void](Assert-StandardSemanticBridgeExecutionLedger -Execution $evidence.execution -Inventory $normalizedInventory -Bindings $normalizedBindings -ProviderRoute $normalizedRoute -AnalyzerSet $expectedAnalyzerSet -Findings @($findings))
        [void](Assert-StandardSemanticBridgeSha256 -Value (Get-StandardSemanticBridgeProperty $evidence.execution 'findingsSha256') -Context 'evidence execution findingsSha256')
        if ([string]$evidence.execution.findingsSha256 -cne $findingsSha) { throw 'evidence findings digest is invalid.' }
        $attestation = $evidence.attestation
        Assert-StandardSemanticBridgeExactProperties -Object $attestation -Expected @('attestationType', 'keyId', 'algorithm', 'signedPayloadSha256', 'issuedAt', 'signature') -Context 'evidence attestation'
        if ([string]$attestation.attestationType -cne $script:StandardSemanticBridgeAttestationType -or [string]$attestation.keyId -cne $ExpectedKeyId -or [string]$attestation.algorithm -cne $script:StandardSemanticBridgeAlgorithm) { throw 'evidence signer identity or algorithm is not trusted by the caller.' }
        $signatureText = Assert-StandardSemanticBridgeCanonicalBase64 $attestation.signature 'evidence signature'
        $signature = [Convert]::FromBase64String($signatureText)
        $unsigned = [ordered]@{}
        foreach ($property in @($evidence.PSObject.Properties | Where-Object { $_.Name -ne 'attestation' })) { $unsigned[$property.Name] = $property.Value }
        $unsignedObject = [pscustomobject]$unsigned
        $unsignedJson = Get-StandardSemanticBridgeCanonicalJson -Value $unsignedObject
        $unsignedBytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($unsignedJson)
        $payloadSha = Get-StandardSemanticBridgeSha256FromBytes -Bytes $unsignedBytes
        if ([string]$attestation.signedPayloadSha256 -cne $payloadSha) { throw 'evidence signed payload digest is invalid.' }
        $issuedAt = Get-StandardSemanticBridgeTimestamp -Value $attestation.issuedAt -Context 'attestation issuedAt'
        if ($issuedAt -ne $generatedAt -or $issuedAt -gt $nowUtc) { throw 'attestation timestamp is invalid.' }
        if (-not $PublicKey.VerifyData($unsignedBytes, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'evidence signature verification failed.' }
        if ($null -ne $ReplayLedger) {
            if ($ReplayLedger.ContainsKey($evidenceId)) { throw 'evidence replay was detected.' }
            $ReplayLedger[$evidenceId] = [pscustomobject][ordered]@{ evidenceSha256 = Get-StandardSemanticBridgeSha256FromBytes -Bytes $EvidenceBytes; status = 'consumed' }
        }
        return [pscustomobject][ordered]@{ valid = $true; reason = $null; evidence = $evidence; evidenceSha256 = Get-StandardSemanticBridgeSha256FromBytes -Bytes $EvidenceBytes }
    }
    catch {
        return [pscustomobject][ordered]@{ valid = $false; reason = [string]$_.Exception.Message; evidence = $null; evidenceSha256 = $null }
    }
}

function Assert-StandardSemanticBridgeEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [hashtable] $Parameters)
    $result = Test-StandardSemanticBridgeEvidence @Parameters
    if (-not [bool]$result.valid) { throw "semantic evidence rejected: $($result.reason)" }
    return $result
}

Export-ModuleMember -Function @(
    'Get-StandardSemanticBridgeCanonicalJson',
    'Get-StandardSemanticBridgeArtifactSha256',
    'Get-StandardSemanticAnalyzerSetIdentity',
    'New-StandardSemanticBridgeAnalyzerSet',
    'New-StandardSemanticBridgeProviderTextInventory',
    'New-StandardSemanticBridgeConsentRequest',
    'New-StandardSemanticBridgeConsentDecision',
    'Test-StandardSemanticBridgeConsent',
    'Assert-StandardSemanticBridgeConsent',
    'Invoke-StandardSemanticBridge',
    'Test-StandardSemanticBridgeEvidence',
    'Assert-StandardSemanticBridgeEvidence'
)
