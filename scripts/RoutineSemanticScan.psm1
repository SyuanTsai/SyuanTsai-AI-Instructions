# Routine semantic authorization candidate. This module derives a bounded,
# candidate-specific preparation decision; it does not invoke a provider or
# elevate a development fixture into a production consent or release receipt.
Set-StrictMode -Version Latest

function Get-RoutineSemanticProperty {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Assert-RoutineSemanticExactProperties {
    param($Object, [string[]] $Expected, [string] $Context)
    if ($null -eq $Object -or ($Object -isnot [System.Collections.IDictionary] -and $Object -isnot [pscustomobject])) {
        throw "AUTHORIZATION_INVALID|$Context must be an object."
    }
    $actual = if ($Object -is [System.Collections.IDictionary]) { @($Object.Keys) } else { @($Object.PSObject.Properties.Name) }
    if ($actual.Count -ne $Expected.Count) { throw "AUTHORIZATION_INVALID|$Context property set is invalid." }
    foreach ($name in $Expected) {
        if (@($actual | Where-Object { $_ -ceq $name }).Count -ne 1) {
            throw "AUTHORIZATION_INVALID|$Context property set is invalid."
        }
    }
}

function Assert-RoutineSemanticString {
    param($Value, [string] $Context, [string] $Pattern = '^[^\x00-\x1F\x7F]+$')
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -cnotmatch $Pattern) {
        throw "AUTHORIZATION_INVALID|$Context is invalid."
    }
    return [string]$Value
}

function Assert-RoutineSemanticInteger {
    param($Value, [string] $Context, [long] $Minimum = 0, [long] $Maximum = [long]::MaxValue)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or [long]$Value -lt $Minimum -or [long]$Value -gt $Maximum) {
        throw "AUTHORIZATION_INVALID|$Context must be a bounded typed integer."
    }
    return [long]$Value
}

function Get-RoutineSemanticSha256 {
    param([byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RoutineSemanticUtcTime {
    param($Value, [string] $Context)
    if ($Value -is [DateTime]) {
        if ($Value.Kind -ne [DateTimeKind]::Utc) { throw "AUTHORIZATION_INVALID|$Context must be UTC." }
        return [DateTimeOffset]$Value
    }
    if ($Value -is [DateTimeOffset]) {
        if ($Value.Offset -ne [TimeSpan]::Zero) { throw "AUTHORIZATION_INVALID|$Context must be UTC." }
        return $Value
    }
    $text = Assert-RoutineSemanticString -Value $Value -Context $Context -Pattern '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?(Z|\+00:00)$'
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero) {
        throw "AUTHORIZATION_INVALID|$Context must be a UTC timestamp."
    }
    return $parsed
}

function Assert-RoutineSemanticUnambiguousJson {
    param([string] $Json, [string] $Context)
    # ConvertFrom-Json may keep the last duplicate property. Check decoded keys
    # first so signed bytes cannot mean different scopes to different readers.
    $tokenPattern = '\G\s*(?:"(?:\\.|[^"\\])*"|[{}\[\],:]|[^{}\[\],:\s]+)'
    $tokenRegex = New-Object Text.RegularExpressions.Regex($tokenPattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2))
    $stack = New-Object System.Collections.ArrayList
    [void]$stack.Add([pscustomobject]@{ kind = 'root'; mode = 'value'; seen = $null })
    $position = 0
    while ($position -lt $Json.Length) {
        $match = $tokenRegex.Match($Json, $position)
        if (-not $match.Success -or $match.Index -ne $position) {
            if ([string]::IsNullOrWhiteSpace($Json.Substring($position))) { break }
            throw "AUTHORIZATION_INVALID|$Context JSON token is invalid."
        }
        $token = $match.Value.TrimStart()
        $position += $match.Length
        $frame = $stack[$stack.Count - 1]
        if ($token -ceq '}' -or $token -ceq ']') {
            if ($frame.kind -ceq 'root' -or
                ($token -ceq '}' -and $frame.kind -cne 'object') -or
                ($token -ceq ']' -and $frame.kind -cne 'array') -or
                $frame.mode -notin @('keyOrEnd', 'valueOrEnd', 'commaOrEnd')) {
                throw "AUTHORIZATION_INVALID|$Context JSON structure is invalid."
            }
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        if ($token -ceq ',') {
            if ($frame.mode -cne 'commaOrEnd') { throw "AUTHORIZATION_INVALID|$Context JSON comma is invalid." }
            $frame.mode = if ($frame.kind -ceq 'object') { 'key' } else { 'value' }
            continue
        }
        if ($token -ceq ':') {
            if ($frame.kind -cne 'object' -or $frame.mode -cne 'colon') { throw "AUTHORIZATION_INVALID|$Context JSON colon is invalid." }
            $frame.mode = 'value'
            continue
        }
        if ($frame.kind -ceq 'object' -and $frame.mode -in @('key', 'keyOrEnd')) {
            if (-not $token.StartsWith('"', [StringComparison]::Ordinal)) { throw "AUTHORIZATION_INVALID|$Context JSON key is invalid." }
            try { $key = [string](Get-RoutineSemanticProperty (ConvertFrom-Json -InputObject ('{"key":' + $token + '}') -ErrorAction Stop) 'key') }
            catch { throw "AUTHORIZATION_INVALID|$Context JSON key is invalid." }
            if (-not $frame.seen.Add($key)) { throw "AUTHORIZATION_INVALID|$Context duplicate decoded JSON property." }
            $frame.mode = 'colon'
            continue
        }
        if ($frame.mode -cne 'value' -and $frame.mode -cne 'valueOrEnd') { throw "AUTHORIZATION_INVALID|$Context JSON value is invalid." }
        $frame.mode = if ($frame.kind -ceq 'root') { 'done' } else { 'commaOrEnd' }
        if ($token -ceq '{') {
            [void]$stack.Add([pscustomobject]@{ kind = 'object'; mode = 'keyOrEnd'; seen = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)) })
        }
        elseif ($token -ceq '[') {
            [void]$stack.Add([pscustomobject]@{ kind = 'array'; mode = 'valueOrEnd'; seen = $null })
        }
    }
    if ($stack.Count -ne 1 -or $stack[0].mode -cne 'done') { throw "AUTHORIZATION_INVALID|$Context JSON is incomplete." }
}

