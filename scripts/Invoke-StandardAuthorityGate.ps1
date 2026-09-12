[CmdletBinding()]
param(
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [System.IO.Path]::GetTempPath() }
    ),

    [string] $ExpectedGoRuntimeVersion = $env:STANDARD_GO_RUNTIME_VERSION,

    [string] $GoCommandPath = $env:STANDARD_GO_COMMAND_PATH,

    [switch] $DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedGoRuntimeSource = 'https://go.dev/dl/?mode=json'

function Get-AuthorityProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) { return ,$DefaultValue }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return ,$DefaultValue }
        return ,$Object[$Name]
    }
    if ($null -eq $Object.PSObject) { return ,$DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ,$DefaultValue }
    return ,$property.Value
}

function Get-AuthorityRequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object) {
        throw "$Context is missing required property '$Name'."
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name) -or $null -eq $Object[$Name]) {
            throw "$Context is missing required property '$Name'."
        }
        return ,$Object[$Name]
    }
    if ($null -eq $Object.PSObject) {
        throw "$Context is missing required property '$Name'."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Context is missing required property '$Name'."
    }
    return ,$property.Value
}

function Assert-AuthorityRunReceiptContext {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $ExpectedRunId,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($ExpectedRunId -notmatch '^[0-9a-f]{32}$') {
        throw "$Context expected run id is malformed."
    }
    $actualRunId = Get-AuthorityRequiredProperty -Object $Receipt -Name 'resolutionRunId' -Context $Context
    if ($actualRunId -isnot [string] -or [string]$actualRunId -cne $ExpectedRunId) {
        throw "$Context is bound to a different authority run."
    }

    $resolvedAtUtc = Get-AuthorityRequiredProperty -Object $Receipt -Name 'resolvedAtUtc' -Context $Context
    if ($resolvedAtUtc -is [DateTime]) {
        if ($resolvedAtUtc.Kind -ne [DateTimeKind]::Utc) {
            throw "$Context resolvedAtUtc is not UTC."
        }
    }
    elseif ($resolvedAtUtc -is [DateTimeOffset]) {
        if ($resolvedAtUtc.Offset -ne [TimeSpan]::Zero) {
            throw "$Context resolvedAtUtc is not UTC."
        }
    }
    elseif ($resolvedAtUtc -is [string] -and
        [string]$resolvedAtUtc -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*Z$') {
        # The JSON reader on Windows PowerShell materializes ISO timestamps as
        # DateTime; retain a string fallback for callers that preserve JSON text.
    }
    else {
        throw "$Context resolvedAtUtc is missing or not a UTC timestamp."
    }
    $parsedResolvedAtUtc = [DateTimeOffset]::MinValue
    $resolvedAtText = if ($resolvedAtUtc -is [DateTime]) {
        $resolvedAtUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    elseif ($resolvedAtUtc -is [DateTimeOffset]) {
        $resolvedAtUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    else { [string]$resolvedAtUtc }
    if (-not [DateTimeOffset]::TryParse(
            $resolvedAtText,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsedResolvedAtUtc) -or
        $parsedResolvedAtUtc.Offset -ne [TimeSpan]::Zero -or
        $parsedResolvedAtUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
        $parsedResolvedAtUtc -lt [DateTimeOffset]::UtcNow.AddMinutes(-15)) {
        throw "$Context resolvedAtUtc is outside the fresh validation receipt window."
    }

    $receiptExecutionContext = Get-AuthorityRequiredProperty -Object $Receipt -Name 'executionContext' -Context $Context
    $executionOs = Get-AuthorityRequiredProperty -Object $receiptExecutionContext -Name 'os' -Context "$Context executionContext"
    $executionArchitecture = Get-AuthorityRequiredProperty -Object $receiptExecutionContext -Name 'architecture' -Context "$Context executionContext"
    if ($executionOs -isnot [string] -or [string]$executionOs -notmatch '^(windows|unix|osx|other)$' -or
        $executionArchitecture -isnot [string] -or [string]$executionArchitecture -notmatch '^[a-z0-9_-]+$') {
        throw "$Context executionContext is malformed."
    }
    return $true
}

function New-AuthorityRunOwnedToolRoot {
    param(
        [Parameter(Mandatory = $true)][string] $RunId
    )

    if ($RunId -notmatch '^[0-9a-f]{32}$') {
        throw 'Authority tool root requires a lowercase 32-character run id.'
    }

    # The authority evidence tree can be nested below a long checkout or CI
    # artifact path. Keep formal tool installations in a compact, run-owned
    # sibling under the OS temp root so Python venv/ensurepip deep paths do not
    # fail on Windows hosts without Long Paths enabled.
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $toolRoot = [System.IO.Path]::GetFullPath((Join-Path $tempRoot ("svt-tools-{0}" -f $RunId)))
    if ($toolRoot.Length -ge 128) {
        throw "Authority tool root is too long for the Windows Python venv path budget: $toolRoot"
    }
    [void](New-Item -ItemType Directory -Path $toolRoot -ErrorAction Stop)
    $toolRootItem = Get-Item -Force -LiteralPath $toolRoot -ErrorAction Stop
    if (-not $toolRootItem.PSIsContainer -or
        ($toolRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Authority tool root must be a new non-reparse directory: $toolRoot"
    }
    return $toolRoot
}

function Assert-AuthorityUpstreamAdapterReport {
    param([Parameter(Mandatory = $true)] $Report)

    $schemaVersion = Get-AuthorityRequiredProperty -Object $Report -Name 'schemaVersion' -Context 'Upstream adapter report'
    $policy = Get-AuthorityRequiredProperty -Object $Report -Name 'policy' -Context 'Upstream adapter report'
    $adapterVersion = Get-AuthorityRequiredProperty -Object $Report -Name 'adapterVersion' -Context 'Upstream adapter report'
    $status = Get-AuthorityRequiredProperty -Object $Report -Name 'status' -Context 'Upstream adapter report'
    $decision = Get-AuthorityRequiredProperty -Object $Report -Name 'decision' -Context 'Upstream adapter report'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1 -or
        $policy -isnot [string] -or [string]$policy -cne 'upstream-interoperability-adapter-v1' -or
        $adapterVersion -isnot [string] -or [string]$adapterVersion -cne 'upstream-interoperability-adapter-v1' -or
        $status -isnot [string] -or [string]$status -notin @('passed', 'not-applicable') -or
        $decision -isnot [string] -or [string]$decision -notin @('PASS', 'NOT_APPLICABLE')) {
        throw 'upstream adapter validation produced an invalid result.'
    }
    if ([string]$status -ceq 'passed') {
        $surfaces = Get-AuthorityRequiredProperty -Object $Report -Name 'surfaces' -Context 'Upstream adapter report'
        $bundledSkills = Get-AuthorityRequiredProperty -Object $Report -Name 'bundledSkills' -Context 'Upstream adapter report'
        $candidateIdentity = Get-AuthorityRequiredProperty -Object $Report -Name 'candidateIdentity' -Context 'Upstream adapter report'
        $componentInventory = Get-AuthorityRequiredProperty -Object $Report -Name 'componentInventory' -Context 'Upstream adapter report'
        $componentInventorySha256 = Get-AuthorityRequiredProperty -Object $Report -Name 'componentInventorySha256' -Context 'Upstream adapter report'
        if ($surfaces -isnot [array] -or @($surfaces).Count -eq 0 -or
            $bundledSkills -isnot [array] -or
            $componentInventory -isnot [array] -or @($componentInventory).Count -eq 0) {
            throw 'A passed upstream adapter report must include surfaces, component inventory and any bundled Skill inventories.'
        }
        $candidateProperties = if ($null -eq $candidateIdentity -or $null -eq $candidateIdentity.PSObject) {
            @()
        }
        else {
            @($candidateIdentity.PSObject.Properties | ForEach-Object { [string]$_.Name })
        }
        if ($null -eq $candidateIdentity -or $candidateProperties.Count -ne 4 -or
            @('sourceRepository', 'sourceRevision', 'archiveSha256', 'packageSha256' | Where-Object { $candidateProperties -cnotcontains $_ }).Count -ne 0) {
            throw 'A passed upstream adapter report must include the exact immutable candidate identity fields.'
        }
        if ([string]$candidateIdentity.sourceRepository -notmatch '^https://[^/?#]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$' -or
            [string]$candidateIdentity.sourceRevision -cnotmatch '^[0-9a-f]{40}$') {
            throw 'A passed upstream adapter report contains a malformed immutable source identity.'
        }
        Assert-AuthoritySha256 -Value $candidateIdentity.archiveSha256 -Context 'Upstream adapter candidate archive SHA-256'
        Assert-AuthoritySha256 -Value $candidateIdentity.packageSha256 -Context 'Upstream adapter candidate package SHA-256'
        Assert-AuthoritySha256 -Value $componentInventorySha256 -Context 'Upstream adapter component inventory SHA-256'
        $observedComponentPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $orderedComponentPaths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($component in @($componentInventory)) {
            $componentProperties = if ($null -eq $component -or $null -eq $component.PSObject) {
                @()
            }
            else {
                @($component.PSObject.Properties | ForEach-Object { [string]$_.Name })
            }
            if ($null -eq $component -or $componentProperties.Count -ne 2 -or
                @('path', 'sha256' | Where-Object { $componentProperties -cnotcontains $_ }).Count -ne 0) {
                throw 'A passed upstream adapter report contains a malformed component inventory entry.'
            }
            if ($component.path -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$component.path) -or
                -not $observedComponentPaths.Add([string]$component.path)) {
                throw 'A passed upstream adapter report contains a duplicate or malformed component path.'
            }
            Assert-AuthoritySha256 -Value $component.sha256 -Context "Upstream adapter component '$($component.path)'"
            [void]$orderedComponentPaths.Add([string]$component.path)
        }
        $sortedComponentPaths = @($orderedComponentPaths.ToArray())
        [System.Array]::Sort($sortedComponentPaths, [StringComparer]::Ordinal)
        for ($index = 0; $index -lt $sortedComponentPaths.Count; $index++) {
            if ([string]$sortedComponentPaths[$index] -cne [string]$orderedComponentPaths[$index]) {
                throw 'A passed upstream adapter report must emit component inventory in ordinal path order.'
            }
        }
        $computedComponentInventorySha256 = Get-AuthorityComponentInventorySha256 -Inventory $componentInventory
        if ([string]$componentInventorySha256 -cne $computedComponentInventorySha256 -or
            [string]$candidateIdentity.packageSha256 -cne $computedComponentInventorySha256) {
            throw 'A passed upstream adapter report has an unbound component/package identity.'
        }
        foreach ($bundledSkill in @($bundledSkills)) {
            $bundledPath = Get-AuthorityRequiredProperty -Object $bundledSkill -Name 'path' -Context 'Upstream adapter bundled Skill'
            $inventory = Get-AuthorityRequiredProperty -Object $bundledSkill -Name 'inventory' -Context 'Upstream adapter bundled Skill'
            if ($bundledPath -isnot [string] -or [string]::IsNullOrWhiteSpace($bundledPath)) {
                throw 'A passed upstream adapter report contains a malformed bundled Skill path.'
            }
            if ($inventory -isnot [array] -or @($inventory).Count -eq 0) {
                throw "Upstream adapter bundled Skill '$bundledPath' must contain a non-empty inventory."
            }
            Assert-AuthorityExactPathInventory -Value $inventory -Expected @($inventory) -Context "Upstream adapter bundled Skill '$bundledPath'" | Out-Null
        }
    }
    return $true
}

function Assert-AuthorityExactString {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]$Value -cne $Expected) {
        throw "$Context must be the exact string '$Expected'."
    }
}

function Assert-AuthorityNonNegativeInteger {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (($Value -isnot [int] -and $Value -isnot [long]) -or [int64]$Value -lt 0) {
        throw "$Context must be a non-negative integer."
    }
}

function Assert-AuthoritySha256 {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase SHA-256 value."
    }
}

function Assert-AuthorityFileIdentity {
    param(
        [Parameter(Mandatory = $true)] $PathValue,
        [Parameter(Mandatory = $true)] $Sha256Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($PathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$PathValue)) {
        throw "$Context path is missing."
    }
    $path = [System.IO.Path]::GetFullPath([string]$PathValue)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Context path is not an installed file: $path"
    }
    $item = Get-Item -Force -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or $item -isnot [System.IO.FileInfo] -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context path must be a regular non-reparse file: $path"
    }
    Assert-AuthoritySha256 -Value $Sha256Value -Context "$Context receipt hash"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$Sha256Value) {
        throw "$Context changed after resolution. Expected '$Sha256Value', got '$actual'."
    }
    return $path
}

function Assert-AuthorityPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $fullPath.StartsWith($fullRoot, $comparison)) {
        throw "$Context escapes the authority run install root: $fullPath"
    }
}

function Get-AuthorityAsciiCaseFold {
    param([Parameter(Mandatory = $true)][string] $Value)

    $builder = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        if ($code -ge 65 -and $code -le 90) { $code += 32 }
        [void]$builder.Append([char]$code)
    }
    return $builder.ToString()
}

function Get-AuthorityDirectoryClosureSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $rootItem = Get-Item -Force -LiteralPath $root -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installed authority tool directory must be a regular non-reparse directory: $root"
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $ordinalPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $nfcPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $asciiCasePaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed authority tool directory contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) { continue }
        if ($item -isnot [System.IO.FileInfo]) {
            throw "Installed authority tool directory contains a non-regular filesystem entry: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($root.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ).Replace([System.IO.Path]::DirectorySeparatorChar, '/').Replace([System.IO.Path]::AltDirectorySeparatorChar, '/')
        if ([string]::IsNullOrEmpty($relative) -or $relative.StartsWith('/') -or $relative.Contains('\') -or
            $relative.Contains(':') -or $relative -match '[\x00-\x1F\x7F]' -or
            @($relative.Split('/') | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
            throw "Installed authority tool directory contains an unsafe relative path: '$relative'."
        }
        if (-not $ordinalPaths.Add($relative)) {
            throw "Installed authority tool directory contains a duplicate path: '$relative'."
        }
        $nfc = $relative.Normalize([System.Text.NormalizationForm]::FormC)
        if ($nfcPaths.ContainsKey($nfc) -and [string]$nfcPaths[$nfc] -cne $relative) {
            throw "Installed authority tool directory contains Unicode-normalization-colliding paths: '$($nfcPaths[$nfc])' and '$relative'."
        }
        $nfcPaths[$nfc] = $relative
        $asciiCase = Get-AuthorityAsciiCaseFold -Value $nfc
        if ($asciiCasePaths.ContainsKey($asciiCase) -and [string]$asciiCasePaths[$asciiCase] -cne $relative) {
            throw "Installed authority tool directory contains ASCII-case-colliding paths: '$($asciiCasePaths[$asciiCase])' and '$relative'."
        }
        $asciiCasePaths[$asciiCase] = $relative
        [void]$entries.Add([pscustomobject][ordered]@{
                path = $relative
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
            })
    }
    if ($entries.Count -eq 0) { throw "Installed authority tool directory is empty: $root" }
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $entries) {
        $insertAt = 0
        while ($insertAt -lt $ordered.Count -and
            [string]::Compare([string]$ordered[$insertAt].path, [string]$entry.path, [StringComparison]::Ordinal) -lt 0) {
            $insertAt++
        }
        [void]$ordered.Insert($insertAt, $entry)
    }
    $canonical = ($ordered | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-AuthorityJson {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Context JSON file is missing: $Path"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "$Context did not produce parseable JSON: $($_.Exception.Message)"
    }
}

function Assert-AuthorityValidationSecurityGate {
    param([Parameter(Mandatory = $true)] $Policy)

    Assert-AuthorityNonNegativeInteger `
        -Value (Get-AuthorityRequiredProperty -Object $Policy -Name 'schemaVersion' -Context 'Validation/security gate policy') `
        -Context 'Validation/security gate policy schemaVersion'
    if ([int64]$Policy.schemaVersion -ne 1) {
        throw 'Validation/security gate policy has an unsupported schemaVersion.'
    }
    Assert-AuthorityExactString `
        -Value (Get-AuthorityRequiredProperty -Object $Policy -Name 'policy' -Context 'Validation/security gate policy') `
        -Expected 'canonical-validation-security-gate-v1' `
        -Context 'Validation/security gate policy identity'

    $expectedStages = @(
        [ordered]@{ order=1; id='controlled-acquisition'; name='Controlled Acquisition'; condition='always'; evidence=@('candidateIdentity', 'authoritySnapshot', 'sourcePin') },
        [ordered]@{ order=2; id='integrity-verification'; name='Integrity Verification'; condition='always'; evidence=@('archiveSha256', 'contentSha256', 'provenance') },
        [ordered]@{ order=3; id='package-validation'; name='Package Validation'; condition='always'; evidence=@('packageInventory', 'packageSchema', 'packageValidatorResult', 'adapterResult', 'skillToolsResult') },
        [ordered]@{ order=4; id='skillspector-static'; name='SkillSpector Static'; condition='always'; evidence=@('scannerIdentity', 'analyzerCompleteness', 'staticReport') },
        [ordered]@{ order=5; id='repository-tests'; name='Repository Tests'; condition='always'; evidence=@('testInventory', 'testResult', 'domainAdapterResult') },
        [ordered]@{ order=6; id='conditional-semantic-scan'; name='Conditional Semantic Scan'; condition='when-triggered'; evidence=@('triggerDecision', 'semanticReport', 'semanticCompleteness') },
        [ordered]@{ order=7; id='ai-review'; name='AI Review'; condition='always'; evidence=@('reviewFindings', 'findingDisposition', 'reviewedCandidate') },
        [ordered]@{ order=8; id='human-approval'; name='Human Approval'; condition='always'; evidence=@('approver', 'approvalTimestamp', 'approvedCandidate') },
        [ordered]@{ order=9; id='publish-or-install'; name='Publish / Install'; condition='approved-release-or-authorized-install'; evidence=@('releaseIdentity', 'publishOrInstallResult', 'authorization', 'attestation') },
        [ordered]@{ order=10; id='post-install-verification'; name='Post-install Verification'; condition='after-install'; evidence=@('installedInventory', 'installedManifest', 'postInstallIntegrity', 'attestation') }
    )
    $stages = Get-AuthorityRequiredProperty -Object $Policy -Name 'stages' -Context 'Validation/security gate policy'
    if ($stages -isnot [array] -or @($stages).Count -ne $expectedStages.Count) {
        throw 'Validation/security gate policy must contain exactly ten ordered stages.'
    }
    for ($index = 0; $index -lt $expectedStages.Count; $index++) {
        $stage = $stages[$index]
        $expected = $expectedStages[$index]
        Assert-AuthorityNonNegativeInteger -Value (Get-AuthorityRequiredProperty -Object $stage -Name 'order' -Context "Validation/security gate stage $($index + 1)") -Context "Validation/security gate stage $($index + 1) order"
        if ([int64]$stage.order -ne [int64]$expected.order) {
            throw "Validation/security gate stage $($index + 1) has a non-canonical order."
        }
        foreach ($name in @('id', 'name', 'condition')) {
            Assert-AuthorityExactString `
                -Value (Get-AuthorityRequiredProperty -Object $stage -Name $name -Context "Validation/security gate stage $($index + 1)") `
                -Expected ([string]$expected[$name]) `
                -Context "Validation/security gate stage $($index + 1) $name"
        }
        Assert-AuthorityExactString `
            -Value (Get-AuthorityRequiredProperty -Object $stage -Name 'failureAction' -Context "Validation/security gate stage $($index + 1)") `
            -Expected 'BLOCK' `
            -Context "Validation/security gate stage $($index + 1) failure action"
        $evidence = Get-AuthorityRequiredProperty -Object $stage -Name 'evidence' -Context "Validation/security gate stage $($index + 1)"
        $expectedEvidence = @($expected.evidence)
        if ($evidence -isnot [array] -or @($evidence).Count -ne $expectedEvidence.Count) {
            throw "Validation/security gate stage $($index + 1) must declare the exact canonical evidence set."
        }
        for ($evidenceIndex = 0; $evidenceIndex -lt $expectedEvidence.Count; $evidenceIndex++) {
            Assert-AuthorityExactString `
                -Value $evidence[$evidenceIndex] `
                -Expected ([string]$expectedEvidence[$evidenceIndex]) `
                -Context "Validation/security gate stage $($index + 1) evidence $($evidenceIndex + 1)"
        }
    }

    $security = Get-AuthorityRequiredProperty -Object $Policy -Name 'security' -Context 'Validation/security gate policy'
    foreach ($name in @('scannerFailure', 'analyzerIncomplete', 'unparsableResult', 'unknownSeverity')) {
        Assert-AuthorityExactString `
            -Value (Get-AuthorityRequiredProperty -Object $security -Name $name -Context 'Validation/security gate security policy') `
            -Expected 'BLOCK' `
            -Context "Validation/security gate security policy $name"
    }
    $severity = Get-AuthorityRequiredProperty -Object $security -Name 'severity' -Context 'Validation/security gate security policy'
    $expectedSeverity = [ordered]@{
        critical = 'BLOCK'
        high = 'BLOCK'
        medium = 'HUMAN_REVIEW_REQUIRED'
        low = 'RECORD_AND_TRACK'
        informational = 'RECORD_AND_TRACK'
    }
    if ($severity -isnot [array] -or @($severity).Count -ne $expectedSeverity.Count) {
        throw 'Validation/security gate severity mapping is incomplete.'
    }
    foreach ($entry in @($severity)) {
        $level = Get-AuthorityRequiredProperty -Object $entry -Name 'level' -Context 'Validation/security gate severity mapping'
        $action = Get-AuthorityRequiredProperty -Object $entry -Name 'action' -Context 'Validation/security gate severity mapping'
        if ($level -isnot [string] -or -not $expectedSeverity.Contains([string]$level)) {
            throw "Validation/security gate contains unknown severity '$level'."
        }
        Assert-AuthorityExactString -Value $action -Expected ([string]$expectedSeverity[[string]$level]) -Context "Validation/security gate severity '$level'"
    }
    $aiReplacement = Get-AuthorityRequiredProperty -Object $security -Name 'aiReviewCannotReplaceHumanApproval' -Context 'Validation/security gate security policy'
    if ($aiReplacement -isnot [bool] -or -not [bool]$aiReplacement) {
        throw 'AI Review must not replace Human Approval in the validation/security gate policy.'
    }
    $semantics = Get-AuthorityRequiredProperty -Object $security -Name 'samePassBlockSemantics' -Context 'Validation/security gate security policy'
    if ($semantics -isnot [array] -or @($semantics).Count -ne 3) {
        throw 'Validation/security gate must bind local, pre-push, and CI pass/block semantics.'
    }
    $expectedSemantics = @('local', 'pre-push', 'ci')
    for ($index = 0; $index -lt $expectedSemantics.Count; $index++) {
        Assert-AuthorityExactString -Value $semantics[$index] -Expected $expectedSemantics[$index] -Context "Validation/security gate pass/block semantics $($index + 1)"
    }

    $childEnvironment = Get-AuthorityRequiredProperty -Object $security -Name 'childProcessEnvironment' -Context 'Validation/security gate child environment policy'
    Assert-AuthorityJsonPropertySet -Object $childEnvironment -Expected @('inheritance', 'allowed', 'forbidden') -Context 'Validation/security gate child environment policy'
    Assert-AuthorityExactString -Value $childEnvironment.inheritance -Expected 'clear-before-launch' -Context 'Validation/security gate child environment inheritance'
    Assert-AuthorityExactStringSequence -Value $childEnvironment.allowed -Expected @('approved-os-runtime', 'STANDARD_VALIDATION_*') -Context 'Validation/security gate child environment allowlist'
    Assert-AuthorityExactString -Value $childEnvironment.forbidden -Expected 'arbitrary-inherited-secrets' -Context 'Validation/security gate child environment forbidden surface'

    $outputReservation = Get-AuthorityRequiredProperty -Object $security -Name 'outputReservation' -Context 'Validation/security gate output reservation policy'
    Assert-AuthorityJsonPropertySet -Object $outputReservation -Expected @('requiredBeforeChildProcess', 'ownership', 'substitutionAction') -Context 'Validation/security gate output reservation policy'
    Assert-AuthorityExactBoolean -Value $outputReservation.requiredBeforeChildProcess -Expected $true -Context 'Validation/security gate output reservation requirement'
    Assert-AuthorityExactString -Value $outputReservation.ownership -Expected 'supervisor-exclusive-handle' -Context 'Validation/security gate output reservation ownership'
    Assert-AuthorityExactString -Value $outputReservation.substitutionAction -Expected 'BLOCK' -Context 'Validation/security gate output reservation substitution action'

    $semanticTrigger = Get-AuthorityRequiredProperty -Object $security -Name 'semanticTrigger' -Context 'Validation/security gate semantic trigger policy'
    Assert-AuthorityJsonPropertySet -Object $semanticTrigger -Expected @('analyzerProperty', 'effectiveDecision', 'recorded') -Context 'Validation/security gate semantic trigger policy'
    Assert-AuthorityExactString -Value $semanticTrigger.analyzerProperty -Expected 'semanticRequired' -Context 'Validation/security gate analyzer semantic trigger property'
    Assert-AuthorityExactString -Value $semanticTrigger.effectiveDecision -Expected 'callerRequested-OR-analyzerRequired' -Context 'Validation/security gate effective semantic trigger'
    Assert-AuthorityExactBoolean -Value $semanticTrigger.recorded -Expected $true -Context 'Validation/security gate semantic trigger recording'

    $semanticEvidence = Get-AuthorityRequiredProperty -Object $security -Name 'semanticEvidence' -Context 'Validation/security gate semantic evidence policy'
    Assert-AuthorityJsonPropertySet -Object $semanticEvidence -Expected @('authentication', 'requiredFields', 'success') -Context 'Validation/security gate semantic evidence policy'
    Assert-AuthorityExactString -Value $semanticEvidence.authentication -Expected 'trusted-supervisor-signed-semantic-v1' -Context 'Validation/security gate semantic evidence authentication'
    Assert-AuthorityExactStringSequence -Value $semanticEvidence.requiredFields -Expected @(
        'provider', 'purpose', 'scope', 'consentGranted', 'analyzerIdentity', 'analyzerCompleteness', 'findings', 'findingsSha256'
    ) -Context 'Validation/security gate semantic evidence required fields'
    Assert-AuthorityExactStringSequence -Value $semanticEvidence.success -Expected @(
        'status=passed', 'decision=PASS', 'consentGranted=true', 'analyzerCompleteness=complete', 'findings=array', 'findingsSha256=verified'
    ) -Context 'Validation/security gate semantic evidence success conditions'

    $aiReview = Get-AuthorityRequiredProperty -Object $security -Name 'aiReview' -Context 'Validation/security gate AI review policy'
    Assert-AuthorityJsonPropertySet -Object $aiReview -Expected @('status', 'decision', 'candidateBinding', 'arrayFields', 'equalCounts', 'severityPolicy', 'authentication', 'digestFields', 'attestation') -Context 'Validation/security gate AI review policy'
    Assert-AuthorityExactString -Value $aiReview.status -Expected 'passed' -Context 'Validation/security gate AI review status'
    Assert-AuthorityExactString -Value $aiReview.decision -Expected 'PASS' -Context 'Validation/security gate AI review decision'
    Assert-AuthorityExactString -Value $aiReview.candidateBinding -Expected 'reviewedCandidate' -Context 'Validation/security gate AI review candidate binding'
    Assert-AuthorityExactStringSequence -Value $aiReview.arrayFields -Expected @('reviewFindings', 'findingDisposition') -Context 'Validation/security gate AI review arrays'
    Assert-AuthorityExactBoolean -Value $aiReview.equalCounts -Expected $true -Context 'Validation/security gate AI review count binding'
    Assert-AuthorityExactString -Value $aiReview.severityPolicy -Expected 'central' -Context 'Validation/security gate AI review severity policy'
    Assert-AuthorityExactString -Value $aiReview.authentication -Expected 'trusted-supervisor-signed-ai-review-v1' -Context 'Validation/security gate AI review authentication'
    Assert-AuthorityExactStringSequence -Value $aiReview.digestFields -Expected @('reviewFindingsSha256', 'findingDispositionSha256') -Context 'Validation/security gate AI review digests'
    Assert-AuthorityExactString -Value $aiReview.attestation -Expected 'trusted-supervisor-ai-review-v1' -Context 'Validation/security gate AI review attestation'

    $trustAnchors = Get-AuthorityRequiredProperty -Object $security -Name 'trustAnchors' -Context 'Validation/security gate trust-anchor policy'
    Assert-AuthorityJsonPropertySet -Object $trustAnchors -Expected @('root', 'supervisorPublicKey', 'humanApprovalPublicKey', 'pinnedHashes') -Context 'Validation/security gate trust-anchor policy'
    Assert-AuthorityExactString -Value $trustAnchors.root -Expected 'docs/standards/trust-anchors' -Context 'Validation/security gate trust-anchor root'
    Assert-AuthorityExactString -Value $trustAnchors.supervisorPublicKey -Expected 'trusted-supervisor-public-key.xml' -Context 'Validation/security gate supervisor trust anchor'
    Assert-AuthorityExactString -Value $trustAnchors.humanApprovalPublicKey -Expected 'human-approval-public-key.xml' -Context 'Validation/security gate human-approval trust anchor'
    Assert-AuthorityExactBoolean -Value $trustAnchors.pinnedHashes -Expected $true -Context 'Validation/security gate pinned trust-anchor hashes'

    Assert-AuthorityEntryPointPolicy -Contract (Get-AuthorityRequiredProperty `
        -Object $Policy `
        -Name 'entryPointContract' `
        -Context 'Validation/security gate policy')

    return ,$Policy
}

function Assert-AuthorityExactBoolean {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][bool] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [bool] -or [bool]$Value -ne $Expected) {
        throw "$Context must be '$Expected'."
    }
}

function Assert-AuthorityJsonPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $Object -is [array] -or $Object -is [string]) {
        throw "$Context must be a JSON object."
    }
    if ($Object -is [System.Collections.IDictionary]) {
        $actual = @($Object.Keys | ForEach-Object { [string]$_ })
    }
    elseif ($null -eq $Object.PSObject) {
        throw "$Context must be a JSON object."
    }
    else {
        $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-AuthorityExactStringSequence {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [array] -or @($Value).Count -ne $Expected.Count) {
        throw "$Context must contain the exact ordered sequence."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Value[$index] -isnot [string] -or [string]$Value[$index] -cne $Expected[$index]) {
            throw "$Context must contain the exact ordered sequence."
        }
    }
}

function Assert-AuthorityEntryPointPolicy {
    param([Parameter(Mandatory = $true)] $Contract)

    Assert-AuthorityJsonPropertySet -Object $Contract -Expected @(
        'canonicalExecution', 'releaseAffectingSurfaces', 'componentScripts',
        'compatibilityLane', 'triggerAdapters', 'authorityWorkflowRoles'
    ) -Context 'Validation/security gate entry-point contract'

    $canonicalExecution = Get-AuthorityRequiredProperty `
        -Object $Contract `
        -Name 'canonicalExecution' `
        -Context 'Validation/security gate entry-point contract'
    Assert-AuthorityJsonPropertySet -Object $canonicalExecution -Expected @(
        'maxPerEventCandidate', 'route', 'sameCandidateBinding', 'samePassBlockSemantics'
    ) -Context 'Entry-point canonical execution policy'
    Assert-AuthorityNonNegativeInteger `
        -Value (Get-AuthorityRequiredProperty -Object $canonicalExecution -Name 'maxPerEventCandidate' -Context 'Entry-point canonical execution policy') `
        -Context 'Entry-point canonical execution maxPerEventCandidate'
    if ([int64]$canonicalExecution.maxPerEventCandidate -ne 1) {
        throw 'Entry-point contract must allow at most one canonical execution per event/candidate.'
    }
    Assert-AuthorityExactString `
        -Value $canonicalExecution.route `
        -Expected 'canonical-validator' `
        -Context 'Entry-point canonical execution route'
    Assert-AuthorityExactBoolean `
        -Value $canonicalExecution.sameCandidateBinding `
        -Expected $true `
        -Context 'Entry-point canonical execution candidate binding'
    Assert-AuthorityExactBoolean `
        -Value $canonicalExecution.samePassBlockSemantics `
        -Expected $true `
        -Context 'Entry-point canonical execution pass/block semantics'

    $surfaces = Get-AuthorityRequiredProperty `
        -Object $Contract `
        -Name 'releaseAffectingSurfaces' `
        -Context 'Validation/security gate entry-point contract'
    Assert-AuthorityJsonPropertySet -Object $surfaces -Expected @(
        'workflowGlob', 'hookRoots', 'publicCommandFiles', 'mustRouteTo', 'alternateGateAction',
        'requiresFailurePropagation', 'forbiddenFailureSuppression'
    ) -Context 'Entry-point release-affecting surface policy'
    Assert-AuthorityExactString -Value $surfaces.workflowGlob -Expected '.github/workflows/*.{yml,yaml}' -Context 'Entry-point workflow inventory'
    Assert-AuthorityExactStringSequence -Value $surfaces.hookRoots -Expected @('.git/hooks', '.githooks') -Context 'Entry-point hook inventory'
    Assert-AuthorityExactStringSequence -Value $surfaces.publicCommandFiles -Expected @(
        'README.md', 'RELEASING.md', 'RELEASE.md', 'docs/RELEASE.md', 'docs/RELEASING.md'
    ) -Context 'Entry-point public command inventory'
    Assert-AuthorityExactString -Value $surfaces.mustRouteTo -Expected 'canonical-validator' -Context 'Entry-point release routing'
    Assert-AuthorityExactString -Value $surfaces.alternateGateAction -Expected 'BLOCK' -Context 'Entry-point alternate gate action'
    Assert-AuthorityExactBoolean -Value $surfaces.requiresFailurePropagation -Expected $true -Context 'Entry-point failure propagation'
    Assert-AuthorityExactStringSequence -Value $surfaces.forbiddenFailureSuppression -Expected @(
        '|| true', '|| :', 'continue-on-error: true', 'if: always()'
    ) -Context 'Entry-point failure suppression inventory'

    $componentScripts = Get-AuthorityRequiredProperty `
        -Object $Contract `
        -Name 'componentScripts' `
        -Context 'Validation/security gate entry-point contract'
    Assert-AuthorityJsonPropertySet -Object $componentScripts -Expected @('mayExist', 'mayBeTopLevelReleaseGate') -Context 'Entry-point component script policy'
    Assert-AuthorityExactBoolean -Value $componentScripts.mayExist -Expected $true -Context 'Entry-point component script availability'
    Assert-AuthorityExactBoolean -Value $componentScripts.mayBeTopLevelReleaseGate -Expected $false -Context 'Entry-point component script release authority'

    $compatibility = Get-AuthorityRequiredProperty `
        -Object $Contract `
        -Name 'compatibilityLane' `
        -Context 'Validation/security gate entry-point contract'
    Assert-AuthorityJsonPropertySet -Object $compatibility -Expected @(
        'allowed', 'requiresCanonicalDependency', 'requiresRestrictedPurpose',
        'mayMirrorCanonicalResult', 'mayRunIndependentPassBlockPolicy', 'mayBeCanonicalReleaseGate'
    ) -Context 'Entry-point compatibility lane policy'
    Assert-AuthorityExactBoolean -Value $compatibility.allowed -Expected $true -Context 'Entry-point compatibility lane availability'
    Assert-AuthorityExactBoolean -Value $compatibility.requiresCanonicalDependency -Expected $true -Context 'Entry-point compatibility canonical dependency'
    Assert-AuthorityExactBoolean -Value $compatibility.requiresRestrictedPurpose -Expected $true -Context 'Entry-point compatibility restricted purpose'
    Assert-AuthorityExactBoolean -Value $compatibility.mayMirrorCanonicalResult -Expected $true -Context 'Entry-point compatibility result mirroring'
    Assert-AuthorityExactBoolean -Value $compatibility.mayRunIndependentPassBlockPolicy -Expected $false -Context 'Entry-point compatibility independent policy'
    Assert-AuthorityExactBoolean -Value $compatibility.mayBeCanonicalReleaseGate -Expected $false -Context 'Entry-point compatibility release authority'

    $triggerAdapters = Get-AuthorityRequiredProperty `
        -Object $Contract `
        -Name 'triggerAdapters' `
        -Context 'Validation/security gate entry-point contract'
    Assert-AuthorityJsonPropertySet -Object $triggerAdapters -Expected @(
        'allowedEvents', 'mustShareCanonicalValidator', 'mustShareCandidateBinding', 'duplicateEventCandidateExecution',
        'candidateKey', 'overlappingFilterAction'
    ) -Context 'Entry-point trigger adapter policy'
    Assert-AuthorityExactStringSequence -Value $triggerAdapters.allowedEvents -Expected @('pull_request', 'push', 'workflow_dispatch') -Context 'Entry-point trigger adapter events'
    Assert-AuthorityExactBoolean -Value $triggerAdapters.mustShareCanonicalValidator -Expected $true -Context 'Entry-point trigger adapter validator binding'
    Assert-AuthorityExactBoolean -Value $triggerAdapters.mustShareCandidateBinding -Expected $true -Context 'Entry-point trigger adapter candidate binding'
    Assert-AuthorityExactBoolean -Value $triggerAdapters.duplicateEventCandidateExecution -Expected $false -Context 'Entry-point duplicate event execution'
    Assert-AuthorityExactString -Value $triggerAdapters.candidateKey -Expected 'event-only' -Context 'Entry-point trigger adapter candidate key'
    Assert-AuthorityExactString -Value $triggerAdapters.overlappingFilterAction -Expected 'BLOCK' -Context 'Entry-point overlapping trigger filter action'

    $roles = Get-AuthorityRequiredProperty `
        -Object $Contract `
        -Name 'authorityWorkflowRoles' `
        -Context 'Validation/security gate entry-point contract'
    if ($roles -isnot [array] -or @($roles).Count -ne 4) {
        throw 'Entry-point authority workflow role inventory must contain exactly four roles.'
    }
    $expectedRoles = @(
        @{ path = '.github/workflows/standards-conformance.yml'; role = 'canonical-authority-regression' },
        @{ path = '.github/workflows/pr8-powershell-validation.yml'; role = 'compatibility-and-linux-composition-bridge' },
        @{ path = '.github/workflows/syp86-production-lock.yml'; role = 'production-lock-contract' },
        @{ path = '.github/workflows/syp101-production-smoke.yml'; role = 'production-smoke-contract' }
    )
    for ($index = 0; $index -lt $expectedRoles.Count; $index++) {
        $role = $roles[$index]
        Assert-AuthorityJsonPropertySet -Object $role -Expected @('path', 'role', 'consumerAlternateGate') -Context "Entry-point authority workflow role $($index + 1)"
        Assert-AuthorityExactString -Value $role.path -Expected $expectedRoles[$index].path -Context "Entry-point authority workflow role $($index + 1) path"
        Assert-AuthorityExactString -Value $role.role -Expected $expectedRoles[$index].role -Context "Entry-point authority workflow role $($index + 1) name"
        Assert-AuthorityExactBoolean -Value $role.consumerAlternateGate -Expected $false -Context "Entry-point authority workflow role $($index + 1) consumer alternate gate"
    }
}

function Remove-AuthorityConsumerShellComments {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Line)

    if ($Line -match '^\s*(?:#|REM(?:\s|$)|::)') { return '' }
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $hash = [char]35
    $inSingleQuote = $false
    $inDoubleQuote = $false
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($character -eq $singleQuote -and -not $inDoubleQuote) {
            $inSingleQuote = -not $inSingleQuote
            continue
        }
        if ($character -eq $doubleQuote -and -not $inSingleQuote) {
            $inDoubleQuote = -not $inDoubleQuote
            continue
        }
        if ($character -eq $hash -and -not $inSingleQuote -and -not $inDoubleQuote -and
            ($index -eq 0 -or [char]::IsWhiteSpace($Line[$index - 1]))) {
            return $Line.Substring(0, $index)
        }
    }
    return $Line
}

function Get-AuthorityConsumerExecutableText {
    param([Parameter(Mandatory = $true)][string] $Text)

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split("`n")
    $fragments = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -notmatch '^\s*(?:-\s+)?(?:"run"|''run''|run|"uses"|''uses''|uses)\s*:\s*(?<value>.*)$') { continue }
        $keyIndent = ([regex]::Match($line, '^\s*')).Value.Length
        $value = (Remove-AuthorityConsumerShellComments -Line ([string]$Matches.value)).Trim()
        if ($value -match '^[|>][+-]?\s*$') {
            $blockLines = New-Object 'System.Collections.Generic.List[string]'
            $nestedIndex = $index + 1
            while ($nestedIndex -lt $lines.Count) {
                $nestedLine = [string]$lines[$nestedIndex]
                if ($nestedLine -match '^\s*$') {
                    [void]$blockLines.Add('')
                    $nestedIndex++
                    continue
                }
                $nestedIndent = ([regex]::Match($nestedLine, '^\s*')).Value.Length
                if ($nestedIndent -le $keyIndent) { break }
                [void]$blockLines.Add((Remove-AuthorityConsumerShellComments -Line $nestedLine))
                $nestedIndex++
            }
            [void]$fragments.Add([string]::Join("`n", $blockLines.ToArray()))
            $index = $nestedIndex - 1
            continue
        }
        [void]$fragments.Add($value)
    }
    return [string]::Join("`n", $fragments.ToArray())
}

