param(
    [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Verify', 'BuildDelivery', 'VerifyDelivery')][string] $Mode,
    [Parameter(Mandatory = $true)][string] $PlanPath,
    [string] $BundlePath,
    [string] $PreparedPath,
    [string] $ManifestPath,
    [string] $ProtectedExpectedPath,
    [string] $DeliveryClaimPath,
    [string] $IssuedAtUtc,
    [string] $ExpiresAtUtc,
    [Parameter(Mandatory = $true)][string] $OutputPath,
    [string] $SourceRoot,
    [string] $GrantPath,
    [string] $RevocationPath,
    [string] $FixturePublicKeyPath,
    [string[]] $PathPrefixes,
    [string] $DataCategory,
    [string] $Provider,
    [string] $Account,
    [string] $ModelFamily,
    [string] $Purpose,
    [string] $DataHandlingSha256,
    [string] $ToolReceiptSha256,
    [int] $PlannedCalls,
    [int] $MaximumBytes,
    [switch] $DevelopmentHarness
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RoutineSemanticScan.psm1') -Force -ErrorAction Stop

try {
    if ($Mode -ceq 'BuildDelivery' -or $Mode -ceq 'VerifyDelivery') {
        foreach ($entry in @(
            @{ value = $BundlePath; name = 'BundlePath' },
            @{ value = $PreparedPath; name = 'PreparedPath' }
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.value)) { throw "DELIVERY_INPUT_MISSING|$($entry.name) is required." }
        }
        $delivery = Join-Path $PSScriptRoot 'routine_semantic_delivery.py'
        if (-not (Test-Path -LiteralPath $delivery -PathType Leaf)) { throw 'DELIVERY_HELPER_MISSING|Delivery helper is unavailable.' }
        if ($Mode -ceq 'BuildDelivery') {
            if ([string]::IsNullOrWhiteSpace($IssuedAtUtc) -or [string]::IsNullOrWhiteSpace($ExpiresAtUtc)) {
                throw 'DELIVERY_INPUT_MISSING|IssuedAtUtc and ExpiresAtUtc are required.'
            }
            & python $delivery build --plan $PlanPath --prepared $PreparedPath --bundle $BundlePath `
                --issued-at $IssuedAtUtc --expires-at $ExpiresAtUtc --output $OutputPath
        }
        else {
            foreach ($entry in @(
                @{ value = $ManifestPath; name = 'ManifestPath' },
                @{ value = $ProtectedExpectedPath; name = 'ProtectedExpectedPath' },
                @{ value = $DeliveryClaimPath; name = 'DeliveryClaimPath' }
            )) {
                if ([string]::IsNullOrWhiteSpace([string]$entry.value)) { throw "DELIVERY_INPUT_MISSING|$($entry.name) is required." }
            }
            & python $delivery verify --plan $PlanPath --prepared $PreparedPath --bundle $BundlePath `
                --manifest $ManifestPath --protected-expected $ProtectedExpectedPath `
                --claim $DeliveryClaimPath --output $OutputPath
        }
        if ($LASTEXITCODE -ne 0) { exit 10 }
        exit 0
    }
    if ($Mode -ceq 'Verify') {
        if ([string]::IsNullOrWhiteSpace($BundlePath)) { throw 'BUNDLE_MISSING|Verify requires a bundle path.' }
        $verifier = Join-Path $PSScriptRoot 'routine_semantic_offline.py'
        if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw 'VERIFIER_MISSING|Offline verifier is unavailable.' }
        & python $verifier verify --plan $PlanPath --bundle $BundlePath --output $OutputPath
        if ($LASTEXITCODE -ne 0) { exit 10 }
        exit 0
    }

    if (-not $DevelopmentHarness) { throw 'TRUST_POLICY_REVIEW_REQUIRED|Production routine semantic preparation is not enabled.' }
    foreach ($entry in @(
        @{ value = $SourceRoot; name = 'SourceRoot' },
        @{ value = $GrantPath; name = 'GrantPath' },
        @{ value = $RevocationPath; name = 'RevocationPath' },
        @{ value = $FixturePublicKeyPath; name = 'FixturePublicKeyPath' },
        @{ value = $DataCategory; name = 'DataCategory' },
        @{ value = $Provider; name = 'Provider' },
        @{ value = $Account; name = 'Account' },
        @{ value = $ModelFamily; name = 'ModelFamily' },
        @{ value = $Purpose; name = 'Purpose' },
        @{ value = $DataHandlingSha256; name = 'DataHandlingSha256' },
        @{ value = $ToolReceiptSha256; name = 'ToolReceiptSha256' }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.value)) { throw "PREPARE_INPUT_MISSING|$($entry.name) is required." }
    }
    if (@($PathPrefixes).Count -eq 0) { throw 'PREPARE_INPUT_MISSING|PathPrefixes are required.' }
    $consumerRecord = Read-RoutineSemanticJsonFile -Path $PlanPath -Context 'consumer plan'
    $consumer = $consumerRecord.value
    if ($consumer.artifactType -cne 'standard-validation-consumer-run-plan-v1' -or
        $consumer.schemaVersion -ne 1 -or ($consumer.schemaVersion -isnot [int] -and $consumer.schemaVersion -isnot [long]) -or
        [string]$consumer.runId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$consumer.source.revision -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$consumer.candidate.candidateId -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$consumer.candidate.contentSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'CONSUMER_PLAN_INVALID|Consumer candidate identity is invalid.'
    }
    $grant = (Read-RoutineSemanticJsonFile -Path $GrantPath -Context 'fixture grant envelope').value
    $revocations = (Read-RoutineSemanticJsonFile -Path $RevocationPath -Context 'fixture revocation envelope').value
    $keyItem = Get-Item -LiteralPath $FixturePublicKeyPath -Force
    if ($keyItem.PSIsContainer -or (($keyItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $keyItem.Length -gt 16384) {
        throw 'FIXTURE_KEY_INVALID|Fixture public key file is invalid.'
    }
    $publicKeyXml = ([Text.UTF8Encoding]::new($false, $true)).GetString([IO.File]::ReadAllBytes($keyItem.FullName))
    $prepared = New-RoutineSemanticPreparation `
        -RepositoryRoot $SourceRoot -Revision ([string]$consumer.source.revision) `
        -Repository ([string]$consumer.source.repository) -PathPrefixes $PathPrefixes `
        -DataCategory $DataCategory -Provider $Provider -Account $Account `
        -ModelFamily $ModelFamily -Purpose $Purpose -DataHandlingSha256 $DataHandlingSha256 `
        -ToolReceiptSha256 $ToolReceiptSha256 -PlannedCalls $PlannedCalls `
        -MaximumBytes $MaximumBytes -GrantEnvelope $grant -RevocationEnvelope $revocations `
        -FixturePublicKeyXml $publicKeyXml -DevelopmentHarness
    $prepared | Add-Member -NotePropertyName consumerBinding -NotePropertyValue ([pscustomobject][ordered]@{
        runId = [string]$consumer.runId
        candidateId = [string]$consumer.candidate.candidateId
        contentSha256 = [string]$consumer.candidate.contentSha256
        sourceRevision = [string]$consumer.source.revision
        consumerPlanSha256 = [string]$consumerRecord.sha256
    })
    if ($null -ne $consumer.PSObject.Properties['semantic']) {
        $prepared | Add-Member -NotePropertyName deliveryBinding -NotePropertyValue `
            (Get-RoutineSemanticDeliveryPlanBinding -Consumer $consumer -ConsumerPlanSha256 $consumerRecord.sha256)
    }
    $encoded = ([Text.UTF8Encoding]::new($false)).GetBytes(($prepared | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    $file = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($encoded, 0, $encoded.Length) }
    finally { $file.Dispose() }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 10
}