function Read-RoutineSemanticJsonFile {
    param([Parameter(Mandatory = $true)] [string] $Path, [string] $Context = 'JSON input')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "INPUT_MISSING|$Context is missing." }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "INPUT_INVALID|$Context must be a regular file." }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -lt 2 -or $bytes.Length -gt 16777216) { throw "INPUT_INVALID|$Context size is invalid." }
    try {
        $json = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
        Assert-RoutineSemanticUnambiguousJson -Json $json -Context $Context
        $value = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch { throw "INPUT_INVALID|$Context is not unambiguous strict UTF-8 JSON." }
    if ($null -eq $value -or $value -is [array]) { throw "INPUT_INVALID|$Context must be one object." }
    return [pscustomobject]@{ value = $value; bytes = $bytes; sha256 = (Get-RoutineSemanticSha256 $bytes) }
}

function Get-RoutineSemanticSignedPayload {
    param($Envelope, [Security.Cryptography.RSACryptoServiceProvider] $PublicKey, [string] $Context)
    Assert-RoutineSemanticExactProperties -Object $Envelope -Expected @('schemaVersion', 'keyId', 'payloadBase64', 'signatureBase64') -Context $Context
    if ((Assert-RoutineSemanticInteger -Value (Get-RoutineSemanticProperty $Envelope 'schemaVersion') -Context "$Context schemaVersion" -Minimum 1 -Maximum 1) -ne 1) {
        throw "AUTHORIZATION_INVALID|$Context schemaVersion is invalid."
    }
    if ((Assert-RoutineSemanticString -Value (Get-RoutineSemanticProperty $Envelope 'keyId') -Context "$Context keyId") -cne 'fixture') {
        throw "AUTHORIZATION_INVALID|$Context keyId is not the development fixture key."
    }
    $payloadText = Assert-RoutineSemanticString -Value (Get-RoutineSemanticProperty $Envelope 'payloadBase64') -Context "$Context payloadBase64" -Pattern '^[A-Za-z0-9+/]+={0,2}$'
    $signatureText = Assert-RoutineSemanticString -Value (Get-RoutineSemanticProperty $Envelope 'signatureBase64') -Context "$Context signatureBase64" -Pattern '^[A-Za-z0-9+/]+={0,2}$'
    try {
        $bytes = [Convert]::FromBase64String($payloadText)
        $signature = [Convert]::FromBase64String($signatureText)
    }
    catch { throw "AUTHORIZATION_INVALID|$Context base64 is invalid." }
    if ($bytes.Length -lt 2 -or $bytes.Length -gt 65536 -or $signature.Length -lt 128) {
        throw "AUTHORIZATION_INVALID|$Context size is invalid."
    }
    if (-not $PublicKey.VerifyData($bytes, 'SHA256', $signature)) {
        throw "AUTHORIZATION_INVALID|$Context signature is invalid."
    }
    try {
        $json = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
        Assert-RoutineSemanticUnambiguousJson -Json $json -Context $Context
        $value = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch { throw "AUTHORIZATION_INVALID|$Context payload is not strict UTF-8 JSON." }
    return [pscustomobject]@{ value = $value; sha256 = (Get-RoutineSemanticSha256 -Bytes $bytes) }
}

function Assert-RoutineSemanticStringArray {
    param($Value, [string] $Context, [string] $Pattern)
    if ($Value -isnot [array] -or @($Value).Count -eq 0) {
        throw "AUTHORIZATION_INVALID|$Context must be a non-empty array."
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $result = @()
    foreach ($item in @($Value)) {
        $text = Assert-RoutineSemanticString -Value $item -Context $Context -Pattern $Pattern
        if (-not $seen.Add($text)) { throw "AUTHORIZATION_INVALID|$Context contains a duplicate value." }
        $result += $text
    }
    return ,$result
}

function Test-RoutineSemanticAuthorization {
    [CmdletBinding()]
    param(
        [AllowNull()] $GrantEnvelope,
        [AllowNull()] $RevocationEnvelope,
        [Parameter(Mandatory = $true)] $Candidate,
        [string] $FixturePublicKeyXml,
        [switch] $DevelopmentHarness,
        [DateTime] $Now = [DateTime]::UtcNow
    )

    # No production grant trust policy or protected signer has been approved.
    # This branch is a testable preparation candidate only.
    if (-not $DevelopmentHarness) { throw 'TRUST_POLICY_REVIEW_REQUIRED|Production standing-grant verification is unavailable.' }
    if ([string]::IsNullOrWhiteSpace($FixturePublicKeyXml)) { throw 'AUTHORIZATION_INVALID|A fixture verification key is required.' }
    $publicKey = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        try { $publicKey.FromXmlString($FixturePublicKeyXml) }
        catch { throw 'AUTHORIZATION_INVALID|The fixture verification key is invalid.' }
        $grantRecord = Get-RoutineSemanticSignedPayload -Envelope $GrantEnvelope -PublicKey $publicKey -Context 'standing grant'
        $revocationRecord = Get-RoutineSemanticSignedPayload -Envelope $RevocationEnvelope -PublicKey $publicKey -Context 'revocation registry'
    }
    finally { $publicKey.Dispose() }

    $grant = $grantRecord.value
    Assert-RoutineSemanticExactProperties -Object $grant -Expected @(
        'schemaVersion', 'grantType', 'grantId', 'repository', 'pathPrefixes', 'dataCategories',
        'provider', 'account', 'modelFamily', 'purpose', 'dataHandlingSha256',
        'approvalEvidenceSha256', 'maxSourceBytes', 'maxCalls', 'notBefore', 'expiresAt'
    ) -Context 'standing grant payload'
    [void](Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $grant 'schemaVersion') 'grant schemaVersion' 1 1)
    if ((Assert-RoutineSemanticString (Get-RoutineSemanticProperty $grant 'grantType') 'grantType') -cne 'routine-semantic-standing-grant-v1') { throw 'AUTHORIZATION_INVALID|Grant type is invalid.' }
    $grantId = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $grant 'grantId') 'grantId' '^[0-9a-f-]{36}$'
    $grantRepository = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $grant 'repository') 'repository' '^https://[^\s]+\.git$'
    $prefixes = Assert-RoutineSemanticStringArray (Get-RoutineSemanticProperty $grant 'pathPrefixes') 'pathPrefixes' '^[A-Za-z0-9][A-Za-z0-9_./-]*/$'
    foreach ($prefix in @($prefixes)) {
        if ($prefix -match '(^|/)\.\.?(/|$)' -or $prefix.Contains('//')) { throw 'AUTHORIZATION_INVALID|Standing grant path prefix is unsafe.' }
    }
    $categories = Assert-RoutineSemanticStringArray (Get-RoutineSemanticProperty $grant 'dataCategories') 'dataCategories' '^[a-z][a-z0-9-]*$'
    foreach ($name in @('provider', 'account', 'modelFamily', 'purpose')) { [void](Assert-RoutineSemanticString (Get-RoutineSemanticProperty $grant $name) "grant $name") }
    foreach ($name in @('dataHandlingSha256', 'approvalEvidenceSha256')) { [void](Assert-RoutineSemanticString (Get-RoutineSemanticProperty $grant $name) "grant $name" '^[0-9a-f]{64}$') }
    $maxBytes = Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $grant 'maxSourceBytes') 'maxSourceBytes' 1 2097152
    $maxCalls = Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $grant 'maxCalls') 'maxCalls' 1 48
    $notBefore = Get-RoutineSemanticUtcTime (Get-RoutineSemanticProperty $grant 'notBefore') 'grant notBefore'
    $grantExpiry = Get-RoutineSemanticUtcTime (Get-RoutineSemanticProperty $grant 'expiresAt') 'grant expiresAt'
    $nowUtc = [DateTimeOffset]$Now.ToUniversalTime()
    if ($notBefore -gt $nowUtc -or $grantExpiry -le $nowUtc -or $grantExpiry -le $notBefore) {
        throw 'AUTHORIZATION_EXPIRED|Standing grant is not active.'
    }

    $registry = $revocationRecord.value
    Assert-RoutineSemanticExactProperties -Object $registry -Expected @('schemaVersion', 'registryType', 'sequence', 'updatedAt', 'expiresAt', 'revokedGrantIds') -Context 'revocation registry payload'
    [void](Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $registry 'schemaVersion') 'registry schemaVersion' 1 1)
    if ((Assert-RoutineSemanticString (Get-RoutineSemanticProperty $registry 'registryType') 'registryType') -cne 'routine-semantic-revocations-v1') { throw 'AUTHORIZATION_INVALID|Revocation registry type is invalid.' }
    [void](Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $registry 'sequence') 'registry sequence' 1)
    $updatedAt = Get-RoutineSemanticUtcTime (Get-RoutineSemanticProperty $registry 'updatedAt') 'registry updatedAt'
    $registryExpiry = Get-RoutineSemanticUtcTime (Get-RoutineSemanticProperty $registry 'expiresAt') 'registry expiresAt'
    if ($updatedAt -gt $nowUtc -or $registryExpiry -le $nowUtc -or $registryExpiry -gt $updatedAt.AddMinutes(30)) {
        throw 'AUTHORIZATION_EXPIRED|Revocation registry is stale or invalid.'
    }
    $revokedIds = Get-RoutineSemanticProperty $registry 'revokedGrantIds'
    if ($revokedIds -isnot [array]) { throw 'AUTHORIZATION_INVALID|Revoked grant IDs must be an array.' }
    foreach ($id in @($revokedIds)) {
        [void](Assert-RoutineSemanticString $id 'revoked grant ID' '^[0-9a-f-]{36}$')
        if ($id -ceq $grantId) { throw 'AUTHORIZATION_REVOKED|Standing grant has been revoked.' }
    }

    Assert-RoutineSemanticExactProperties -Object $Candidate -Expected @(
        'repository', 'sourceRevision', 'candidateId', 'inputInventorySha256', 'toolReceiptSha256',
        'paths', 'dataCategory', 'provider', 'account', 'modelFamily', 'purpose',
        'dataHandlingSha256', 'sourceBytes', 'plannedCalls'
    ) -Context 'candidate'
    $candidateRepository = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Candidate 'repository') 'candidate repository' '^https://[^\s]+\.git$'
    $revision = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Candidate 'sourceRevision') 'sourceRevision' '^[0-9a-f]{40}$'
    $candidateId = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Candidate 'candidateId') 'candidateId' '^[0-9a-f]{64}$'
    $inventorySha = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Candidate 'inputInventorySha256') 'inputInventorySha256' '^[0-9a-f]{64}$'
    $toolSha = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Candidate 'toolReceiptSha256') 'toolReceiptSha256' '^[0-9a-f]{64}$'
    $paths = Assert-RoutineSemanticStringArray (Get-RoutineSemanticProperty $Candidate 'paths') 'candidate paths' '^[A-Za-z0-9][A-Za-z0-9_./-]*$'
    $candidateBytes = Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $Candidate 'sourceBytes') 'sourceBytes' 1
    $candidateCalls = Assert-RoutineSemanticInteger (Get-RoutineSemanticProperty $Candidate 'plannedCalls') 'plannedCalls' 1
    if ($candidateRepository -cne $grantRepository -or $candidateBytes -gt $maxBytes -or $candidateCalls -gt $maxCalls) {
        throw 'AUTHORIZATION_SCOPE_CHANGE|Repository or budget is outside the standing grant.'
    }
    foreach ($name in @('provider', 'account', 'modelFamily', 'purpose', 'dataHandlingSha256')) {
        if ((Get-RoutineSemanticProperty $Candidate $name) -isnot [string] -or
            [string](Get-RoutineSemanticProperty $Candidate $name) -cne [string](Get-RoutineSemanticProperty $grant $name)) {
            throw "AUTHORIZATION_SCOPE_CHANGE|Candidate $name is outside the standing grant."
        }
    }
    $category = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Candidate 'dataCategory') 'dataCategory' '^[a-z][a-z0-9-]*$'
    if (@($categories | Where-Object { $_ -ceq $category }).Count -ne 1) { throw 'AUTHORIZATION_SCOPE_CHANGE|Data category is outside the standing grant.' }
    foreach ($path in @($paths)) {
        if ($path -match '(^|/)\.\.?(/|$)' -or $path.Contains('//')) { throw 'AUTHORIZATION_SCOPE_CHANGE|Candidate path is unsafe.' }
        $covered = $false
        foreach ($prefix in @($prefixes)) { if ($path.StartsWith($prefix, [StringComparison]::Ordinal)) { $covered = $true; break } }
        if (-not $covered) { throw 'AUTHORIZATION_SCOPE_CHANGE|Candidate path is outside the standing grant.' }
    }

    $decisionText = @(
        'routine-semantic-decision-v1', $grantRecord.sha256, $candidateRepository, $revision,
        $candidateId, $inventorySha, $toolSha, $category, ($paths -join ',')
    ) -join "`n"
    $decisionSha = Get-RoutineSemanticSha256 -Bytes ([Text.UTF8Encoding]::new($false)).GetBytes($decisionText)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        artifactType = 'routine-semantic-derived-decision-v1'
        decisionId = "routine-semantic-run-v1:$decisionSha"
        grantId = $grantId
        grantSha256 = [string]$grantRecord.sha256
        revocationRegistrySha256 = [string]$revocationRecord.sha256
        candidateId = $candidateId
        sourceRevision = $revision
        inputInventorySha256 = $inventorySha
        toolReceiptSha256 = $toolSha
        scopeAllowed = $true
        egressAuthorized = $false
        scanExecuted = $false
        ciAdmission = 'BLOCKED'
        releaseEligible = $false
        status = 'PREPARED_FIXTURE_ONLY'
    }
}