function Get-AuthorityConsumerScriptText {
    param([Parameter(Mandatory = $true)][string] $Text)

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split("`n")
    $cleanLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        [void]$cleanLines.Add((Remove-AuthorityConsumerShellComments -Line ([string]$line)))
    }
    return [string]::Join("`n", $cleanLines.ToArray())
}

function Get-AuthorityConsumerWorkflowCandidateKey {
    param(
        [Parameter(Mandatory = $true)][string] $Event,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines
    )

    # Trigger path/branch filters are not a proof of disjoint candidates: one
    # change can match two normalized filter expressions. Use the event as the
    # conservative candidate key so overlapping adapters fail closed instead
    # of being treated as separate canonical executions.
    return $Event
}

function Get-AuthorityConsumerWorkflowEvents {
    param([Parameter(Mandatory = $true)][string] $Text)

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split("`n")
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $onFound = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -notmatch '^\s*(?:"on"|''on''|on)\s*:\s*(?<value>.*)$') { continue }
        $onFound = $true
        $inlineValue = (Remove-AuthorityConsumerShellComments -Line ([string]$Matches.value)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($inlineValue) -and $inlineValue -notmatch '^\{?\s*\}?$') {
            $recognized = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($match in [regex]::Matches($inlineValue, '(?<![A-Za-z0-9_-])(pull_request|push|workflow_dispatch)(?![A-Za-z0-9_-])')) {
                $event = [string]$match.Groups[1].Value
                if ($recognized.Add($event)) {
                    [void]$candidates.Add([pscustomobject]@{
                            Event = $event
                            CandidateKey = Get-AuthorityConsumerWorkflowCandidateKey -Event $event -Lines @($inlineValue)
                        })
                }
            }
            if ($candidates.Count -eq 0) {
                [void]$candidates.Add([pscustomobject]@{ Event = '__unsupported__'; CandidateKey = '__unsupported__' })
            }
            break
        }

        $onIndent = ([regex]::Match($line, '^\s*')).Value.Length
        $eventIndent = $null
        $currentEvent = $null
        $currentLines = New-Object 'System.Collections.Generic.List[string]'
        for ($nestedIndex = $index + 1; $nestedIndex -lt $lines.Count; $nestedIndex++) {
            $nestedLine = [string]$lines[$nestedIndex]
            if ($nestedLine -match '^\s*(?:#.*)?$') {
                if ($null -ne $currentEvent) { [void]$currentLines.Add($nestedLine) }
                continue
            }
            $nestedIndent = ([regex]::Match($nestedLine, '^\s*')).Value.Length
            if ($nestedIndent -le $onIndent) { break }
            if ($nestedLine -match '^(?<indent>\s*)(?<event>[A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(?<value>.*)$') {
                if ($null -eq $eventIndent) { $eventIndent = $nestedIndent }
                if ($nestedIndent -eq $eventIndent) {
                    if ($null -ne $currentEvent) {
                        [void]$candidates.Add([pscustomobject]@{
                                Event = $currentEvent
                                CandidateKey = Get-AuthorityConsumerWorkflowCandidateKey -Event $currentEvent -Lines $currentLines.ToArray()
                            })
                    }
                    $currentEvent = [string]$Matches.event
                    $currentLines = New-Object 'System.Collections.Generic.List[string]'
                    [void]$currentLines.Add([string]$Matches.value)
                    continue
                }
            }
            if ($null -ne $currentEvent) { [void]$currentLines.Add($nestedLine) }
        }
        if ($null -ne $currentEvent) {
            [void]$candidates.Add([pscustomobject]@{
                    Event = $currentEvent
                    CandidateKey = Get-AuthorityConsumerWorkflowCandidateKey -Event $currentEvent -Lines $currentLines.ToArray()
                })
        }
        break
    }

    if (-not $onFound -or $candidates.Count -eq 0) {
        return ,([pscustomobject]@{ Event = '__unsupported__'; CandidateKey = '__unsupported__' })
    }
    return $candidates.ToArray()
}

function Get-AuthorityConsumerCanonicalTokenPattern {
    param([Parameter(Mandatory = $true)][string] $CanonicalRelativePath)

    $pathPattern = [regex]::Escape($CanonicalRelativePath.Replace('\', '/')).Replace('/', '[/\\]')
    return '(?<![A-Za-z0-9_.-])(?:\.[/\\])?' + $pathPattern + '(?![A-Za-z0-9_.-])'
}

function Test-AuthorityConsumerCanonicalInvocation {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $CanonicalRelativePath
    )

    $pattern = Get-AuthorityConsumerCanonicalTokenPattern -CanonicalRelativePath $CanonicalRelativePath
    $count = 0
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    foreach ($line in $normalized.Split("`n")) {
        $commandSegments = [regex]::Split((Remove-AuthorityConsumerShellComments -Line ([string]$line)), '(?:;|&&|\|\|)')
        foreach ($segment in $commandSegments) {
            $command = ([string]$segment).Trim()
            if ([string]::IsNullOrWhiteSpace($command) -or
                $command -match '(?i)^(?:echo|printf|Write-Output|Write-Host|Set-Content|Add-Content|cat|type|grep|Select-String)\b' -or
                $command -match '(?i)^(?:[A-Za-z_][A-Za-z0-9_]*\s*=|set\s+[A-Za-z_][A-Za-z0-9_]*=)') {
                continue
            }
            $count += [regex]::Matches($command, $pattern).Count
        }
    }
    return $count
}

function Test-AuthorityConsumerNonCanonicalValidationCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $CanonicalRelativePath
    )

    $canonicalPattern = Get-AuthorityConsumerCanonicalTokenPattern -CanonicalRelativePath $CanonicalRelativePath
    $scriptPattern = '(?i)(?<![A-Za-z0-9_.-])(?:\.[/\\]|[A-Za-z0-9_.-]+[/\\])+[A-Za-z0-9_.-]+\.(?:ps1|psm1|py|js|sh|cmd|bat|exe)(?![A-Za-z0-9_.-])'
    $localValidationPathPattern = '(?i)(?<![A-Za-z0-9_.-])(?:\.[/\\]|[A-Za-z0-9_.-]+[/\\])+[A-Za-z0-9_.-]*(?:test|validate|check|lint|scan|gate)[A-Za-z0-9_.-]*(?![A-Za-z0-9_.-])'
    foreach ($pattern in @($scriptPattern, $localValidationPathPattern)) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            if ($match.Value -notmatch $canonicalPattern) { return $true }
        }
    }
    $toolPattern = '(?im)(?<![A-Za-z0-9_.-])(?:Invoke-Pester|pytest|dotnet\s+(?:test|tool\s+install)|(?:make|cargo|mvn|gradle)\s+(?:test|check|verify)|(?:npm|pnpm|yarn)\s+(?:(?:run\s+)?(?:install|ci|test|validate|lint|check|scan)(?:[-:][A-Za-z0-9_.-]+)?)|(?:pip|python\s+-m\s+pip)\s+install|go\s+install|skillspector|skill-validator|skill-tools)(?![A-Za-z0-9_.-])'
    return [regex]::IsMatch($Text, $toolPattern)
}

function Test-AuthorityConsumerCompatibilityMarker {
    param([Parameter(Mandatory = $true)][string] $Text)

    return ($Text -match '(?im)\bneeds\s*:\s*[^\r\n]*canonical' -and
        $Text -match '(?i)\b(?:compatibility|legacy|windows\s+powershell\s*5\.1|pester\s*3)\b')
}

function Test-AuthorityConsumerCompatibilityLane {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $ExecutableText,
        [Parameter(Mandatory = $true)][string] $CanonicalRelativePath
    )

    if (-not (Test-AuthorityConsumerCompatibilityMarker -Text $Text)) { return $false }
    if ($ExecutableText -match '(?im)actions/checkout@|\b(?:Install-Module|pip\s+install|npm\s+(?:install|ci)|go\s+install)\b') { return $false }
    if (Test-AuthorityConsumerNonCanonicalValidationCommand -Text $ExecutableText -CanonicalRelativePath $CanonicalRelativePath) { return $false }
    if ($Text -match '(?im)^\s*if\s*:\s*failure\(\)|\|\s*failure\b' -or
        $ExecutableText -match '(?im)^\s*(?:exit\s+[1-9]|exit\s+/b\s+[1-9]|throw\b|return\s+[1-9]|false\b)') { return $false }
    return $true
}

function Test-AuthorityConsumerReleaseAffectingCommand {
    param([Parameter(Mandatory = $true)][string] $Text)

    # Action delegates are executable release surfaces too. Their behavior is
    # opaque to this repository, so they must still be structurally bound to
    # the canonical validator before the release job can run.
    $releasePattern = '(?im)(?<![A-Za-z0-9_.-])(?:gh\s+release\b|git\s+(?:tag\b|push\b[^\r\n]*(?:--tags?\b|refs/tags/))|(?:npm|pnpm|yarn|cargo)\s+(?:publish\b|run\s+(?:deploy|release|publish)\b)|dotnet\s+(?:publish\b|nuget\s+push\b)|twine\s+upload\b|docker\s+push\b|helm\s+push\b|semantic-release\b|(?:make|just|task)\s+(?:deploy|release|publish)\b|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]*(?:release|publish|deploy)[A-Za-z0-9_.-]*(?:@[A-Za-z0-9_./-]+)?|[A-Za-z0-9_.-]+/(?:[A-Za-z0-9_.-]+/)*(?:ship|release|publish|deploy)(?:/[A-Za-z0-9_.-]+)?@[A-Za-z0-9][A-Za-z0-9_./-]*)(?![A-Za-z0-9_.-])'
    return [regex]::IsMatch($Text, $releasePattern) -or (Test-AuthorityConsumerOpaqueReleaseHelper -Text $Text)
}

function Test-AuthorityConsumerOpaqueReleaseHelper {
    param([Parameter(Mandatory = $true)][string] $Text)

    # A local helper can hide the actual publish command and its failure behavior. Until a
    # trusted helper manifest/inspection contract exists, classify these dispatches as unsafe.
    $opaqueHelperPattern = '(?im)(?<![A-Za-z0-9_.-])(?:(?:\.[/\\])|(?:[A-Za-z0-9_.-]+[/\\])+)(?:ship|release|publish|deploy)(?:\.(?:ps1|psm1|py|js|sh|cmd|bat|exe))?(?![A-Za-z0-9_.-])'
    return [regex]::IsMatch($Text, $opaqueHelperPattern)
}

function Test-AuthorityConsumerFailureSuppression {
    param([Parameter(Mandatory = $true)][string] $Text)

    $suppressionPatterns = @(
        '(?i)\|\|\s*(?:true|:|echo|printf|write-output|write-host|exit\s+0)\b',
        '(?im)^\s*continue-on-error\s*:\s*(?!false\b)\S+',
        '(?im)^\s*if\s*:\s*(?:\$\{\{\s*)?(?:always|failure|cancelled)\s*\(\)',
        '(?im)^\s*if\s*:\s*(?:\$\{\{\s*)?!\s*cancelled\s*\(\)'
    )
    foreach ($pattern in $suppressionPatterns) {
        if ([regex]::IsMatch($Text, $pattern)) { return $true }
    }
    return $false
}

function Get-AuthorityConsumerWorkflowJobs {
    param([Parameter(Mandatory = $true)][string] $Text)

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split("`n")
    $jobsLineIndex = -1
    $jobsIndent = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^(?<indent>\s*)jobs\s*:\s*(?:#.*)?$') {
            $jobsLineIndex = $index
            $jobsIndent = $Matches.indent.Length
            break
        }
    }
    if ($jobsLineIndex -lt 0) { return @() }

    $jobs = New-Object 'System.Collections.Generic.List[object]'
    $current = $null
    for ($index = $jobsLineIndex + 1; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        $indent = ([regex]::Match($line, '^\s*')).Value.Length
        if ($indent -le $jobsIndent) { break }
        if ($line -match '^(?<jobIndent>\s{1,})(?<jobId>[A-Za-z0-9_.-]+)\s*:\s*(?:#.*)?$' -and
            $Matches.jobIndent.Length -eq ($jobsIndent + 2)) {
            if ($null -ne $current) {
                $current.endIndex = $index - 1
                [void]$jobs.Add($current)
            }
            $current = [pscustomobject][ordered]@{
                id = [string]$Matches.jobId
                startIndex = $index
                endIndex = $null
                text = $null
            }
        }
    }
    if ($null -ne $current) {
        $current.endIndex = $lines.Count - 1
        [void]$jobs.Add($current)
    }
    foreach ($job in $jobs.ToArray()) {
        $jobLines = New-Object 'System.Collections.Generic.List[string]'
        for ($index = [int]$job.startIndex; $index -le [int]$job.endIndex; $index++) {
            [void]$jobLines.Add([string]$lines[$index])
        }
        $job.text = [string]::Join("`n", $jobLines.ToArray())
    }
    return $jobs.ToArray()
}

function Test-AuthorityConsumerJobNeedsCanonical {
    param(
        [Parameter(Mandatory = $true)][string] $JobText,
        [Parameter(Mandatory = $true)][string] $CanonicalJobId
    )

    $normalized = $JobText.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized.Split("`n")
    $jobIndent = $null
    $needsLineIndex = -1
    $needsIndent = -1
    $needsCount = 0
    $needsValueRaw = $null
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($null -eq $jobIndent) {
            $jobIndent = ([regex]::Match($line, '^[ \t]*')).Value.Length
            continue
        }
        $needsMatch = [regex]::Match($line, '^(?<indent>[ \t]*)needs\s*:\s*(?<value>.*)$')
        if (-not $needsMatch.Success -or $needsMatch.Groups['indent'].Value.Length -ne ([int]$jobIndent + 2)) { continue }
        $needsCount++
        if ($needsCount -eq 1) {
            $needsLineIndex = $index
            $needsIndent = $needsMatch.Groups['indent'].Value.Length
            $needsValueRaw = $needsMatch.Groups['value'].Value
        }
    }
    if ($needsCount -ne 1) { return $false }

    $canonicalValues = @($CanonicalJobId, "'$CanonicalJobId'", ('"' + $CanonicalJobId + '"'))
    $needsValue = (Remove-AuthorityConsumerShellComments -Line ([string]$needsValueRaw)).Trim()
    if (-not [string]::IsNullOrWhiteSpace($needsValue)) {
        if ($needsValue.StartsWith('[', [StringComparison]::Ordinal) -and $needsValue.EndsWith(']', [StringComparison]::Ordinal)) {
            foreach ($item in @($needsValue.Substring(1, $needsValue.Length - 2) -split ',')) {
                if ($canonicalValues -ccontains ([string]$item).Trim()) { return $true }
            }
        }
        return $canonicalValues -ccontains $needsValue
    }

    for ($index = $needsLineIndex + 1; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        $indent = ([regex]::Match($line, '^[ \t]*')).Value.Length
        if ($indent -le $needsIndent) { break }
        if ($indent -ne ($needsIndent + 2)) { return $false }
        $itemMatch = [regex]::Match($line, '^[ \t]*-\s*(?<value>.*)$')
        if (-not $itemMatch.Success) { return $false }
        $item = (Remove-AuthorityConsumerShellComments -Line $itemMatch.Groups['value'].Value).Trim()
        if ($canonicalValues -ccontains $item) { return $true }
    }
    return $false
}

