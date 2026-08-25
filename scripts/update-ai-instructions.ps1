[CmdletBinding()]
param(
    [string] $CodexHome,
    [switch] $ForceCheck,
    [switch] $InstallApproved,
    [switch] $RecoverInterruptedInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RecoverInterruptedInstall -and ($ForceCheck -or $InstallApproved)) {
    throw 'RecoverInterruptedInstall cannot be combined with update-check or installation switches.'
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
        if (-not (Test-Path -LiteralPath $installedLauncher -PathType Leaf)) { throw "Installed AI instructions preflight launcher is missing: $installedLauncher" }
        if ($RecoverInterruptedInstall) {
            & $installedLauncher -RecoverInterruptedInstall
            return
        }

        $installLockPath = Join-Path ([System.IO.Path]::GetFullPath($CodexHome)) 'ai-instructions-install.lock'
        if (-not (Test-Path -LiteralPath $installLockPath -PathType Leaf)) { throw 'AI instructions install lock is missing from the installed runtime.' }
        $installLockItem = Get-Item -Force -LiteralPath $installLockPath
        if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'AI instructions install lock must be a non-reparse file.'
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
                throw 'AI instructions runtime is being installed; updater stopped before reading a mixed runtime.'
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
            throw 'RecoverInterruptedInstall is available only from a verified installed AI instructions runtime.'
        }
        if ($isInstalledStableEntryPoint) {
            throw "Installed updater module is missing or invalid: $installedModule"
        }
        $modulePath = Join-Path $PSScriptRoot 'ai-instructions-updater.psm1'
    }
    Import-Module $modulePath -Force

    $result = Invoke-AiInstructionsUpdateWorkflow -CodexHome $CodexHome -ForceCheck:$ForceCheck -InstallApproved:$InstallApproved
    Write-Output "AI instructions update outcome: $($result.outcome). $($result.message)"
    if ([string]$result.outcome -in @('failed','drift','concurrent')) {
        throw "AI instructions update stopped: $($result.message)"
    }
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