function Invoke-RoutineSemanticGitBytes {
    param([string] $RepositoryRoot, [string] $Arguments, [int] $MaximumOutputBytes)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = 'git'
    $start.Arguments = $Arguments
    $start.WorkingDirectory = $RepositoryRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $stream = New-Object IO.MemoryStream
    try {
        if (-not $process.Start()) { throw 'SOURCE_GIT_FAILED|Could not start Git.' }
        $buffer = New-Object byte[] 8192
        while ($true) {
            $readTask = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait(30000)) {
                $process.Kill()
                throw 'SOURCE_GIT_TIMEOUT|Git output stalled.'
            }
            $read = $readTask.Result
            if ($read -eq 0) { break }
            if ($stream.Length + $read -gt $MaximumOutputBytes) {
                $process.Kill()
                throw 'SOURCE_BUDGET_EXCEEDED|Git output exceeds the bounded preparation limit.'
            }
            $stream.Write($buffer, 0, $read)
        }
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw 'SOURCE_GIT_TIMEOUT|Git did not exit.'
        }
        if ($process.ExitCode -ne 0) { throw 'SOURCE_GIT_FAILED|Git could not read the immutable candidate.' }
        return ,$stream.ToArray()
    }
    finally {
        if (-not $process.HasExited) { $process.Kill() }
        $stream.Dispose()
        $process.Dispose()
    }
}

