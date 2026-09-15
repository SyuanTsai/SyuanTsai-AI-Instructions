[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ScannerResultPath,
    [Parameter(Mandatory = $true)][string] $OutputPath,
    [Parameter(Mandatory = $true)][string] $CandidateId,
    [Parameter(Mandatory = $true)][string] $InputInventorySha256,
    [Parameter(Mandatory = $true)][string] $Provider,
    [Parameter(Mandatory = $true)][string] $Purpose,
    [Parameter(Mandatory = $true)][string] $Scope,
    [Parameter(Mandatory = $true)][string[]] $ExpectedActiveSkills,
    [Parameter(Mandatory = $true)][string[]] $ExpectedAnalyzerIds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PreflightScalar {
    param([AllowNull()] $Value, [string] $Name)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 4096 -or $Value -match '[\x00-\x1F\x7F]') {
        throw "Semantic preflight $Name must be a non-empty string without control characters."
    }
    return [string]$Value
}

function Assert-PreflightSha256 {
    param([AllowNull()] $Value, [string] $Name)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "Semantic preflight $Name must be a lowercase SHA-256 identity."
    }
}

function Assert-PreflightOutsideAuthoritySource {
    param([string] $Path, [string] $Context)
    $full = [IO.Path]::GetFullPath($Path)
    $authorityRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else { [StringComparison]::Ordinal }
    if ($full.Equals($authorityRoot, $comparison) -or
        $full.StartsWith($authorityRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "Semantic preflight $Context must be outside the authority source tree."
    }
    if ([IO.File]::Exists($full) -and
        (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Semantic preflight $Context must not use a reparse file path."
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    while (-not [string]::IsNullOrWhiteSpace($parent)) {
        if (-not [IO.Directory]::Exists($parent)) {
            throw "Semantic preflight $Context parent directory does not exist: $parent"
        }
        if (([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Semantic preflight $Context must not use a reparse parent path."
        }
        $parent = [IO.Path]::GetDirectoryName($parent.TrimEnd([IO.Path]::DirectorySeparatorChar))
    }
    return $full
}

function Assert-PreflightExactProperties {
    param([AllowNull()] $Object, [string[]] $Expected, [string] $Context)
    if ($null -eq $Object -or $Object -is [array] -or $Object -is [string] -or $Object -is [ValueType]) {
        throw "Semantic preflight $Context must be a structured object."
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $Expected.Count) {
        throw "Semantic preflight $Context has missing or unsupported properties."
    }
    foreach ($name in $actual) {
        if (-not @($Expected | Where-Object { [string]::Equals($_, $name, [StringComparison]::Ordinal) }).Count) {
            throw "Semantic preflight $Context has unsupported property '$name'."
        }
    }
}

function Assert-PreflightExactSet {
    param([AllowNull()] $Actual, [string[]] $Expected, [string] $Context, [string] $Pattern)
    if ($Actual -isnot [array] -or @($Actual).Count -eq 0 -or $Expected.Count -eq 0) {
        throw "Semantic preflight $Context must contain a non-empty array."
    }
    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Actual)) {
        if ($item -isnot [string] -or $item -cnotmatch $Pattern -or -not $actualSet.Add($item)) {
            throw "Semantic preflight $Context contains an invalid or duplicate identity."
        }
    }
    foreach ($item in $Expected) {
        if ($item -isnot [string] -or $item -cnotmatch $Pattern -or -not $expectedSet.Add($item)) {
            throw "Semantic preflight expected $Context contains an invalid or duplicate identity."
        }
    }
    if (-not $actualSet.SetEquals($expectedSet)) {
        throw "Semantic preflight $Context does not cover the exact expected identities."
    }
}

function Assert-PreflightUniqueJsonProperties {
    param([System.Text.Json.JsonElement] $Element)
    switch ($Element.ValueKind) {
        Object {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) {
                    throw "Semantic preflight scanner JSON contains duplicate property '$($property.Name)'."
                }
                Assert-PreflightUniqueJsonProperties -Element $property.Value
            }
        }
        Array {
            foreach ($item in $Element.EnumerateArray()) {
                Assert-PreflightUniqueJsonProperties -Element $item
            }
        }
    }
}

function Get-PreflightFileSnapshot {
    param([string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw "Semantic preflight scanner result is not a regular file: $full" }
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ($stream.Length -eq 0 -or $stream.Length -gt 16777216) {
            throw 'Semantic preflight scanner result must be between 1 byte and 16 MiB.'
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -eq 0) { throw 'Semantic preflight scanner result ended during a protected read.' }
            $read += $count
        }
    }
    finally { $stream.Dispose() }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw 'Semantic preflight scanner result must use UTF-8 without BOM.'
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $jsonText = $utf8.GetString($bytes)
    $document = [System.Text.Json.JsonDocument]::Parse($jsonText)
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'Semantic preflight scanner result root must be an object.'
        }
        Assert-PreflightUniqueJsonProperties -Element $document.RootElement
    }
    finally { $document.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{
        value = ConvertFrom-Json -InputObject $jsonText -Depth 64
        sha256 = $digest
    }
}