function Assert-AuthorityConsumerReleaseFailurePropagation {
    param(
        [Parameter(Mandatory = $true)][string] $WorkflowPath,
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $CanonicalRelativePath
    )

    $executableText = Get-AuthorityConsumerExecutableText -Text $Text
    if (Test-AuthorityConsumerOpaqueReleaseHelper -Text $executableText) {
        throw "BLOCK: release-affecting workflow '$WorkflowPath' invokes an opaque local release helper; inspect the helper or fail closed."
    }
    if (-not (Test-AuthorityConsumerReleaseAffectingCommand -Text $executableText)) { return }
    if (Test-AuthorityConsumerFailureSuppression -Text $Text) {
        throw "BLOCK: release-affecting workflow '$WorkflowPath' suppresses canonical or release failure propagation."
    }

    $jobs = @(Get-AuthorityConsumerWorkflowJobs -Text $Text)
    if ($jobs.Count -eq 0) {
        throw "BLOCK: release-affecting workflow '$WorkflowPath' has no structurally inspectable jobs for canonical failure propagation."
    }
    $canonicalPattern = Get-AuthorityConsumerCanonicalTokenPattern -CanonicalRelativePath $CanonicalRelativePath
    $canonicalJobs = @()
    $releaseJobs = @()
    foreach ($job in $jobs) {
        $jobExecutableText = Get-AuthorityConsumerExecutableText -Text ([string]$job.text)
        $canonicalCount = Test-AuthorityConsumerCanonicalInvocation -Text $jobExecutableText -CanonicalRelativePath $CanonicalRelativePath
        $release = Test-AuthorityConsumerReleaseAffectingCommand -Text $jobExecutableText
        if ($canonicalCount -gt 0) { $canonicalJobs += $job }
        if ($release) { $releaseJobs += $job }
    }
    if ($canonicalJobs.Count -ne 1 -or $releaseJobs.Count -eq 0) {
        throw "BLOCK: release-affecting workflow '$WorkflowPath' must structurally bind its release job to exactly one canonical job."
    }

    $canonicalJob = $canonicalJobs[0]
    foreach ($releaseJob in $releaseJobs) {
        $releaseExecutableText = Get-AuthorityConsumerExecutableText -Text ([string]$releaseJob.text)
        if ($releaseJob.id -ceq $canonicalJob.id) {
            $canonicalMatch = [regex]::Match($releaseExecutableText, $canonicalPattern)
            $releaseMatch = [regex]::Match($releaseExecutableText, '(?im)(?<![A-Za-z0-9_.-])(?:gh\s+release\b|git\s+(?:tag\b|push\b[^\r\n]*(?:--tags?\b|refs/tags/))|(?:npm|pnpm|yarn|cargo)\s+(?:publish\b|run\s+(?:deploy|release|publish)\b)|dotnet\s+(?:publish\b|nuget\s+push\b)|twine\s+upload\b|docker\s+push\b|helm\s+push\b|semantic-release\b|(?:make|just|task)\s+(?:deploy|release|publish)\b|[A-Za-z0-9_.-]+/(?:[A-Za-z0-9_.-]+/)*(?:ship|release|publish|deploy)(?:/[A-Za-z0-9_.-]+)?@[A-Za-z0-9][A-Za-z0-9_./-]*)(?![A-Za-z0-9_.-])')
            if (-not $canonicalMatch.Success -or -not $releaseMatch.Success -or $releaseMatch.Index -lt $canonicalMatch.Index) {
                throw "BLOCK: release-affecting workflow '$WorkflowPath' must run the canonical validator before its release command in job '$($releaseJob.id)'."
            }
        }
        elseif (-not (Test-AuthorityConsumerJobNeedsCanonical -JobText ([string]$releaseJob.text) -CanonicalJobId ([string]$canonicalJob.id))) {
            throw "BLOCK: release-affecting workflow '$WorkflowPath' release job '$($releaseJob.id)' must depend on canonical job '$($canonicalJob.id)'."
        }
    }
}

function Assert-AuthorityConsumerEntryPointContract {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $CanonicalValidatorPath,
        [Parameter(Mandatory = $true)] $Policy
    )

    $contract = Get-AuthorityRequiredProperty -Object $Policy -Name 'entryPointContract' -Context 'Consumer entry-point contract'
    Assert-AuthorityEntryPointPolicy -Contract $contract

    $rootItem = Get-Item -Force -LiteralPath $RepositoryRoot -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCK: consumer entry-point contract requires a non-reparse repository root.'
    }
    $rootFull = [System.IO.Path]::GetFullPath($rootItem.FullName)
    $authorityRepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $isAuthorityRepository = Test-AuthorityPathEqual -Left $rootFull -Right $authorityRepositoryRoot
    $canonicalRelative = $CanonicalValidatorPath.Replace('\', '/')
    while ($canonicalRelative.StartsWith('./', [System.StringComparison]::Ordinal)) {
        $canonicalRelative = $canonicalRelative.Substring(2)
    }
    if ([string]::IsNullOrWhiteSpace($canonicalRelative) -or
        [System.IO.Path]::IsPathRooted($CanonicalValidatorPath) -or
        $canonicalRelative -match '(^|/)\.\.(?:/|$)' -or
        $canonicalRelative -match '(^|/)\.(?:/|$)' -or
        $canonicalRelative -match '^[A-Za-z]:' -or
        $canonicalRelative -match '//') {
        throw 'BLOCK: consumer entry-point contract has an unsafe canonical validator path.'
    }
    $canonicalFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($canonicalRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    [void](Assert-AuthorityPathWithinRoot -Path $canonicalFull -Root $rootFull -Context 'Consumer canonical validator')
    $canonicalItem = Get-Item -Force -LiteralPath $canonicalFull -ErrorAction Stop
    if ($canonicalItem.PSIsContainer -or ($canonicalItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCK: consumer entry-point contract canonical validator must be a non-reparse regular file.'
    }

    $authorityRolePaths = @($contract.authorityWorkflowRoles | ForEach-Object { ([string]$_.path).Replace('\', '/') })
    $eventOwners = @{}
    $workflowRoot = Join-Path $rootFull '.github/workflows'
    $workflowFiles = @()
    if (Test-Path -LiteralPath $workflowRoot -PathType Container) {
        $workflowRootItem = Get-Item -Force -LiteralPath $workflowRoot -ErrorAction Stop
        if (($workflowRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'BLOCK: consumer entry-point workflow inventory encountered a reparse-point directory.'
        }
        $workflowFiles = @(Get-ChildItem -Force -LiteralPath $workflowRoot -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.yml', '.yaml') } | Sort-Object FullName)
    }
    foreach ($workflowFile in $workflowFiles) {
        if (($workflowFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BLOCK: consumer entry-point workflow '$($workflowFile.FullName)' is a reparse point."
        }
        $relativePath = $workflowFile.FullName.Substring($rootFull.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar
        ).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        if ($isAuthorityRepository -and $authorityRolePaths -contains $relativePath) { continue }
        $text = [System.IO.File]::ReadAllText($workflowFile.FullName)
        $executableText = Get-AuthorityConsumerExecutableText -Text $text
        $canonicalCount = Test-AuthorityConsumerCanonicalInvocation -Text $executableText -CanonicalRelativePath $canonicalRelative
        $nonCanonical = Test-AuthorityConsumerNonCanonicalValidationCommand -Text $executableText -CanonicalRelativePath $canonicalRelative
        $compatibility = Test-AuthorityConsumerCompatibilityLane `
            -Text $text `
            -ExecutableText $executableText `
            -CanonicalRelativePath $canonicalRelative
        $compatibilityDeclared = Test-AuthorityConsumerCompatibilityMarker -Text $text
        $releaseAffecting = Test-AuthorityConsumerReleaseAffectingCommand -Text $executableText
        if ($releaseAffecting -and [bool]$contract.releaseAffectingSurfaces.requiresFailurePropagation) {
            Assert-AuthorityConsumerReleaseFailurePropagation `
                -WorkflowPath $relativePath `
                -Text $text `
                -CanonicalRelativePath $canonicalRelative
        }
        if ($compatibilityDeclared -and $canonicalCount -eq 0 -and -not $compatibility) {
            throw "BLOCK: compatibility workflow '$relativePath' must depend on the canonical result and only mirror its status."
        }
        if ($nonCanonical) {
            if ($compatibility) {
                throw "BLOCK: compatibility workflow '$relativePath' executes an independent validation command; compatibility lanes may only mirror the canonical result."
            }
            throw "BLOCK: consumer entry-point contract found an alternate or non-canonical validation command in workflow '$relativePath'."
        }
        if ($compatibility -and $releaseAffecting) {
            throw "BLOCK: compatibility workflow '$relativePath' must not publish, deploy, or otherwise act as a release gate."
        }
        if ($releaseAffecting -and $canonicalCount -ne 1) {
            throw "BLOCK: release-affecting workflow '$relativePath' must execute the canonical validator exactly once."
        }
        if ($canonicalCount -gt 1) {
            throw "BLOCK: consumer entry-point contract found duplicate canonical executions in workflow '$relativePath'."
        }
        $candidates = @(Get-AuthorityConsumerWorkflowEvents -Text $text)
        if ($canonicalCount -gt 0) {
            if (@($candidates | Where-Object { [string]$_.Event -ceq '__unsupported__' }).Count -gt 0) {
                throw "BLOCK: consumer entry-point contract found an unsupported or unbound trigger in workflow '$relativePath'."
            }
            foreach ($candidate in $candidates) {
                $event = [string]$candidate.Event
                if ($event -notin @('pull_request', 'push', 'workflow_dispatch')) {
                    throw "BLOCK: consumer entry-point contract found unsupported trigger '$event' in workflow '$relativePath'."
                }
                $candidateKey = [string]$candidate.CandidateKey
                if ($eventOwners.ContainsKey($candidateKey)) {
                    throw "BLOCK: consumer entry-point contract found duplicate canonical execution for event/candidate '$candidateKey' in '$relativePath' and '$($eventOwners[$candidateKey])'."
                }
                $eventOwners[$candidateKey] = $relativePath
            }
        }
    }

    foreach ($hookRootRelative in @($contract.releaseAffectingSurfaces.hookRoots)) {
        $hookRoot = Join-Path $rootFull ([string]$hookRootRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $hookRoot -PathType Container)) { continue }
        $hookRootItem = Get-Item -Force -LiteralPath $hookRoot -ErrorAction Stop
        if (($hookRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BLOCK: consumer entry-point hook inventory root '$hookRootRelative' is a reparse point."
        }
        $hookFiles = @(Get-ChildItem -Force -LiteralPath $hookRoot -File -Recurse -ErrorAction Stop |
            Where-Object {
                -not ([string]$hookRootRelative -ceq '.git/hooks' -and
                    $_.Name.EndsWith('.sample', [System.StringComparison]::OrdinalIgnoreCase))
            })
        foreach ($hookFile in $hookFiles) {
            if (($hookFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "BLOCK: consumer entry-point hook '$($hookFile.FullName)' is a reparse point."
            }
            $hookText = [System.IO.File]::ReadAllText($hookFile.FullName)
            $hookExecutableText = Get-AuthorityConsumerScriptText -Text $hookText
            $hookCanonicalCount = Test-AuthorityConsumerCanonicalInvocation -Text $hookExecutableText -CanonicalRelativePath $canonicalRelative
            $hookReleaseAffecting = Test-AuthorityConsumerReleaseAffectingCommand -Text $hookExecutableText
            if (Test-AuthorityConsumerOpaqueReleaseHelper -Text $hookExecutableText) {
                throw "BLOCK: release-affecting hook '$($hookFile.FullName)' invokes an opaque local release helper; inspect the helper or fail closed."
            }
            if ($hookReleaseAffecting -and [bool]$contract.releaseAffectingSurfaces.requiresFailurePropagation -and
                (Test-AuthorityConsumerFailureSuppression -Text $hookText)) {
                throw "BLOCK: release-affecting hook '$($hookFile.FullName)' suppresses canonical or release failure propagation."
            }
            if ($hookReleaseAffecting -and $hookCanonicalCount -ne 1) {
                throw "BLOCK: consumer entry-point contract found a release-affecting hook that does not execute the canonical validator exactly once: '$hookFile'."
            }
            if ((Test-AuthorityConsumerNonCanonicalValidationCommand -Text $hookExecutableText -CanonicalRelativePath $canonicalRelative) -or
                $hookCanonicalCount -eq 0 -and $hookExecutableText -match '(?im)\b(?:validate|validation|test|pester|pytest|lint|scan|gate)\b') {
                throw "BLOCK: consumer entry-point contract found a hook that bypasses the canonical validator: '$hookFile'."
            }
            if ($hookCanonicalCount -gt 1) {
                throw "BLOCK: consumer entry-point contract found duplicate canonical executions in hook '$hookFile'."
            }
        }
    }

    foreach ($publicRelativePath in @($contract.releaseAffectingSurfaces.publicCommandFiles)) {
        $publicPath = Join-Path $rootFull ([string]$publicRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $publicPath -PathType Leaf)) { continue }
        $publicItem = Get-Item -Force -LiteralPath $publicPath -ErrorAction Stop
        if (($publicItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BLOCK: consumer entry-point public command '$publicRelativePath' is a reparse point."
        }
        $publicText = [System.IO.File]::ReadAllText($publicPath)
        $nonCanonicalPublicCommand = Test-AuthorityConsumerNonCanonicalValidationCommand -Text $publicText -CanonicalRelativePath $canonicalRelative
        $publicCanonicalCount = Test-AuthorityConsumerCanonicalInvocation -Text $publicText -CanonicalRelativePath $canonicalRelative
        $publicReleaseAffecting = Test-AuthorityConsumerReleaseAffectingCommand -Text $publicText
        if ($publicReleaseAffecting -and [bool]$contract.releaseAffectingSurfaces.requiresFailurePropagation -and
            (Test-AuthorityConsumerFailureSuppression -Text $publicText)) {
            throw "BLOCK: release-affecting public command '$publicRelativePath' suppresses canonical or release failure propagation."
        }
        $isReleaseInstructions = $publicRelativePath -match '(?i)(?:^|/)RELEAS(?:E|ING)\.md$'
        if ($publicReleaseAffecting -and $publicCanonicalCount -ne 1) {
            throw "BLOCK: consumer entry-point contract found a public release command without exactly one canonical validator invocation: '$publicRelativePath'."
        }
        if ($nonCanonicalPublicCommand -and ($isReleaseInstructions -or
            $publicText -match '(?is)(?:release|publish|pre-push|merge|release\s+gate|validation\s+gate).{0,240}(?:scripts[/\\]|Invoke-Pester|pytest|npm\s+(?:install|ci|test)|pip\s+install|go\s+install)|(?:scripts[/\\]|Invoke-Pester|pytest|npm\s+(?:install|ci|test)|pip\s+install|go\s+install).{0,240}(?:release|publish|pre-push|merge|release\s+gate|validation\s+gate)')) {
            throw "BLOCK: consumer entry-point contract found a public command that declares an alternate release gate: '$publicRelativePath'."
        }
    }

    return $true
}

function Invoke-AuthorityExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $DiagnosticRoot
    )

    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) {
        throw "$Context executable is missing: $Command"
    }
    $stderrPath = Join-Path $DiagnosticRoot ("stderr-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        $stdout = & $Command @Arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stdoutText = @($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Get-Content -Raw -Encoding UTF8 -LiteralPath $stderrPath
        }
        else { '' }
        if ($exitCode -ne 0) {
            throw "$Context exited with code $exitCode.`nSTDOUT:`n$stdoutText`nSTDERR:`n$stderrText"
        }
        return $stdoutText
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AuthorityLauncherDigest {
    param([Parameter(Mandatory = $true)] $Launcher)

    $lines = @('launcherType=validation-launcher-v1')
    foreach ($name in @('kind', 'shimPath', 'shimSha256', 'payloadPath', 'payloadSha256', 'runtimePath', 'runtimeSha256')) {
        $propertyValue = Get-AuthorityProperty -Object $Launcher -Name $name
        $value = if ($null -eq $propertyValue) { 'null' } else { [string]$propertyValue }
        $lines += "$name=$value"
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
            $sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes(($lines -join "`n") + "`n"))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-AuthorityLauncherReceipt {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $ToolName,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $launcher = Get-AuthorityRequiredProperty -Object $Receipt -Name 'launcher' -Context $Context
    $expectedNames = @('kind', 'shimPath', 'shimSha256', 'payloadPath', 'payloadSha256', 'runtimePath', 'runtimeSha256')
    Assert-AuthorityJsonPropertySet -Object $launcher -Expected $expectedNames -Context "$Context launcher"
    $kind = Get-AuthorityRequiredProperty -Object $launcher -Name 'kind' -Context "$Context launcher"
    if ($kind -isnot [string] -or [string]$kind -notin @('direct-executable', 'windows-cmd-shim', 'unix-node-shim')) {
        throw "$Context launcher kind is not approved."
    }
    if ($kind -ceq 'direct-executable') {
        foreach ($name in @('shimPath', 'shimSha256', 'payloadPath', 'payloadSha256', 'runtimePath', 'runtimeSha256')) {
            if ($null -ne (Get-AuthorityProperty -Object $launcher -Name $name)) {
                throw "$Context direct executable launcher must not declare shim, payload, or runtime files."
            }
        }
        return
    }
    if ($ToolName -cne 'skill-tools') { throw "$Context package shim is only approved for skill-tools." }
    $windowsShim = $kind -ceq 'windows-cmd-shim'
    if ($windowsShim -ne ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)) {
        throw "$Context launcher kind does not match the execution platform."
    }
    $shimPath = Assert-AuthorityFileIdentity `
        -PathValue (Get-AuthorityRequiredProperty -Object $launcher -Name 'shimPath' -Context "$Context launcher") `
        -Sha256Value (Get-AuthorityRequiredProperty -Object $launcher -Name 'shimSha256' -Context "$Context launcher") `
        -Context "$Context launcher shim"
    $payloadPath = Assert-AuthorityFileIdentity `
        -PathValue (Get-AuthorityRequiredProperty -Object $launcher -Name 'payloadPath' -Context "$Context launcher") `
        -Sha256Value (Get-AuthorityRequiredProperty -Object $launcher -Name 'payloadSha256' -Context "$Context launcher") `
        -Context "$Context launcher payload"
    $runtimePath = Assert-AuthorityFileIdentity `
        -PathValue (Get-AuthorityRequiredProperty -Object $launcher -Name 'runtimePath' -Context "$Context launcher") `
        -Sha256Value (Get-AuthorityRequiredProperty -Object $launcher -Name 'runtimeSha256' -Context "$Context launcher") `
        -Context "$Context launcher runtime"
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($shimPath, [IO.Path]::GetFullPath($ExecutablePath), $comparison)) {
        throw "$Context launcher shim does not match the executable path."
    }
    Assert-AuthorityPathWithinRoot -Path $shimPath -Root $InstallRoot -Context "$Context launcher shim"
    Assert-AuthorityPathWithinRoot -Path $payloadPath -Root $InstallRoot -Context "$Context launcher payload"
    if ([IO.Path]::GetFileName($runtimePath).ToLowerInvariant() -notin @('node', 'node.exe', 'nodejs', 'nodejs.exe')) {
        throw "$Context launcher runtime is not the approved Node runtime."
    }
}

function Assert-InstalledAuthorityToolReceipt {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $ToolName,
        [Parameter(Mandatory = $true)][string] $ExpectedSource,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [string] $ExpectedRunId
    )

    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId)) {
        Assert-AuthorityRunReceiptContext -Receipt $Receipt -ExpectedRunId $ExpectedRunId -Context "$ToolName receipt" | Out-Null
    }

    $schemaVersion = Get-AuthorityRequiredProperty -Object $Receipt -Name 'schemaVersion' -Context "$ToolName receipt"
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1) {
        throw "$ToolName receipt has an unsupported schemaVersion."
    }
    if ((Get-AuthorityProperty -Object $Receipt -Name 'toolName') -isnot [string] -or
        [string](Get-AuthorityProperty -Object $Receipt -Name 'toolName') -cne $ToolName) {
        throw "$ToolName receipt has the wrong tool identity."
    }
    if ((Get-AuthorityProperty -Object $Receipt -Name 'source') -isnot [string] -or
        [string](Get-AuthorityProperty -Object $Receipt -Name 'source') -cne $ExpectedSource) {
        throw "$ToolName receipt has an unapproved source."
    }
    Assert-AuthorityExactString -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'channel' -Context "$ToolName receipt") -Expected 'latest-stable' -Context "$ToolName receipt channel"
    if ((Get-AuthorityProperty -Object $Receipt -Name 'frozenForRun') -isnot [bool] -or
        -not [bool](Get-AuthorityProperty -Object $Receipt -Name 'frozenForRun')) {
        throw "$ToolName receipt is not frozen at latest-stable for this run."
    }
    foreach ($name in @('resolvedVersion', 'resolvedIdentity', 'identityKind')) {
        $value = Get-AuthorityProperty -Object $Receipt -Name $name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
            throw "$ToolName receipt is missing $name."
        }
    }

    $toolInstallRoot = Get-AuthorityProperty -Object $Receipt -Name 'installRoot'
    if ($toolInstallRoot -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$toolInstallRoot) -or
        -not (Test-Path -LiteralPath ([string]$toolInstallRoot) -PathType Container)) {
        throw "$ToolName receipt is missing its persistent install root."
    }
    Assert-AuthorityPathWithinRoot -Path ([string]$toolInstallRoot) -Root $InstallRoot -Context "$ToolName install root"

    $executablePath = Assert-AuthorityFileIdentity `
        -PathValue (Get-AuthorityProperty -Object $Receipt -Name 'executablePath') `
        -Sha256Value (Get-AuthorityProperty -Object $Receipt -Name 'executableSha256') `
        -Context "$ToolName executable"
    Assert-AuthorityPathWithinRoot -Path $executablePath -Root ([string]$toolInstallRoot) -Context "$ToolName executable"

    Assert-AuthoritySha256 `
        -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'installedClosureSha256' -Context "$ToolName receipt") `
        -Context "$ToolName installed closure"
    $actualInstalledClosure = Get-AuthorityDirectoryClosureSha256 -Path ([string]$toolInstallRoot)
    if ($actualInstalledClosure -cne [string]$Receipt.installedClosureSha256) {
        throw "$ToolName installed closure changed after resolution."
    }
    Assert-AuthorityLauncherReceipt `
        -Receipt $Receipt `
        -ToolName $ToolName `
        -InstallRoot ([string]$toolInstallRoot) `
        -ExecutablePath $executablePath `
        -Context "$ToolName receipt"
    Assert-AuthoritySha256 -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'launcherDigestSha256' -Context "$ToolName receipt") -Context "$ToolName launcher digest"
    if ([string]$Receipt.launcherDigestSha256 -cne (Get-AuthorityLauncherDigest -Launcher $Receipt.launcher)) {
        throw "$ToolName launcher metadata changed after resolution."
    }

    Assert-AuthoritySha256 `
        -Value (Get-AuthorityProperty -Object $Receipt -Name 'dependencyClosureSha256') `
        -Context "$ToolName dependency closure"
    $closure = Get-AuthorityProperty -Object $Receipt -Name 'dependencyClosure'
    if ($closure -isnot [array] -or @($closure).Count -le 0) {
        throw "$ToolName receipt does not contain a dependency/install closure."
    }

    return $executablePath
}

function Assert-AuthoritySkillValidatorRuntimeReceipt {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $GoCommandPath,
        [Parameter(Mandatory = $true)][string] $ExpectedGoRuntimeVersion,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $receiptGoPath = Get-AuthorityRequiredProperty -Object $Receipt -Name 'goRuntimePath' -Context $Context
    $receiptGoSha256 = Get-AuthorityRequiredProperty -Object $Receipt -Name 'goRuntimeSha256' -Context $Context
    $validatedGoPath = Assert-AuthorityFileIdentity `
        -PathValue $receiptGoPath `
        -Sha256Value $receiptGoSha256 `
        -Context "$Context Go runtime"
    $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($validatedGoPath),
        [IO.Path]::GetFullPath($GoCommandPath),
        $pathComparison
    )) {
        throw "$Context Go runtime path does not match the setup-resolved executable."
    }

    $versionOutput = Get-AuthorityRequiredProperty -Object $Receipt -Name 'goRuntimeVersionOutput' -Context $Context
    if ($versionOutput -isnot [array] -or @($versionOutput).Count -ne 1) {
        throw "$Context Go runtime version output must contain exactly one line."
    }
    $versionMatch = [regex]::Match(
        [string]@($versionOutput)[0],
        '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+) (?<os>[^\s]+)/(?<architecture>[^\s]+)$'
    )
    if (-not $versionMatch.Success -or
        [string]$versionMatch.Groups['version'].Value -cne $ExpectedGoRuntimeVersion) {
        throw "$Context Go runtime version output is not the expected stable runtime."
    }
    $receiptVersion = Get-AuthorityRequiredProperty -Object $Receipt -Name 'goRuntimeVersion' -Context $Context
    $receiptOs = Get-AuthorityRequiredProperty -Object $Receipt -Name 'goRuntimeOs' -Context $Context
    $receiptArchitecture = Get-AuthorityRequiredProperty -Object $Receipt -Name 'goRuntimeArchitecture' -Context $Context
    if ($receiptVersion -isnot [string] -or [string]$receiptVersion -cne $ExpectedGoRuntimeVersion -or
        $receiptOs -isnot [string] -or [string]$receiptOs -cne [string]$versionMatch.Groups['os'].Value -or
        $receiptArchitecture -isnot [string] -or [string]$receiptArchitecture -cne [string]$versionMatch.Groups['architecture'].Value) {
        throw "$Context Go runtime identity does not match its exact version output."
    }
    return $validatedGoPath
}

function Assert-AuthorityPolicyReceipt {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [string] $ExpectedRunId
    )

    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId)) {
        Assert-AuthorityRunReceiptContext -Receipt $Receipt -ExpectedRunId $ExpectedRunId -Context 'Validation policy receipt' | Out-Null
    }

    $schemaVersion = Get-AuthorityRequiredProperty -Object $Receipt -Name 'schemaVersion' -Context 'Validation policy receipt'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1) {
        throw 'Canonical validation policy receipt has an unsupported schemaVersion.'
    }
    Assert-AuthorityExactString `
        -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'policy' -Context 'Validation policy receipt') `
        -Expected 'latest-stable-per-validation-run' `
        -Context 'Validation policy receipt policy'
    $sourceTrust = Get-AuthorityRequiredProperty -Object $Receipt -Name 'sourceTrust' -Context 'Validation policy receipt'
    Assert-AuthorityExactString `
        -Value (Get-AuthorityRequiredProperty -Object $sourceTrust -Name 'enforcement' -Context 'Validation policy sourceTrust') `
        -Expected 'exact-approved-source' `
        -Context 'Validation policy sourceTrust enforcement'
    Assert-AuthorityExactString `
        -Value (Get-AuthorityRequiredProperty -Object $Receipt -Name 'trustedGoRuntimeVersion' -Context 'Validation policy receipt') `
        -Expected 'latest-stable' `
        -Context 'Validation policy receipt Go runtime rule'
    $failClosed = Get-AuthorityRequiredProperty -Object $sourceTrust -Name 'failClosedOnMismatch' -Context 'Validation policy sourceTrust'
    $recordIdentity = Get-AuthorityRequiredProperty -Object $Receipt -Name 'recordResolvedIdentityWhenAvailable' -Context 'Validation policy receipt'
    if ($failClosed -isnot [bool] -or -not [bool]$failClosed -or
        $recordIdentity -isnot [bool] -or -not [bool]$recordIdentity) {
        throw 'Canonical validation policy receipt is incomplete or untrusted.'
    }
}

function Assert-AuthorityPesterResult {
    param(
        [Parameter(Mandatory = $true)] $Result,
        [int] $MinimumTotalCount = 35,
        [int] $PesterMajorVersion = 6
    )

    if ($null -eq $Result) { throw 'Pester did not return a result object.' }
    $total = Get-AuthorityRequiredProperty -Object $Result -Name 'TotalCount' -Context 'Pester result'
    $passed = Get-AuthorityRequiredProperty -Object $Result -Name 'PassedCount' -Context 'Pester result'
    $failed = Get-AuthorityRequiredProperty -Object $Result -Name 'FailedCount' -Context 'Pester result'
    foreach ($entry in @(
        @{ Name='TotalCount'; Value=$total },
        @{ Name='PassedCount'; Value=$passed },
        @{ Name='FailedCount'; Value=$failed }
    )) {
        Assert-AuthorityNonNegativeInteger -Value $entry.Value -Context "Pester $($entry.Name)"
    }
    if ([int64]$total -lt $MinimumTotalCount) {
        throw "Pester discovered only $total authority tests; expected at least $MinimumTotalCount."
    }
    if ([int64]$failed -ne 0 -or [int64]$passed -ne [int64]$total) {
        throw "Pester authority tests did not all pass. Total=$total Passed=$passed Failed=$failed."
    }
    if ($PesterMajorVersion -ge 5) {
        Assert-AuthorityExactString `
            -Value (Get-AuthorityRequiredProperty -Object $Result -Name 'Result' -Context 'Pester result') `
            -Expected 'Passed' `
            -Context 'Pester result status'
    }

    $requiredZeroCounts = if ($PesterMajorVersion -ge 5) {
        @('FailedBlocksCount', 'FailedContainersCount', 'SkippedCount', 'NotRunCount', 'InconclusiveCount')
    }
    else {
        @('SkippedCount', 'PendingCount', 'InconclusiveCount')
    }
    foreach ($name in $requiredZeroCounts) {
        $value = Get-AuthorityRequiredProperty -Object $Result -Name $name -Context 'Pester result'
        Assert-AuthorityNonNegativeInteger -Value $value -Context "Pester $name"
        if ([int64]$value -ne 0) {
            throw "Pester reported $name=$value."
        }
    }

    foreach ($name in @('FailedBlocksCount', 'FailedContainersCount', 'SkippedCount', 'NotRunCount', 'PendingCount', 'InconclusiveCount')) {
        if ($name -in $requiredZeroCounts) { continue }
        $property = $Result.PSObject.Properties[$name]
        if ($null -eq $property) { continue }
        Assert-AuthorityNonNegativeInteger -Value $property.Value -Context "Pester $name"
        if ([int64]$property.Value -ne 0) { throw "Pester reported $name=$($property.Value)." }
    }
    $errorsProperty = $Result.PSObject.Properties['Errors']
    if ($null -ne $errorsProperty) {
        $errors = $errorsProperty.Value
        if ($errors -isnot [array]) { throw 'Pester Errors must be an array when present.' }
        if (@($errors).Count -ne 0) { throw "Pester reported $(@($errors).Count) discovery/container errors." }
    }
}

