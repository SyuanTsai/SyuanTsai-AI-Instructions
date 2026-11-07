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
$script:agentEnvironmentTrustedReadLease = $null
$script:agentEnvironmentRecoveryStarted = $false
$script:agentEnvironmentRefusalCodes = @(
    'capability-unavailable','platform-mismatch','downgrade-refused','mixed-generation','unsupported-version',
    'closure-invalid','interrupted-install','projection-runtime-unavailable','runtime-baseline-unavailable'
)

function Get-AgentEnvironmentRefusalCode {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $ErrorRecordOrException)
    $candidate = $ErrorRecordOrException
    if ($candidate -is [Management.Automation.ErrorRecord]) { $candidate = $candidate.Exception }
    while ($candidate -is [Exception]) {
        if ($null -ne $candidate.PSObject.Properties['Code'] -and [string]$candidate.Code -cin $script:agentEnvironmentRefusalCodes) { return [string]$candidate.Code }
        if ($candidate.Data.Contains('Code') -and [string]$candidate.Data['Code'] -cin $script:agentEnvironmentRefusalCodes) { return [string]$candidate.Data['Code'] }
        $candidate = $candidate.InnerException
    }
    $matches = [regex]::Matches([string]$ErrorRecordOrException,'\[ai-instructions-refusal-code=([^\]\r\n]*)\]')
    if ($matches.Count -gt 0) {
        $code = $matches[$matches.Count - 1].Groups[1].Value
        if ($code -cin $script:agentEnvironmentRefusalCodes) { return $code }
    }
    return $null
}