function Get-RoutineSemanticGitInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $Revision,
        [Parameter(Mandatory = $true)] [string[]] $PathPrefixes,
        [Parameter(Mandatory = $true)] [int] $MaximumBytes
    )
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw 'SOURCE_INVALID|Repository root does not exist.' }
    if ($Revision -cnotmatch '^[0-9a-f]{40}$') { throw 'SOURCE_INVALID|Revision must be an exact commit SHA.' }
    if ($MaximumBytes -lt 1 -or $MaximumBytes -gt 2097152) { throw 'SOURCE_INVALID|Source budget is invalid.' }
    $prefixes = Assert-RoutineSemanticStringArray $PathPrefixes 'selected pathPrefixes' '^[A-Za-z0-9][A-Za-z0-9_./-]*/$'
    foreach ($prefix in @($prefixes)) {
        if ($prefix -match '(^|/)\.\.?(/|$)' -or $prefix.Contains('//')) { throw 'SOURCE_INVALID|Selected path prefix is unsafe.' }
    }
    $typeBytes = Invoke-RoutineSemanticGitBytes $RepositoryRoot "--no-replace-objects cat-file -t $Revision" 64
    if (([Text.Encoding]::ASCII.GetString($typeBytes)).Trim() -cne 'commit') { throw 'SOURCE_INVALID|Revision is not a commit.' }
    $treeBytes = Invoke-RoutineSemanticGitBytes $RepositoryRoot "--no-replace-objects ls-tree -rz --full-tree $Revision -- $($prefixes -join ' ')" 4194304
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $files = @()
    $total = 0L
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($record in @([Text.Encoding]::GetEncoding(28591).GetString($treeBytes).Split([char]0))) {
        if ([string]::IsNullOrEmpty($record)) { continue }
        # Latin-1 is a reversible byte container on both supported runtimes.
        $recordBytes = [Text.Encoding]::GetEncoding(28591).GetBytes($record)
        try { $line = $utf8.GetString($recordBytes) }
        catch { throw 'SOURCE_ENCODING_INVALID|Git tree path is not strict UTF-8.' }
        if ($line -cnotmatch '^([0-9]{6}) blob ([0-9a-f]{40})\t(.+)$') { throw 'SOURCE_INVALID|Selected tree entry is not a regular blob.' }
        $mode = $Matches[1]
        $blobId = $Matches[2]
        $path = $Matches[3]
        if ($mode -cne '100644' -and $mode -cne '100755') { throw 'SOURCE_INVALID|Selected entry is not a regular file.' }
        if ($path -match '[\x00-\x1F\x7F]' -or $path -match '(^|/)\.\.?(/|$)' -or $path.Contains('//') -or -not $seen.Add($path)) {
            throw 'SOURCE_INVALID|Selected tree path is unsafe or duplicated.'
        }
        $covered = $false
        foreach ($prefix in @($prefixes)) { if ($path.StartsWith($prefix, [StringComparison]::Ordinal)) { $covered = $true; break } }
        if (-not $covered) { throw 'SOURCE_INVALID|Git returned a path outside selected prefixes.' }
        $blob = Invoke-RoutineSemanticGitBytes $RepositoryRoot "--no-replace-objects cat-file blob $blobId" ($MaximumBytes + 1)
        try { [void]$utf8.GetString($blob) }
        catch { throw 'SOURCE_ENCODING_INVALID|Selected blob is not strict UTF-8.' }
        $total += $blob.Length
        if ($total -gt $MaximumBytes) { throw 'SOURCE_BUDGET_EXCEEDED|Selected source exceeds the approved budget.' }
        $files += [pscustomobject][ordered]@{ path = $path; gitBlobSha1 = $blobId; bytes = $blob.Length; sha256 = (Get-RoutineSemanticSha256 $blob) }
    }
    if ($files.Count -eq 0) { throw 'SOURCE_INVALID|Selected prefixes have no committed files.' }
    $ordered = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($file in $files) { $ordered.Add($file.path, $file) }
    $sortedFiles = @($ordered.Values)
    $lines = @('routine-semantic-git-inventory-v1', $Revision)
    foreach ($file in $sortedFiles) { $lines += "$($file.path)`t$($file.gitBlobSha1)`t$($file.bytes)`t$($file.sha256)" }
    $inventorySha = Get-RoutineSemanticSha256 ([Text.UTF8Encoding]::new($false)).GetBytes(($lines -join "`n"))
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        artifactType = 'routine-semantic-git-inventory-v1'
        sourceRevision = $Revision
        pathPrefixes = @($prefixes)
        files = $sortedFiles
        sourceBytes = $total
        inputInventorySha256 = $inventorySha
        payloadComplete = $false
        egressAuthorized = $false
        ciAdmission = 'BLOCKED'
        status = 'SOURCE_INVENTORY_ONLY'
    }
}