function Convert-PreflightFinding {
    param([AllowNull()] $Finding)
    $allowed = @('severity', 'fingerprint', 'ruleId', 'message', 'path')
    if ($null -eq $Finding -or $Finding -is [array] -or $Finding -is [string] -or $Finding -is [ValueType]) {
        throw 'Semantic preflight findings must contain structured objects.'
    }
    $names = @($Finding.PSObject.Properties | ForEach-Object { [string]$_.Name })
    foreach ($name in $names) {
        if (-not @($allowed | Where-Object { [string]::Equals($_, $name, [StringComparison]::Ordinal) }).Count) {
            throw "Semantic preflight finding contains unsupported property '$name'."
        }
    }
    if (-not @($names | Where-Object { $_ -ceq 'severity' }).Count -or
        $Finding.severity -isnot [string] -or
        $Finding.severity -cnotin @('critical', 'high', 'medium', 'low', 'informational')) {
        throw 'Semantic preflight finding severity is missing or unknown.'
    }
    $canonical = [ordered]@{ severity = [string]$Finding.severity }
    foreach ($name in @('fingerprint', 'ruleId', 'message', 'path')) {
        $property = $Finding.PSObject.Properties[$name]
        if ($null -ne $property) { $canonical[$name] = Assert-PreflightScalar -Value $property.Value -Name "finding $name" }
    }
    return [pscustomobject]$canonical
}

