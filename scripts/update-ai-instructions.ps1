[CmdletBinding()]
param(
    [string] $CodexHome,
    [switch] $ForceCheck,
    [switch] $InstallApproved,
    [switch] $RecoverInterruptedInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LocalAiInstructionsUpdateFailureDisposition {
    param([Parameter(Mandatory = $true)][string] $Message)

    if ($Message -match '\[classification=([^;\]]+);[^\]]*retryable=(true|false)\]') {
        return [pscustomobject]@{
            classification = [string]$Matches[1]
            retryable = [bool]([string]$Matches[2] -ceq 'true')
        }
    }
    $classification = if ($Message -match '(?i)access(?: to the path.*?)? is denied|permission denied|unauthorizedaccess|operation not permitted') { 'sandbox' }
        elseif ($Message -match '(?i)incompatible|capability evidence') { 'compatibility' }
        elseif ($Message -match '(?i)hash|sha-?256|inventory|bundle|archive|tamper|drift|mismatch|immutable pin') { 'integrity' }
        elseif ($Message -match '(?i)configuration|schemaVersion|unknown (?:profile|Skill)|update policy|unsupported property') { 'configuration' }
        else { 'operational' }
    return [pscustomobject]@{ classification=$classification; retryable=[bool]($classification -ceq 'sandbox') }
}

trap {
    $message = [string]$_.Exception.Message
    if ($message -match 'AI instructions (?:updater|bootstrap) stopped \[classification=') { throw $_.Exception }
    $disposition = Get-LocalAiInstructionsUpdateFailureDisposition -Message $message
    $retryable = ([string]$disposition.retryable).ToLowerInvariant()
    throw [System.InvalidOperationException]::new(
        "$message`nAI instructions updater disposition [classification=$($disposition.classification); retryable=$retryable].",
        $_.Exception
    )
}

if ($RecoverInterruptedInstall -and ($ForceCheck -or $InstallApproved)) {
    throw [System.InvalidOperationException]::new(
        "RecoverInterruptedInstall cannot be combined with update-check or installation switches.`nAI instructions updater stopped [classification=configuration; installationState=not-installed; retryable=false]."
    )
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$installedModule = Join-Path $PSScriptRoot 'ai-instructions-runtime\ai-instructions-updater.psm1'
$installedLauncher = Join-Path $PSScriptRoot 'bootstrap-ai-instructions.ps1'
$entryPointDirectoryName = Split-Path -Leaf ([System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]@('\','/')))
$isInstalledStableEntryPoint = $entryPointDirectoryName -ieq 'hooks'
$runtimeSnapshotRoot = $null
try {
    if (Test-Path -LiteralPath $installedModule -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $installedLauncher -PathType Leaf)) {
            throw [System.InvalidOperationException]::new(
                "Installed AI instructions preflight launcher is missing: $installedLauncher`nAI instructions updater stopped [classification=integrity; installationState=not-installed; retryable=false]."
            )
        }
        if ($RecoverInterruptedInstall) {
            & $installedLauncher -RecoverInterruptedInstall
            return
        }

        $installLockPath = Join-Path ([System.IO.Path]::GetFullPath($CodexHome)) 'ai-instructions-install.lock'
        if (-not (Test-Path -LiteralPath $installLockPath -PathType Leaf)) {
            throw [System.InvalidOperationException]::new(
                "AI instructions install lock is missing from the installed runtime.`nAI instructions updater stopped [classification=integrity; installationState=not-installed; retryable=false]."
            )
        }
        $installLockItem = Get-Item -Force -LiteralPath $installLockPath
        if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [System.InvalidOperationException]::new(
                "AI instructions install lock must be a non-reparse file.`nAI instructions updater stopped [classification=integrity; installationState=not-installed; retryable=false]."
            )
        }
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
        $runtimeSnapshotRoot = Join-Path $tempRoot ('ai-instructions-updater-runtime-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runtimeSnapshotRoot | Out-Null
        $runtimeReadLock = $null
        try {
            try {
                $runtimeReadLock = [System.IO.File]::Open(
                    $installLockPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read
                )
            }
            catch [System.IO.IOException] {
                throw [System.InvalidOperationException]::new(
                    "AI instructions runtime is being installed; updater stopped before reading a mixed runtime.`nAI instructions updater stopped [classification=concurrency; installationState=not-installed; retryable=false].",
                    $_.Exception
                )
            }
            & $installedLauncher -ValidateOnly
            $installedRuntimeRoot = Split-Path -Parent $installedModule
            foreach ($fileName in @('ai-instructions-updater.psm1','ai-instructions-runtime-contract.psm1','safe-zip.psm1')) {
                Copy-Item -LiteralPath (Join-Path $installedRuntimeRoot $fileName) -Destination (Join-Path $runtimeSnapshotRoot $fileName)
            }
        }
        finally { if ($null -ne $runtimeReadLock) { $runtimeReadLock.Dispose() } }
        $modulePath = Join-Path $runtimeSnapshotRoot 'ai-instructions-updater.psm1'
    }
    else {
        if ($RecoverInterruptedInstall) {
            throw [System.InvalidOperationException]::new(
                "RecoverInterruptedInstall is available only from a verified installed AI instructions runtime.`nAI instructions updater stopped [classification=configuration; installationState=not-installed; retryable=false]."
            )
        }
        if ($isInstalledStableEntryPoint) {
            throw [System.InvalidOperationException]::new(
                "Installed updater module is missing or invalid: $installedModule`nAI instructions updater stopped [classification=integrity; installationState=not-installed; retryable=false]."
            )
        }
        $modulePath = Join-Path $PSScriptRoot 'ai-instructions-updater.psm1'
    }
    Import-Module $modulePath -Force

    $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $CodexHome -ForceCheck:$ForceCheck -InstallApproved:$InstallApproved
    $disposition = Get-AiInstructionsUpdateDisposition -Outcome ([string]$result.outcome) -Message ([string]$result.message)
    $retryable = ([string]$disposition.retryable).ToLowerInvariant()
    if ([string]$result.outcome -in @('failed','drift','concurrent')) {
        throw [System.InvalidOperationException]::new(
            "AI instructions update stopped: Outcome $($result.outcome). $($result.message)`nAI instructions updater stopped [classification=$($disposition.classification); installationState=$($disposition.installationState); retryable=$retryable]."
        )
    }
    Write-Output "AI instructions update outcome: $($result.outcome) [classification=$($disposition.classification); installationState=$($disposition.installationState); retryable=$retryable]. $($result.message)"
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($runtimeSnapshotRoot) -and (Test-Path -LiteralPath $runtimeSnapshotRoot -PathType Container)) {
        $resolvedSnapshotRoot = [System.IO.Path]::GetFullPath($runtimeSnapshotRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
        $expectedPrefix = $resolvedTempRoot + [System.IO.Path]::DirectorySeparatorChar + 'ai-instructions-updater-runtime-'
        if (-not $resolvedSnapshotRoot.StartsWith($expectedPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe updater runtime snapshot cleanup path: $resolvedSnapshotRoot"
        }
        $snapshotItem = Get-Item -Force -LiteralPath $resolvedSnapshotRoot
        if (($snapshotItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe reparse-backed updater runtime snapshot cleanup path: $resolvedSnapshotRoot"
        }
        Remove-Item -LiteralPath $resolvedSnapshotRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