function New-RoutineSemanticPreparation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $Revision,
        [Parameter(Mandatory = $true)] [string] $Repository,
        [Parameter(Mandatory = $true)] [string[]] $PathPrefixes,
        [Parameter(Mandatory = $true)] [string] $DataCategory,
        [Parameter(Mandatory = $true)] [string] $Provider,
        [Parameter(Mandatory = $true)] [string] $Account,
        [Parameter(Mandatory = $true)] [string] $ModelFamily,
        [Parameter(Mandatory = $true)] [string] $Purpose,
        [Parameter(Mandatory = $true)] [string] $DataHandlingSha256,
        [Parameter(Mandatory = $true)] [string] $ToolReceiptSha256,
        [Parameter(Mandatory = $true)] [int] $PlannedCalls,
        [Parameter(Mandatory = $true)] [int] $MaximumBytes,
        [AllowNull()] $GrantEnvelope,
        [AllowNull()] $RevocationEnvelope,
        [string] $FixturePublicKeyXml,
        [switch] $DevelopmentHarness,
        [DateTime] $Now = [DateTime]::UtcNow
    )
    if (-not $DevelopmentHarness) { throw 'TRUST_POLICY_REVIEW_REQUIRED|Production preparation is not enabled.' }
    $repositoryValue = Assert-RoutineSemanticString $Repository 'repository' '^https://[^\s]+\.git$'
    $originBytes = Invoke-RoutineSemanticGitBytes $RepositoryRoot '--no-replace-objects remote get-url origin' 4096
    try { $origin = ([Text.UTF8Encoding]::new($false, $true)).GetString($originBytes).Trim() }
    catch { throw 'SOURCE_REPOSITORY_MISMATCH|Origin URL is not strict UTF-8.' }
    if ($origin -cne $repositoryValue) { throw 'SOURCE_REPOSITORY_MISMATCH|Caller repository does not match Git origin.' }
    $inventory = Get-RoutineSemanticGitInventory -RepositoryRoot $RepositoryRoot -Revision $Revision -PathPrefixes $PathPrefixes -MaximumBytes $MaximumBytes
    [void](Assert-RoutineSemanticString $ToolReceiptSha256 'toolReceiptSha256' '^[0-9a-f]{64}$')
    [void](Assert-RoutineSemanticString $DataHandlingSha256 'dataHandlingSha256' '^[0-9a-f]{64}$')
    [void](Assert-RoutineSemanticInteger $PlannedCalls 'plannedCalls' 1 48)
    foreach ($item in @(@{ value = $Provider; name = 'provider' }, @{ value = $Account; name = 'account' }, @{ value = $ModelFamily; name = 'modelFamily' }, @{ value = $Purpose; name = 'purpose' })) {
        [void](Assert-RoutineSemanticString $item.value $item.name)
    }
    $candidateText = @(
        'routine-semantic-candidate-v1', $repositoryValue, $Revision,
        $inventory.inputInventorySha256, $ToolReceiptSha256, $DataCategory,
        $Provider, $Account, $ModelFamily, $Purpose, $DataHandlingSha256,
        [string]$inventory.sourceBytes, [string]$PlannedCalls
    ) -join "`n"
    $candidateId = Get-RoutineSemanticSha256 ([Text.UTF8Encoding]::new($false)).GetBytes($candidateText)
    $candidate = [pscustomobject][ordered]@{
        repository = $repositoryValue
        sourceRevision = $Revision
        candidateId = $candidateId
        inputInventorySha256 = $inventory.inputInventorySha256
        toolReceiptSha256 = $ToolReceiptSha256
        paths = @($inventory.files | ForEach-Object { $_.path })
        dataCategory = $DataCategory
        provider = $Provider
        account = $Account
        modelFamily = $ModelFamily
        purpose = $Purpose
        dataHandlingSha256 = $DataHandlingSha256
        sourceBytes = $inventory.sourceBytes
        plannedCalls = $PlannedCalls
    }
    $decision = Test-RoutineSemanticAuthorization -GrantEnvelope $GrantEnvelope -RevocationEnvelope $RevocationEnvelope -Candidate $candidate -FixturePublicKeyXml $FixturePublicKeyXml -DevelopmentHarness -Now $Now
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        artifactType = 'routine-semantic-prepared-plan-v1'
        authority = [pscustomobject][ordered]@{ repository = $repositoryValue; sourceRevision = $Revision; root = $null; rootIsTrustedInput = $false }
        candidateId = $candidateId
        sourceInventory = $inventory
        decision = $decision
        route = [pscustomobject][ordered]@{ provider = $Provider; account = $Account; modelFamily = $ModelFamily; purpose = $Purpose; dataHandlingSha256 = $DataHandlingSha256 }
        executionPlan = [pscustomobject][ordered]@{ plannedCalls = $PlannedCalls; toolReceiptSha256 = $ToolReceiptSha256; analyzerSet = @(); providerTextInventory = @(); maximumSourceBytes = $MaximumBytes }
        payloadComplete = $false
        scanStatus = 'NOT_RUN'
        ciAdmission = 'BLOCKED'
        releaseEligible = $false
        capabilityGaps = @('PROVIDER_ISOLATION_UNVERIFIED', 'TOOL_RECEIPT_UNVERIFIED', 'PROMPT_PAYLOAD_INCOMPLETE', 'PRODUCTION_TRUST_POLICY_UNREVIEWED')
    }
}