function Test-AuthorityPathEqual {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right
    )

    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else { [System.StringComparison]::Ordinal }
    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left),
        [System.IO.Path]::GetFullPath($Right),
        $comparison
    )
}

function Assert-AuthorityExactPathInventory {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $observed = @($Value)
    if ($Value -isnot [array] -or $observed.Count -ne $Expected.Count) {
        throw "$Context does not match the exact expected inventory."
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in $observed) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or -not $seen.Add([string]$path)) {
            throw "$Context contains a duplicate or malformed path."
        }
    }
    foreach ($path in $Expected) {
        if (-not $seen.Contains([string]$path)) { throw "$Context is missing '$path'." }
    }
    return $true
}

function Assert-AuthorityExactComponentInventory {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $observed = @($Value)
    $expectedEntries = @($Expected)
    if ($Value -isnot [array] -or $observed.Count -ne $expectedEntries.Count) {
        throw "$Context does not match the exact expected component inventory."
    }
    $observedByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($component in $observed) {
        if ($null -eq $component -or $null -eq $component.PSObject -or
            $component.path -isnot [string] -or $component.sha256 -isnot [string] -or
            $observedByPath.ContainsKey([string]$component.path)) {
            throw "$Context contains a duplicate or malformed component entry."
        }
        $observedByPath.Add([string]$component.path, [string]$component.sha256)
        Assert-AuthoritySha256 -Value $component.sha256 -Context "$Context '$($component.path)'"
    }
    foreach ($expectedComponent in $expectedEntries) {
        $expectedPath = [string]$expectedComponent.path
        $expectedHash = [string]$expectedComponent.sha256
        if (-not $observedByPath.ContainsKey($expectedPath) -or
            [string]$observedByPath[$expectedPath] -cne $expectedHash) {
            throw "$Context does not contain expected identity for '$expectedPath'."
        }
    }
    return $true
}

function Assert-AuthorityComponentInventoryFiles {
    param(
        [Parameter(Mandatory = $true)] $Inventory,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    foreach ($component in @($Inventory)) {
        $relative = [string](Get-AuthorityRequiredProperty -Object $component -Name 'path' -Context $Context)
        $expectedHash = [string](Get-AuthorityRequiredProperty -Object $component -Name 'sha256' -Context "$Context '$relative'")
        $fullPath = Join-Path $Root ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        [void](Assert-AuthorityPathWithinRoot -Path $fullPath -Root $Root -Context "$Context '$relative'")
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "$Context component '$relative' is missing."
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
        if ([string]$actualHash -cne $expectedHash) {
            throw "$Context component '$relative' changed after adapter validation."
        }
    }
    return $true
}

function Resolve-AuthorityReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Context must be a non-empty path string."
    }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) {
            throw "$Context must be a local fixture path."
        }
        $candidate = $uri.LocalPath
    }
    elseif (-not [System.IO.Path]::IsPathRooted($candidate) -and $candidate -cmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        throw "$Context must be a local fixture path."
    }
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $FixtureRoot $candidate
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    Assert-AuthorityPathWithinRoot -Path $fullPath -Root $FixtureRoot -Context $Context
    foreach ($relativePath in $ExpectedInventoryPaths) {
        if (Test-AuthorityPathEqual -Left $fullPath -Right (Join-Path $FixtureRoot $relativePath)) {
            return $fullPath
        }
    }
    throw "$Context does not identify a file in the controlled fixture inventory: $fullPath"
}

function Get-AuthorityReportedInventoryPath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = Resolve-AuthorityReportedFilePath `
        -Value $Value `
        -FixtureRoot $FixtureRoot `
        -ExpectedInventoryPaths $ExpectedInventoryPaths `
        -Context $Context
    foreach ($relativePath in $ExpectedInventoryPaths) {
        if (Test-AuthorityPathEqual -Left $fullPath -Right (Join-Path $FixtureRoot $relativePath)) {
            return [string]$relativePath
        }
    }
    throw "$Context does not identify a file in the controlled fixture inventory."
}

function Assert-AuthoritySkillValidatorTokenCounts {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string[]] $ExpectedTokenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ExpectedOtherTokenPaths
    )

    # Upstream excludes scripts from token accounting while still checking
    # their structure and reachability. The controlled caller supplies the
    # known token-eligible paths for each native table; input hashes separately
    # bind every file, including resources omitted from token accounting.
    [void](Get-AuthorityRequiredProperty -Object $Report -Name 'token_counts' -Context 'skill-validator token accounting')
    $expectedByTable = @{ token_counts=$ExpectedTokenPaths; other_token_counts=$ExpectedOtherTokenPaths }
    $expectedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in @($ExpectedTokenPaths) + @($ExpectedOtherTokenPaths)) {
        if ($ExpectedInventoryPaths -cnotcontains $path -or -not $expectedPaths.Add($path)) {
            throw 'skill-validator token-accounted inventory must contain distinct controlled input paths.'
        }
    }
    if ($ExpectedTokenPaths -cnotcontains 'SKILL.md') {
        throw 'skill-validator token-accounted inventory must include the SKILL.md body.'
    }
    $tokenPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($envelopeName in @('token_counts', 'other_token_counts')) {
        $expectedTablePaths = @($expectedByTable[$envelopeName])
        $envelopeProperty = $Report.PSObject.Properties[$envelopeName]
        if ($null -eq $envelopeProperty) {
            if ($expectedTablePaths.Count -gt 0) {
                throw "skill-validator $envelopeName token-accounted inventory is missing."
            }
            continue
        }
        $envelope = $envelopeProperty.Value
        if ($envelope -isnot [pscustomobject]) {
            throw "skill-validator $envelopeName token accounting must be an object."
        }
        $files = Get-AuthorityRequiredProperty -Object $envelope -Name 'files' -Context "skill-validator $envelopeName token accounting"
        $total = Get-AuthorityRequiredProperty -Object $envelope -Name 'total' -Context "skill-validator $envelopeName token accounting"
        if ($files -isnot [array] -and $files -isnot [pscustomobject]) {
            throw "skill-validator $envelopeName token accounting files must be a non-empty array."
        }
        $fileEntries = @($files)
        if ($fileEntries.Count -le 0) {
            throw "skill-validator $envelopeName token accounting files must be a non-empty array."
        }
        Assert-AuthorityNonNegativeInteger -Value $total -Context "skill-validator $envelopeName token total"
        [int64]$sum = 0
        $tablePaths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($entry in $fileEntries) {
            if ($entry -isnot [pscustomobject]) {
                throw "skill-validator $envelopeName token entries must be structured objects."
            }
            $file = Get-AuthorityRequiredProperty -Object $entry -Name 'file' -Context "skill-validator $envelopeName token entry"
            $tokens = Get-AuthorityRequiredProperty -Object $entry -Name 'tokens' -Context "skill-validator $envelopeName token entry"
            Assert-AuthorityNonNegativeInteger -Value $tokens -Context "skill-validator $envelopeName token count"
            [int64]$sum += [int64]$tokens
            if ($file -isnot [string] -or [string]::IsNullOrWhiteSpace($file)) {
                throw "skill-validator $envelopeName token entry file must be a non-empty string."
            }
            if ([string]$file -ceq 'SKILL.md body') {
                $reportedPath = 'SKILL.md'
            }
            else {
                $reportedPath = Get-AuthorityReportedInventoryPath `
                    -Value $file `
                    -FixtureRoot $FixtureRoot `
                    -ExpectedInventoryPaths $ExpectedInventoryPaths `
                    -Context "skill-validator $envelopeName token entry file"
            }
            if (-not $tokenPaths.Contains($reportedPath)) {
                [void]$tokenPaths.Add($reportedPath)
                [void]$tablePaths.Add($reportedPath)
            }
            else {
                throw "skill-validator token accounting contains duplicate file '$reportedPath'."
            }
        }
        if ($sum -ne [int64]$total) {
            throw "skill-validator $envelopeName token total does not equal the sum of its file token counts."
        }
        if ($expectedTablePaths.Count -eq 0) {
            throw "skill-validator $envelopeName token-accounted inventory contains unexpected files."
        }
        Assert-AuthorityExactPathInventory -Value @($tablePaths.ToArray()) -Expected $expectedTablePaths `
            -Context "skill-validator $envelopeName token-accounted inventory" | Out-Null
    }
}

function Assert-AuthorityToolInputInventory {
    param(
        [Parameter(Mandatory = $true)] $Envelope,
        [Parameter(Mandatory = $true)][ValidateSet('skill-validator', 'skill-tools')][string] $ExpectedToolName,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths
    )

    if ($null -eq $Envelope -or $null -eq $Envelope.PSObject) {
        throw "$ExpectedToolName coverage envelope is missing."
    }
    $propertyNames = @($Envelope.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $expectedPropertyNames = @('schemaVersion', 'toolName', 'coverageMode', 'root', 'files')
    if ($propertyNames.Count -ne $expectedPropertyNames.Count) {
        throw "$ExpectedToolName coverage envelope has an unexpected property set."
    }
    foreach ($name in $expectedPropertyNames) {
        if ($propertyNames -cnotcontains $name) {
            throw "$ExpectedToolName coverage envelope is missing '$name'."
        }
    }

    $schemaVersion = Get-AuthorityRequiredProperty -Object $Envelope -Name 'schemaVersion' -Context "$ExpectedToolName coverage envelope"
    $toolName = Get-AuthorityRequiredProperty -Object $Envelope -Name 'toolName' -Context "$ExpectedToolName coverage envelope"
    $coverageMode = Get-AuthorityRequiredProperty -Object $Envelope -Name 'coverageMode' -Context "$ExpectedToolName coverage envelope"
    $root = Get-AuthorityRequiredProperty -Object $Envelope -Name 'root' -Context "$ExpectedToolName coverage envelope"
    $files = Get-AuthorityRequiredProperty -Object $Envelope -Name 'files' -Context "$ExpectedToolName coverage envelope"
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1 -or
        $toolName -isnot [string] -or [string]$toolName -cne $ExpectedToolName -or
        $coverageMode -isnot [string] -or [string]$coverageMode -cne 'authority-input-inventory' -or
        $root -isnot [string] -or -not (Test-AuthorityPathEqual -Left $root -Right $ExpectedFixtureRoot) -or
        $files -isnot [array] -or @($files).Count -le 0) {
        throw "$ExpectedToolName coverage envelope is not bound to the expected tool and fixture root."
    }

    $inputRootItem = Get-Item -LiteralPath $ExpectedFixtureRoot -Force -ErrorAction Stop
    if (-not $inputRootItem.PSIsContainer -or ($inputRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$ExpectedToolName coverage envelope requires a regular input directory."
    }
    $inputRoot = $inputRootItem.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $directories = New-Object 'System.Collections.Generic.Queue[string]'
    $directories.Enqueue($inputRoot)
    $actualPaths = New-Object 'System.Collections.Generic.List[string]'
    while ($directories.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $directories.Dequeue() -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$ExpectedToolName coverage envelope input contains a link or reparse point."
            }
            if ($item.PSIsContainer) { $directories.Enqueue($item.FullName) }
            else {
                $relative = $item.FullName.Substring($inputRoot.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
                [void]$actualPaths.Add($relative)
            }
        }
    }
    Assert-AuthorityExactPathInventory -Value $actualPaths.ToArray() -Expected $ExpectedInventoryPaths -Context "$ExpectedToolName coverage envelope on-disk input" | Out-Null

    $observedPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @($files)) {
        if ($entry -isnot [pscustomobject]) {
            throw "$ExpectedToolName coverage envelope file entries must be structured objects."
        }
        $entryProperties = @($entry.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($entryProperties.Count -ne 2 -or $entryProperties -cnotcontains 'path' -or $entryProperties -cnotcontains 'sha256') {
            throw "$ExpectedToolName coverage envelope file has an unexpected property set."
        }
        $path = Get-AuthorityRequiredProperty -Object $entry -Name 'path' -Context "$ExpectedToolName coverage envelope file"
        $sha256 = Get-AuthorityRequiredProperty -Object $entry -Name 'sha256' -Context "$ExpectedToolName coverage envelope file"
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$path)) {
            throw "$ExpectedToolName coverage envelope file path must be a non-empty string."
        }
        Assert-AuthoritySha256 -Value $sha256 -Context "$ExpectedToolName coverage envelope file hash"
        $reportedPath = Get-AuthorityReportedInventoryPath `
            -Value $path `
            -FixtureRoot $ExpectedFixtureRoot `
            -ExpectedInventoryPaths $ExpectedInventoryPaths `
            -Context "$ExpectedToolName coverage envelope file path"
        if (-not $observedPaths.Contains($reportedPath)) {
            [void]$observedPaths.Add($reportedPath)
        }
        else {
            throw "$ExpectedToolName coverage envelope contains duplicate file '$reportedPath'."
        }
        $actualPath = Join-Path $ExpectedFixtureRoot $reportedPath
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $actualPath).Hash.ToLowerInvariant()
        if ($actualHash -cne [string]$sha256) {
            throw "$ExpectedToolName coverage envelope file '$reportedPath' changed after the tool run."
        }
    }
    Assert-AuthorityExactPathInventory `
        -Value $observedPaths.ToArray() `
        -Expected $ExpectedInventoryPaths `
        -Context "$ExpectedToolName coverage envelope" | Out-Null
    return $true
}

