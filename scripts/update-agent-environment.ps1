[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $CodexHome,
    [string] $UserHome,
    [switch] $Apply,
    [switch] $VerifyOnly,
    [switch] $ForceReinstallManagedSkills,
    [switch] $MigrateLegacyCatalogSkills,
    [switch] $Recover,
    [ValidateSet('Text','Json')][string] $OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:agentEnvironmentRuntimeReadLock = $null
$script:agentEnvironmentRecoveryStarted = $false

function New-AgentEnvironmentStableRecoveryFailureResult {
    param([Parameter(Mandatory = $true)][string] $Message)
    $journalPath = '.agents/update-agent-environment.recovery.json'
    $evidence = "Recovery validation failed; the retained journal '$journalPath' was not removed: $Message"
    return [pscustomobject][ordered]@{
        schemaVersion=1; outcome='failed'; exitCode=1; runtimeCommit=$null; catalogCommit=$null; catalogLockSha256=$null
        installed=@(); updated=@(); removed=@(); preserved=@(); failed=@($Message)
        failureDetails=@([pscustomobject][ordered]@{
            schemaVersion=1; code='recovery-required'; skillId='transaction'; path=$journalPath
            classification='controlled-candidate'; owner='transaction-journal'; evidence=$evidence
            destructiveChangeAllowed=$false; backupCreated=$false; expectedSha256=$null; actualSha256=$null
            remediation=@(
                'Inspect the retained recovery journal and transaction backup before retrying -Recover.',
                'Repair or restore valid recovery metadata; do not delete the journal or start another reconciliation while recovery is required.'
            )
        })
        ownership=@([pscustomobject][ordered]@{
            schemaVersion=1; skillId='transaction'; path=$journalPath; classification='controlled-candidate'
            owner='transaction-journal'; evidence='The retained recovery journal is the authoritative transaction record; recovery validation did not complete.'
            destructiveChangeAllowed=$false; operation='observe'
        })
        rollbackState='recovery-required'; backupPath=$null
    }
}

trap {
    $message = [string]$_.Exception.Message
    if ($null -ne $script:agentEnvironmentRuntimeReadLock) {
        try { $script:agentEnvironmentRuntimeReadLock.Dispose() }
        catch { }
        $script:agentEnvironmentRuntimeReadLock = $null
    }
    $failureResult = if ($Recover -and $script:agentEnvironmentRecoveryStarted) {
        New-AgentEnvironmentStableRecoveryFailureResult -Message $message
    }
    else {
        [pscustomobject][ordered]@{
            schemaVersion=1; outcome='failed'; exitCode=1; runtimeCommit=$null; catalogCommit=$null
            installed=@(); updated=@(); removed=@(); preserved=@(); failed=@($message)
            rollbackState='not-started'; backupPath=$null
        }
    }
    if ($OutputFormat -eq 'Json') {
        $failureResult | ConvertTo-Json -Depth 20 -Compress | Write-Output
    }
    else {
        Write-Output "Agent environment outcome: $($failureResult.outcome)"
        Write-Output "exitCode: $($failureResult.exitCode)"
        Write-Output "failed: $message"
        if ($Recover -and $script:agentEnvironmentRecoveryStarted) {
            foreach ($detail in @($failureResult.failureDetails)) {
                Write-Output ("Failure detail: {0} [{1}]" -f $detail.code, $detail.path)
            }
        }
    }
    exit 1
}

if (@(@($Apply,$VerifyOnly,$Recover) | Where-Object { [bool]$_ }).Count -ne 1) {
    throw 'Specify exactly one of -Apply, -VerifyOnly, or -Recover.'
}
if ($Recover -and ($ForceReinstallManagedSkills -or $MigrateLegacyCatalogSkills -or $WhatIfPreference)) {
    throw '-Recover cannot be combined with reconciliation or WhatIf switches.'
}
if ($VerifyOnly -and ($ForceReinstallManagedSkills -or $MigrateLegacyCatalogSkills -or $WhatIfPreference)) {
    throw '-VerifyOnly cannot be combined with mutation switches or -WhatIf.'
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
if ([string]::IsNullOrWhiteSpace($UserHome)) { $UserHome = $HOME }
$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd([char[]]@('\','/'))
$userHomePath = [System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\','/'))
$runtimeRoot = Join-Path $codexHomePath 'hooks/ai-instructions-runtime'
$launcher = Join-Path $codexHomePath 'hooks/bootstrap-ai-instructions.ps1'

function Open-AgentEnvironmentRuntimeReadLock {
    $installLockPath = Join-Path $codexHomePath 'ai-instructions-install.lock'
    if (-not (Test-Path -LiteralPath $installLockPath -PathType Leaf)) {
        throw 'AI instructions install lock is missing from the installed runtime.'
    }
    $installLockItem = Get-Item -Force -LiteralPath $installLockPath
    if ($installLockItem.PSIsContainer -or ($installLockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'AI instructions install lock must be a non-reparse file.'
    }
    try {
        return [System.IO.File]::Open(
            $installLockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
    }
    catch [System.IO.IOException] {
        throw 'AI instructions runtime is being installed; Agent environment update stopped before reading a mixed runtime.'
    }
}

function Write-AgentEnvironmentResult {
    param([Parameter(Mandatory = $true)][object] $Result)
    if ($OutputFormat -eq 'Json') { Write-Output ($Result | ConvertTo-Json -Depth 20 -Compress); return }
    Write-Output "Agent environment outcome: $($Result.outcome)"
    foreach ($name in @('exitCode','runtimeCommit','catalogCommit','installed','updated','removed','preserved','failed','rollbackState','backupPath')) {
        if ($null -eq $Result.PSObject.Properties[$name]) { continue }
        $value = $Result.$name
        if ($value -is [array]) { $value = @($value).Count }
        Write-Output ("{0}: {1}" -f $name,$value)
    }
    if ($null -ne $Result.PSObject.Properties['licenseWarnings']) {
        foreach ($warning in @($Result.licenseWarnings)) { Write-Output "License warning: $warning" }
    }
    if ($null -ne $Result.PSObject.Properties['failureDetails']) {
        foreach ($detail in @($Result.failureDetails)) {
            Write-Output ("Failure detail: {0} [{1}]" -f $detail.code, $detail.path)
        }
    }
}

$temporaryRoot = $null
$finalResult = $null
try {
    if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { throw "Installed AI instructions runtime is missing: $runtimeRoot" }
    $reconcilerPath = Join-Path $runtimeRoot 'agent-environment-reconciler.psm1'
    if (-not (Test-Path -LiteralPath $reconcilerPath -PathType Leaf)) { throw "Installed Agent environment reconciler is missing: $reconcilerPath" }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Installed AI instructions validation launcher is missing: $launcher" }

    $script:agentEnvironmentRuntimeReadLock = Open-AgentEnvironmentRuntimeReadLock
    & $launcher -ValidateOnly | Out-Null

    Remove-Module agent-environment-reconciler -Force -ErrorAction SilentlyContinue
    Import-Module $reconcilerPath -Force

    if ($Recover) {
        $script:agentEnvironmentRecoveryStarted = $true
        $finalResult = Invoke-UserSkillsRecovery -UserHome $userHomePath
    }
    else {
        $configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
        $bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
        try {
            $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
            $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
        }
        catch { throw "Installed Agent environment state is invalid: $($_.Exception.Message)" }
        if ([string]$configuration.catalog.ref -cne [string]$bundle.commit) { throw 'Installed Catalog configuration and runtime bundle commit do not match.' }

        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-environment-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        $desiredState = Get-UserSkillsDesiredState -RuntimeRoot $runtimeRoot -Configuration $configuration `
            -CatalogRepository ([string]$bundle.repository) -CatalogCommit ([string]$bundle.commit) -WorkingRoot $temporaryRoot
        $mode = if ($VerifyOnly) { 'VerifyOnly' } elseif ($WhatIfPreference) { 'WhatIf' } else { 'Apply' }
        $finalResult = Invoke-UserSkillsReconciliation -DesiredState $desiredState -UserHome $userHomePath -Mode $mode `
            -ForceReinstallManagedSkills:$ForceReinstallManagedSkills -MigrateLegacyCatalogSkills:$MigrateLegacyCatalogSkills
        $finalResult | Add-Member -NotePropertyName runtimeCommit -NotePropertyValue ([string]$bundle.commit) -Force
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($temporaryRoot) -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        $resolved = [System.IO.Path]::GetFullPath($temporaryRoot)
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
        if ($resolved.StartsWith($temp + [System.IO.Path]::DirectorySeparatorChar + 'agent-environment-',[System.StringComparison]::OrdinalIgnoreCase)) {
            $item = Get-Item -Force -LiteralPath $resolved
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($null -ne $script:agentEnvironmentRuntimeReadLock) {
        $script:agentEnvironmentRuntimeReadLock.Dispose()
        $script:agentEnvironmentRuntimeReadLock = $null
    }
}

Write-AgentEnvironmentResult -Result $finalResult
exit [int]$finalResult.exitCode