function Get-RoutineSemanticDeliveryPlanBinding {
    param($Consumer, [string] $ConsumerPlanSha256)
    $source = Get-RoutineSemanticProperty $Consumer 'source'
    $candidate = Get-RoutineSemanticProperty $Consumer 'candidate'
    $authority = Get-RoutineSemanticProperty $Consumer 'authority'
    $tools = Get-RoutineSemanticProperty $Consumer 'tools'
    $semantic = Get-RoutineSemanticProperty $Consumer 'semantic'
    if ($null -eq $source -or $null -eq $candidate -or $null -eq $authority -or $null -eq $tools -or $null -eq $semantic) {
        throw 'DELIVERY_PLAN_INCOMPLETE|Source, candidate, authority, tools and semantic closure are required.'
    }
    $hex40 = '^[0-9a-f]{40}$'
    $hex64 = '^[0-9a-f]{64}$'
    $artifacts = [ordered]@{}
    foreach ($name in @('consentRequestPath', 'consentDecisionPath', 'evidencePath', 'publicKeyPath')) {
        $artifacts[$name] = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $semantic $name) $name
    }
    return [pscustomobject][ordered]@{
        runId = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $Consumer 'runId') 'runId' '^[0-9a-f]{32}$'
        consumerPlanSha256 = Assert-RoutineSemanticString $ConsumerPlanSha256 'consumerPlanSha256' $hex64
        sourceRevision = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $source 'revision') 'sourceRevision' $hex40
        sourceBaseRevision = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $source 'baseRevision') 'sourceBaseRevision' $hex40
        sourceTree = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $source 'tree') 'sourceTree' $hex40
        consumerCandidateId = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $candidate 'candidateId') 'consumerCandidateId' $hex64
        consumerContentSha256 = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $candidate 'contentSha256') 'consumerContentSha256' $hex64
        authorityArchiveSha256 = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $authority 'archiveSha256') 'authorityArchiveSha256' $hex64
        authorityRunnerSha256 = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $authority 'runnerSha256') 'authorityRunnerSha256' $hex64
        toolPolicyReceiptSha256 = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $tools 'policyReceiptSha256') 'toolPolicyReceiptSha256' $hex64
        publicKeyId = Assert-RoutineSemanticString (Get-RoutineSemanticProperty $semantic 'publicKeyId') 'publicKeyId'
        artifacts = [pscustomobject]$artifacts
    }
}

Export-ModuleMember -Function Test-RoutineSemanticAuthorization, Get-RoutineSemanticGitInventory, New-RoutineSemanticPreparation, Read-RoutineSemanticJsonFile, Get-RoutineSemanticDeliveryPlanBinding