function Assert-AuthoritySkillToolsCoverageEnvelope {
    param(
        [Parameter(Mandatory = $true)] $Envelope,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths
    )

    Assert-AuthorityToolInputInventory `
        -Envelope $Envelope `
        -ExpectedToolName 'skill-tools' `
        -ExpectedFixtureRoot $ExpectedFixtureRoot `
        -ExpectedInventoryPaths $ExpectedInventoryPaths
}

function Assert-AuthoritySkillSpectorReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths
    )

    $executionSuccessful = Get-AuthorityProperty -Object $Report -Name 'execution_successful'
    $completeness = Get-AuthorityProperty -Object $Report -Name 'analysis_completeness'
    $completenessExecutionSuccessful = Get-AuthorityProperty -Object $completeness -Name 'execution_successful'
    $isComplete = Get-AuthorityProperty -Object $completeness -Name 'is_complete'
    $status = Get-AuthorityProperty -Object $completeness -Name 'status'
    $coveragePercent = Get-AuthorityProperty -Object $completeness -Name 'coverage_percent'
    $coverageIsNumeric = (
        $coveragePercent -is [byte] -or $coveragePercent -is [sbyte] -or
        $coveragePercent -is [int16] -or $coveragePercent -is [uint16] -or
        $coveragePercent -is [int] -or $coveragePercent -is [uint32] -or
        $coveragePercent -is [long] -or $coveragePercent -is [uint64] -or
        $coveragePercent -is [single] -or $coveragePercent -is [double] -or
        $coveragePercent -is [decimal]
    )
    if ($executionSuccessful -isnot [bool] -or -not $executionSuccessful -or
        $completenessExecutionSuccessful -isnot [bool] -or -not $completenessExecutionSuccessful -or
        $isComplete -isnot [bool] -or -not $isComplete -or
        $status -isnot [string] -or $status -cne 'complete' -or
        -not $coverageIsNumeric -or $coveragePercent -ne 100) {
        throw 'SkillSpector static scan was unsuccessful or incomplete.'
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        $items = Get-AuthorityProperty -Object $completeness -Name $name
        if ($items -isnot [array] -or @($items).Count -ne 0) {
            throw "SkillSpector analysis_completeness.$name must be an empty array."
        }
    }
    $issues = Get-AuthorityProperty -Object $Report -Name 'issues'
    $riskAssessment = Get-AuthorityProperty -Object $Report -Name 'risk_assessment'
    $recommendation = Get-AuthorityProperty -Object $riskAssessment -Name 'recommendation'
    if ($issues -isnot [array] -or @($issues).Count -ne 0 -or
        $recommendation -isnot [string] -or $recommendation -cne 'SAFE') {
        throw 'SkillSpector controlled fixture must have an empty issues[] array and a SAFE recommendation.'
    }

    $skill = Get-AuthorityProperty -Object $Report -Name 'skill'
    $skillName = Get-AuthorityProperty -Object $skill -Name 'name'
    $skillSource = Get-AuthorityProperty -Object $skill -Name 'source'
    if ($skillName -isnot [string] -or $skillName -cne $ExpectedSkillId -or
        $skillSource -isnot [string] -or [string]::IsNullOrWhiteSpace($skillSource) -or
        -not (Test-AuthorityPathEqual -Left $skillSource -Right $ExpectedFixtureRoot)) {
        throw 'SkillSpector report is not bound to the controlled fixture identity and source path.'
    }

    $components = Get-AuthorityProperty -Object $Report -Name 'components'
    if ($components -isnot [array] -or @($components).Count -ne $ExpectedInventoryPaths.Count) {
        throw 'SkillSpector components do not match the exact controlled fixture inventory.'
    }
    $observedPaths = @()
    foreach ($component in @($components)) {
        if ($component -isnot [pscustomobject]) {
            throw 'SkillSpector components do not match the exact controlled fixture inventory.'
        }
        $componentPath = Get-AuthorityProperty -Object $component -Name 'path'
        if ($componentPath -isnot [string] -or
            -not ($ExpectedInventoryPaths -ccontains [string]$componentPath) -or
            $observedPaths -ccontains [string]$componentPath) {
            throw 'SkillSpector components do not match the exact controlled fixture inventory.'
        }
        $observedPaths += [string]$componentPath
    }
    foreach ($expectedPath in $ExpectedInventoryPaths) {
        if ($observedPaths -cnotcontains $expectedPath) {
            throw 'SkillSpector components do not match the exact controlled fixture inventory.'
        }
    }
}

function Assert-AuthoritySkillValidatorReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string[]] $ExpectedTokenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ExpectedOtherTokenPaths
    )

    $skillDirectory = Get-AuthorityProperty -Object $Report -Name 'skill_dir'
    $passed = Get-AuthorityProperty -Object $Report -Name 'passed'
    $errors = Get-AuthorityProperty -Object $Report -Name 'errors'
    $warnings = Get-AuthorityProperty -Object $Report -Name 'warnings'
    $results = Get-AuthorityProperty -Object $Report -Name 'results'
    if ($skillDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($skillDirectory) -or
        -not (Test-AuthorityPathEqual -Left $skillDirectory -Right $ExpectedFixtureRoot) -or
        $passed -isnot [bool] -or -not $passed -or
        ($errors -isnot [int] -and $errors -isnot [long]) -or [int64]$errors -ne 0 -or
        ($warnings -isnot [int] -and $warnings -isnot [long]) -or [int64]$warnings -ne 0 -or
        $results -isnot [array] -or @($results).Count -le 0) {
        throw 'skill-validator did not produce a clean, non-empty package validation report.'
    }
    foreach ($result in @($results)) {
        if ($result -isnot [pscustomobject]) {
            throw 'skill-validator result entries must be structured validation objects.'
        }
        $level = Get-AuthorityProperty -Object $result -Name 'level'
        $category = Get-AuthorityProperty -Object $result -Name 'category'
        $message = Get-AuthorityProperty -Object $result -Name 'message'
        if ($level -isnot [string] -or $level -cnotin @('pass', 'info', 'warning', 'error') -or
            $level -in @('warning', 'error') -or
            $category -isnot [string] -or [string]::IsNullOrWhiteSpace($category) -or
            $message -isnot [string] -or [string]::IsNullOrWhiteSpace($message)) {
            throw 'skill-validator result entries do not describe a clean controlled fixture.'
        }
        $fileProperty = $result.PSObject.Properties['file']
        if ($null -ne $fileProperty) {
            if ($fileProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$fileProperty.Value)) {
                throw 'skill-validator result file must be a non-empty path string when present.'
            }
            [void](Get-AuthorityReportedInventoryPath `
                -Value $fileProperty.Value `
                -FixtureRoot $ExpectedFixtureRoot `
                -ExpectedInventoryPaths $ExpectedInventoryPaths `
                -Context 'skill-validator result file')
        }
        $lineProperty = $result.PSObject.Properties['line']
        if ($null -ne $lineProperty -and
            (($lineProperty.Value -isnot [int] -and $lineProperty.Value -isnot [long]) -or [int64]$lineProperty.Value -le 0)) {
            throw 'skill-validator result line must be a positive integer when present.'
        }
    }
    Assert-AuthoritySkillValidatorTokenCounts `
        -Report $Report `
        -FixtureRoot $ExpectedFixtureRoot `
        -ExpectedInventoryPaths $ExpectedInventoryPaths `
        -ExpectedTokenPaths $ExpectedTokenPaths `
        -ExpectedOtherTokenPaths $ExpectedOtherTokenPaths
}

function Assert-AuthoritySkillToolsSarifReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $ExpectedFixtureRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)] $CoverageEnvelope
    )

    Assert-AuthoritySkillToolsCoverageEnvelope `
        -Envelope $CoverageEnvelope `
        -ExpectedFixtureRoot $ExpectedFixtureRoot `
        -ExpectedInventoryPaths $ExpectedInventoryPaths | Out-Null

    $version = Get-AuthorityProperty -Object $Report -Name 'version'
    $runs = Get-AuthorityProperty -Object $Report -Name 'runs'
    if ($version -isnot [string] -or $version -cne '2.1.0' -or
        $runs -isnot [array] -or @($runs).Count -ne 1) {
        throw 'skill-tools did not produce a non-empty SARIF 2.1.0 report.'
    }
    $reportedPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($run in @($runs)) {
        $tool = Get-AuthorityProperty -Object $run -Name 'tool'
        $driver = Get-AuthorityProperty -Object $tool -Name 'driver'
        $driverName = Get-AuthorityProperty -Object $driver -Name 'name'
        $rules = Get-AuthorityProperty -Object $driver -Name 'rules'
        $results = Get-AuthorityProperty -Object $run -Name 'results'
        if ($driverName -isnot [string] -or $driverName -cne 'skill-tools' -or
            $rules -isnot [array] -or @($rules).Count -le 0 -or
            $results -isnot [array] -or @($results).Count -le 0) {
            throw 'skill-tools SARIF report is incomplete or contains an error-level result.'
        }
        $ruleById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($rule in @($rules)) {
            if ($rule -isnot [pscustomobject]) {
                throw 'skill-tools SARIF rule metadata is incomplete or malformed.'
            }
            $ruleId = Get-AuthorityProperty -Object $rule -Name 'id'
            if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or $ruleById.ContainsKey($ruleId)) {
                throw 'skill-tools SARIF rule metadata is incomplete or malformed.'
            }
            $ruleById.Add($ruleId, $rule)
        }
        foreach ($result in @($results)) {
            if ($result -isnot [pscustomobject]) {
                throw 'skill-tools SARIF report is incomplete or contains an error-level result.'
            }
            $ruleId = Get-AuthorityProperty -Object $result -Name 'ruleId'
            if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or -not $ruleById.ContainsKey($ruleId)) {
                throw 'skill-tools SARIF result references an unknown or malformed ruleId.'
            }
            $levelProperty = $result.PSObject.Properties['level']
            if ($null -ne $levelProperty) {
                $effectiveLevel = $levelProperty.Value
            }
            else {
                $defaultConfiguration = Get-AuthorityProperty -Object $ruleById[$ruleId] -Name 'defaultConfiguration'
                if ($defaultConfiguration -isnot [pscustomobject] -or
                    $null -eq $defaultConfiguration.PSObject.Properties['level']) {
                    throw 'skill-tools SARIF result without level requires an exact rule defaultConfiguration.level.'
                }
                $effectiveLevel = $defaultConfiguration.PSObject.Properties['level'].Value
            }
            if ($effectiveLevel -isnot [string] -or
                $effectiveLevel -cnotin @('none', 'note', 'warning', 'error') -or
                $effectiveLevel -ceq 'error') {
                throw 'skill-tools SARIF report is incomplete or contains an error-level result.'
            }
            $message = Get-AuthorityProperty -Object $result -Name 'message'
            $messageText = Get-AuthorityProperty -Object $message -Name 'text'
            $locations = Get-AuthorityProperty -Object $result -Name 'locations'
            if ($messageText -isnot [string] -or [string]::IsNullOrWhiteSpace($messageText) -or
                $locations -isnot [array] -or @($locations).Count -le 0) {
                throw 'skill-tools SARIF result is missing its message or controlled fixture location.'
            }
            foreach ($location in @($locations)) {
                $physicalLocation = Get-AuthorityProperty -Object $location -Name 'physicalLocation'
                $artifactLocation = Get-AuthorityProperty -Object $physicalLocation -Name 'artifactLocation'
                $uri = Get-AuthorityProperty -Object $artifactLocation -Name 'uri'
                $reportedPath = Get-AuthorityReportedInventoryPath `
                    -Value $uri `
                    -FixtureRoot $ExpectedFixtureRoot `
                    -ExpectedInventoryPaths $ExpectedInventoryPaths `
                    -Context 'skill-tools SARIF artifact location'
                if (-not $reportedPaths.Contains($reportedPath)) { [void]$reportedPaths.Add($reportedPath) }
            }
        }
    }
    if ($reportedPaths.Count -le 0) {
        throw 'skill-tools SARIF report did not contain a controlled fixture diagnostic location.'
    }
}

function Get-AuthorityComponentInventorySha256 {
    param([Parameter(Mandatory = $true)] $Inventory)

    $canonical = (@($Inventory | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join '')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-AuthorityCandidateCommit {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [AllowEmptyString()][string] $ExpectedCommit = [string]$env:GITHUB_SHA
    )

    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $gitPathValue = if ($null -ne $git.PSObject.Properties['Path']) { [string]$git.Path } else { [string]$git.Source }
    if ([string]::IsNullOrWhiteSpace($gitPathValue) -or -not [System.IO.Path]::IsPathRooted($gitPathValue)) {
        throw 'Authority gate could not resolve Git to an absolute application path.'
    }
    $gitPath = [System.IO.Path]::GetFullPath($gitPathValue)
    $candidateOutput = @(& $gitPath -C $RepositoryRoot rev-parse HEAD 2>$null)
    $gitExitCode = $LASTEXITCODE
    $candidateCommit = ([string]($candidateOutput | Select-Object -First 1)).Trim()
    if ($gitExitCode -ne 0 -or $candidateCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Authority gate could not bind its candidate commit to checkout HEAD.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit)) {
        if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw 'GITHUB_SHA must be a lowercase full commit SHA when present.'
        }
        if ($ExpectedCommit -cne $candidateCommit) {
            throw "GITHUB_SHA '$ExpectedCommit' does not match checkout HEAD '$candidateCommit'."
        }
    }
    return $candidateCommit
}