Assert-PreflightSha256 -Value $CandidateId -Name 'candidateId'
Assert-PreflightSha256 -Value $InputInventorySha256 -Name 'inputInventorySha256'
foreach ($entry in @(@{ value = $Provider; name = 'provider' }, @{ value = $Purpose; name = 'purpose' }, @{ value = $Scope; name = 'scope' })) {
    [void](Assert-PreflightScalar -Value $entry.value -Name $entry.name)
}
Assert-PreflightExactSet -Actual @($ExpectedActiveSkills) -Expected $ExpectedActiveSkills -Context 'expected activeSkills' -Pattern '^[a-z0-9]+(?:-[a-z0-9]+)*$'
Assert-PreflightExactSet -Actual @($ExpectedAnalyzerIds) -Expected $ExpectedAnalyzerIds -Context 'expected analyzers' -Pattern '^[a-z][a-z0-9_-]*$'
$scannerFull = Assert-PreflightOutsideAuthoritySource -Path $ScannerResultPath -Context 'scanner result'
$outputFull = Assert-PreflightOutsideAuthoritySource -Path $OutputPath -Context 'output'
$snapshot = Get-PreflightFileSnapshot -Path $scannerFull
$result = $snapshot.value
Assert-PreflightExactProperties -Object $result -Expected @(
    'schemaVersion', 'resultType', 'candidateId', 'inputInventorySha256',
    'provider', 'purpose', 'scope', 'activeSkills', 'analyzers'
) -Context 'scanner result'
if ($result.schemaVersion -isnot [int] -and $result.schemaVersion -isnot [long]) {
    throw 'Semantic preflight scanner schemaVersion must be a typed integer.'
}
if ([int64]$result.schemaVersion -ne 1 -or $result.resultType -cne 'standard-semantic-scan-result-v1' -or
    $result.candidateId -cne $CandidateId -or $result.inputInventorySha256 -cne $InputInventorySha256 -or
    $result.provider -cne $Provider -or $result.purpose -cne $Purpose -or $result.scope -cne $Scope) {
    throw 'Semantic preflight scanner result does not match this candidate, provider, purpose, scope or inventory.'
}
Assert-PreflightExactSet -Actual $result.activeSkills -Expected $ExpectedActiveSkills -Context 'activeSkills' -Pattern '^[a-z0-9]+(?:-[a-z0-9]+)*$'
if ($result.analyzers -isnot [array] -or @($result.analyzers).Count -ne $ExpectedAnalyzerIds.Count) {
    throw 'Semantic preflight scanner result does not contain every expected analyzer.'
}
$analyzerById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach ($analyzer in @($result.analyzers)) {
    Assert-PreflightExactProperties -Object $analyzer -Expected @(
        'identity', 'status', 'completeness', 'coveredSkills', 'findings'
    ) -Context 'analyzer result'
    if ($analyzer.identity -isnot [string] -or $analyzer.identity -cnotmatch '^[a-z][a-z0-9_-]*$' -or
        $analyzer.status -cne 'passed' -or $analyzer.completeness -cne 'complete' -or
        $analyzer.findings -isnot [array]) {
        throw 'Semantic preflight analyzer failed, is incomplete or has invalid findings.'
    }
    Assert-PreflightExactSet -Actual $analyzer.coveredSkills -Expected $ExpectedActiveSkills -Context "coverage for $($analyzer.identity)" -Pattern '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    if ($analyzerById.ContainsKey([string]$analyzer.identity)) {
        throw 'Semantic preflight scanner result contains a duplicate analyzer.'
    }
    $analyzerById.Add([string]$analyzer.identity, $analyzer)
}
$allFindings = [Collections.Generic.List[object]]::new()
$severityGate = 'pass'
foreach ($id in $ExpectedAnalyzerIds) {
    if (-not $analyzerById.ContainsKey($id)) {
        throw "Semantic preflight required analyzer '$id' is missing."
    }
    foreach ($finding in @($analyzerById[$id].findings)) {
        $canonical = Convert-PreflightFinding -Finding $finding
        $allFindings.Add($canonical)
        if ($canonical.severity -in @('critical', 'high')) { $severityGate = 'blocked' }
        elseif ($canonical.severity -ceq 'medium' -and $severityGate -ne 'blocked') { $severityGate = 'human-review' }
    }
}
$findings = [object[]]$allFindings.ToArray()
$canonicalJson = if ($findings.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $findings -Compress -Depth 20 }
$sha = [Security.Cryptography.SHA256]::Create()
try { $findingsDigest = [Convert]::ToHexString($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($canonicalJson))).ToLowerInvariant() }
finally { $sha.Dispose() }

# This artifact is a scanner preflight, never a semantic receipt. A protected
# supervisor must separately authenticate consent and sign the exact candidate.
$preflight = [ordered]@{
    schemaVersion = 1
    preflightType = 'semantic-scan-preflight-v1'
    candidateId = $CandidateId
    inputInventorySha256 = $InputInventorySha256
    scanOutputSha256 = $snapshot.sha256
    provider = $Provider
    purpose = $Purpose
    scope = $Scope
    activeSkills = @($ExpectedActiveSkills)
    analyzerIdentity = @($ExpectedAnalyzerIds)
    analyzerCompleteness = 'declared-set-complete'
    analyzerInventoryVerified = $false
    findings = $findings
    findingsSha256 = $findingsDigest
    severityGate = $severityGate
    consentStatus = 'pending'
    signed = $false
    releaseEligible = $false
}
if ([IO.File]::Exists($outputFull)) {
    throw "Semantic preflight output already exists: $outputFull"
}
$utf8Out = [Text.UTF8Encoding]::new($false)
$outputJson = ConvertTo-Json -InputObject $preflight -Depth 30
$stream = [IO.File]::Open($outputFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = $utf8Out.GetBytes($outputJson + "`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
}
finally { $stream.Dispose() }
[pscustomobject]@{ outputPath = $outputFull; candidateId = $CandidateId; findingsSha256 = $findingsDigest; severityGate = $severityGate }
