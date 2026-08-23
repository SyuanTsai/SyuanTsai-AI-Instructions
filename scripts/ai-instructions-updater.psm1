Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:CanonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:RuntimeContractModule = Join-Path $PSScriptRoot 'ai-instructions-runtime-contract.psm1'
Import-Module $script:RuntimeContractModule

function Test-AiInstructionsTransientNetworkError {
    param([Parameter(Mandatory = $true)][System.Exception] $Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.WebException] -or $current -is [System.Net.Sockets.SocketException] -or
            $current.GetType().FullName -eq 'System.Net.Http.HttpRequestException') { return $true }
        if ([string]$current.Message -match '(?i)network|offline|socket|name resolution|connect(?:ion)?|timed?\s*out|temporarily unavailable') { return $true }
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
        if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
            throw 'The canonical GitHub latest release does not expose a tag_name.'
        }
        $ref = [string]$release.tag_name
    }
    $escapedRef = [System.Uri]::EscapeDataString($ref)
    $commitUri = "https://api.github.com/repos/$owner/$repository/commits/$escapedRef"
    $commit = Invoke-RestMethod -UseBasicParsing -Uri $commitUri -Headers $headers -Method Get
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
        $archiveSha256 = Get-AiInstructionsFileSha256 -Path $archivePath
        Import-Module (Join-Path $PSScriptRoot 'safe-zip.psm1') -Force
        $sourceRoot = Expand-SafeZipRepository -ArchivePath $archivePath -DestinationRoot $extractRoot
        foreach ($relativePath in @(
            'scripts\install-ai-instructions-bootstrap.ps1',
            'scripts\bootstrap-ai-instructions-installed.ps1',
            'scripts\ai-instructions-runtime-contract.psm1',
            'scripts\ai-instructions-updater.psm1',
            'scripts\update-ai-instructions.ps1',
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
        if (Test-Path -LiteralPath $workingRoot) { Remove-Item -LiteralPath $workingRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
        -ExpectedCurrentCommit ([string]$Request.CurrentCommit)
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

    $codexHomePath = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\','/'))
    $runtimeRoot = Join-Path $codexHomePath 'hooks\ai-instructions-runtime'
    $configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
    $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
    $receiptPath = Join-Path $codexHomePath 'ai-instructions-update-receipt.json'
    $lockPath = Join-Path $codexHomePath 'ai-instructions-update.lock'
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
            try {
                $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
                $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
            }
            catch { throw "Installed AI instruction update state is invalid: $($_.Exception.Message)" }
            Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot | Out-Null
        }
        finally {
            $installStateLockStream.Dispose()
            $installStateLockStream = $null
        }

        if (-not $ForceCheck -and (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            try {
                $previousReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json
                $checkedAt = ([datetime]::Parse([string]$previousReceipt.checkedAtUtc)).ToUniversalTime()
                $minimumInterval = [timespan]::FromMinutes([int]$configuration.updates.minimumCheckIntervalMinutes)
                if ($NowUtc -lt $checkedAt.Add($minimumInterval)) {
                    return [pscustomobject][ordered]@{ outcome='rate-limit'; message='The minimum update check interval has not elapsed.' }
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
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome 'current' -ArchiveSha256 $null -Message 'The installed runtime is current.'
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
            if ($null -eq $package -or [string]$package.ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
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
                Package = $package
            }
            & $InstallCandidate $installRequest
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome 'installed' -ArchiveSha256 ([string]$package.ArchiveSha256) -Message 'The canonical candidate was installed transactionally.'
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }
        catch {
            $installOutcome = if (Test-AiInstructionsTransientNetworkError -Exception $_.Exception) { 'offline' } else { 'failed' }
            $result = New-AiInstructionsUpdateResult -CheckedAtUtc $NowUtc -Configuration $configuration -CurrentCommit ([string]$bundle.commit) -CandidateCommit $candidateCommit -Outcome $installOutcome -ArchiveSha256 $(if ($null -ne $package) { [string]$package.ArchiveSha256 } else { $null }) -Message $_.Exception.Message
            Write-AiInstructionsUpdateReceipt -Path $receiptPath -Result $result
            return $result
        }
        finally {
            if ($null -ne $package -and $null -ne $package.PSObject.Properties['CleanupRoot'] -and
                -not [string]::IsNullOrWhiteSpace([string]$package.CleanupRoot) -and (Test-Path -LiteralPath ([string]$package.CleanupRoot))) {
                $cleanupRoot = [System.IO.Path]::GetFullPath([string]$package.CleanupRoot)
                $expectedPrefix = $codexHomePath + [System.IO.Path]::DirectorySeparatorChar + '.ai-instructions-update-'
                if (-not $cleanupRoot.StartsWith($expectedPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Unsafe updater cleanup path: $cleanupRoot"
                }
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
