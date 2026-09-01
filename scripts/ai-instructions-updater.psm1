Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:CanonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:RuntimeContractModule = Join-Path $PSScriptRoot 'ai-instructions-runtime-contract.psm1'
Import-Module $script:RuntimeContractModule

function Test-AiInstructionsTransientHttpStatusCode {
    param([Parameter(Mandatory = $true)][int] $StatusCode)
    return $StatusCode -in @(408,429,500,502,503,504)
}

function Get-AiInstructionsHttpHeaderValue {
    param([AllowNull()][object] $Response,[Parameter(Mandatory = $true)][string] $Name)

    if ($null -eq $Response -or $null -eq $Response.PSObject.Properties['Headers']) { return $null }
    try {
        $headers = $Response.Headers
        if ($null -ne $headers.PSObject.Methods['GetValues']) {
            return (@($headers.GetValues($Name)) -join ',')
        }
        return [string]$headers[$Name]
    }
    catch { return $null }
}

function Test-AiInstructionsTransientNetworkError {
    param([Parameter(Mandatory = $true)][System.Exception] $Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.Sockets.SocketException]) { return $true }
        if ($current -is [System.Net.WebException]) {
            if ($null -ne $current.Response -and $null -ne $current.Response.PSObject.Properties['StatusCode']) {
                $statusCode = [int]$current.Response.StatusCode
                if (Test-AiInstructionsTransientHttpStatusCode -StatusCode $statusCode) { return $true }
                if ($statusCode -eq 403) {
                    $rateLimitRemaining = Get-AiInstructionsHttpHeaderValue -Response $current.Response -Name 'X-RateLimit-Remaining'
                    $retryAfter = Get-AiInstructionsHttpHeaderValue -Response $current.Response -Name 'Retry-After'
                    if ([string]$current.Message -match '(?i)rate[\s-]*limit|too many requests' -or
                        $rateLimitRemaining -ceq '0' -or -not [string]::IsNullOrWhiteSpace($retryAfter)) {
                        return $true
                    }
                }
                return $false
            }
            if ($current.Status -in @(
                [System.Net.WebExceptionStatus]::ConnectFailure,
                [System.Net.WebExceptionStatus]::ConnectionClosed,
                [System.Net.WebExceptionStatus]::KeepAliveFailure,
                [System.Net.WebExceptionStatus]::NameResolutionFailure,
                [System.Net.WebExceptionStatus]::PipelineFailure,
                [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [System.Net.WebExceptionStatus]::ReceiveFailure,
                [System.Net.WebExceptionStatus]::RequestCanceled,
                [System.Net.WebExceptionStatus]::SendFailure,
                [System.Net.WebExceptionStatus]::Timeout
            )) { return $true }
        }
        if ($current.GetType().FullName -in @('System.Net.Http.HttpRequestException','Microsoft.PowerShell.Commands.HttpResponseException')) {
            $response = if ($null -ne $current.PSObject.Properties['Response']) { $current.Response } else { $null }
            $statusCodeProperty = $current.PSObject.Properties['StatusCode']
            if (($null -eq $statusCodeProperty -or $null -eq $statusCodeProperty.Value) -and
                $null -ne $response -and $null -ne $response.PSObject.Properties['StatusCode']) {
                $statusCodeProperty = $response.PSObject.Properties['StatusCode']
            }
            if ($null -ne $statusCodeProperty -and $null -ne $statusCodeProperty.Value) {
                $statusCode = [int]$statusCodeProperty.Value
                if (Test-AiInstructionsTransientHttpStatusCode -StatusCode $statusCode) { return $true }
                if ($statusCode -eq 403) {
                    $rateLimitRemaining = Get-AiInstructionsHttpHeaderValue -Response $response -Name 'X-RateLimit-Remaining'
                    $retryAfter = Get-AiInstructionsHttpHeaderValue -Response $response -Name 'Retry-After'
                    return [string]$current.Message -match '(?i)rate[\s-]*limit|too many requests' -or
                        $rateLimitRemaining -ceq '0' -or -not [string]::IsNullOrWhiteSpace($retryAfter)
                }
                return $false
            }
            if ($current.GetType().FullName -eq 'System.Net.Http.HttpRequestException') { return $true }
        }
        if ([string]$current.Message -match '(?i)network|offline|socket|name resolution|connect(?:ion)?|timed?\s*out|temporarily unavailable|rate[\s-]*limit|too many requests') { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Get-AiInstructionsRepositoryCoordinates {
    param([Parameter(Mandatory = $true)][string] $Repository)

    Assert-AiInstructionsCanonicalRepository -Repository $Repository
    $uri = [System.Uri]$Repository
    $parts = @($uri.AbsolutePath.Trim('/').Split('/'))
    if ($parts.Count -ne 2) { throw "Canonical AI-Instructions repository does not identify owner/repository: $Repository" }
    $repositoryName = $parts[1]
    if ($repositoryName.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $repositoryName = $repositoryName.Substring(0, $repositoryName.Length - 4)
    }
    return [pscustomobject]@{ Owner=$parts[0]; Repository=$repositoryName }
}

function Get-AiInstructionsRemoteCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Request)

    $coordinates = Get-AiInstructionsRepositoryCoordinates -Repository ([string]$Request.Repository)
    $owner = [System.Uri]::EscapeDataString([string]$coordinates.Owner)
    $repository = [System.Uri]::EscapeDataString([string]$coordinates.Repository)
    $headers = @{ 'User-Agent'='Codex-AI-Instructions-Updater'; 'Accept'='application/vnd.github+json' }
    $ref = [string]$Request.Ref
    if ([string]$Request.Channel -ceq 'github-release') {
        $releaseUri = "https://api.github.com/repos/$owner/$repository/releases/latest"
        $release = Invoke-RestMethod -UseBasicParsing -Uri $releaseUri -Headers $headers -Method Get
        if ($null -eq $release -or $release.tag_name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
            throw 'The canonical GitHub latest release does not expose a tag_name.'
        }
        $ref = [string]$release.tag_name
    }
    $escapedRef = [System.Uri]::EscapeDataString($ref)
    $commitUri = "https://api.github.com/repos/$owner/$repository/commits/$escapedRef"
    $commit = Invoke-RestMethod -UseBasicParsing -Uri $commitUri -Headers $headers -Method Get
    if ($null -eq $commit -or $commit.sha -isnot [string]) {
        throw 'The canonical GitHub candidate did not expose a scalar commit SHA.'
    }
    $sha = [string]$commit.sha
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'The canonical GitHub candidate did not resolve to a full lowercase commit SHA.' }
    $currentCommit = [string]$Request.CurrentCommit
    if ($currentCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'The installed runtime does not expose a valid immutable commit for lineage validation.' }
    $relation = 'identical'
    if ($sha -cne $currentCommit) {
        $escapedCurrent = [System.Uri]::EscapeDataString($currentCommit)
        $escapedCandidate = [System.Uri]::EscapeDataString($sha)
        $compareUri = "https://api.github.com/repos/$owner/$repository/compare/$escapedCurrent...$escapedCandidate"
        $comparison = Invoke-RestMethod -UseBasicParsing -Uri $compareUri -Headers $headers -Method Get
        if ($null -eq $comparison -or $comparison.status -isnot [string]) {
            throw 'The canonical GitHub comparison did not expose a scalar commit relation.'
        }
        $relation = [string]$comparison.status
        if ($relation -cnotin @('ahead','behind','diverged')) {
            throw "The canonical GitHub candidate returned an unsupported commit relation '$relation'."
        }
    }
    return [pscustomobject][ordered]@{ Commit=$sha; Relation=$relation }
}