function Assert-AuthorityFixtureContract {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId
    )

    if ($ExpectedSkillId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Authority fixture Skill ID '$ExpectedSkillId' is invalid."
    }
    $skillPath = Join-Path $FixtureRoot 'SKILL.md'
    $metadataPath = Join-Path $FixtureRoot 'agents/openai.yaml'
    foreach ($path in @($skillPath, $metadataPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Authority fixture is missing required file: $path"
        }
    }

    $skillText = [IO.File]::ReadAllText($skillPath).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($skillText -notmatch '(?s)^---\n(?<frontmatter>.*?)\n---\n(?<body>.+)$') {
        throw 'Authority fixture SKILL.md must contain closed YAML frontmatter and a non-empty body.'
    }
    $frontmatter = $Matches.frontmatter
    $body = $Matches.body
    $frontmatterValues = @{}
    foreach ($line in $frontmatter.Split("`n")) {
        if ($line -notmatch '^(?<key>[a-z][a-z-]*): (?<value>\S.*)$') {
            throw "Authority fixture SKILL.md has unsupported frontmatter syntax: '$line'."
        }
        $key = [string]$Matches.key
        if ($key -cnotin @('name', 'description') -or $frontmatterValues.ContainsKey($key)) {
            throw "Authority fixture SKILL.md has unsupported or duplicate frontmatter key '$key'."
        }
        $frontmatterValues[$key] = [string]$Matches.value
    }
    if ($frontmatterValues.Count -ne 2 -or
        [string]$frontmatterValues.name -cne $ExpectedSkillId -or
        [string]::IsNullOrWhiteSpace([string]$frontmatterValues.description) -or
        [string]::IsNullOrWhiteSpace($body)) {
        throw 'Authority fixture SKILL.md metadata or body is incomplete.'
    }

    $metadataText = [IO.File]::ReadAllText($metadataPath).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
    $metadataLines = $metadataText.Split("`n")
    if ($metadataLines.Count -ne 4 -or $metadataLines[0] -cne 'interface:') {
        throw 'Authority fixture agents/openai.yaml must contain one interface mapping.'
    }
    $interface = @{}
    foreach ($line in @($metadataLines | Select-Object -Skip 1)) {
        if ($line -notmatch '^  (?<key>[a-z_]+): (?<jsonString>"(?:[^"\\]|\\.)*")$') {
            throw "Authority fixture agents/openai.yaml requires unquoted keys and double-quoted string values: '$line'."
        }
        $key = [string]$Matches.key
        if ($key -cnotin @('display_name', 'short_description', 'default_prompt') -or $interface.ContainsKey($key)) {
            throw "Authority fixture agents/openai.yaml has unsupported or duplicate interface key '$key'."
        }
        try { $interface[$key] = [string]($Matches.jsonString | ConvertFrom-Json) }
        catch { throw "Authority fixture agents/openai.yaml has an invalid quoted string for '$key'." }
    }
    if ($interface.Count -ne 3 -or [string]::IsNullOrWhiteSpace([string]$interface.display_name)) {
        throw 'Authority fixture agents/openai.yaml is missing required interface fields.'
    }
    $shortDescription = [string]$interface.short_description
    if ($shortDescription.Length -lt 25 -or $shortDescription.Length -gt 64) {
        throw 'Authority fixture interface.short_description must contain 25 to 64 characters.'
    }
    $expectedToken = '$' + $ExpectedSkillId
    if ([string]$interface.default_prompt -cnotmatch ("(?<![a-z0-9-]){0}(?![a-z0-9-])" -f [regex]::Escape($expectedToken))) {
        throw "Authority fixture interface.default_prompt must reference exact token '$expectedToken'."
    }
}

if ($DefineFunctionsOnly) { return }

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$resolverPath = Join-Path $PSScriptRoot 'Resolve-StandardValidationTool.ps1'
$pythonClosureHelperPath = Join-Path $PSScriptRoot 'Resolve-PythonWheelClosure.py'
$validationSecurityGatePath = Join-Path $repositoryRoot 'docs/standards/validation-security-gate.json'
$upstreamAdapterPolicyPath = Join-Path $repositoryRoot 'docs/standards/upstream-adapter.json'
$upstreamAdapterValidatorPath = Join-Path $PSScriptRoot 'Validate-UpstreamAdapter.ps1'
$expectedGoRuntimeVersion = [string]$ExpectedGoRuntimeVersion
if ([string]::IsNullOrWhiteSpace($expectedGoRuntimeVersion) -or
    $expectedGoRuntimeVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw 'The authority gate requires STANDARD_GO_RUNTIME_VERSION from the setup-go run-resolved latest stable runtime.'
}
$goCommandPath = [string]$GoCommandPath
if ([string]::IsNullOrWhiteSpace($goCommandPath)) {
    $goApplications = @(Get-Command -Name 'go' -CommandType Application -ErrorAction SilentlyContinue)
    if ($goApplications.Count -ne 1) {
        throw 'The authority gate requires one run-resolved Go executable path from setup-go.'
    }
    $goCommandPath = if ($null -ne $goApplications[0].PSObject.Properties['Path']) {
        [string]$goApplications[0].Path
    }
    else {
        [string]$goApplications[0].Source
    }
}
if ([string]::IsNullOrWhiteSpace($goCommandPath) -or -not [IO.Path]::IsPathRooted($goCommandPath)) {
    throw 'The authority gate requires an absolute run-resolved Go executable path.'
}
$goCommandPath = [IO.Path]::GetFullPath($goCommandPath)
$goCommandItem = Get-Item -Force -LiteralPath $goCommandPath -ErrorAction SilentlyContinue
if ($null -eq $goCommandItem -or $goCommandItem.PSIsContainer -or
    ($goCommandItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The authority gate requires a regular run-resolved Go executable: $goCommandPath"
}
$authorityTestPaths = @(
    (Join-Path $repositoryRoot 'tests/skill-repository-standard.Tests.ps1')
    (Join-Path $repositoryRoot 'tests/skill-repository-workflows.Tests.ps1')
    (Join-Path $repositoryRoot 'tests/standard-validation-resolver-hardening.Tests.ps1')
    (Join-Path $repositoryRoot 'tests/standard-validation-runner.Tests.ps1')
)
foreach ($requiredPath in @($validationSecurityGatePath, $upstreamAdapterPolicyPath, $upstreamAdapterValidatorPath, $resolverPath, $pythonClosureHelperPath) + $authorityTestPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Authority gate input is missing: $requiredPath"
    }
}

$validationSecurityGate = Assert-AuthorityValidationSecurityGate `
    -Policy (Read-AuthorityJson -Path $validationSecurityGatePath -Context 'Validation/security gate policy')
$validationSecurityGatePolicySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $validationSecurityGatePath).Hash.ToLowerInvariant()

$artifactsRootPath = [System.IO.Path]::GetFullPath($ArtifactsRoot)
[void](New-Item -ItemType Directory -Path $artifactsRootPath -Force)
$artifactsItem = Get-Item -Force -LiteralPath $artifactsRootPath
if (-not $artifactsItem.PSIsContainer -or
    ($artifactsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Authority artifacts root must be a non-reparse directory: $artifactsRootPath"
}

$runId = [guid]::NewGuid().ToString('N')
$runRoot = Join-Path $artifactsRootPath "standard-authority-$runId"
$installRoot = New-AuthorityRunOwnedToolRoot -RunId $runId
$fixtureRoot = Join-Path $runRoot 'fixture/standard-validation-fixture'
[void](New-Item -ItemType Directory -Path $fixtureRoot -Force)

$fixtureText = @'
---
name: standard-validation-fixture
description: Use when verifying that the canonical validation toolchain can inspect a harmless and deterministic Agent Skill package.
---

# Standard Validation Fixture

Use this deterministic fixture to confirm that each approved validation tool can inspect one complete Agent Skill package.

## Procedure

1. Read this file.
2. Confirm that the package metadata is valid.
3. Return a short validation status without changing files.

## Expected result

Report that the fixture is structurally valid and contains no executable content.
'@
$fixturePath = Join-Path $fixtureRoot 'SKILL.md'
[System.IO.File]::WriteAllText($fixturePath, $fixtureText.TrimStart() + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
$fixtureSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash.ToLowerInvariant()

$fixtureAgentsRoot = Join-Path $fixtureRoot 'agents'
[void](New-Item -ItemType Directory -Path $fixtureAgentsRoot -Force)
$fixtureMetadataText = @'
interface:
  display_name: "Standard Validation Fixture"
  short_description: "Validate one deterministic canonical Skill package."
  default_prompt: "Use $standard-validation-fixture to verify the canonical validation toolchain."
'@
$fixtureMetadataPath = Join-Path $fixtureAgentsRoot 'openai.yaml'
[System.IO.File]::WriteAllText($fixtureMetadataPath, $fixtureMetadataText.TrimStart() + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Assert-AuthorityFixtureContract -FixtureRoot $fixtureRoot -ExpectedSkillId 'standard-validation-fixture'
$fixtureMetadataSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureMetadataPath).Hash.ToLowerInvariant()
$fixtureFiles = @(
    [pscustomobject][ordered]@{ path = 'SKILL.md'; sha256 = $fixtureSha256 },
    [pscustomobject][ordered]@{ path = 'agents/openai.yaml'; sha256 = $fixtureMetadataSha256 }
)
$fixtureCanonicalInventory = ($fixtureFiles | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
$fixtureInventoryHasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $fixtureInventorySha256 = ([System.BitConverter]::ToString(
        $fixtureInventoryHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fixtureCanonicalInventory))
    ) -replace '-', '').ToLowerInvariant()
}
finally {
    $fixtureInventoryHasher.Dispose()
}

$policyReceiptPath = Join-Path $runRoot 'policy.json'
& $resolverPath -ValidatePolicyOnly -RunId $runId -OutputPath $policyReceiptPath | Out-Host
$policyReceipt = Read-AuthorityJson -Path $policyReceiptPath -Context 'Validation policy resolver'
Assert-AuthorityPolicyReceipt -Receipt $policyReceipt -ExpectedRunId $runId

$expectedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}
$receipts = [ordered]@{}
$executablePaths = [ordered]@{}

# Freeze the complete formal toolset before any validator executes.
foreach ($entry in $expectedSources.GetEnumerator()) {
    $receiptPath = Join-Path $runRoot ("receipt-{0}.json" -f $entry.Key)
    & $resolverPath `
        -ToolName $entry.Key `
        -Install `
        -InstallRoot $installRoot `
        -RunId $runId `
        -ExpectedGoRuntimeVersion $expectedGoRuntimeVersion `
        -GoCommandPath $goCommandPath `
        -OutputPath $receiptPath | Out-Host
    $receipt = Read-AuthorityJson -Path $receiptPath -Context "$($entry.Key) resolver"
    $executablePaths[$entry.Key] = Assert-InstalledAuthorityToolReceipt `
        -Receipt $receipt -ToolName $entry.Key -ExpectedSource $entry.Value -InstallRoot $installRoot -ExpectedRunId $runId
    $receipts[$entry.Key] = $receipt
    if ($entry.Key -ceq 'skillspector') {
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue
    }
}

foreach ($entry in $expectedSources.GetEnumerator()) {
    $receipt = $receipts[$entry.Key]
    $expectedClosure = Get-AuthorityProperty -Object $receipt -Name 'installedClosureSha256'
    Assert-AuthoritySha256 -Value $expectedClosure -Context "$($entry.Key) installed closure"
    $actualClosure = Get-AuthorityDirectoryClosureSha256 -Path ([string]$receipt.installRoot)
    if ($actualClosure -cne [string]$expectedClosure) {
        throw "$($entry.Key) installed closure changed after resolution. Expected '$expectedClosure', got '$actualClosure'."
    }
}

$skillSpectorReceipt = $receipts.skillspector
if ($skillSpectorReceipt.pythonPackageIndex -isnot [string] -or
    [string]$skillSpectorReceipt.pythonPackageIndex -cnotmatch '^https://pypi\.org/simple/?$' -or
    $skillSpectorReceipt.installEnvironment -isnot [string] -or
    [string]$skillSpectorReceipt.installEnvironment -cne 'isolated-venv' -or
    $skillSpectorReceipt.interpreterIsolation -isnot [string] -or
    [string]$skillSpectorReceipt.interpreterIsolation -cne 'python-isolated-mode' -or
    $skillSpectorReceipt.credentialIsolation -isnot [string] -or
    [string]$skillSpectorReceipt.credentialIsolation -cne 'github-token-cleared-before-python' -or
    $skillSpectorReceipt.installedMetadataVerification -isnot [string] -or
    [string]$skillSpectorReceipt.installedMetadataVerification -cne 'static-dist-info-metadata' -or
    $skillSpectorReceipt.directReferencesAllowed -isnot [bool] -or
    [bool]$skillSpectorReceipt.directReferencesAllowed -or
    $skillSpectorReceipt.pipOnlineDependencyTraversalAllowed -isnot [bool] -or
    [bool]$skillSpectorReceipt.pipOnlineDependencyTraversalAllowed -or
    $skillSpectorReceipt.yankedAllowed -isnot [bool] -or
    [bool]$skillSpectorReceipt.yankedAllowed -or
    $skillSpectorReceipt.dependencyDiscovery -isnot [string] -or
    [string]$skillSpectorReceipt.dependencyDiscovery -cne 'approved-simple-json-lazy' -or
    $skillSpectorReceipt.requiresPythonPolicy -isnot [string] -or
    [string]$skillSpectorReceipt.requiresPythonPolicy -cne 'simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' -or
    $skillSpectorReceipt.dependencyResolver -isnot [string] -or
    [string]$skillSpectorReceipt.dependencyResolver -cne 'pip-offline-backtracking' -or
    $skillSpectorReceipt.offlineResolutionVerified -isnot [bool] -or
    -not [bool]$skillSpectorReceipt.offlineResolutionVerified -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'interpreterIsolation=python-isolated-mode' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'credentialIsolation=github-token-cleared-before-python' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'installedMetadataVerification=static-dist-info-metadata' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'directReferences=blocked' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'pipOnlineDependencyTraversal=disabled' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'dependencyDiscovery=approved-simple-json-lazy' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'requiresPython=simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'offlineBacktracking=verified' -or
    [string]$skillSpectorReceipt.resolvedIdentity -cnotmatch 'offlineResolution=verified' -or
    @($skillSpectorReceipt.dependencyClosure).Count -le 1) {
    throw 'SkillSpector receipt does not bind the approved isolated dependency closure.'
}
Assert-AuthoritySha256 -Value $skillSpectorReceipt.installedClosureSha256 -Context 'SkillSpector installed closure'
$skillSpectorHelper = Assert-AuthorityFileIdentity `
    -PathValue $skillSpectorReceipt.resolverHelperPath `
    -Sha256Value $skillSpectorReceipt.resolverHelperSha256 `
    -Context 'SkillSpector Python wheel closure helper'
if ($skillSpectorHelper -cne [System.IO.Path]::GetFullPath($pythonClosureHelperPath)) {
    throw 'SkillSpector receipt identifies the wrong Python wheel closure helper.'
}
foreach ($name in @('candidateInventorySha256', 'selectionPlanSha256', 'rawSelectionPlanSha256', 'selectedClosureSha256')) {
    Assert-AuthoritySha256 -Value $skillSpectorReceipt.$name -Context "SkillSpector $name"
}
foreach ($name in @('resolutionRounds', 'candidateCount')) {
    Assert-AuthorityNonNegativeInteger -Value $skillSpectorReceipt.$name -Context "SkillSpector $name"
    if ([int64]$skillSpectorReceipt.$name -le 0) { throw "SkillSpector $name must be positive." }
}
if ($skillSpectorReceipt.pipVersion -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$skillSpectorReceipt.pipVersion) -or
    $skillSpectorReceipt.consoleEntryPoint -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$skillSpectorReceipt.consoleEntryPoint)) {
    throw 'SkillSpector receipt is missing pip or console entry-point identity.'
}
foreach ($binding in @(
    "pipVersion=$($skillSpectorReceipt.pipVersion)",
    "resolutionRounds=$($skillSpectorReceipt.resolutionRounds)",
    "candidateCount=$($skillSpectorReceipt.candidateCount)",
    "resolverHelperSha256=$($skillSpectorReceipt.resolverHelperSha256)",
    "candidateInventorySha256=$($skillSpectorReceipt.candidateInventorySha256)",
    "selectionPlanSha256=$($skillSpectorReceipt.selectionPlanSha256)",
    "selectedClosureSha256=$($skillSpectorReceipt.selectedClosureSha256)",
    "consoleEntryPoint=$($skillSpectorReceipt.consoleEntryPoint)"
)) {
    if ([string]$skillSpectorReceipt.resolvedIdentity -cnotlike "*$binding*") {
        throw "SkillSpector resolved identity is missing '$binding'."
    }
}

$skillValidatorReceipt = $receipts.'skill-validator'
$skillValidatorRuntimeVersion = if ($skillValidatorReceipt.goRuntimeVersion -is [string]) {
    [string]$skillValidatorReceipt.goRuntimeVersion
}
else {
    ''
}
$skillValidatorRuntimeIdentityPattern = if ($skillValidatorRuntimeVersion -match '^[0-9]+\.[0-9]+\.[0-9]+$') {
    "*#goRuntime=$skillValidatorRuntimeVersion#*"
}
else {
    ''
}
if ($skillValidatorReceipt.proxy -isnot [string] -or [string]$skillValidatorReceipt.proxy -cne 'https://proxy.golang.org' -or
    $skillValidatorReceipt.checksumDatabase -isnot [string] -or [string]$skillValidatorReceipt.checksumDatabase -cne 'sum.golang.org' -or
    $skillValidatorRuntimeVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
    [string]$skillValidatorReceipt.resolvedIdentity -cnotlike $skillValidatorRuntimeIdentityPattern -or
    $skillValidatorReceipt.moduleCacheIsolation -isnot [string] -or [string]$skillValidatorReceipt.moduleCacheIsolation -cne 'temporary-empty' -or
    $skillValidatorReceipt.buildCacheIsolation -isnot [string] -or [string]$skillValidatorReceipt.buildCacheIsolation -cne 'temporary-empty' -or
    $skillValidatorReceipt.temporaryDirectoryIsolation -isnot [string] -or [string]$skillValidatorReceipt.temporaryDirectoryIsolation -cne 'temporary-empty' -or
    $skillValidatorReceipt.binaryInstallIsolation -isnot [string] -or [string]$skillValidatorReceipt.binaryInstallIsolation -cne 'run-owned' -or
    $skillValidatorReceipt.goRuntimeSource -isnot [string] -or [string]$skillValidatorReceipt.goRuntimeSource -cne $expectedGoRuntimeSource -or
    [string]$skillValidatorReceipt.resolvedIdentity -cnotmatch ('#goRuntimeSource=' + [regex]::Escape($expectedGoRuntimeSource) + '#')) {
    throw 'skill-validator receipt does not bind the approved Go distribution isolation.'
}
if ($skillValidatorRuntimeVersion -cne $expectedGoRuntimeVersion) {
    throw "skill-validator receipt Go runtime '$skillValidatorRuntimeVersion' does not match the setup-go run-resolved latest stable runtime '$expectedGoRuntimeVersion'."
}
Assert-AuthoritySkillValidatorRuntimeReceipt `
    -Receipt $skillValidatorReceipt `
    -GoCommandPath $goCommandPath `
    -ExpectedGoRuntimeVersion $expectedGoRuntimeVersion `
    -Context 'skill-validator receipt' | Out-Null

$skillToolsReceipt = $receipts.'skill-tools'
if ($skillToolsReceipt.registry -isnot [string] -or
    [string]$skillToolsReceipt.registry -cnotmatch '^https://registry\.npmjs\.org/?$' -or
    $skillToolsReceipt.executableVerified -isnot [bool] -or -not [bool]$skillToolsReceipt.executableVerified) {
    throw 'skill-tools receipt does not bind the approved npm registry and entry point.'
}
Assert-AuthoritySha256 -Value $skillToolsReceipt.packageLockSha256 -Context 'skill-tools package lock'
$skillToolsEntryPoint = Assert-AuthorityFileIdentity `
    -PathValue $skillToolsReceipt.entryPointPath `
    -Sha256Value $skillToolsReceipt.entryPointSha256 `
    -Context 'skill-tools package entry point'
$skillToolsNode = Assert-AuthorityFileIdentity `
    -PathValue $skillToolsReceipt.nodePath `
    -Sha256Value $skillToolsReceipt.nodeSha256 `
    -Context 'skill-tools Node runtime'
Assert-AuthorityPathWithinRoot -Path $skillToolsEntryPoint -Root ([string]$skillToolsReceipt.installRoot) -Context 'skill-tools package entry point'