function New-AgentEnvironmentStableRecoveryFailureResult {
    param([Parameter(Mandatory = $true)][string] $Message,[AllowNull()][string]$Code=$null)
    $journalPath = '.agents/update-agent-environment.recovery.json'
    $evidence = "Recovery validation failed; the retained journal '$journalPath' was not removed: $Message"
    return [pscustomobject][ordered]@{
        schemaVersion=1; outcome='failed'; exitCode=1; Code=$Code; runtimeCommit=$null; catalogCommit=$null; catalogLockSha256=$null
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

function New-AgentEnvironmentEntryRefusalException {
    param([Parameter(Mandatory=$true)][string]$Code,[Parameter(Mandatory=$true)][string]$Message)
    $exception=[InvalidOperationException]::new("$Message [ai-instructions-refusal-code=$Code]")
    $exception.Data['Code']=$Code
    return $exception
}

function Get-AgentEnvironmentEntrySchemaVersion {
    param([AllowNull()][object]$Document)
    if($null-eq$Document-or$null-eq$Document.PSObject.Properties['schemaVersion']){return $null}
    $value=$Document.schemaVersion
    if($value-isnot[int]-and$value-isnot[long]){return $null}
    return [int64]$value
}

function Assert-AgentEnvironmentEntryGenerationPair {
    param([AllowNull()][object]$Configuration,[AllowNull()][object]$Bundle)
    # P7e integration point: replace this minimal D11 pair gate with the verified
    # reader/baseline/closure/platform gate once that runtime is production-pinned.
    $configurationVersion=Get-AgentEnvironmentEntrySchemaVersion $Configuration
    $bundleVersion=Get-AgentEnvironmentEntrySchemaVersion $Bundle
    if($null-eq$configurationVersion-or$null-eq$bundleVersion-or$configurationVersion-notin@(4,5)-or$bundleVersion-notin@(2,3)){
        throw (New-AgentEnvironmentEntryRefusalException -Code 'unsupported-version' -Message 'Installed Agent environment configuration or runtime bundle version is missing or unsupported.')
    }
    if(($configurationVersion-eq5)-xor($bundleVersion-eq3)){
        throw (New-AgentEnvironmentEntryRefusalException -Code 'mixed-generation' -Message 'Installed Agent environment configuration and runtime bundle are from mixed generations.')
    }
    if($configurationVersion-eq5-and$bundleVersion-eq3){
        throw (New-AgentEnvironmentEntryRefusalException -Code 'projection-runtime-unavailable' -Message 'Projection-aware production runtime is unavailable until the P7e gate and production pins are installed.')
    }
}

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

function Close-AgentEnvironmentEntryReadLeases {
    $firstFailure=$null
    if($null-ne$script:agentEnvironmentTrustedReadLease){
        try{$script:agentEnvironmentTrustedReadLease.Dispose()}
        catch{$firstFailure=$_}
        finally{$script:agentEnvironmentTrustedReadLease=$null}
    }
    if($null-ne$script:agentEnvironmentRuntimeReadLock){
        try{$script:agentEnvironmentRuntimeReadLock.Dispose()}
        catch{if($null-eq$firstFailure){$firstFailure=$_}}
        finally{$script:agentEnvironmentRuntimeReadLock=$null}
    }
    if($null-ne$firstFailure){throw $firstFailure}
}

trap {
    $message = [string]$_.Exception.Message
    $refusalCode = Get-AgentEnvironmentRefusalCode $_
    try{Close-AgentEnvironmentEntryReadLeases}catch{}
    $failureResult = if ($Recover -and $script:agentEnvironmentRecoveryStarted) {
        New-AgentEnvironmentStableRecoveryFailureResult -Message $message -Code $refusalCode
    }
    else {
        [pscustomobject][ordered]@{
            schemaVersion=1; outcome='failed'; exitCode=1; Code=$refusalCode; runtimeCommit=$null; catalogCommit=$null
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
        if(-not[string]::IsNullOrEmpty($refusalCode)){Write-Output "Code: $refusalCode"}
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
$configurationPath = Join-Path $codexHomePath 'ai-instructions-sync.json'
$bundlePath = Join-Path $runtimeRoot 'runtime-bundle.json'
$configuration=$null;$bundle=$null

function Write-AgentEnvironmentResult {
    param([Parameter(Mandatory = $true)][object] $Result)
    $closedCode=$null
    if($null-ne$Result.PSObject.Properties['Code'] -and [string]$Result.Code -cin $script:agentEnvironmentRefusalCodes){$closedCode=[string]$Result.Code}
    if($null-ne$Result.PSObject.Properties['Code']){$Result.Code=$closedCode}
    elseif($null-ne$closedCode){$Result|Add-Member -NotePropertyName Code -NotePropertyValue $closedCode}
    if ($OutputFormat -eq 'Json') { Write-Output ($Result | ConvertTo-Json -Depth 20 -Compress); return }
    Write-Output "Agent environment outcome: $($Result.outcome)"
    if($null-ne$Result.PSObject.Properties['Code']-and-not[string]::IsNullOrEmpty([string]$Result.Code)){Write-Output "Code: $($Result.Code)"}
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
$reconcilerCommands = @{}
try {
    $script:agentEnvironmentRuntimeReadLock = Open-AgentEnvironmentRuntimeReadLock
    if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { throw "Installed AI instructions runtime is missing: $runtimeRoot" }
    $reconcilerPath = Join-Path $runtimeRoot 'agent-environment-reconciler.psm1'
    if (-not (Test-Path -LiteralPath $reconcilerPath -PathType Leaf)) { throw "Installed Agent environment reconciler is missing: $reconcilerPath" }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Installed AI instructions validation launcher is missing: $launcher" }

    if(-not$Recover){
        try{
            if(Test-Path -LiteralPath $configurationPath -PathType Leaf){$configuration=Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json}
            if(Test-Path -LiteralPath $bundlePath -PathType Leaf){$bundle=Get-Content -Raw -Encoding UTF8 -LiteralPath $bundlePath|ConvertFrom-Json}
        }
        catch{throw (New-AgentEnvironmentEntryRefusalException -Code 'unsupported-version' -Message "Installed Agent environment generation metadata is invalid: $($_.Exception.Message)")}
        Assert-AgentEnvironmentEntryGenerationPair -Configuration $configuration -Bundle $bundle
    }
    & $launcher -ValidateOnly | Out-Null

    Remove-Module agent-environment-reconciler -Force -ErrorAction SilentlyContinue
    $reconcilerModule = @(Import-Module $reconcilerPath -Force -PassThru | Where-Object { [string]::Equals([IO.Path]::GetFullPath([string]$_.Path),[IO.Path]::GetFullPath($reconcilerPath),[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -Last 1
    foreach($commandName in @('Assert-UserProjectionRuntimeGate','Get-UserSkillsDesiredState','Invoke-UserSkillsReconciliation','Invoke-UserSkillsRecovery','New-AgentEnvironmentInstallReadLeaseEvidence')){
        $command=$reconcilerModule.ExportedCommands[$commandName]
        if($null-eq$command){throw "Installed Agent environment reconciler does not export '$commandName'."}
        $reconcilerCommands[$commandName]=$command
    }
    $command=$reconcilerCommands['New-AgentEnvironmentInstallReadLeaseEvidence']
    $script:agentEnvironmentTrustedReadLease = & $command -Lease $script:agentEnvironmentRuntimeReadLock

    if(-not$Recover-and($VerifyOnly-or$WhatIfPreference)){
        $command=$reconcilerCommands['Invoke-UserSkillsRecovery']
        $readOnlyMode=if($VerifyOnly){'VerifyOnly'}else{'WhatIf'}
        $residueResult=& $command -UserHome $userHomePath -InstallReadLease $script:agentEnvironmentTrustedReadLease -Mode $readOnlyMode
        if([string]$residueResult.outcome-cne'nothing-to-recover'){$finalResult=$residueResult}
    }

    if($null-eq$finalResult-and$Recover) {
        $script:agentEnvironmentRecoveryStarted = $true
        $command=$reconcilerCommands['Invoke-UserSkillsRecovery']
        $finalResult = & $command -UserHome $userHomePath -InstallReadLease $script:agentEnvironmentTrustedReadLease
    }
    elseif($null-eq$finalResult) {
        if ([string]$configuration.catalog.ref -cne [string]$bundle.commit) { throw 'Installed Catalog configuration and runtime bundle commit do not match.' }
        $catalogVersion=(Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog.json')|ConvertFrom-Json).schemaVersion
        $lockVersion=(Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $runtimeRoot 'catalog/skills-catalog-lock.json')|ConvertFrom-Json).schemaVersion
        if([int64]$catalogVersion-eq3-or[int64]$lockVersion-eq3){$command=$reconcilerCommands['Assert-UserProjectionRuntimeGate'];& $command -RuntimeRoot $runtimeRoot}

        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-environment-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        $command=$reconcilerCommands['Get-UserSkillsDesiredState']
        $desiredState = & $command -RuntimeRoot $runtimeRoot -Configuration $configuration `
            -CatalogRepository ([string]$bundle.repository) -CatalogCommit ([string]$bundle.commit) -WorkingRoot $temporaryRoot
        $mode = if ($VerifyOnly) { 'VerifyOnly' } elseif ($WhatIfPreference) { 'WhatIf' } else { 'Apply' }
        $command=$reconcilerCommands['Invoke-UserSkillsReconciliation']
        $finalResult = & $command -DesiredState $desiredState -UserHome $userHomePath -Mode $mode `
            -ForceReinstallManagedSkills:$ForceReinstallManagedSkills -MigrateLegacyCatalogSkills:$MigrateLegacyCatalogSkills `
            -InstallReadLease $script:agentEnvironmentTrustedReadLease
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
    Close-AgentEnvironmentEntryReadLeases
}

Write-AgentEnvironmentResult -Result $finalResult
exit [int]$finalResult.exitCode