function ConvertTo-AiInstructionsResolvedCandidate {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $CurrentCommit
    )

    if ($Value -is [string]) {
        $commit = [string]$Value
        $relation = if ($commit -ceq $CurrentCommit) { 'identical' } else { 'ahead' }
    }
    else {
        if ($null -eq $Value -or $null -eq $Value.PSObject.Properties['Commit'] -or $null -eq $Value.PSObject.Properties['Relation']) {
            throw 'AI instructions candidate resolver returned an invalid result.'
        }
        if ($Value.Commit -isnot [string] -or $Value.Relation -isnot [string]) {
            throw 'AI instructions candidate resolver must return scalar string Commit and Relation values.'
        }
        $commit = [string]$Value.Commit
        $relation = [string]$Value.Relation
    }
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'AI instructions update candidate must be a full lowercase 40-character commit SHA.' }
    if ($relation -cnotin @('identical','ahead','behind','diverged')) { throw "Unsupported AI instructions candidate relation '$relation'." }
    if (($commit -ceq $CurrentCommit) -ne ($relation -ceq 'identical')) {
        throw 'AI instructions candidate commit and lineage relation are inconsistent.'
    }
    return [pscustomobject][ordered]@{ Commit=$commit; Relation=$relation }
}

function Test-AiInstructionsPowerShellFiles {
    param([Parameter(Mandatory = $true)][string] $SourceRoot)

    foreach ($scriptPath in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath.FullName, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) {
            throw "Candidate contains a PowerShell parse error in '$($scriptPath.FullName)': $(@($errors)[0].Message)"
        }
    }
}

