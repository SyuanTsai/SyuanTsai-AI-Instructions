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

trap {
    $message = [string]$_.Exception.Message
    $global:LASTEXITCODE = 1
    if ($OutputFormat -eq 'Json') {
        [pscustomobject][ordered]@{
            schemaVersion=1; outcome='failed'; exitCode=1; runtimeCommit=$null; catalogCommit=$null
            installed=@(); updated=@(); removed=@(); preserved=@(); failed=@($message)
            rollbackState='not-started'; backupPath=$null
        } | ConvertTo-Json -Depth 20 -Compress | Write-Output
    }
    else {
        Write-Output 'Agent environment outcome: failed'
        Write-Output 'exitCode: 1'
        Write-Output "failed: $message"
    }
    return
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
$runtimeUpdater = Join-Path $codexHomePath 'hooks/update-ai-instructions.ps1'

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
}

if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { throw "Installed AI instructions runtime is missing: $runtimeRoot" }
$reconcilerPath = Join-Path $runtimeRoot 'agent-environment-reconciler.psm1'
if (-not (Test-Path -LiteralPath $reconcilerPath -PathType Leaf)) { throw "Installed Agent environment reconciler is missing: $reconcilerPath" }
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Installed AI instructions validation launcher is missing: $launcher" }
& $launcher -ValidateOnly | Out-Null
Import-Module $reconcilerPath -Force

if ($Recover) {
    $recoveryResult = Invoke-UserSkillsRecovery -UserHome $userHomePath
    Write-AgentEnvironmentResult -Result $recoveryResult
    $global:LASTEXITCODE = [int]$recoveryResult.exitCode
    return
}

if ($Apply -and -not $WhatIfPreference) {
    if (-not (Test-Path -LiteralPath $runtimeUpdater -PathType Leaf)) { throw "Installed AI instructions updater is missing: $runtimeUpdater" }
    & $runtimeUpdater -CodexHome $codexHomePath -ForceCheck -InstallApproved | Out-Null
    & $launcher -ValidateOnly | Out-Null
    Remove-Module agent-environment-reconciler -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Force
}

$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
$bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
try {
    $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath | ConvertFrom-Json
    $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath | ConvertFrom-Json
}
catch { throw "Installed Agent environment state is invalid: $($_.Exception.Message)" }
if ([string]$configuration.catalog.ref -cne [string]$bundle.commit) { throw 'Installed Catalog configuration and runtime bundle commit do not match.' }

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-environment-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $desiredState = Get-UserSkillsDesiredState -RuntimeRoot $runtimeRoot -Configuration $configuration `
        -CatalogRepository ([string]$bundle.repository) -CatalogCommit ([string]$bundle.commit) -WorkingRoot $temporaryRoot
    $mode = if ($VerifyOnly) { 'VerifyOnly' } elseif ($WhatIfPreference) { 'WhatIf' } else { 'Apply' }
    $result = Invoke-UserSkillsReconciliation -DesiredState $desiredState -UserHome $userHomePath -Mode $mode `
        -ForceReinstallManagedSkills:$ForceReinstallManagedSkills -MigrateLegacyCatalogSkills:$MigrateLegacyCatalogSkills
    $result | Add-Member -NotePropertyName runtimeCommit -NotePropertyValue ([string]$bundle.commit) -Force
    if ([string]$result.outcome -eq 'failed') { throw "Agent environment reconciliation failed: $(@($result.failed) -join ' | ')" }
    Write-AgentEnvironmentResult -Result $result
    $global:LASTEXITCODE = [int]$result.exitCode
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolved = [System.IO.Path]::GetFullPath($temporaryRoot)
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
        if ($resolved.StartsWith($temp + [System.IO.Path]::DirectorySeparatorChar + 'agent-environment-',[System.StringComparison]::OrdinalIgnoreCase)) {
            $item = Get-Item -Force -LiteralPath $resolved
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