$pesterReceipt = $receipts.pester
$pesterModulePath = Assert-AuthorityFileIdentity `
    -PathValue $pesterReceipt.modulePath `
    -Sha256Value $pesterReceipt.executableSha256 `
    -Context 'Pester module'
if ([System.IO.Path]::GetFullPath([string]$pesterReceipt.modulePath) -cne
    [System.IO.Path]::GetFullPath([string]$pesterReceipt.executablePath)) {
    throw 'Pester receipt modulePath and executablePath must identify the same frozen module manifest.'
}

# Keep a run-owned fixture with every adopted upstream surface present.  The
# adapter must prove that it can validate a real surface before later security
# stages are allowed to run; the ordinary validation fixture intentionally has
# no optional upstream metadata.
$upstreamAdapterFixtureRoot = Join-Path $runRoot 'fixture/upstream-adapter-fixture'
$upstreamAdapterSourceRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$upstreamAdapterSourceRevision = ('a' * 40)
$upstreamAdapterArchiveSha256 = ('b' * 64)
[void](New-Item -ItemType Directory -Path (Join-Path $upstreamAdapterFixtureRoot '.codex-plugin') -Force)
$upstreamAdapterSkillRoot = Join-Path $upstreamAdapterFixtureRoot 'skills/adapter-fixture-skill'
[void](New-Item -ItemType Directory -Path (Join-Path $upstreamAdapterSkillRoot 'agents') -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $upstreamAdapterSkillRoot 'scripts') -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $upstreamAdapterFixtureRoot '.agents/plugins') -Force)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterSkillRoot 'SKILL.md'),
    "---`nname: adapter-fixture-skill`ndescription: A deterministic upstream adapter fixture Skill.`n---`n`n# Adapter Fixture`n`nThe [fixture script](scripts/run.ps1) prints one fixture message.`n",
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterSkillRoot 'agents/openai.yaml'),
    "interface:`n  display_name: `"Adapter Fixture Skill`"`n  short_description: `"Validate one deterministic upstream adapter Skill.`"`n  default_prompt: `"Use `$adapter-fixture-skill to verify the upstream adapter.`"`n",
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterSkillRoot 'scripts/run.ps1'),
    "Write-Output 'adapter fixture'`n",
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterFixtureRoot '.codex-plugin/plugin.json'),
    '{"name":"adapter-fixture-plugin","description":"A deterministic upstream adapter fixture.","version":"1.0.0","skills":["./skills/adapter-fixture-skill"]}',
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterFixtureRoot 'adapter-command.ps1'),
    "Write-Output 'adapter fixture'`n",
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterFixtureRoot '.mcp.json'),
    '{"mcpServers":{"local":{"command":"./adapter-command.ps1","args":[]}}}',
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterFixtureRoot '.app.json'),
    '{"apps":[{"name":"adapter-fixture-app","mcpServer":"local"}]}',
    (New-Object Text.UTF8Encoding($false))
)
[System.IO.File]::WriteAllText(
    (Join-Path $upstreamAdapterFixtureRoot '.agents/plugins/marketplace.json'),
    ('{"plugins":[{"name":"adapter-fixture-marketplace-entry","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + $upstreamAdapterSourceRevision + '"}}]}'),
    (New-Object Text.UTF8Encoding($false))
)
Assert-AuthorityFixtureContract -FixtureRoot $upstreamAdapterSkillRoot -ExpectedSkillId 'adapter-fixture-skill'
$upstreamAdapterSkillFiles = @(
    [pscustomobject][ordered]@{ path = 'SKILL.md'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterSkillRoot 'SKILL.md')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = 'agents/openai.yaml'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterSkillRoot 'agents/openai.yaml')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = 'scripts/run.ps1'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterSkillRoot 'scripts/run.ps1')).Hash.ToLowerInvariant() }
)
$upstreamAdapterSkillInventoryPaths = @($upstreamAdapterSkillFiles | ForEach-Object { [string]$_.path })
$upstreamAdapterComponentFiles = @(
    [pscustomobject][ordered]@{ path = '.agents/plugins/marketplace.json'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterFixtureRoot '.agents/plugins/marketplace.json')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = '.app.json'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterFixtureRoot '.app.json')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = '.codex-plugin/plugin.json'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterFixtureRoot '.codex-plugin/plugin.json')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = '.mcp.json'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterFixtureRoot '.mcp.json')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = 'adapter-command.ps1'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $upstreamAdapterFixtureRoot 'adapter-command.ps1')).Hash.ToLowerInvariant() },
    [pscustomobject][ordered]@{ path = 'skills/adapter-fixture-skill/SKILL.md'; sha256 = [string]$upstreamAdapterSkillFiles[0].sha256 },
    [pscustomobject][ordered]@{ path = 'skills/adapter-fixture-skill/agents/openai.yaml'; sha256 = [string]$upstreamAdapterSkillFiles[1].sha256 },
    [pscustomobject][ordered]@{ path = 'skills/adapter-fixture-skill/scripts/run.ps1'; sha256 = [string]$upstreamAdapterSkillFiles[2].sha256 }
)
$upstreamAdapterComponentInventorySha256 = Get-AuthorityComponentInventorySha256 -Inventory $upstreamAdapterComponentFiles

# Stage 3: Package Validation. The optional upstream adapter and both package tools
# must pass before any SkillSpector scan or repository test can run.
# Context 'upstream adapter validation'
$upstreamAdapterReportPath = Join-Path $runRoot 'upstream-adapter-report.json'
try {
    & $upstreamAdapterValidatorPath `
        -PackageRoot $upstreamAdapterFixtureRoot `
        -PolicyPath $upstreamAdapterPolicyPath `
        -SourceRepository $upstreamAdapterSourceRepository `
        -SourceRevision $upstreamAdapterSourceRevision `
        -ArchiveSha256 $upstreamAdapterArchiveSha256 `
        -OutputPath $upstreamAdapterReportPath | Out-Null
}
catch {
    throw "upstream adapter validation failed: $($_.Exception.Message)"
}
$upstreamAdapterReport = Read-AuthorityJson -Path $upstreamAdapterReportPath -Context 'upstream adapter validation'
Assert-AuthorityUpstreamAdapterReport -Report $upstreamAdapterReport | Out-Null
if ([string]$upstreamAdapterReport.status -cne 'passed' -or [string]$upstreamAdapterReport.decision -cne 'PASS') {
    throw 'upstream adapter validation must pass a fixture with adopted surfaces before Stage 4.'
}
foreach ($surface in @('plugin', 'mcp', 'app', 'marketplace')) {
    if (@($upstreamAdapterReport.surfaces) -cnotcontains $surface) {
        throw "upstream adapter validation did not exercise required surface '$surface'."
    }
}

$bundledSkills = Get-AuthorityRequiredProperty -Object $upstreamAdapterReport -Name 'bundledSkills' -Context 'upstream adapter validation'
if ($bundledSkills -isnot [array] -or @($bundledSkills).Count -ne 1) {
    throw 'upstream adapter validation must report exactly one declared bundled Skill for the controlled fixture.'
}
$bundledSkill = @($bundledSkills)[0]
$bundledSkillPath = Get-AuthorityRequiredProperty -Object $bundledSkill -Name 'path' -Context 'upstream adapter bundled Skill inventory'
if ($bundledSkillPath -isnot [string] -or [string]$bundledSkillPath -cne './skills/adapter-fixture-skill') {
    throw 'upstream adapter bundled Skill inventory is not bound to the controlled Plugin declaration.'
}
Assert-AuthorityExactPathInventory `
    -Value (Get-AuthorityRequiredProperty -Object $bundledSkill -Name 'inventory' -Context 'upstream adapter bundled Skill inventory') `
    -Expected $upstreamAdapterSkillInventoryPaths `
    -Context 'upstream adapter bundled Skill inventory' | Out-Null
Assert-AuthorityExactComponentInventory `
    -Value (Get-AuthorityRequiredProperty -Object $upstreamAdapterReport -Name 'componentInventory' -Context 'upstream adapter component inventory') `
    -Expected $upstreamAdapterComponentFiles `
    -Context 'upstream adapter component inventory' | Out-Null
if ([string]$upstreamAdapterReport.adapterVersion -cne 'upstream-interoperability-adapter-v1' -or
    [string]$upstreamAdapterReport.candidateIdentity.sourceRepository -cne $upstreamAdapterSourceRepository -or
    [string]$upstreamAdapterReport.candidateIdentity.sourceRevision -cne $upstreamAdapterSourceRevision -or
    [string]$upstreamAdapterReport.candidateIdentity.archiveSha256 -cne $upstreamAdapterArchiveSha256 -or
    [string]$upstreamAdapterReport.candidateIdentity.packageSha256 -cne $upstreamAdapterComponentInventorySha256 -or
    [string]$upstreamAdapterReport.componentInventorySha256 -cne $upstreamAdapterComponentInventorySha256) {
    throw 'upstream adapter report does not bind the controlled fixture identity and component inventory.'
}
Assert-AuthorityComponentInventoryFiles `
    -Inventory (Get-AuthorityRequiredProperty -Object $upstreamAdapterReport -Name 'componentInventory' -Context 'upstream adapter component inventory') `
    -Root $upstreamAdapterFixtureRoot `
    -Context 'upstream adapter component identity' | Out-Null

# Prove that a report cannot be replayed after one validated component changes.
$mutatedAdapterComponentPath = Join-Path $upstreamAdapterFixtureRoot '.app.json'
$originalMutatedAdapterComponentBytes = [System.IO.File]::ReadAllBytes($mutatedAdapterComponentPath)
try {
    [System.IO.File]::WriteAllText(
        $mutatedAdapterComponentPath,
        '{"apps":[{"name":"adapter-fixture-app","mcpServer":"local"},{"name":"unexpected","mcpServer":"local"}]}',
        (New-Object Text.UTF8Encoding($false))
    )
    $mutationDetected = $false
    try {
        Assert-AuthorityComponentInventoryFiles `
            -Inventory (Get-AuthorityRequiredProperty -Object $upstreamAdapterReport -Name 'componentInventory' -Context 'upstream adapter component inventory') `
            -Root $upstreamAdapterFixtureRoot `
            -Context 'upstream adapter replay check' | Out-Null
    }
    catch {
        $mutationDetected = $true
    }
    if (-not $mutationDetected) { throw 'upstream adapter replay check failed to detect component mutation.' }
}
finally {
    [System.IO.File]::WriteAllBytes($mutatedAdapterComponentPath, $originalMutatedAdapterComponentBytes)
}

# Token statistics do not enumerate every file passed to skill-validator.
# Capture all input hashes before invocation and verify them again afterward.
$skillValidatorCoveragePath = Join-Path $runRoot 'skill-validator-coverage.json'
$skillValidatorCoverageEnvelope = [pscustomobject][ordered]@{
    schemaVersion = 1
    toolName = 'skill-validator'
    coverageMode = 'authority-input-inventory'
    root = $upstreamAdapterSkillRoot
    files = @($upstreamAdapterSkillFiles)
}
Assert-AuthorityToolInputInventory `
    -Envelope $skillValidatorCoverageEnvelope `
    -ExpectedToolName 'skill-validator' `
    -ExpectedFixtureRoot $upstreamAdapterSkillRoot `
    -ExpectedInventoryPaths $upstreamAdapterSkillInventoryPaths | Out-Null

$skillValidatorOutput = Invoke-AuthorityExternalCommand `
    -Command $executablePaths.'skill-validator' `
    -Arguments @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $upstreamAdapterSkillRoot) `
    -Context 'skill-validator package validation' `
    -DiagnosticRoot $runRoot
$skillValidatorOutputPath = Join-Path $runRoot 'skill-validator-report.json'
[System.IO.File]::WriteAllText($skillValidatorOutputPath, $skillValidatorOutput + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
$skillValidatorReport = Read-AuthorityJson -Path $skillValidatorOutputPath -Context 'skill-validator package validation'
Assert-AuthoritySkillValidatorReport `
    -Report $skillValidatorReport `
    -ExpectedFixtureRoot $upstreamAdapterSkillRoot `
    -ExpectedInventoryPaths $upstreamAdapterSkillInventoryPaths `
    -ExpectedTokenPaths @('SKILL.md') `
    -ExpectedOtherTokenPaths @('agents/openai.yaml')
Assert-AuthorityToolInputInventory `
    -Envelope $skillValidatorCoverageEnvelope `
    -ExpectedToolName 'skill-validator' `
    -ExpectedFixtureRoot $upstreamAdapterSkillRoot `
    -ExpectedInventoryPaths $upstreamAdapterSkillInventoryPaths | Out-Null
$skillValidatorCoverageJson = $skillValidatorCoverageEnvelope | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($skillValidatorCoveragePath, $skillValidatorCoverageJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

# skill-tools v0.4.1 SARIF carries diagnostic locations, not a complete file
# inventory.  Keep a run-owned input snapshot in memory so the diagnostic
# report is bound to the same exact adapter inventory without mistaking
# findings for coverage.  It is re-hashed after the tool exits and persisted
# only after that post-run identity check succeeds.
$skillToolsCoveragePath = Join-Path $runRoot 'skill-tools-coverage.json'
$skillToolsCoverageEnvelope = [pscustomobject][ordered]@{
    schemaVersion = 1
    toolName = 'skill-tools'
    coverageMode = 'authority-input-inventory'
    root = $upstreamAdapterSkillRoot
    files = @($upstreamAdapterSkillFiles)
}
Assert-AuthoritySkillToolsCoverageEnvelope `
    -Envelope $skillToolsCoverageEnvelope `
    -ExpectedFixtureRoot $upstreamAdapterSkillRoot `
    -ExpectedInventoryPaths $upstreamAdapterSkillInventoryPaths | Out-Null

$skillToolsOutput = Invoke-AuthorityExternalCommand `
    -Command $skillToolsNode `
    -Arguments @($skillToolsEntryPoint, 'check', $upstreamAdapterSkillRoot, '--format', 'sarif', '--fail-on', 'error', '--min-score', '0') `
    -Context 'skill-tools package validation' `
    -DiagnosticRoot $runRoot
$skillToolsOutputPath = Join-Path $runRoot 'skill-tools-report.sarif.json'
[System.IO.File]::WriteAllText($skillToolsOutputPath, $skillToolsOutput + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
$skillToolsReport = Read-AuthorityJson -Path $skillToolsOutputPath -Context 'skill-tools package validation'
Assert-AuthoritySkillToolsSarifReport `
    -Report $skillToolsReport `
    -ExpectedFixtureRoot $upstreamAdapterSkillRoot `
    -ExpectedInventoryPaths $upstreamAdapterSkillInventoryPaths `
    -CoverageEnvelope $skillToolsCoverageEnvelope
$skillToolsCoverageJson = $skillToolsCoverageEnvelope | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($skillToolsCoveragePath, $skillToolsCoverageJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Assert-AuthorityComponentInventoryFiles `
    -Inventory (Get-AuthorityRequiredProperty -Object $upstreamAdapterReport -Name 'componentInventory' -Context 'upstream adapter component inventory') `
    -Root $upstreamAdapterFixtureRoot `
    -Context 'upstream adapter post-package-validation identity' | Out-Null

# Stage 4: SkillSpector Static.
$skillSpectorReportPath = Join-Path $runRoot 'skillspector-report.json'
[void](Invoke-AuthorityExternalCommand `
    -Command $executablePaths.skillspector `
    -Arguments @('scan', $upstreamAdapterSkillRoot, '--no-llm', '--format', 'json', '--output', $skillSpectorReportPath) `
    -Context 'SkillSpector static scan' `
    -DiagnosticRoot $runRoot)
$skillSpectorReport = Read-AuthorityJson -Path $skillSpectorReportPath -Context 'SkillSpector static scan'
Assert-AuthoritySkillSpectorReport `
    -Report $skillSpectorReport `
    -ExpectedFixtureRoot $upstreamAdapterSkillRoot `
    -ExpectedSkillId 'adapter-fixture-skill' `
    -ExpectedInventoryPaths $upstreamAdapterSkillInventoryPaths

# Stage 5: Repository Tests. Only repository/authority tests remain after the
# deterministic package and static security stages have passed.
Import-Module $pesterModulePath -Force -ErrorAction Stop
$pesterModuleRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $pesterModulePath))
$loadedPester = Get-Module Pester | Where-Object {
    [string]::Equals([System.IO.Path]::GetFullPath([string]$_.ModuleBase), $pesterModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)
} | Select-Object -First 1
if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne [string]$pesterReceipt.resolvedVersion) {
    throw 'The exact frozen Pester module was not imported.'
}
$authorityResult = Invoke-Pester -Path $authorityTestPaths -PassThru
Assert-AuthorityPesterResult `
    -Result $authorityResult `
    -MinimumTotalCount 45 `
    -PesterMajorVersion ([version]$pesterReceipt.resolvedVersion).Major

$candidateCommit = Get-AuthorityCandidateCommit -RepositoryRoot $repositoryRoot

$summary = [ordered]@{
    schemaVersion = 1
    runId = $runId
    candidateCommit = $candidateCommit
    goRuntimeVersion = $expectedGoRuntimeVersion
    canonicalGate = [ordered]@{
        policy = [string]$validationSecurityGate.policy
        policyPath = 'docs/standards/validation-security-gate.json'
        policySha256 = $validationSecurityGatePolicySha256
        stageIds = @($validationSecurityGate.stages | ForEach-Object { [string]$_.id })
        executionScope = 'protected-authority-fixture-regression'
        productionCandidateRunnerInvoked = $false
        tenStageCompletionClaim = $false
    }
    fixture = [ordered]@{
        id = 'standard-validation-fixture'
        inventorySha256 = $fixtureInventorySha256
        files = $fixtureFiles
    }
    upstreamAdapterFixture = [ordered]@{
        id = 'adapter-fixture-skill'
        rootRelativePath = 'skills/adapter-fixture-skill'
        files = $upstreamAdapterSkillFiles
    }
    tools = @($expectedSources.Keys | ForEach-Object {
        $receipt = $receipts[$_]
        [ordered]@{
            toolName = $_
            source = [string]$receipt.source
            version = [string]$receipt.resolvedVersion
            resolvedIdentity = [string]$receipt.resolvedIdentity
        }
    })
    stages = @(
        [ordered]@{
            name='package-validation'; result='passed'; exitCode=0; mode='upstream-adapter-skill-validator-skill-tools'
            skillValidatorMode='structure-json-allow-agents-bundled-skill+authority-input-inventory'; skillToolsMode='sarif-check-bundled-skill'
            reports=@('upstream-adapter-report.json', 'skill-validator-report.json', 'skill-validator-coverage.json', 'skill-tools-report.sarif.json', 'skill-tools-coverage.json')
        },
        [ordered]@{ name='skillspector-static'; result='passed'; exitCode=0; mode='static-no-llm-bundled-skill'; report='skillspector-report.json' },
        [ordered]@{
            name='repository-tests'; result='passed'; exitCode=0; mode='authority-pester'
            reports=@(); total=[int]$authorityResult.TotalCount
            passed=[int]$authorityResult.PassedCount; failed=[int]$authorityResult.FailedCount
        }
    )
}
$summaryPath = Join-Path $runRoot 'authority-gate-summary.json'
$summaryJson = $summary | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($summaryPath, $summaryJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Write-Host "Standard authority gate passed. Evidence: $summaryPath"
$summaryJson