function Get-AiInstructionsCandidatePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Request)

    $coordinates = Get-AiInstructionsRepositoryCoordinates -Repository ([string]$Request.Repository)
    $owner = [System.Uri]::EscapeDataString([string]$coordinates.Owner)
    $repository = [System.Uri]::EscapeDataString([string]$coordinates.Repository)
    $commit = [string]$Request.CandidateCommit
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Candidate package commit must be a full lowercase commit SHA.' }
    $workingRoot = Join-Path ([System.IO.Path]::GetFullPath($Request.CodexHome)) ('.ai-instructions-update-' + [Guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $workingRoot 'candidate.zip'
    $extractRoot = Join-Path $workingRoot 'source'
    New-Item -ItemType Directory -Force -Path $workingRoot,$extractRoot | Out-Null
    try {
        $archiveUri = "https://codeload.github.com/$owner/$repository/zip/$commit"
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -Headers @{ 'User-Agent'='Codex-AI-Instructions-Updater' } -OutFile $archivePath
        Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
        $archiveStream = [System.IO.File]::Open(
            $archivePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $archiveSha256 = ([System.BitConverter]::ToString($sha.ComputeHash($archiveStream))).Replace('-','').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $archiveStream.Position = 0
            $sourceRoot = Expand-SafeZipRepository -ArchiveStream $archiveStream -DestinationRoot $extractRoot
        }
        finally { $archiveStream.Dispose() }
        foreach ($relativePath in @(
            'scripts\install-ai-instructions-bootstrap.ps1',
            'scripts\installer-safe-mutation.psm1',
            'scripts\bootstrap-ai-instructions-installed.ps1',
            'scripts\ai-instructions-runtime-contract.psm1',
            'scripts\ai-instructions-updater.psm1',
            'scripts\update-ai-instructions.ps1',
            'scripts\agent-environment-reconciler.psm1',
            'scripts\update-agent-environment.ps1',
            'catalog\skills-catalog.json',
            'catalog\skills-catalog-lock.json'
        )) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relativePath) -PathType Leaf)) {
                throw "Candidate runtime source is incomplete: $relativePath"
            }
        }
        Test-AiInstructionsPowerShellFiles -SourceRoot $sourceRoot
        Import-Module (Join-Path $sourceRoot 'scripts\skills-catalog-contract.psm1') -Force
        Test-SkillsCatalogLockDocument `
            -LockPath (Join-Path $sourceRoot 'catalog\skills-catalog-lock.json') `
            -CatalogPath (Join-Path $sourceRoot 'catalog\skills-catalog.json') | Out-Null
        return [pscustomobject][ordered]@{
            SourceRoot = $sourceRoot
            ArchivePath = $archivePath
            ArchiveSha256 = $archiveSha256
            CleanupRoot = $workingRoot
        }
    }
    catch {
        if (Test-Path -LiteralPath $workingRoot) {
            $safeWorkingRoot = Assert-AiInstructionsSafeChildDirectory -Parent ([string]$Request.CodexHome) -Path $workingRoot -LeafPrefix '.ai-instructions-update-'
            Remove-Item -LiteralPath $safeWorkingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Install-AiInstructionsCandidatePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Request)

    $installerPath = Join-Path ([string]$Request.Package.SourceRoot) 'scripts\install-ai-instructions-bootstrap.ps1'
    & $installerPath `
        -RepositoryRoot ([string]$Request.Package.SourceRoot) `
        -CodexHome ([string]$Request.CodexHome) `
        -SourceRepository ([string]$Request.Repository) `
        -SourceCommit ([string]$Request.CandidateCommit) `
        -Acquisition github-codeload `
        -ArchiveSha256 ([string]$Request.Package.ArchiveSha256) `
        -SourceArchivePath ([string]$Request.Package.ArchivePath) `
        -ExpectedCurrentCommit ([string]$Request.CurrentCommit) `
        -ExpectedUpdateMode ([string]$Request.Mode) `
        -ExpectedUpdateChannel ([string]$Request.Channel) `
        -ExpectedUpdateRef ([string]$Request.Ref)
}

function New-AiInstructionsUpdateResult {
    param(
        [Parameter(Mandatory = $true)][datetime] $CheckedAtUtc,
        [Parameter(Mandatory = $true)][object] $Configuration,
        [Parameter(Mandatory = $true)][string] $CurrentCommit,
        [AllowNull()][string] $CandidateCommit,
        [Parameter(Mandatory = $true)][string] $Outcome,
        [AllowNull()][string] $ArchiveSha256,
        [Parameter(Mandatory = $true)][string] $Message
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        checkedAtUtc = $CheckedAtUtc.ToUniversalTime().ToString('o')
        mode = [string]$Configuration.updates.mode
        channel = [string]$Configuration.updates.channel
        ref = [string]$Configuration.updates.ref
        currentCommit = $CurrentCommit
        candidateCommit = if ([string]::IsNullOrWhiteSpace($CandidateCommit)) { $null } else { $CandidateCommit }
        outcome = $Outcome
        archiveSha256 = if ([string]::IsNullOrWhiteSpace($ArchiveSha256)) { $null } else { $ArchiveSha256 }
        message = $Message
    }
}

function Write-AiInstructionsUpdateReceipt {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][object] $Result)
    Assert-AiInstructionsUpdateReceiptV1 -Receipt $Result | Out-Null
    Assert-AiInstructionsMutationPath -Path $Path -ExpectedType File -Context 'AI instructions update receipt' | Out-Null
    Write-AiInstructionsJsonFile -Path $Path -Document $Result
}

function Invoke-AiInstructionsUpdateWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $CodexHome,
        [switch] $ForceCheck,
        [switch] $InstallApproved,
        [AllowNull()][datetime] $NowUtc,
        [scriptblock] $ResolveCandidate,
        [scriptblock] $AcquireCandidate,
        [scriptblock] $InstallCandidate
    )

    $codexHomePath = Get-AiInstructionsFullDirectoryPath -Path $CodexHome -RejectFileSystemRoot -Context 'Codex Home'
    $runtimeRoot = Join-Path $codexHomePath 'hooks\ai-instructions-runtime'
    $configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
    $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
    $receiptPath = Join-Path $codexHomePath 'ai-instructions-update-receipt.json'
    $lockPath = Join-Path $codexHomePath 'ai-instructions-update.lock'
    $hookRoot = Join-Path $codexHomePath 'hooks'
    Assert-AiInstructionsMutationPath -Path $codexHomePath -ExpectedType Directory -Context 'Codex Home' | Out-Null
    Assert-AiInstructionsMutationPath -Path $hookRoot -ExpectedType Directory -Context 'Codex Home hooks directory' | Out-Null
    Assert-AiInstructionsMutationPath -Path $runtimeRoot -ExpectedType Directory -Context 'Installed AI instructions runtime directory' | Out-Null
    foreach ($stableFilePath in @($configurationPath,$bundlePath,$receiptPath,$lockPath,(Join-Path $codexHomePath 'ai-instructions-install.lock'))) {
        Assert-AiInstructionsMutationPath -Path $stableFilePath -ExpectedType File -Context 'AI instructions stable file' | Out-Null
    }
    if ($null -eq $NowUtc -or $NowUtc -eq [datetime]::MinValue) { $NowUtc = (Get-Date).ToUniversalTime() }
    else { $NowUtc = $NowUtc.ToUniversalTime() }
    if ($null -eq $ResolveCandidate) { $ResolveCandidate = { param($request) Get-AiInstructionsRemoteCandidate -Request $request } }
    if ($null -eq $AcquireCandidate) { $AcquireCandidate = { param($request) Get-AiInstructionsCandidatePackage -Request $request } }
    if ($null -eq $InstallCandidate) { $InstallCandidate = { param($request) Install-AiInstructionsCandidatePackage -Request $request } }

    New-Item -ItemType Directory -Force -Path $codexHomePath | Out-Null
    $lockStream = $null
    $installStateLockStream = $null
    try {
        try {
            $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            return [pscustomobject][ordered]@{ outcome='concurrent'; message='Another AI instructions updater is already running.' }
        }

        try {
            $installStateLockStream = [System.IO.File]::Open((Join-Path $codexHomePath 'ai-instructions-install.lock'),[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            return [pscustomobject][ordered]@{ outcome='concurrent'; message='Another AI instructions installer is already running.' }
        }
        try {
            $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
            $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        }
        catch { throw "Installed AI instruction update state is invalid: $($_.Exception.Message)" }
        Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot | Out-Null

        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                $previousReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json
                Assert-AiInstructionsUpdateReceiptV1 -Receipt $previousReceipt | Out-Null
                $checkedAt = ConvertTo-AiInstructionsUtcDateTime `
                    -Value $previousReceipt.checkedAtUtc `
                    -Context 'AI instructions update receipt checkedAtUtc'
                if ($checkedAt -gt $NowUtc.AddMinutes(5)) { throw 'AI instructions update receipt checkedAtUtc is implausibly in the future.' }
                if ([string]$previousReceipt.mode -cne [string]$configuration.updates.mode -or
                    [string]$previousReceipt.channel -cne [string]$configuration.updates.channel -or
                    [string]$previousReceipt.ref -cne [string]$configuration.updates.ref) {
                    throw 'AI instructions update receipt policy does not match the active configuration.'
                }
                $receiptMatchesActiveRuntime = [string]$previousReceipt.currentCommit -ceq [string]$bundle.commit
                if ([string]$previousReceipt.outcome -ceq 'installed' -and
                    [string]$previousReceipt.candidateCommit -ceq [string]$bundle.commit) {
                    $receiptMatchesActiveRuntime = $true
                }
                if (-not $receiptMatchesActiveRuntime) { throw 'AI instructions update receipt does not describe the active runtime.' }
                if (-not $ForceCheck) {
                    $minimumInterval = [timespan]::FromMinutes([int]$configuration.updates.minimumCheckIntervalMinutes)
                    if ($NowUtc -lt $checkedAt.Add($minimumInterval)) {
                        return [pscustomobject][ordered]@{ outcome='rate-limit'; message='The minimum update check interval has not elapsed.' }
                    }
                }
            }
            catch {
                $receiptError = $_
                $quarantinePath = Join-Path $codexHomePath ('ai-instructions-update-receipt.invalid-' + $NowUtc.ToString('yyyyMMddHHmmssfffffff') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
                try { Move-Item -LiteralPath $receiptPath -Destination $quarantinePath }
                catch { Write-Warning "Malformed update receipt could not be quarantined and will be replaced after this check: $receiptPath" }
                Write-Warning "Malformed update receipt was ignored so the verified installed runtime can self-heal: $($receiptError.Exception.Message)"
            }
        }

        $request = [pscustomobject][ordered]@{
            CodexHome = $codexHomePath
            Repository = [string]$bundle.repository
            CurrentCommit = [string]$bundle.commit
            Mode = [string]$configuration.updates.mode
            Channel = [string]$configuration.updates.channel
            Ref = [string]$configuration.updates.ref
        }
        try {
            $resolvedCandidate = ConvertTo-AiInstructionsResolvedCandidate -Value (& $ResolveCandidate $request) -CurrentCommit ([string]$bundle.commit)
        }
        catch {
            $resolveOutcome = if (Test-AiInstructionsTransientNetworkError -Exception $_.Exception) { 'offline' } else { 'failed' }
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $null -Outcome $resolveOutcome -ArchiveSha256 $null -Message $_.Exception.Message
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }
        $candidateCommit = [string]$resolvedCandidate.Commit
        if ($candidateCommit -ceq [string]$bundle.commit) {
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $null -Outcome 'current' -ArchiveSha256 $null -Message 'The installed runtime is current.'
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }
        if ([string]$resolvedCandidate.Relation -cne 'ahead') {
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome 'stale' -ArchiveSha256 $null -Message "The canonical candidate is $($resolvedCandidate.Relation) relative to the installed runtime; downgrade or divergent installation was refused."
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }
        if (-not $InstallApproved -and [string]$configuration.updates.mode -ceq 'notify-only') {
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome 'available' -ArchiveSha256 $null -Message 'A verified canonical candidate is available; notify-only mode did not install it.'
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }

        $package = $null
        try {
            $request | Add-Member -NotePropertyName CandidateCommit -NotePropertyValue $candidateCommit
            $package = & $AcquireCandidate $request
            if ($null -eq $package -or $null -eq $package.PSObject.Properties['ArchiveSha256'] -or
                $package.ArchiveSha256 -isnot [string] -or [string]$package.ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Candidate package did not provide a valid archiveSha256.'
            }
            $resolvedAfterAcquisition = ConvertTo-AiInstructionsResolvedCandidate -Value (& $ResolveCandidate $request) -CurrentCommit ([string]$bundle.commit)
            $candidateAfterAcquisition = [string]$resolvedAfterAcquisition.Commit
            if ($candidateAfterAcquisition -cne $candidateCommit -or [string]$resolvedAfterAcquisition.Relation -cne 'ahead') {
                $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome 'drift' -ArchiveSha256 ([string]$package.ArchiveSha256) -Message "Candidate drifted to $candidateAfterAcquisition before installation."
                Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
                return $result
            }
            $installRequest = [pscustomobject][ordered]@{
                CodexHome = $codexHomePath
                Repository = [string]$bundle.repository
                CurrentCommit = [string]$bundle.commit
                CandidateCommit = $candidateCommit
                Mode = [string]$configuration.updates.mode
                Channel = [string]$configuration.updates.channel
                Ref = [string]$configuration.updates.ref
                Package = $package
            }
            $installStateLockStream.Dispose()
            $installStateLockStream = $null
            & $InstallCandidate $installRequest
            try {
                $installStateLockStream = [System.IO.File]::Open((Join-Path $codexHomePath 'ai-instructions-install.lock'),[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
            }
            catch [System.IO.IOException] {
                throw 'The active runtime could not be verified because another AI instructions installer is running.'
            }
            try {
                try {
                    $activeConfiguration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
                    $activeBundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
                }
                catch { throw "The active runtime could not be verified after installation: $($_.Exception.Message)" }
                Assert-AiInstructionsRuntimeBundleV2 -Bundle $activeBundle -Configuration $activeConfiguration -RuntimeRoot $runtimeRoot | Out-Null
                if ([string]$activeBundle.repository -cne [string]$bundle.repository -or [string]$activeBundle.commit -cne $candidateCommit) {
                    throw 'The active runtime does not match the selected canonical candidate after installation.'
                }
                if ([string]$activeConfiguration.updates.mode -cne [string]$configuration.updates.mode -or
                    [string]$activeConfiguration.updates.channel -cne [string]$configuration.updates.channel -or
                    [string]$activeConfiguration.updates.ref -cne [string]$configuration.updates.ref) {
                    throw 'The active runtime update policy changed during installation.'
                }
                $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $activeConfiguration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome 'installed' -ArchiveSha256 ([string]$package.ArchiveSha256) -Message 'The canonical candidate was installed and verified as the active runtime.'
                Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
                return $result
            }
            finally {
                if ($null -ne $installStateLockStream) {
                    $installStateLockStream.Dispose()
                    $installStateLockStream = $null
                }
            }
        }
        catch {
            if ($null -eq $installStateLockStream) {
                try {
                    $installStateLockStream = [System.IO.File]::Open((Join-Path $codexHomePath 'ai-instructions-install.lock'),[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
                }
                catch [System.IO.IOException] {
                    return [pscustomobject][ordered]@{ outcome='concurrent'; message='Another AI instructions installer changed or is changing the active runtime.' }
                }

                try {
                    $activeConfigurationAfterFailure = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
                    $activeBundleAfterFailure = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
                    Assert-AiInstructionsRuntimeBundleV2 -Bundle $activeBundleAfterFailure -Configuration $activeConfigurationAfterFailure -RuntimeRoot $runtimeRoot | Out-Null
                }
                catch {
                    return [pscustomobject][ordered]@{ outcome='failed'; message="The active runtime could not be verified after candidate installation failed: $($_.Exception.Message)" }
                }
                if ([string]$activeBundleAfterFailure.repository -cne [string]$bundle.repository -or
                    [string]$activeBundleAfterFailure.commit -cne [string]$bundle.commit -or
                    [string]$activeConfigurationAfterFailure.updates.mode -cne [string]$configuration.updates.mode -or
                    [string]$activeConfigurationAfterFailure.updates.channel -cne [string]$configuration.updates.channel -or
                    [string]$activeConfigurationAfterFailure.updates.ref -cne [string]$configuration.updates.ref) {
                    return [pscustomobject][ordered]@{ outcome='concurrent'; message='Another AI instructions installer changed the active runtime before the failed update could be recorded.' }
                }
            }
            $installOutcome = if (Test-AiInstructionsTransientNetworkError -Exception $_.Exception) { 'offline' } else { 'failed' }
            $verifiedArchiveSha256 = $null
            if ($null -ne $package -and
                $null -ne $package.PSObject.Properties['ArchiveSha256'] -and
                $package.ArchiveSha256 -is [string] -and
                [string]$package.ArchiveSha256 -cmatch '^[0-9a-f]{64}$') {
                $verifiedArchiveSha256 = [string]$package.ArchiveSha256
            }
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome $installOutcome -ArchiveSha256 $verifiedArchiveSha256 -Message $_.Exception.Message
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }
        finally {
            if ($null -ne $package -and $null -ne $package.PSObject.Properties['CleanupRoot'] -and
                -not [string]::IsNullOrWhiteSpace([string]$package.CleanupRoot) -and (Test-Path -LiteralPath ([string]$package.CleanupRoot))) {
                $cleanupRoot = Assert-AiInstructionsSafeChildDirectory -Parent $codexHomePath -Path ([string]$package.CleanupRoot) -LeafPrefix '.ai-instructions-update-'
                Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        if ($null -ne $installStateLockStream) { $installStateLockStream.Dispose() }
        if ($null -ne $lockStream) { $lockStream.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'Get-AiInstructionsCandidatePackage',
    'Get-AiInstructionsRemoteCandidate',
    'Install-AiInstructionsCandidatePackage',
    'Invoke-AiInstructionsUpdateWorkflow'
)
